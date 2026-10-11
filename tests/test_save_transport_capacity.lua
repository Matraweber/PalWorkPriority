-- Terminal capacity is identity, not permission to consume an unreadable result.
local path=TEST_ROOT..'/experiments/save_transport.lua'
local Transport=dofile(path)
local DEFAULT,MAX=65536,262144
local A='PWP_SaveScratch_v1_A'
local function copy(t)
    local out={};for k,v in pairs(t) do out[k]=v end;return out
end
local function fixture(T,cap)
    local f={consumes=0,dispatches=0}
    local b={contract='PWP-SCOPED-DEV-1',max_payload_bytes=cap}
    b.dispatch=function(request)
        f.dispatches=f.dispatches+1
        f.expected=copy(request)
        f.request=request
        return true
    end
    b.peek=function(id)
        assert(id.max_payload_bytes==cap,'request mutation changed stored capacity')
        f.peek_identity=id
        return f.result
    end
    b.consume=function(id)
        assert(id.max_payload_bytes==cap and id.ticket==f.expected.ticket)
        f.consumes=f.consumes+1
        -- A backend must not be able to alter retained ownership via this copy.
        id.max_payload_bytes=1;id.ticket=999
        return not f.block_consume
    end
    f.adapter=T.new{enabled=true,storage=string.rep('1',32),guild=string.rep('a',32),
        stream='priorities',incarnation='boot',backend=b,max_payload_bytes=cap}
    function f:terminal()
        local r=copy(self.expected)
        r.terminal=true;r.success=false;r.read={status='missing'}
        return r
    end
    return f
end

local function wrong_terminal(T)
    for _,cap in ipairs({DEFAULT,MAX}) do
        for _,variant in ipairs({'wrong','missing','false','string','oversized'}) do
            if not (cap==DEFAULT and variant=='missing') then
                local f=fixture(T,cap);assert(f.adapter.start_read(A,1))
                f.result=f:terminal()
                local values={wrong=cap==MAX and DEFAULT or MAX,
                    ['false']=false,string=tostring(cap),oversized=MAX+1}
                f.result.max_payload_bytes=values[variant]
                assert(f.adapter.poll(1)==nil,'foreign terminal returned a result')
                assert(f.consumes==0,'foreign terminal was consumed')
                assert(f.adapter.start_read(A,2)==false and f.dispatches==1,
                    'foreign terminal released ownership')
                -- A later exact envelope must still resolve the original ticket.
                f.result=f:terminal()
                local done=assert(f.adapter.poll(1))
                assert(done.ticket==1 and f.consumes==1)
                assert(f.adapter.poll(1)==nil and f.consumes==1)
                assert(f.adapter.start_read(A,2) and f.dispatches==2)
            end
        end
    end
    local legacy=fixture(T,DEFAULT);assert(legacy.adapter.start_read(A,1))
    legacy.result=legacy:terminal();legacy.result.max_payload_bytes=nil
    assert(legacy.adapter.poll(1).ticket==1 and legacy.consumes==1)
end

local function request_mutation(T)
    local f=fixture(T,MAX);assert(f.adapter.start_read(A,1))
    f.request.max_payload_bytes=DEFAULT
    f.result=copy(f.request);f.result.terminal=true;f.result.success=false
    f.result.read={status='missing'}
    assert(f.adapter.poll(1)==nil and f.consumes==0)
    assert(f.adapter.start_read(A,2)==false and f.dispatches==1)
    -- Mutating the identity supplied to peek must not alter the captured owner.
    f.peek_identity.max_payload_bytes=DEFAULT
    f.peek_identity.ticket=999
    f.result=f:terminal();f.block_consume=true
    assert(f.adapter.poll(1)==nil and f.consumes==1)
    assert(f.adapter.start_read(A,2)==false)
    f.block_consume=false
    assert(f.adapter.poll(1).ticket==1 and f.consumes==2)
end
wrong_terminal(Transport)
request_mutation(Transport)

-- Execute mutants in memory only; never alter the source under test.
local file=assert(io.open(path,'r'));local source=file:read('*a');file:close()
source=source:gsub('\r\n','\n')
local function replace_once(text,old,new)
    local first,last=assert(text:find(old,1,true))
    assert(not text:find(old,last+1,true))
    return text:sub(1,first-1)..new..text:sub(last+1)
end
local function mutant(old,new,check)
    local text=replace_once(source,old,new)
    local module=assert(load(text,'@'..path,'t',_ENV))()
    assert(not pcall(check,module),'capacity/identity mutant survived')
end
mutant("\n        and (a.max_payload_bytes==b.max_payload_bytes\n            or (a.max_payload_bytes==nil and b.max_payload_bytes==65536))",'',wrong_terminal)
mutant('return {scope=op.scope,incarnation=op.incarnation,ticket=op.ticket,kind=op.kind,slot=op.slot,\n        max_payload_bytes=op.max_payload_bytes}',
    'return op',request_mutation)
print('transport capacity: terminal rejection before consume, legacy omission, copied identities, two mutants rejected')
