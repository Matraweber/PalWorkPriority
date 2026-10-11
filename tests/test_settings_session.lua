-- Real Codec/Transport/Queue/Session/shared-stream Barrier; in-memory backend.
-- No production state installation, native calls or actual first initialization.
package.loaded.datafile={read=function() error('unexpected IO') end,write=function() error('unexpected IO') end}
package.loaded.log={warn=function() error('unexpected log') end,error=function() error('unexpected log') end}
local Store,Caps=require('store'),require('caps')
local store_data,caps_data,store_state,caps_state=Store.data,Caps.data,Store.state,Caps.state
local Factory=dofile(TEST_ROOT..'/experiments/settings_session.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local Read=dofile(TEST_ROOT..'/experiments/save_read.lua')
local W,G,H=string.rep('a',32),string.rep('b',32),string.rep('c',32)
local function copy(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t) do out[k]=copy(v) end;return out
end

local function record(owner,generation,payload)
    local text=string.format('PWP-SCRATCH-1:%d:%s:%d:%s',#owner,owner,generation,payload)
    local h=2166136261
    for i=1,#text do h=((h~text:byte(i))*16777619)&0xffffffff end
    return {session=owner,generation=generation,payload=payload,checksum=string.format('%08x',h)}
end
local function body(stream,n)
    if stream=='limits' then return assert(Caps.serialize_snapshot({[G]={Mining={Stone=false,Ore=n or 100}}})) end
    return assert(Store.serialize_snapshot({palA={[1]=false,[2]=n or 1},palB={[1]=3}},true))
end
local function fixture(options)
    options=options or {}
    local stream=options.stream or 'priorities'
    local max=options.max_payload_bytes or 65536
    local scope=Scope.new(W,G,stream)
    local codec=Codec.new{storage=W,guild=G,stream=stream,max_payload_bytes=max}
    local f={writes=0,dispatches=0,consumes=0,proofs=0,disk={},now=0}
    f.a={scope=scope.key,session='boot',incarnation='epoch-1',guild=G,camp='A',stream=stream,authority=true}
    f.b=copy(f.a);f.b.camp='B'
    f.codec,f.scope,f.max=codec,scope,max
    if not options.missing then f.disk[scope.a]=record(scope.key,7,assert(codec.encode(body(stream)))) end
    f.backend={contract='PWP-SCOPED-DEV-1',max_payload_bytes=max}
    f.backend.dispatch=function(op)
        assert(not f.op)
        f.op=copy(op);f.dispatches=f.dispatches+1
        if op.kind=='write' then f.writes=f.writes+1 end
        if f.on_dispatch then f.on_dispatch() end
        return true
    end
    f.backend.peek=function(id)
        if not f.ready then return end
        assert(f.op.ticket==id.ticket)
        local out=copy(f.op);out.terminal=true;out.success=not f.fail
        local r=f.disk[id.slot]
        out.read=r and Read.from_native(scope.key,{schema='PWP-SCRATCH-1',fields_read=true,
            max_payload_bytes=max,record=copy(r)},{max_payload_bytes=max}) or {status='missing'}
        return out
    end
    f.backend.consume=function(id)
        assert(f.op.ticket==id.ticket)
        f.op=nil;f.ready=false;f.consumes=f.consumes+1;return true
    end
    f.options={enabled=true,storage=W,guild=G,stream=stream,session='boot',incarnation='epoch-1',
        backend=f.backend,lease=options.lease or {},clock=function() return f.now end,max_payload_bytes=max,
        authorize=not options.no_authorize and function(c)
            f.proofs=f.proofs+1
            if f.on_authorize then f.on_authorize(c) end
            if f.throw_authorize then error('unavailable') end
            return not f.denied and c.scope==scope.key and c.guild==G and c.session=='boot'
        end or nil}
    if options.journal then
        f.a.epoch=7;f.b.epoch=7
        f.options.backend_kind='PWP-JOURNAL-DEV-1';f.options.epoch=7
        f.token='pair-0';f.history={}
        f.slots={{status='missing'},{status='missing'}}
        if not options.missing then
            f.slots[1]={status='valid',scope=scope.key,generation=7,payload=codec.encode(body(stream))}
        end
        local fields={'scope','incarnation','epoch','ticket','kind','max_payload_bytes'}
        local function same(a,b) for _,key in ipairs(fields) do assert(a[key]==b[key],key) end end
        local function admission(op)
            assert(not f.op and op.scope==scope.key and op.incarnation=='epoch-1' and op.epoch==7)
            assert(op.max_payload_bytes==max and not op.root and not op.path)
            f.dispatches=f.dispatches+1;f.history[#f.history+1]=copy(op)
            if f.reject then return false end
            f.op=copy(op)
            if op.kind=='update' then f.writes=f.writes+1 end
            if f.on_dispatch then f.on_dispatch() end
            return true
        end
        f.backend={contract='PWP-JOURNAL-DEV-1',max_payload_bytes=max,
            recover=function(op) assert(op.kind=='recover');return admission(op) end,
            update=function(op)
                assert(op.kind=='update' and op.preimages==f.token and codec.supported(op.payload))
                local generation=0
                for _,slot in ipairs(f.slots) do
                    if slot.status=='valid' then generation=math.max(generation,slot.generation) end
                end
                assert(op.journal_generation==generation+1 and op.initialize==(generation==0))
                return admission(op)
            end,
            peek=function(id)
                assert(f.op);same(f.op,id)
                return f.result
            end,
            consume=function(id)
                assert(f.op and f.result and f.result.certain);same(f.op,id);same(f.result,id)
                if f.on_consume then f.on_consume() end
                if f.hold_consume then return false end
                f.op,f.result,f.ready=nil,nil,false;f.consumes=f.consumes+1;return true
            end}
        f.options.backend=f.backend
        local authorize=f.options.authorize
        if authorize then f.options.authorize=function(c)
            assert(c.epoch==7 and c.incarnation=='epoch-1')
            return authorize(c)
        end end
    end
    f.session=Factory.new(f.options)
    function f:finish(c)
        assert(self.op)
        if options.journal then
            if not self.ready then
                local op=self.op
                local result=copy(op);result.terminal=true;result.certain=not self.uncertain
                if self.uncertain then result.status='uncertain'
                elseif self.fail then result.status='io_error'
                elseif op.kind=='recover' then
                    result.status='recovered';result.slots=copy(self.slots);result.preimages=self.token
                else
                    result.status=op.initialize and 'initialized' or 'updated'
                    local a,b=self.slots[1],self.slots[2]
                    local target=a.status=='valid' and 2 or 1
                    if b.status=='valid' and (a.status~='valid' or b.generation>a.generation) then target=1 end
                    self.slots[target]={status='valid',scope=scope.key,generation=op.journal_generation,payload=op.payload}
                    self.token='pair-'..op.ticket;result.preimages=self.token
                    result.cleanup_error=self.cleanup_error
                end
                self.result=result;self.ready=true
            end
            return self.session:poll(c or self.a)
        end
        if self.op.kind=='write' and not self.fail then self.disk[self.op.slot]=copy(self.op.record) end
        self.ready=true
        return self.session:poll(c or self.a)
    end
    function f:open()
        assert(self.session:open(self.a))
        if options.journal then assert(self:finish()=='recovered')
        else self:finish();assert(self:finish()=='recovered') end
        local restored=assert(self.session:take_recovered(self.a))
        assert(restored.revision==(options.journal and 0 or 7) and restored.settings.data)
        assert(self.session:take_recovered(self.a)==nil)
        assert(self.session:register_camp(self.a,true))
        assert(self.session:register_camp(self.b,true))
        return restored
    end
    return f
end
local route={peer='peer',client='connection-1'}
local function metadata(id,baseline)
    return {baseline=baseline,request={peer=route.peer,client=route.client,id=id,command='edit-'..id}}
end

-- No authorization, throws, or mutable options can silently enable IO.
do
    local f=fixture{no_authorize=true}
    f.options.authorize=function() return true end
    assert(f.session:open(f.a)==false and f.dispatches==0)
    assert(not f.session:retry(f.a) and f.dispatches==0)
    f=fixture();f.throw_authorize=true
    assert(f.session:open(f.a)==false and f.dispatches==0)
    f=fixture();local foreign=copy(f.a);foreign.guild=H
    assert(not f.session:open(foreign) and f.dispatches==0)
    f.backend.max_payload_bytes=262144
    assert(not pcall(Factory.new,f.options),'capacity mismatch must fail before IO')
end

-- A missing save is not a first-initialization authorization, even when the
-- fixture knows absence positively. Nothing may activate, stage, or write.
do
    local f=fixture{missing=true};assert(f.session:open(f.a));f:finish();f:finish()
    assert(f.session:status(f.a).state=='first initialization required')
    assert(not f.session:take_recovered(f.a) and not f.session:register_camp(f.a,true))
    assert(not f.session:stage(f.a,{}) and not f.session:ready(f.a) and f.writes==0)
    assert(not f.session:retry(f.a) and f.writes==0)
end

-- Mandatory semantic injection: checksum-valid raw/malformed/foreign typed
-- records cannot activate or fall back to an older valid slot, in either order.
for _,stream in ipairs({'priorities','limits'}) do
    for _,kind in ipairs({'raw','foreign-guild','foreign-storage','unknown-schema','malformed'}) do
        for _,reverse in ipairs({false,true}) do
            local f=fixture{stream=stream}
            local good=assert(f.codec.encode(body(stream)))
            local bad=kind=='raw' and body(stream)
                or kind=='foreign-guild' and good:gsub(G,H,1)
                or kind=='foreign-storage' and good:gsub(W,H,1)
                or kind=='unknown-schema' and good:gsub('PWP%-SETTINGS%-1','PWP-SETTINGS-2',1)
                or good..'bad'
            f.disk[f.scope.a]=record(f.scope.key,reverse and 8 or 7,reverse and bad or good)
            f.disk[f.scope.b]=record(f.scope.key,reverse and 7 or 8,reverse and good or bad)
            assert(f.session:open(f.a));f:finish()
            if f.op then f:finish() end
            assert(f.session:status(f.a).state=='error')
            assert(not f.session:take_recovered(f.a) and not f.session:ready(f.a))
            assert(not f.session:stage(f.a,{}) and f.writes==0)
            assert(not f.session:retry(f.a) and f.writes==0,'failed recovery is not accepted dirty data')
        end
    end
end

-- Shared camp ledger, typed recovery, no ACK on enqueue, and older completion.
for _,stream in ipairs({'priorities','limits'}) do
    local f=fixture{stream=stream};local s=f.session
    local restored=f:open()
    if stream=='priorities' then assert(restored.settings.data.palA[1]==false)
    else assert(restored.settings.data[G].Mining.Stone==false) end
    assert(s:ready(f.a) and s:ready(f.b))
    local t1=assert(s:stage(f.a,metadata(1)))
    assert(not s:ready(f.a) and not s:ready(f.b))
    assert(not s:submit(f.b,t1,body(stream,2)) and f.writes==0)
    assert(not s:submit(f.a,t1,'malformed') and f.writes==0)
    assert(not s:submit(f.a,t1,string.rep('x',65537)) and f.writes==0)
    local r1=assert(s:submit(f.a,t1,body(stream,2)))
    local t2=assert(s:stage(f.b,metadata(2)))
    local r2=assert(s:submit(f.b,t2,body(stream,3)))
    local t3=assert(s:stage(f.a,metadata(3)))
    local r3=assert(s:submit(f.a,t3,body(stream,4)))
    assert(r1.revision==8 and r2.revision==9 and r3.revision==10 and f.writes==1)
    assert(not s:peek_ack(f.a,t1,route) and not s:ready(f.a))
    assert(s:stage(f.a,metadata(3))==t3)
    assert(not s:submit(f.a,t3,body(stream,5)) and f.writes==1,'duplicate submission')
    f:finish(f.b)
    assert(s:peek_ack(f.a,t1,route).revision==8)
    assert(not s:peek_ack(f.b,t2,route) and not s:peek_ack(f.a,t3,route))
    assert(not s:ready(f.a) and f.writes==2)
    f:finish()
    assert(s:ready(f.a) and s:ready(f.b))
    assert(s:peek_ack(f.b,t2,route).camp=='B' and s:peek_ack(f.a,t3,route).revision==10)
    assert(not s:peek_ack(f.a,t2,route))
    assert(s:consume_ack(f.b,t2,route) and not s:peek_ack(f.b,t2,route))
    local final=assert(f.codec.decode(f.disk[f.scope.a].generation==10 and f.disk[f.scope.a].payload
        or f.disk[f.scope.b].payload))
    if stream=='priorities' then assert(final.data.palA[1]==false and final.data.palA[2]==4)
    else assert(final.data[G].Mining.Stone==false and final.data[G].Mining.Ore==4) end
end

-- Nested backend polling must not consume a completion before receipt admission.
do
    local f=fixture();f:open();local s=f.session
    local ticket=assert(s:stage(f.a,metadata(1)))
    f.on_dispatch=function()
        local value,why=s:poll(f.a);assert(value==nil and why=='busy')
        assert(not s:peek_ack(f.a,ticket,route))
        assert(not s:stage(f.b,metadata(2)))
    end
    local r=assert(s:submit(f.a,ticket,body('priorities',2)))
    assert(r.revision==8 and not s:peek_ack(f.a,ticket,route))
    f.on_dispatch=nil;f:finish();assert(s:peek_ack(f.a,ticket,route).revision==8)
end

-- Definite failure/retry and uncertain late completion cannot emit premature ACKs.
for _,uncertain in ipairs({false,true}) do
    local f=fixture();f:open();local s=f.session
    local t=assert(s:stage(f.b,metadata(1,true)))
    assert(s:submit(f.b,t,body('priorities',2)))
    if uncertain then
        f.now=11;s:poll(f.a)
        assert(s:status(f.b,t).state=='uncertain' and not s:retry(f.b))
    else
        f.fail=true;f:finish();assert(s:status(f.b,t).state=='error')
        f.fail=false;assert(s:retry(f.b))
    end
    assert(not s:ready(f.a) and not s:peek_ack(f.b,t,route))
    f:finish();assert(s:ready(f.a) and s:peek_ack(f.b,t,route))
end

-- Authority revoked inside dispatch: no receipt/activation/ACK escapes; original
-- session retains and drains accepted IO even after wrapper retirement.
do
    local f=fixture();f:open();local s=f.session
    local t=assert(s:stage(f.a,metadata(1)))
    f.on_dispatch=function() f.denied=true end
    assert(not s:submit(f.a,t,body('priorities',2)) and f.op)
    assert(not s:ready(f.a) and not s:peek_ack(f.a,t,route))
    f.fail=true;f:finish();assert(not f.op and f.consumes==3)
    -- Native acceptance preceded wrapper receipt registration/revocation. The
    -- queue's accepted data still needs drain even though submit returned nil.
    f.fail=false;assert(s:retry(f.a));f:finish()
    assert(not f.op and f.consumes==4 and f.options.lease.holder==nil)
    f.denied=false
    assert(not s:ready(f.a) and not s:open(f.a),'revocation must not resurrect an incarnation')
end
-- Negotiated large typed settings include envelope overhead and retain the real
-- 300-Pal snapshot through submit/readback and a fresh wrapper's read-only recovery.
do
    local rows={}
    for pal=1,300 do
        local key=string.format('%08d-1234567890-1234567890-1234567890',pal)
        rows[key]={}
        for work=1,14 do
            if work%6==0 then rows[key][work]=false else rows[key][work]=work%5+1 end
        end
    end
    local large=assert(Store.serialize_snapshot(rows,true));assert(#large==194799)
    local f=fixture{max_payload_bytes=262144};f:open()
    local t=assert(f.session:stage(f.a,metadata(1)))
    local accepted=assert(f.session:submit(f.a,t,large));assert(accepted.revision==8)
    assert(#f.op.record.payload>#large and not f.session:peek_ack(f.a,t,route))
    f:finish();assert(f.session:peek_ack(f.a,t,route).revision==8)
    assert(f.session:close(f.a))
    local fresh=fixture{max_payload_bytes=262144};fresh.disk=copy(f.disk)
    assert(fresh.session:open(fresh.a));fresh:finish();fresh:finish()
    local restored=assert(fresh.session:take_recovered(fresh.a))
    assert(restored.revision==8 and restored.settings.count==4200 and fresh.writes==0)
    assert(Store.serialize_snapshot(restored.settings.data,restored.settings.baseline)==large)
end

-- Revocation while the final recovery read is being consumed cannot expose a
-- decoded activation. Scope/stream/context cannot be switched on an open wrapper.
do
    local f=fixture();assert(f.session:open(f.a));f:finish()
    local consume=f.backend.consume
    f.backend.consume=function(id)
        local result=consume(id);f.denied=true;return result
    end
    f:finish()
    assert(not f.session:take_recovered(f.a) and not f.session:ready(f.a) and f.writes==0)
    local other=fixture();other:open()
    for _,field in ipairs({'scope','guild','stream','session','incarnation','authority'}) do
        local wrong=copy(other.a);wrong[field]=field=='authority' and false or 'other'
        assert(not other.session:ready(wrong) and not other.session:stage(wrong,{}))
    end
end
-- Retired accepted data retains its original lease after a definite failure.
-- Explicit retry must drain that data, without reviving admission or ACK routes.
for _,revoked in ipairs({false,true}) do
    for _,coalesced in ipairs({false,true}) do
        local f=fixture();f:open();local s=f.session
        local t=assert(s:stage(f.a,metadata(1)))
        local r=assert(s:submit(f.a,t,body('priorities',2)))
        local expected=2
        if coalesced then
            local t2=assert(s:stage(f.b,metadata(2)))
            r=assert(s:submit(f.b,t2,body('priorities',3)));expected=3
        end
        if revoked then f.denied=true;s:poll(f.a) else assert(not s:close(f.a)) end
        -- Pending/uncertain operations cannot be retried or lose their lease.
        assert(not s:retry(f.a) and f.writes==1)
        f.now=11;s:poll(f.a);assert(not s:retry(f.a) and f.writes==1)
        f.fail=true;f:finish();assert(not f.op and f.options.lease.holder)
        assert(s:status(f.a).drain_state=='closing')
        assert(not s:stage(f.a,metadata(3)) and not s:submit(f.a,t,body('priorities',4)))
        assert(not s:peek_ack(f.a,t,route) and not s:ready(f.a))
        for _,field in ipairs({'scope','guild','stream','session','incarnation'}) do
            local wrong=copy(f.a);wrong[field]='replacement'
            assert(not s:retry(wrong) and f.writes==1,'another incarnation may not retry this owner')
        end
        local replacement_options={}
        for k,v in pairs(f.options) do replacement_options[k]=v end
        replacement_options.session='next';replacement_options.incarnation='epoch-next'
        replacement_options.authorize=function() return true end
        local next_context=copy(f.a);next_context.session='next';next_context.incarnation='epoch-next'
        local contender=Factory.new(replacement_options)
        assert(not contender:open(next_context) and f.writes==1 and not f.op)
        -- RED before the fix: wrapper incorrectly applies current authority to
        -- the retired owner's existing drain obligation and refuses this retry.
        f.fail=false
        assert(s:retry(f.a),'retired accepted dirty data cannot be retried')
        assert(f.op and f.op.kind=='write' and f.op.incarnation=='boot')
        assert(f.op.record.generation==r.revision)
        assert(f.codec.decode(f.op.record.payload).data.palA[2]==expected)
        assert(not s:retry(f.a) and f.writes==2,'one explicit retry cannot duplicate in-flight IO')
        f:finish();assert(not f.op and f.options.lease.holder==nil)
        assert(s:status(f.a).drain_state=='closed')
        assert(not s:retry(f.a) and f.writes==2)
        assert(not s:peek_ack(f.a,t,route) and not s:ready(f.a))
        assert(not s:stage(f.a,metadata(4)) and not s:take_recovered(f.a))
        local replacement=Factory.new(replacement_options)
        assert(replacement:open(next_context),'drained old owner must release the shared lease')
        f:finish(next_context) -- old wrapper rejects the replacement context; no accidental consume
        assert(f.op,'only replacement wrapper may consume its recovery')
        replacement:poll(next_context)
        f.ready=true;replacement:poll(next_context)
        local recovered=assert(replacement:take_recovered(next_context))
        assert(recovered.revision==r.revision and recovered.settings.data.palA[2]==expected)
        assert(not s:retry(f.a) and f.writes==2)
    end
end
-- Whole-journal mode is opt-in: default contract and its missing-save refusal
-- above remain unchanged. Epoch/native incarnation never become caller paths.
do
    local f=fixture{journal=true,missing=true}
    f.options.backend_kind=nil;assert(not pcall(Factory.new,f.options))
    f.options.backend_kind='PWP-JOURNAL-DEV-1';f.options.epoch=nil
    assert(not pcall(Factory.new,f.options) and f.dispatches==0)
    f=fixture{journal=true,missing=true,no_authorize=true}
    assert(not f.session:open(f.a) and not f.session:initialize(f.a,body('priorities')) and f.writes==0)
    f=fixture{missing=true};assert(not f.session:initialize(f.a,body('priorities')) and f.writes==0)
end
for _,stream in ipairs({'priorities','limits'}) do
    local f=fixture{journal=true,missing=true,stream=stream};local s=f.session
    assert(not s:initialize(f.a,body(stream)) and f.writes==0)
    assert(s:open(f.a));assert(not s:initialize(f.a,body(stream)) and f.writes==0)
    assert(f:finish()=='initialization_required')
    assert(not s:take_recovered(f.a) and not s:register_camp(f.a,true) and not s:stage(f.a,{}))
    assert(not s:ready(f.a) and not s:retry(f.a))
    local wrong=copy(f.a);wrong.epoch=8
    assert(not s:initialize(wrong,body(stream)) and not s:initialize(f.a,'malformed') and f.writes==0)
    f.on_dispatch=function()
        local value,why=s:poll(f.a);assert(value==nil and why=='busy')
        assert(not s:initialize(f.a,body(stream,5)) and not s:close(f.a))
    end
    local initial=body(stream,2)
    local receipt=assert(s:initialize(f.a,initial))
    assert(receipt.revision==1 and receipt.session=='boot' and receipt.scope==f.scope.key)
    assert(s:status(f.a).state=='initializing' and not s:ready(f.a))
    assert(not s:initialize(f.a,body(stream,3)) and not s:take_recovered(f.a) and f.writes==1)
    f.on_dispatch=nil;f.cleanup_error=5;f.hold_consume=true;f:finish()
    assert(not s:take_recovered(f.a) and not s:ready(f.a) and f.consumes==1)
    f.hold_consume=false;assert(s:poll(f.a)=='recovered')
    local restored=assert(s:take_recovered(f.a));assert(restored.revision==1)
    local reserialized=stream=='priorities' and Store.serialize_snapshot(restored.settings.data,restored.settings.baseline)
        or Caps.serialize_snapshot(restored.settings.data)
    assert(reserialized==initial and not s:take_recovered(f.a))
    assert(not s:ready(f.a));assert(s:register_camp(f.a,true) and s:register_camp(f.b,true))
    assert(s:ready(f.a) and s:ready(f.b))
    -- Journal generation stays physical while Barrier receipts count all edits.
    local t1=assert(s:stage(f.a,metadata(1)))
    local r1=assert(s:submit(f.a,t1,body(stream,3)))
    local t2=assert(s:stage(f.b,metadata(2)))
    assert(s:submit(f.b,t2,body(stream,4)).revision==3)
    local t3=assert(s:stage(f.a,metadata(3)))
    assert(s:submit(f.a,t3,body(stream,5)).revision==4 and r1.revision==2)
    assert(not s:peek_ack(f.a,t1,route));f:finish()
    assert(s:peek_ack(f.a,t1,route).revision==2 and not s:peek_ack(f.b,t2,route))
    assert(f.op.journal_generation==3 and f.op.covered_revision==4 and not f.op.initialize)
    f:finish();assert(s:ready(f.a) and s:peek_ack(f.a,t3,route).revision==4)
end
-- Existing journal recovery activates without initialization and starts a fresh
-- logical receipt sequence, independently of persisted generation seven.
do
    local f=fixture{journal=true};f:open()
    assert(not f.session:initialize(f.a,body('priorities')) and f.writes==0)
    local t=assert(f.session:stage(f.a,metadata(1)))
    assert(f.session:submit(f.a,t,body('priorities',2)).revision==1)
    assert(f.op.journal_generation==8);f:finish();assert(f.session:peek_ack(f.a,t,route))
end
-- Unsupported/ambiguous recovery cannot be converted into initialization.
for _,state in ipairs({'corrupt','unsupported','foreign','unreadable'}) do
    local f=fixture{journal=true,missing=true};f.slots[2]={status=state}
    assert(f.session:open(f.a));f:finish()
    assert(not f.session:initialize(f.a,body('priorities')) and f.writes==0)
end
for _,when in ipairs({'before','dispatch','consume','close','rejected-close'}) do
    local f=fixture{journal=true,missing=true};local s=f.session
    assert(s:open(f.a));f:finish()
    if when=='before' then f.denied=true
    elseif when=='dispatch' then f.on_dispatch=function() f.denied=true end
    elseif when=='consume' then f.on_consume=function() f.denied=true end
    elseif when=='rejected-close' then f.reject=true end
    local receipt=s:initialize(f.a,body('priorities',2))
    if when=='before' then assert(not receipt and f.writes==0)
    else
        if when=='dispatch' then assert(not receipt and f.op) else assert(receipt) end
        if when=='close' or when=='rejected-close' then assert(not s:close(f.a)) end
        if when=='rejected-close' then
            assert(f.options.lease.holder and not f.op and f.writes==0)
            f.reject=false;assert(s:retry(f.a) and f.op.initialize)
        end
        f:finish()
        assert(not f.op and f.options.lease.holder==nil and s:status(f.a).drain_state=='closed')
        assert(not s:take_recovered(f.a) and not s:ready(f.a) and not s:stage(f.a,metadata(1)))
    end
end
for _,failure in ipairs({'rejected','uncertain','io_error'}) do
    local f=fixture{journal=true,missing=true};local s=f.session
    assert(s:open(f.a));f:finish();f.reject=failure=='rejected'
    assert(s:initialize(f.a,body('priorities',2)))
    if failure=='rejected' then
        assert(s:status(f.a).state=='error' and not s:take_recovered(f.a))
        f.reject=false;assert(s:retry(f.a));assert(f.codec.decode(f.op.payload).data.palA[2]==2)
        assert(f:finish()=='recovered' and s:take_recovered(f.a).revision==1)
    else
        f.uncertain=failure=='uncertain';f.fail=failure=='io_error';f:finish()
        assert(not s:retry(f.a) and not s:take_recovered(f.a) and not s:ready(f.a))
        assert(f.options.lease.holder and not s:close(f.a))
    end
end
assert(Store.data==store_data and Caps.data==caps_data and Store.state==store_state and Caps.state==caps_state,
    'isolated composition must never activate production state')
print('settings session: legacy default, journal opt-in/init, typed policy, two-camp ACK ordering, reentry and revoked drain passed')
