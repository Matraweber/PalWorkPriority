local path=TEST_ROOT..'/experiments/save_durability_barrier.lua'
local Barrier=dofile(path)
local function fixture(B)
    local ctx={scope='world:guild:priorities',session='session-1',guild='guild-1',
        camp='camp-1',incarnation='epoch-1',stream='priorities',authority=true}
    local b=B.new{enabled=true,context=ctx}
    assert(b:recover(ctx,{scope=ctx.scope,session=ctx.session,revision=0},false))
    local function accept(id,revision,baseline)
        local ticket=assert(b:stage(ctx,{baseline=baseline,request={peer='peer',client='client',
            id=id,command='Pal|1|'..id}}))
        assert(b:accept(ctx,ticket,{scope=ctx.scope,session=ctx.session,revision=revision}))
        return ticket
    end
    return b,ctx,accept
end
local function older_completion(B)
    local b,c,accept=fixture(B)
    local first=accept(1,1,true)
    local second=accept(2,2,false)
    assert(b:commit(c,{scope=c.scope,session=c.session,first=1,last=1}))
    assert(b:peek_ack(c,first,{peer='peer',client='client'}))
    assert(not b:peek_ack(c,second,{peer='peer',client='client'}),'older completion acknowledged newer edit')
    assert(not b:ready(c),'older durable generation opened required-generation barrier')
end
local function baseline_capture(B)
    local b,c,accept=fixture(B)
    accept(1,1,false)
    assert(b:commit(c,{scope=c.scope,session=c.session,first=1,last=1}))
    assert(not b:ready(c),'ordinary edit cannot establish missing baseline coverage')
end
local function staged_barrier(B)
    local b,c,accept=fixture(B)
    accept(1,1,true)
    assert(b:commit(c,{scope=c.scope,session=c.session,first=1,last=1}) and b:ready(c))
    assert(b:stage(c,{}))
    assert(not b:ready(c),'unsubmitted mutation must block native writes')
end
older_completion(Barrier);baseline_capture(Barrier);staged_barrier(Barrier)

-- A priorities commit cannot open a limits barrier or release its ACK.
do
    local b,c,accept=fixture(Barrier);local t=accept(1,1,true)
    assert(not b:commit(c,{scope='world:guild:limits',session=c.session,first=1,last=1}))
    assert(not b:ready(c) and not b:peek_ack(c,t,{peer='peer',client='client'}))
    for _,bad in ipairs({false,0,1025,math.huge,1.5}) do
        assert(not pcall(Barrier.new,{enabled=true,context=c,max_pending=bad}))
    end
end

local file=assert(io.open(path,'r'));local source=file:read('*a');file:close()
source=source:gsub('\r\n','\n')
local function mutant(old,new,test)
    local first,last=assert(source:find(old,1,true))
    assert(not source:find(old,last+1,true),'ambiguous mutation')
    local code=source:sub(1,first-1)..new..source:sub(last+1)
    local module=assert(load(code,'@'..path,'t',_ENV))()
    assert(not pcall(test,module),'unsafe barrier mutant survived')
end
mutant("if e.revision and e.revision<=durable then", "if e.revision and e.revision<=accepted then",older_completion)
mutant(' and durable>=accepted','',older_completion)
mutant('and camp.baseline and durable>=camp.baseline_required','and durable>=camp.baseline_required',baseline_capture)
mutant('return unstaged==0 and durable>=accepted','return durable>=accepted',staged_barrier)
print('durability barrier: cross-stream guard and four older-ACK/required-generation/baseline/staging mutants rejected')
