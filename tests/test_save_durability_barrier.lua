local Barrier=dofile(TEST_ROOT..'/experiments/save_durability_barrier.lua')
local Session=dofile(TEST_ROOT..'/experiments/save_session.lua')
local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local function clone(t) local r={};for k,v in pairs(t) do r[k]=v end;return r end
local function context()
    return {scope='world:guild:priorities',session='authority-boot-1',guild='guild-1',
        camp='camp-1',incarnation='epoch-1',stream='priorities',authority=true}
end
local function request(id,peer,client,command)
    return {id=id,peer=peer or 'peer-A',client=client or 'client-A',command=command or 'Pal|1|X'}
end
local function route(r) return {peer=r.peer,client=r.client} end
local function fixture(baseline)
    local f={ctx=context(),disk={},writes=0,now=0}
    f.barrier=Barrier.new{enabled=true,context=f.ctx}
    f.controller=Session.new{enabled=true,lease={},clock=function() return f.now end,
        authorize=function(owner,token)
            return not f.denied and owner==f.ctx.scope and token==f.ctx.session
        end,
        factory=function(owner,token)
            local function start(kind,r,s,t)
                assert(not f.flight)
                f.flight={kind=kind,record=r,slot=s,ticket=t}
                if kind=='write' then f.writes=f.writes+1 end
                return true
            end
            f.queue=Queue.new({
                start=function(r,s,t) return start('write',r,s,t) end,
                start_read=function(s,t) return start('read',nil,s,t) end,
                poll=function(t)
                    assert(f.flight.ticket==t)
                    if not f.complete then return end
                    local op=f.flight;f.flight=nil;f.complete=false
                    if op.kind=='write' and not f.fail then f.disk[op.slot]=clone(op.record) end
                    local r=f.disk[op.slot]
                    return {ticket=t,success=not f.fail,read=r and {status='ok',record=clone(r)}
                        or (f.fail and {status='unreadable'} or {status='missing'})}
                end},owner,token)
            return f.queue
        end}
    function f:finish()
        self.complete=true
        local recovered=self.controller:poll()
        local event=self.controller:take_committed(self.ctx.session)
        if event then assert(self.barrier:commit(self.ctx,event)) end
        return recovered,event
    end
    function f:submit(payload,meta)
        local ticket=assert(self.barrier:stage(self.ctx,meta or {}))
        assert(not self.barrier:ready(self.ctx),'staged edit must close barrier BEFORE enqueue')
        local receipt=assert(self.controller:submit(self.ctx.session,payload))
        assert(self.barrier:accept(self.ctx,ticket,receipt))
        return ticket,receipt
    end
    assert(f.controller:open(f.ctx.scope,f.ctx.session))
    f:finish();local recovered=f:finish()
    assert(f.barrier:recover(f.ctx,recovered,baseline==true))
    return f
end

-- Request IDs are NOT durable generations. Old completion, even for a greater
-- request ID from another peer, never acknowledges the newer generation.
do
    local f=fixture(true);local b,c=f.barrier,f.ctx
    local old,new,third=request(900),request(1,'peer-B','client-B'),request(2,'peer-B','client-B')
    local t1,r1=f:submit('first',{request=old})
    local t2,r2=f:submit('second',{request=new})
    local t3,r3=f:submit('third X OFF',{request=third})
    assert(f.writes==1 and b:status(c).required==3 and b:status(c).durable==0)
    assert(not b:ready(c) and not b:peek_ack(c,t1,route(old)))
    local _,event=f:finish();assert(event.first==1 and event.last==1)
    assert(f.writes==2 and f.flight.record.payload=='third X OFF')
    assert(not b:ready(c) and b:status(c).durable==1)
    assert(b:peek_ack(c,t1,route(old)).revision==1)
    assert(not b:peek_ack(c,t2,route(new)) and not b:peek_ack(c,t3,route(third)))
    assert(f.controller:status(r2).state=='saving')
    assert(b:commit(c,event),'duplicate commit is idempotent')
    local _,coalesced=f:finish();assert(coalesced.first==2 and coalesced.last==3)
    assert(b:ready(c) and b:peek_ack(c,t2,route(new)).revision==2)
    local ack=assert(b:peek_ack(c,t3,route(third)))
    assert(ack.status=='durable_prefix' and ack.durable_revision==3 and ack.id==2)
    ack.id=999;ack.camp='other'
    assert(b:peek_ack(c,t3,route(third)).id==2,'ACK must be a detached copy')
    assert(b:consume_ack(c,t1,route(old)) and not b:consume_ack(c,t1,route(old)))
    assert(b:commit(c,event) and not b:peek_ack(c,t1,route(old)))
    assert(b:stage(c,{request=old})==nil,'consumed request must not be reapplied')
    assert(b:stage(c,{request=third})==t3,'retained exact request is deduplicated')
    third.command='different';assert(b:stage(c,{request=third})==nil)
end

-- A failed baseline capture leaves in-memory data but cannot open the fence.
-- Explicit retry + validated completion opens it; enqueue acceptance cannot.
do
    local f=fixture(false);local b,c=f.barrier,f.ctx
    assert(not b:ready(c))
    local r=request(1)
    local ticket,receipt=f:submit('# baseline=vanilla\nPal|1|X',{baseline=true,request=r})
    assert(not b:ready(c) and b:status(c).baseline_required==1)
    f.fail=true;local _,event=f:finish();assert(event==nil)
    assert(b:failed(c,receipt,'error'))
    assert(b:status(c,ticket).state=='error' and not b:ready(c))
    assert(not b:peek_ack(c,ticket,route(r)))
    f.fail=false;assert(f.controller:retry(c.session))
    assert(not b:ready(c));f:finish()
    assert(b:ready(c) and b:peek_ack(c,ticket,route(r)))
    -- Another Pal needs a fresh baseline; the previous baseline cannot cover it.
    local newer=assert(b:stage(c,{baseline=true}))
    assert(not b:ready(c) and b:status(c).unsubmitted==1)
    assert(not b:accept(c,newer,true),'bare enqueue=true cannot prove acceptance or persistence')
    local receipt2=assert(f.controller:submit(c.session,'baseline includes another Pal'))
    assert(b:accept(c,newer,receipt2) and not b:ready(c))
    assert(b:commit(c,{scope=c.scope,session=c.session,first=1,last=1}))
    assert(not b:ready(c),'older baseline completion must not cover newer capture')
    f:finish();assert(b:ready(c))
end

-- Uncertain IO keeps the barrier and ACK closed; a late matching event may resolve.
do
    local f=fixture(true);local b,c=f.barrier,f.ctx;local r=request(1)
    local ticket,receipt=f:submit('pending',{request=r})
    f.now=11;f.controller:poll();assert(f.controller:status(receipt).state=='uncertain')
    assert(b:failed(c,receipt,'uncertain'))
    assert(not f.controller:retry(c.session) and not b:ready(c))
    assert(not b:peek_ack(c,ticket,route(r)))
    f:finish();assert(b:ready(c) and b:peek_ack(c,ticket,route(r)))
    assert(not b:failed(c,receipt,'error'),'old failure cannot revoke a newer durable prefix')
end

-- Every fence and ACK is bound to scope/session/guild/camp/incarnation/stream.
do
    local f=fixture(true);local b,c=f.barrier,f.ctx;local r=request(1)
    local ticket,receipt=f:submit('durable',{request=r});f:finish()
    for _,field in ipairs({'scope','session','guild','camp','incarnation','stream','authority'}) do
        local changed=clone(c);changed[field]=field=='authority' and false or 'changed'
        assert(not b:ready(changed) and b:status(changed).state=='stale')
        assert(not b:peek_ack(changed,ticket,route(r)))
        assert(not b:consume_ack(changed,ticket,route(r)))
        assert(not b:stage(changed,{}) and not b:accept(changed,ticket,receipt))
        assert(not b:commit(changed,{scope=c.scope,session=c.session,first=1,last=1}))
    end
    assert(not b:peek_ack(c,ticket,{peer=r.peer,client='reconnected'}))
    assert(not b:consume_ack(c,ticket,{peer='other',client=r.client}))
    b:retire();assert(not b:ready(c) and not b:peek_ack(c,ticket,route(r)))
    assert(not b:commit(c,{scope=c.scope,session=c.session,first=1,last=1}))
end

-- Recovery is a baseline generation, not a fresh ACK for an old connection.
do
    local c=context();c.session='new-session';c.incarnation='epoch-2'
    local b=Barrier.new{enabled=true,context=c}
    assert(b:recover(c,{scope=c.scope,session=c.session,revision=7},true))
    assert(b:ready(c) and not b:peek_ack(c,1,route(request(1))))
    local ticket=assert(b:stage(c,{request=request(1)}))
    assert(not b:accept(c,ticket,{scope=c.scope,session='authority-boot-1',revision=8}))
    assert(b:accept(c,ticket,{scope=c.scope,session=c.session,revision=8}))
    assert(not b:commit(c,{scope=c.scope,session='authority-boot-1',first=8,last=8}))
    assert(not b:commit(c,{scope=c.scope,session=c.session,first=9,last=9}))
    assert(not b:commit(c,{scope=c.scope,session=c.session,first=8,last=9}))
    assert(not b:peek_ack(c,ticket,route(request(1))))
    assert(b:commit(c,{scope=c.scope,session=c.session,first=8,last=8}))
end

-- Hard bounds reject BEFORE caller mutation/submit; no pending entry eviction.
do
    local c=context();local original=clone(c)
    local b=Barrier.new{enabled=true,context=c,max_pending=2,max_peers=1}
    c.camp='mutated';assert(not b:ready(c))
    c=original;assert(b:recover(c,{scope=c.scope,session=c.session,revision=0},true))
    local r=request(1);local t=assert(b:stage(c,{request=r}))
    r.id=99;r.client='mutated'
    assert(b:stage(c,{request=request(1)})==t,'request input must be copied')
    assert(not b:stage(c,{request=request(1,'other','other')}))
    assert(b:stage(c,{request=request(2)}))
    assert(not b:stage(c,{}))
    assert(b:status(c).pending==2 and b:status(c).unsubmitted==2)
    assert(not b:commit(c,{scope=c.scope,session=c.session,first=1,last=1}))
    assert(not b:recover(c,{scope=c.scope,session=c.session,revision=999},true))
end

-- Authority revocation suppresses both completion events and retained replies;
-- retiring this model must not release the native/session drain obligation.
do
    local f=fixture(true);local ticket=f:submit('pending',{request=request(1)})
    f.denied=true;f.barrier:retire()
    assert(not f.controller:close(f.ctx.session))
    assert(not f.barrier:peek_ack(f.ctx,ticket,route(request(1))))
    local _,event=f:finish();assert(event==nil)
    assert(f.queue:can_shutdown() and f.controller:status().state=='closed')
end
print('durability barrier: real session/queue prefix ACKs, old completion, failure/retry/coalescing, baseline, contexts and bounds passed')
