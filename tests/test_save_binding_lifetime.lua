-- Pure coordinator + actual Settings/Session/JournalQueue/Codec/Barrier.
-- Native journal completion and retire/release are injected, no engine or IO.
package.loaded.datafile={read=function() error('IO') end,write=function() error('IO') end}
package.loaded.log={warn=function() end,error=function() end}
local Lifetime=dofile(TEST_ROOT..'/experiments/save_binding_lifetime.lua')
local Settings=dofile(TEST_ROOT..'/experiments/settings_session.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local Store=require('store')
local W,G=string.rep('a',32),string.rep('b',32)
local function copy(t)
    if type(t)~='table' then return t end
    local r={};for k,v in pairs(t) do r[k]=copy(v) end;return r
end
local function ctx(epoch)
    return {scope=Scope.new(W,G,'priorities').key,storage=W,guild=G,stream='priorities',
        session='session-'..epoch,incarnation='boot:'..epoch,epoch=epoch,camp='A',authority=true}
end
local function fixture(unopened)
    local f={calls={},retired=false,released=false,updates={},consumes=0,context=ctx(1)}
    local c=f.context
    local codec=Codec.new{storage=W,guild=G,stream='priorities'}
    function f.body(n) return assert(Store.serialize_snapshot({pal={[1]=n}},true)) end
    f.slots={{status='valid',scope=c.scope,generation=7,payload=codec.encode(f.body(1))},{status='missing'}}
    f.token='initial'
    f.life=Lifetime.new{enabled=true,
        retire=function(id,old)
            assert(id==1 and old.session==c.session and old.epoch==1)
            assert(not f.op and #f.updates==(f.expected_updates or 2),'EARLY native retirement')
            assert(not f.retired);f.retired=true;f.calls[#f.calls+1]='retire'
            if f.on_retire then return f.on_retire() end
            return true
        end,
        release=function(id,old)
            assert(id==1 and old.session==c.session and f.retired and not f.released)
            f.released=true;f.calls[#f.calls+1]='release'
            if f.on_release then return f.on_release() end
            return true
        end}
    assert(f.life.track(1,c))
    local function admit(op)
        assert(not f.retired and not f.op,'reservation after retire/overlap')
        f.op=copy(op)
        if op.kind=='update' then f.updates[#f.updates+1]=copy(op) end
        if f.on_admit then f.on_admit() end
        return true
    end
    local backend={contract='PWP-JOURNAL-DEV-1',max_payload_bytes=65536,
        recover=admit,update=admit,
        peek=function(id)
            assert(f.op and id.ticket==f.op.ticket and id.incarnation==c.incarnation)
            if f.on_peek then f.on_peek() end
            return f.result
        end,
        consume=function(id)
            assert(f.op and f.result and f.result.certain and id.ticket==f.op.ticket)
            f.op,f.result=nil,nil;f.consumes=f.consumes+1;return true
        end}
    f.session=Settings.new{enabled=true,storage=W,guild=G,stream='priorities',session=c.session,
        incarnation=c.incarnation,epoch=c.epoch,backend_kind='PWP-JOURNAL-DEV-1',backend=backend,
        lease={},clock=function() return 0 end,authorize=function(a) return f.life.current(1,a) end}
    assert(f.life.attach(1,Lifetime.settings(f.session)))
    function f.complete(status)
        local op=assert(f.op);local r=copy(op);r.terminal=true;r.certain=status~='uncertain'
        if op.kind=='recover' then r.status='recovered';r.slots=copy(f.slots);r.preimages=f.token
        else
            r.status=status or 'updated'
            if r.status=='updated' then
                f.token='pair-'..op.ticket;r.preimages=f.token
                f.slots[op.journal_generation%2+1]={status='valid',scope=c.scope,
                    generation=op.journal_generation,payload=op.payload}
            end
        end
        f.result=r
    end
    if unopened then return f end
    assert(f.session:open(c));f.complete();assert(f.session:poll(c)=='recovered')
    assert(f.session:take_recovered(c));assert(f.session:register_camp(c,true))
    function f.edit(n)
        local t=assert(f.session:stage(c,{request={peer='peer',client='client',id=n,command='edit'}}))
        return t,assert(f.session:submit(c,t,f.body(n)))
    end
    return f
end

-- Attachment before session.open has no queue/reservations and is safely inert.
do
    local f=fixture(true);f.expected_updates=0
    assert(f.life.discard(1) and f.life.poll(1) and #f.calls==2)
    assert(not f.session:open(f.context))
end

-- Real accepted revision 1 plus coalesced 2/3. Native retirement must wait for
-- the second reservation AND its consumed completion, despite session revocation.
do
    local f=fixture();local t=f.edit(1);f.edit(2);f.edit(3)
    assert(#f.updates==1 and f.updates[1].covered_revision==1)
    assert(f.life.discard(1) and f.life.discard(1))
    assert(not f.life.current(1,f.context) and not f.retired)
    assert(not f.session:stage(f.context,{}) and not f.session:take_recovered(f.context))
    assert(not f.session:peek_ack(f.context,t,{peer='peer',client='client'}))
    assert(not f.life.poll(1) and not f.retired)
    local newer=ctx(2);assert(f.life.track(2,newer) and f.life.current(2,newer))
    assert(not f.life.current(2,f.context) and not f.life.current(1,newer))
    assert(not f.session:poll(newer) and not f.session:consume_ack(newer,t,{}))
    f.complete();assert(not f.life.poll(1) and not f.retired)
    assert(#f.updates==2 and f.updates[2].covered_revision==3)
    assert(f.updates[2].journal_generation==9 and f.updates[2].payload:find('pal|1|3',1,true))
    f.complete();assert(f.life.poll(1) and f.retired and f.released)
    assert(f.life.poll(1) and f.life.discard(1) and #f.calls==2)
    assert(f.life.status(1).state=='released' and f.life.current(2,newer))
    assert(not f.session:peek_ack(f.context,t,{peer='peer',client='client'}))
end

-- Definite IO failure or uncertainty must retain the original owner and tail;
-- repeated coordinator polls must not dispatch a retry, retire, or release.
for _,failure in ipairs({'io_error','uncertain'}) do
    local f=fixture();f.edit(1);f.edit(2);f.life.discard(1);f.complete(failure)
    for _=1,4 do assert(not f.life.poll(1)) end
    assert(not f.retired and #f.updates==1 and #f.calls==0)
    assert(not f.session:retry(ctx(2)))
end

-- Reentry during drain and native calls: nested polls cannot duplicate calls;
-- discards remain immediately effective, including another live binding.
do
    local f=fixture();f.edit(1);f.edit(2);f.life.discard(1)
    local newer=ctx(2);assert(f.life.track(2,newer))
    f.on_peek=function()
        assert(not f.life.poll(1));assert(f.life.discard(2));assert(not f.life.current(2,newer))
    end
    f.on_retire=function() assert(not f.life.poll(1));assert(f.life.discard(1));return true end
    f.on_release=function() assert(not f.life.poll(1));return true end
    f.complete();assert(not f.life.poll(1));f.complete();assert(f.life.poll(1))
    assert(#f.calls==2)
end

-- Discard inside admission revokes before the caller sees acceptance. A nested
-- drain sees settings_session's busy guard and defers without native retirement.
do
    local f=fixture();f.expected_updates=1
    f.on_admit=function()
        assert(f.life.discard(1));assert(not f.life.current(1,f.context))
        assert(not f.life.poll(1))
    end
    local t=assert(f.session:stage(f.context,{request={peer='p',client='c',id=1,command='x'}}))
    assert(not f.session:submit(f.context,t,f.body(2)))
    assert(f.life.status(1).state=='draining' and not f.retired)
    f.on_admit=nil;f.complete();assert(f.life.poll(1) and #f.calls==2)
end

-- Lost/ambiguous returns after native effects are terminal uncertainty. The
-- underlying bridge rejects duplicate 7/8, so even repeated discard must not retry.
for _,phase in ipairs({'retire','release'}) do
    for _,mode in ipairs({'throw','nil','false'}) do
        local f=fixture();f.expected_updates=0
        f['on_'..phase]=function()
            if mode=='throw' then error('return lost after effect') end
            if mode=='false' then return false end
        end
        assert(f.life.discard(1));assert(not f.life.poll(1))
        local count=#f.calls
        for _=1,3 do assert(f.life.discard(1));assert(not f.life.poll(1)) end
        assert(#f.calls==count and count==(phase=='retire' and 1 or 2))
        assert(f.life.status(1).state=='uncertain')
        assert(f.life.status(1).retired==(phase=='release'))
    end
end

-- Inert post-bind discard; scalar context and callbacks captured against caller
-- mutation. IDs stay burned after release and the lifetime count is bounded.
do
    local seen={};local original=ctx(1)
    local o={enabled=true,limit=1,
        retire=function(id,c) assert(id==7 and c.session=='session-1');c.session='mutated';seen[#seen+1]=7;return true end,
        release=function(id,c) assert(id==7 and c.session=='session-1');seen[#seen+1]=8;return true end}
    local l=Lifetime.new(o);assert(l.track(7,original));original.session='other'
    o.retire=function() error('mutated options') end
    assert(not l.track(8,ctx(2)) and not l.track(7,ctx(1)))
    assert(not l.discard(99));assert(l.discard(7));assert(l.poll(7));assert(l.poll(7))
    assert(#seen==2 and not l.track(7,ctx(2)) and not l.track(8,ctx(2)))
end
for _,bad in ipairs({'close','poll','drained'}) do
    local calls=0
    local l=Lifetime.new{enabled=true,retire=function() calls=calls+1;return true end,release=function() calls=calls+1;return true end}
    local drain={close=function() return false end,poll=function() end,drained=function() return true end}
    drain[bad]=function() error('lost drain result') end
    assert(l.track(1,ctx(1)) and l.attach(1,drain));assert(l.discard(1))
    assert(not l.poll(1) and l.status(1).reason=='drain_uncertain' and calls==0)
    assert(not l.attach(1,drain) and not l.poll(1))
end
print('binding lifetime: real coalesced drain, revocation, reentry, native lost returns, bounded inert cleanup PASS')
