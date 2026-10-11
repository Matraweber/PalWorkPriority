local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local Session=dofile(TEST_ROOT..'/experiments/save_session.lua')
local function fixture()
    local f={time=0,calls={},disk={},made=0}
    local function start(kind,record,slot,ticket,owner)
        assert(not f.flight,'overlapping physical IO')
        f.calls[#f.calls+1]={kind=kind,record=record,slot=slot,ticket=ticket,owner=owner}
        if f.reject then return false end
        f.flight=f.calls[#f.calls]
        if f.on_start then f.on_start(kind) end
        if f.ambiguous then error('enqueued before exception') end
        return true
    end
    f.options={enabled=true,lease={},clock=function() return f.time end,timeout=2,
        authorize=function() return not f.denied end,
        factory=function(owner,token)
            assert(not f.flight);f.made=f.made+1
            local adapter={
                start=function(r,s,t) return start('write',r,s,t,owner) end,
                start_read=function(s,t) return start('read',nil,s,t,owner) end,
                poll=function(ticket)
                    local op=assert(f.flight);assert(op.ticket==ticket)
                    if not f.complete then return end
                    f.flight,f.complete=nil,false
                    if op.kind=='write' and not f.fail then f.disk[owner..op.slot]=op.record end
                    local record=f.disk[owner..op.slot]
                    return {ticket=ticket,success=not f.fail,
                        read=f.unreadable and {status='unreadable'} or record
                            and {status='ok',record=record} or {status='missing'}}
                end}
            return Queue.new(adapter,owner,token)
        end}
    f.c=Session.new(f.options)
    function f:finish() self.complete=true;return self.c:poll() end
    function f:open(owner,token)
        assert(self.c:open(owner,token)==true)
        assert(self.c:submit(token,'too early')==nil)
        assert(self:finish()==nil)
        local recovered=self:finish();assert(recovered.session==token)
        return recovered
    end
    return f
end

-- Disabled gate must not invoke the factory, clock or IO.
local off=Session.new{factory=function() error('disabled factory called') end}
assert(off:status().state=='disabled' and off:open('a','b')==false)

-- Full snapshots coalesce; successful old completion cannot claim a newer edit.
do
    local f=fixture();local c=f.c;f:open('guild-a','boot-a')
    local r1=c:submit('boot-a','Pal|1|X\n')
    local r2=c:submit('boot-a','Pal|1|X\nPal|2|3\n')
    local r3=c:submit('boot-a','Pal|1|X\nPal|2|1\n')
    assert(#f.calls==3 and c:status(r3).state=='saving')
    assert(c:take_committed('boot-a')==nil)
    f:finish()
    assert(c:status(r1).state=='saved' and c:status(r2).state=='saving')
    local e=c:take_committed('boot-a');assert(e.first==1 and e.last==1)
    assert(c:take_committed('boot-a')==nil and f.flight.record.generation==3)
    f:finish();e=c:take_committed('boot-a')
    assert(e.first==2 and e.last==3 and c:status(r2).state=='saved')
    assert(c:close('boot-a'))
    local restored=f:open('guild-a','boot-b')
    assert(restored.payload=='Pal|1|X\nPal|2|1\n' and restored.revision==3)
    assert(c:take_committed('boot-b')==nil,'recovery must not acknowledge old connection edits')
    assert(c:status(r3).state=='stale' and c:submit('boot-a','late')==nil)
    c:close('boot-b');assert(not c:open('guild-a','boot-a'),'old incarnation reused')
end

-- A long save is uncertain, never cancelled/retried/announced as durable.
do
    local f=fixture();local c=f.c;f:open('owner','one')
    local receipt=c:submit('one','pending')
    f.time=2.1;c:poll()
    assert(c:status(receipt).state=='uncertain' and not c:retry('one'))
    assert(c:submit('one','no implicit retry')==nil)
    assert(not c:close('one') and c:status(receipt).state=='stale')
    assert(not c:open('different-world','two') and f.made==1)
    f:finish();assert(c:status().state=='closed' and c:take_committed('one')==nil)
    f:open('different-world','two');assert(c:status().saved==0)
end

-- Queued snapshots belong to the old owner while draining; no stale ACK escapes.
do
    local f=fixture();local c=f.c;f:open('a','one')
    c:submit('one','first');c:submit('one','latest')
    assert(not c:close('one'));f:finish()
    assert(f.flight.owner=='a' and f.flight.record.payload=='latest')
    assert(not c:open('b','two') and not c:take_committed('one'))
    f:finish();f:open('b','two');assert(c:status().saved==0)
end

-- Definitely completed failure retains dirty data, requires explicit retry.
do
    local f=fixture();local c=f.c;f:open('owner','one')
    local receipt=c:submit('one','retry me');f.fail=true;f:finish()
    assert(c:status(receipt).state=='error' and not c:take_committed('one'))
    assert(c:submit('one','click cannot retry')==nil)
    f.fail=false;assert(c:retry('one'));f:finish()
    assert(c:status(receipt).state=='saved' and c:take_committed('one').last==1)
end

-- Throwing start may have accepted native IO: keep its lock until completion.
do
    local f=fixture();local c=f.c;f:open('owner','one');f.ambiguous=true
    local receipt=c:submit('one','unknown')
    assert(c:status(receipt).state=='uncertain' and not c:retry('one'))
    local n=#f.calls;c:poll();assert(#f.calls==n)
    f.ambiguous=false;f:finish();assert(c:status(receipt).state=='saved')
end

-- Unreadable recovery cannot create an empty configuration or enable edits.
do
    local f=fixture();f.unreadable=true;assert(f.c:open('a','one'))
    f:finish();assert(f.c:status().state=='error' and f.c:submit('one','bad')==nil)
end

-- Do not refresh deadlines on every poll; only new operations get a new one.
do
    local f=fixture();local c=f.c;f:open('a','one');c:submit('one','first')
    f.time=1;c:poll();f.time=2.1;c:poll();assert(c:status().state=='uncertain')
    f:finish();c:submit('one','second');f.time=3;c:poll();assert(c:status().state=='saving')
    f.time=4.2;c:poll();assert(c:status().state=='uncertain')
    assert(c:status({revision=999,session='one',scope='a'}).state=='stale')
    assert(c:status('bad').state=='stale')
end
-- Replacing a controller must not bypass another queue's uncertain native IO.
do
    local f=fixture();f:open('world-a:priorities','one')
    local other=Session.new(f.options)
    assert(not other:open('world-b:limits','two') and f.made==1)
    f.c:submit('one','slow');f.time=3;f.c:poll();f.c:close('one')
    assert(not other:open('world-b:limits','two') and f.made==1)
    f:finish();assert(other:open('world-b:limits','two') and f.made==2)
    assert(f.c:open('world-a:priorities','three')==false)
end
do
    local f=fixture();f:open('owner','same');assert(f.c:close('same'))
    local replacement=Session.new(f.options)
    assert(not replacement:open('owner','same'),'replacement reused an old receipt incarnation')
    assert(replacement:open('owner','new'))
end
-- Accepted in memory is not saved when dispatch is definitely rejected.
do
    local f=fixture();f:open('a','one');f.reject=true
    local receipt=f.c:submit('one','not started')
    assert(receipt.revision==1 and f.c:status(receipt).state=='error')
    assert(not f.c:take_committed('one') and not f.c:close('one'))
end
-- Reserve the lease before calling an injected constructor; no reentrant owner.
do
    local f=fixture();f:open('old','one');f.c:submit('one','accepted')
    f.c:close('one');f.fail=true;f:finish()
    assert(f.c:status().state=='closing' and not f.c:open('new','two'))
    f.fail=false;assert(f.c:retry('one'));f:finish()
    assert(f.c:status().state=='closed' and not f.c:take_committed('one'))
    f:open('new','two');assert(not f.c:retry('one'))
end
-- Reserve the lease before calling an injected constructor; no reentrant owner.
do
    local f=fixture();local base=f.options.factory
    local other=Session.new(f.options)
    f.options.factory=function(owner,token)
        assert(not other:open('other','nested'))
        assert(not f.c:open('same','nested'))
        return base(owner,token)
    end
    f:open('a','one')
end
do
    local lease={}
    local c=Session.new{enabled=true,lease=lease,clock=function() return 0 end,
        authorize=function() return true end,
        factory=function() error('no IO construction failure') end}
    assert(c:open('a','one')==false and lease.holder==nil)
end
-- Old-token operations cannot release a constructor's new reservation.
do
    local f=fixture();f:open('old','one');assert(f.c:close('one'))
    local base=f.options.factory;local other=Session.new(f.options)
    f.options.factory=function(owner,token)
        assert(not f.c:close('one'))
        f.c:poll()
        assert(not f.c:retry('one'))
        assert(not other:open('intruder','three'))
        return base(owner,token)
    end
    f:open('new','two')
end
-- Adapter dispatch may reenter submission: each receipt keeps its own revision.
do
    local f=fixture();f:open('a','one');local nested
    f.on_start=function(kind)
        if kind=='write' then
            f.on_start=nil
            nested=f.c:submit('one','second')
        end
    end
    local first=f.c:submit('one','first')
    assert(first.revision==1 and nested.revision==2)
    assert(f.flight.record.payload=='first' and f.flight.record.generation==1)
    f:finish()
    assert(f.c:status(first).state=='saved' and f.c:status(nested).state=='saving')
    assert(f.flight.record.payload=='second' and f.flight.record.generation==2)
    f:finish();assert(f.c:status(nested).state=='saved')
end
-- Missing, false, ambiguous and throwing evidence never constructs a queue.
for _,mode in ipairs({'missing','false','nil','string','throw'}) do
    local f=fixture()
    f.options.authorize=function()
        if mode=='throw' then error('unreadable authority') end
        if mode=='false' then return false end
        if mode=='string' then return 'true' end
    end
    if mode=='missing' then f.options.authorize=nil end
    assert(not f.c:open('stale-selected-id','client'))
    assert(f.made==0 and #f.calls==0)
end
-- Authority lost with accepted IO: drain the old owner, never ACK or revive it.
do
    local f=fixture(); f:open('local-save','host-1')
    local r=f.c:submit('host-1','accepted'); f.c:submit('host-1','latest')
    f.denied=true
    assert(not f.c:submit('host-1','client edit'))
    assert(f.c:status(r).state=='stale' and not f.c:take_committed('host-1'))
    assert(not f.c:open('local-save','client-2'))
    f:finish(); assert(f.flight.owner=='local-save' and f.flight.record.payload=='latest')
    f:finish(); assert(f.c:status().state=='closed')
    f.denied=false
    assert(not f.c:submit('host-1','revived') and not f.c:open('local-save','host-1'))
    f:open('local-save','host-3')
end
-- Recovery completing after a role change must not install host settings.
do
    local f=fixture(); assert(f.c:open('local-save','host'))
    f:finish(); f.denied=true
    assert(f:finish()==nil and f.c:status().state=='closed')
end
-- Constructor cannot carry earlier permission across a transition.
do
    local f=fixture(); local base=f.options.factory
    f.options.factory=function(owner,token)
        local q=base(owner,token); f.denied=true; return q
    end
    assert(not f.c:open('local-save','host') and #f.calls==0)
    assert(f.options.lease.holder==nil)
end
-- Optional initialization capability. The composition test exercises the real
-- journal queue; this controlled queue tests Session's admission/event boundary.
local function init_fixture()
    local f={lease={},writes=0}
    local q={max_payload_bytes=65536,ticket=0,generation=0,saved=0,state='unrecovered'}
    function q:recover() self.ticket=1;self.state='recovering';return true end
    function q:can_initialize() return f.missing==true and self.generation==0 end
    function q:initialize(payload)
        assert(self:can_initialize());self.generation=1;self.ticket=self.ticket+1
        f.payload=payload;f.writes=f.writes+1;self.state=f.reject and 'error' or 'saving'
        if f.on_init then f.on_init() end
        return 1
    end
    function q:poll()
        if f.complete_missing then f.complete_missing=false;f.missing=true;self.state='error';return false end
        if f.complete_init then
            f.complete_init=false;self.saved=1;self.state='saved';return true,f.payload
        end
    end
    function q:can_shutdown() return self.saved==self.generation and self.state~='recovering' end
    function q:retry()
        if self.state~='error' or self.generation~=1 then return false end
        self.ticket=self.ticket+1;self.state='saving';f.writes=f.writes+1;return true
    end
    function q:timeout() if self.state=='saving' then self.state='uncertain' end end
    f.q=q
    f.c=Session.new{enabled=true,lease=f.lease,factory=function() return q end,
        clock=function() if f.on_clock then f.on_clock() end;return 0 end,
        authorize=function() return not f.denied end}
    assert(f.c:open('scope','token'))
    function f:missing_ready() self.complete_missing=true;assert(not self.c:poll()) end
    return f
end
do
    local f=init_fixture()
    assert(not f.c:initialize('token','initial') and f.writes==0)
    f:missing_ready();assert(f.c:status().state=='initialization_required')
    assert(not f.c:initialize('wrong','initial') and f.writes==0)
    f.on_clock=function() f.denied=true end
    assert(not f.c:initialize('token','initial') and f.writes==0,'fresh auth after clock')
end
for _,stop in ipairs({'none','close','revoke','dispatch-revoke'}) do
    local f=init_fixture();f:missing_ready()
    f.on_init=function()
        assert(not f.c:poll() and not f.c:initialize('token','nested'))
        if stop=='dispatch-revoke' then f.denied=true end
    end
    local r=assert(f.c:initialize('token','original'))
    assert(r.scope=='scope' and r.session=='token' and r.revision==1)
    assert(not f.c:initialize('token','replacement') and not f.c:submit('token','new'))
    assert(not f.c:take_committed('token') and f.writes==1)
    if stop=='close' then assert(not f.c:close('token'))
    elseif stop=='revoke' then f.denied=true end
    f.complete_init=true;local event=f.c:poll()
    if stop=='none' then
        assert(event.payload=='original' and event.revision==1)
        assert(f.c:status(r).state=='saved' and not f.c:poll() and not f.c:take_committed('token'))
    else
        assert(not event and f.lease.holder==nil and f.c:status().state=='closed')
        assert(f.c:status(r).state=='stale')
    end
end
do
    local f=init_fixture();f:missing_ready();f.reject=true
    assert(f.c:initialize('token','accepted'));assert(not f.c:close('token'))
    assert(f.lease.holder and not f.c:retry('other'))
    f.reject=false;assert(f.c:retry('token') and f.writes==2)
    f.complete_init=true;assert(not f.c:poll() and f.lease.holder==nil)
end
do
    local f=fixture();f:open('local-save','host')
    assert(not f.c:initialize('host','no optional API'),'legacy queue must not initialize through new API')
end
print('save session: durable ranges, explicit initialization, authority revocation and gated IO passed')
