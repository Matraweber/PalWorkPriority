-- Synthetic native contract only: no files, SHA implementation, worker or live admission.
package.loaded.datafile={read=function() error('unexpected IO') end,write=function() error('unexpected IO') end}
package.loaded.log={warn=function() error('unexpected log') end,error=function() error('unexpected log') end}
local Queue=dofile(TEST_ROOT..'/experiments/save_journal_queue.lua')
local Session=dofile(TEST_ROOT..'/experiments/save_session.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local Store,Caps=require('store'),require('caps')
local W,G=string.rep('a',32),string.rep('b',32)
local function copy(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t) do out[k]=copy(v) end;return out
end
local identity={'scope','incarnation','epoch','ticket','kind','max_payload_bytes'}
local function same(a,b)
    for _,k in ipairs(identity) do assert(a[k]==b[k],'backend identity mismatch: '..k) end
end
local function missing() return {status='missing'} end
local function fixture(slots,stream)
    stream=stream or 'priorities'
    local s={calls={},consumed=0,peeks=0,slots=copy(slots or {missing(),missing()}),token='pair-0',serial=0}
    s.scope=Scope.new(W,G,stream).key
    s.codec=Codec.new{storage=W,guild=G,stream=stream}
    function s.payload(n)
        local body=stream=='priorities' and Store.serialize_snapshot({pal={[1]=n or false}},true)
            or Caps.serialize_snapshot({[G]={Mining={Stone=n or false}}})
        return assert(s.codec.encode(body))
    end
    function s.valid(n,payload) return {status='valid',scope=s.scope,generation=n,payload=payload or s.payload(1)} end
    local function admit(op)
        assert(not s.native_retired,'native owner cannot reserve after retirement')
        assert(not s.pending,'overlapping reservation')
        assert(op.ticket>(s.high or 0));s.high=op.ticket
        s.calls[#s.calls+1]=copy(op)
        if s.reject then return false end
        s.pending=copy(op)
        if s.on_admit then s.on_admit(op) end
        if s.throw_dispatch then error('dispatch outcome unknown') end
        if s.ambiguous then return nil end
        return true
    end
    s.backend={contract='PWP-JOURNAL-DEV-1',max_payload_bytes=65536,
        recover=function(op) assert(op.kind=='recover');return admit(op) end,
        update=function(op)
            assert(op.kind=='update' and op.preimages==s.token)
            local highest=0
            for _,r in ipairs(s.slots) do if r.status=='valid' then highest=math.max(highest,r.generation) end end
            assert(op.journal_generation==highest+1,'physical generation must be consecutive')
            assert(op.initialize==(highest==0),'initialization must be explicit')
            assert(s.codec.supported(op.payload))
            return admit(op)
        end,
        peek=function(op)
            s.peeks=s.peeks+1;assert(s.pending);same(op,s.pending)
            if s.throw_peek then error('peek failed') end
            return s.result
        end,
        consume=function(op)
            assert(s.pending);same(op,s.pending);same(op,s.result)
            assert(s.result.certain==true,'uncertain owner must remain reserved')
            if s.throw_consume then error('consume failed') end
            if s.reject_consume then return false end
            s.consumed=s.consumed+1;s.pending=nil;s.result=nil
            return true
        end}
    s.options={enabled=true,storage=W,guild=G,stream=stream,incarnation='boot:1',epoch=7,backend=s.backend}
    s.q=Queue.new(s.options)
    function s.finish(status)
        assert(s.pending)
        local op=s.pending
        local result={terminal=true,certain=true}
        for _,k in ipairs(identity) do result[k]=op[k] end
        if op.kind=='recover' then
            result.status='recovered';result.slots=copy(s.slots);result.preimages=s.token
        else
            result.status=status or (op.initialize and 'initialized' or 'updated')
            if result.status=='updated' or result.status=='initialized' then
                local a,b=s.slots[1],s.slots[2]
                local active=a.status=='valid' and 1 or b.status=='valid' and 2 or nil
                if a.status=='valid' and b.status=='valid' and b.generation>a.generation then active=2 end
                s.slots[active==1 and 2 or 1]=s.valid(op.journal_generation,op.payload)
                s.serial=s.serial+1;s.token='pair-'..s.serial
                result.preimages=s.token
                result.journal_generation=op.journal_generation
                result.covered_revision=op.covered_revision
            end
        end
        if status=='uncertain' then result.status=status;result.certain=false end
        s.result=result;return result
    end
    function s.recover()
        assert(s.q:recover());s.finish();return s.q:poll()
    end
    function s.seed(n)
        s.slots={s.valid(n or 5),missing()}
        local ok,payload=s.recover();assert(ok and payload==s.payload(1))
        assert(s.q.generation==0 and s.q.saved==0 and s.q.journal_generation==(n or 5))
    end
    return s
end

-- Explicit initialization, immutable coalescing and independent counters.
local s=fixture();assert(#s.calls==0)
assert(not s.q:can_initialize())
assert(s.recover()==false and s.q.error=='explicit initialization required')
assert(s.q:can_initialize())
assert(not pcall(s.q.submit,s.q,s.payload(1)) and #s.calls==1)
assert(s.q:initialize(s.payload(1))==1)
assert(s.q:submit(s.payload(2))==2 and s.q:submit(s.payload(3))==3)
assert(#s.calls==2 and s.calls[2].payload==s.payload(1))
s.finish();local initialized,initial_payload=s.q:poll()
assert(initialized==true and initial_payload==s.payload(1) and not s.q:can_initialize())
assert(s.q.saved==1 and s.q.generation==3 and s.q.state=='saving')
assert(#s.calls==3 and s.calls[3].journal_generation==2 and s.calls[3].covered_revision==3)
assert(s.calls[3].payload==s.payload(3) and not s.calls[3].initialize)
assert(not s.q:can_shutdown())
s.finish();assert(s.q:poll()==nil,'initialization event must not repeat for an update')
assert(s.q.saved==3 and s.q.journal_generation==2 and s.q:can_shutdown())
assert(s.q.state=='saved' and not pcall(s.q.initialize,s.q,s.payload(4)))
-- Missing proof and initialized activation both wait for exact mailbox consumption.
s=fixture();assert(s.q:recover());s.finish();s.reject_consume=true;s.q:poll()
assert(not s.q:can_initialize() and not pcall(s.q.initialize,s.q,s.payload(1)))
s.reject_consume=false;s.q:poll();assert(s.q:can_initialize())
s.reject=true;assert(s.q:initialize(s.payload(1))==1 and not s.q:can_initialize())
assert(s.q:poll()==nil and not pcall(s.q.initialize,s.q,s.payload(2)))
s.reject=false;assert(s.q:retry());assert(s.pending.payload==s.payload(1))
s.finish();s.reject_consume=true;assert(s.q:poll()==nil and s.q.saved==0)
s.reject_consume=false;local done,original=s.q:poll()
assert(done and original==s.payload(1) and s.q.saved==1 and s.q:poll()==nil)

-- Construction never negotiates an implicit upgrade or accepts the old slot API.
for _,change in ipairs({
    function(o) o.enabled=false end,
    function(o) o.epoch=0 end,
    function(o) o.max_payload_bytes=false end,
    function(o) o.max_payload_bytes=262145 end,
    function(o) o.backend.contract='PWP-SCOPED-DEV-1' end,
    function(o) o.backend.max_payload_bytes=262144 end,
    function(o) o.backend.consume=nil end,
}) do
    s=fixture();change(s.options)
    assert(not pcall(Queue.new,s.options) and #s.calls==0)
end
-- Recovered limits retain OFF rather than confusing false with absence.
s=fixture(nil,'limits');s.slots={s.valid(4,s.payload(false)),missing()}
local ok,payload=s.recover();assert(ok and s.codec.decode(payload).data[G].Mining.Stone==false)
-- No pending/absent result frees the owner or permits an overlapping recovery.
s=fixture();assert(s.q:recover());s.q:poll()
assert(s.consumed==0 and not s.q:can_shutdown() and not pcall(s.q.recover,s.q))
s.finish();s.q:poll();assert(not s.q:retry())

-- Both integrity-valid candidates are semantically checked, in either order.
for _,stream in ipairs({'priorities','limits'}) do
    for _,bad in ipairs({'future','foreign_payload','noncanonical','oversize'}) do
        for _,position in ipairs({1,2}) do
            s=fixture(nil,stream)
            local payload=s.payload(false)
            if bad=='future' then payload=payload:gsub('PWP%-SETTINGS%-1','PWP-SETTINGS-2',1)
            elseif bad=='foreign_payload' then payload=payload:gsub(W,string.rep('c',32),1)
            elseif bad=='noncanonical' then payload=payload..'junk'
            else payload=string.rep('x',65537) end
            s.slots={s.valid(8),s.valid(9)};s.slots[position]=s.valid(position==1 and 8 or 9,payload)
            assert(s.recover()==false and s.q.state=='error')
            assert(s.consumed==1 and #s.calls==1 and not s.q.recovered_payload)
            assert(not pcall(s.q.submit,s.q,s.payload(2)))
            assert(not pcall(s.q.initialize,s.q,s.payload(2)))
        end
    end
end
for _,blocked in ipairs({'unsupported','foreign','unreadable'}) do
    for _,position in ipairs({1,2}) do
        s=fixture();s.slots={s.valid(1),s.valid(2)};s.slots[position]={status=blocked}
        assert(s.recover()==false and s.q.state=='error' and #s.calls==1)
    end
end
for _,other in ipairs({'corrupt','missing'}) do
    for _,position in ipairs({1,2}) do
        s=fixture();s.slots={s.valid(6),s.valid(6)};s.slots[position]={status=other}
        assert(s.recover()==true and s.q.journal_generation==6)
    end
end
for _,slots in ipairs({{{status='corrupt'},missing()},{{status='corrupt'},{status='corrupt'}}}) do
    s=fixture(slots);assert(s.recover()==false)
    assert(not pcall(s.q.initialize,s.q,s.payload(1)))
end
s=fixture();s.slots={s.valid(3,s.payload(1)),s.valid(3,s.payload(2))}
assert(s.recover()==false and s.q.error=='conflicting generations')
s=fixture();s.slots={s.valid(3),s.valid(3)};assert(s.recover()==true)
s=fixture();s.slots={s.valid(1),{status='missing',payload=s.payload(2)}};assert(s.recover()==false)
s=fixture();s.slots={s.valid(1),s.valid(2)};s.slots[2].scope='foreign';assert(s.recover()==false)

-- No stale/cross-binding terminal can acknowledge a native reservation.
for _,field in ipairs(identity) do
    for _,kind in ipairs({'recover','update'}) do
        s=fixture()
        if kind=='recover' then assert(s.q:recover()) else s.seed();assert(s.q:submit(s.payload(2))==1) end
        local result=s.finish();local correct=copy(result)
        result[field]=type(result[field])=='number' and result[field]+1 or result[field]..'-stale'
        local consumed=s.consumed;s.q:poll()
        assert(s.consumed==consumed and not s.q:can_shutdown())
        s.result=correct;s.q:poll();assert(s.consumed==consumed+1)
    end
end
-- Wrong covered revision/generation and malformed terminals cannot mark saved.
for _,field in ipairs({'covered_revision','journal_generation','terminal','cleanup_error'}) do
    s=fixture();s.seed();s.q:submit(s.payload(2));local r=s.finish()
    r[field]=field=='terminal' and false or -1
    s.q:poll();assert(s.q.state=='uncertain' and s.q.saved==0 and s.consumed==1)
    assert(not s.q:retry() and not s.q:can_shutdown())
end

-- Native uncertainty stays owned even if a later peek advertises success.
s=fixture();s.seed();s.q:submit(s.payload(2));s.finish('uncertain');s.q:poll()
assert(s.q.state=='uncertain' and not s.q:retry() and s.consumed==1)
s.finish();s.q:poll();assert(s.q.saved==0 and s.consumed==1 and not s.q:can_shutdown())
-- A timer timeout alone is not native terminal uncertainty: exact late success resolves it.
s=fixture();s.seed();s.q:submit(s.payload(2));assert(s.q:timeout())
assert(not s.q:retry());s.finish();s.q:poll();assert(s.q.saved==1 and s.q:can_shutdown())
for _,fault in ipairs({'throw_dispatch','ambiguous'}) do
    s=fixture();s.seed();s[fault]=true;s.q:submit(s.payload(2))
    assert(s.q.state=='uncertain' and not s.q:retry() and not s.q:can_shutdown())
    s.finish();s.q:poll();assert(s.q.saved==1)
end
for _,status in ipairs({'conflict','io_error','cancelled-before-io'}) do
    s=fixture();s.seed();s.q:submit(s.payload(2));s.finish(status);s.q:poll()
    assert(s.q.state=='error' and s.q.saved==0 and not s.q:retry())
    assert(not s.q:can_shutdown() and #s.calls==2,'accepted work needs reconciliation, not a blind retry')
end
s=fixture();s.seed();s.reject=true;s.q:submit(s.payload(2))
assert(s.q.state=='error' and not s.q:can_shutdown())
s.reject=false;assert(s.q:retry());s.finish();s.q:poll();assert(s.q.saved==1)

-- Cleanup warnings never retry a successful publication.
s=fixture();s.seed();s.q:submit(s.payload(2));s.finish().cleanup_error=5;s.q:poll()
assert(s.q.saved==1 and s.q.state=='saved' and s.q.cleanup_error==5 and not s.q:retry())
assert(#s.calls==2)
-- Retain a copied terminal until consumption succeeds; no duplicate IO.
for _,fault in ipairs({'reject_consume','throw_consume','throw_peek'}) do
    s=fixture();s.seed();s.q:submit(s.payload(2));s.finish();s[fault]=true;s.q:poll()
    assert(s.q.saved==0 and s.consumed==1 and #s.calls==2)
    s[fault]=false;s.q:poll();assert(s.q.saved==1 and #s.calls==2)
end
s=fixture();s.seed();s.q:submit(s.payload(2));s.finish();s.reject_consume=true;s.q:poll()
s.result.covered_revision=999;s.reject_consume=false;s.q:poll();assert(s.q.saved==1)

-- Retire only Lua admission until the accepted tail drains through fresh reservations.
s=fixture();s.seed();s.q:submit(s.payload(2));s.q:submit(s.payload(3))
assert(not s.q:retire() and not pcall(s.q.submit,s.q,s.payload(4)))
s.finish();s.q:poll();assert(s.q.saved==1 and #s.calls==3 and not s.q:can_shutdown())
s.finish();s.q:poll();assert(s.q.saved==2 and s.q:can_shutdown())
s.native_retired=true -- SaveOwner::retire/release is now legal; no further dispatch.
assert(s.q:retire() and not s.q:retry());s.q:poll();assert(#s.calls==3)
s=fixture();s.seed();s.reject=true;s.q:submit(s.payload(2));assert(not s.q:retire())
s.reject=false;assert(s.q:retry());s.finish();s.q:poll();assert(s.q:can_shutdown())

-- Reentry and mutable backend/options cannot replace captured identity or payload.
s=fixture();s.seed()
s.on_admit=function(op)
    assert(s.q:poll()==nil);assert(s.q:submit(s.payload(5))==nil)
    op.payload='mutated request';op.scope='mutated scope'
end
s.options.incarnation='other';s.options.epoch=99;s.backend.update=function() error('replaced') end
assert(s.q:submit(s.payload(2))==1);s.finish();s.q:poll();assert(s.q.saved==1)
s=fixture();s.seed(2147483646);assert(not pcall(s.q.submit,s.q,s.payload(2)))

-- Actual save_session integration: logical receipts, coalesced committed prefixes,
-- recovered disk generation independent of edit revisions, and original-owner drain.
s=fixture();s.slots={s.valid(10),missing()}
local now=0
local controller=Session.new{enabled=true,lease={},clock=function() return now end,
    authorize=function(owner,token) return owner==s.scope and token=='boot:1' end,
    factory=function() return s.q end}
assert(controller:open(s.scope,'boot:1'));s.finish()
local recovered=controller:poll();assert(recovered.revision==0 and recovered.payload==s.payload(1))
local a=controller:submit('boot:1',s.payload(2))
local b=controller:submit('boot:1',s.payload(3))
local c=controller:submit('boot:1',s.payload(4))
assert(a.revision==1 and b.revision==2 and c.revision==3 and not controller:take_committed('boot:1'))
s.finish();controller:poll()
local event=controller:take_committed('boot:1');assert(event.first==1 and event.last==1)
assert(controller:status(a).state=='saved' and controller:status(c).state=='saving')
assert(s.calls[3].journal_generation==12 and s.calls[3].covered_revision==3)
s.finish();controller:poll();event=controller:take_committed('boot:1')
assert(event.first==2 and event.last==3 and not controller:take_committed('boot:1'))
assert(controller:status(b).state=='saved' and controller:status(c).state=='saved')
controller:submit('boot:1',s.payload(1));controller:submit('boot:1',s.payload(2))
assert(not controller:close('boot:1') and not controller:submit('boot:1',s.payload(3)))
s.finish();controller:poll();s.finish();controller:poll()
assert(controller:status().state=='closed' and not controller:take_committed('boot:1'))
print('journal queue: whole updates, codec recovery, logical/physical generations, coalescing, ownership and session receipts passed')
