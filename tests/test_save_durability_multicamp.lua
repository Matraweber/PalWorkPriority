-- ONE guild-stream session/queue and ONE ledger, interleaved across camps.
local Barrier=dofile(TEST_ROOT..'/experiments/save_durability_barrier.lua')
local Session=dofile(TEST_ROOT..'/experiments/save_session.lua')
local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local function clone(t) local r={};for k,v in pairs(t) do r[k]=v end;return r end
local a={scope='world:guild:priorities',session='boot',guild='guild',camp='A',
    incarnation='authority-1',stream='priorities',authority=true}
local b=clone(a);b.camp='B'
local ledger=Barrier.new{enabled=true,context=a,max_camps=3}
local f={disk={},writes=0}
local controller=Session.new{enabled=true,lease={},clock=function() return 0 end,
    authorize=function(scope,session) return scope==a.scope and session==a.session end,
    factory=function(scope,session)
        local function start(kind,r,slot,ticket)
            assert(not f.pending)
            f.pending={kind=kind,record=r,slot=slot,ticket=ticket}
            if kind=='write' then f.writes=f.writes+1 end
            return true
        end
        f.queue=Queue.new({
            start=function(r,s,t) return start('write',r,s,t) end,
            start_read=function(s,t) return start('read',nil,s,t) end,
            poll=function(ticket)
                local op=assert(f.pending);assert(op.ticket==ticket)
                if not f.complete then return end
                f.pending=nil;f.complete=false
                if op.kind=='write' and not f.fail then f.disk[op.slot]=clone(op.record) end
                local r=f.disk[op.slot]
                return {ticket=ticket,success=not f.fail,read=r and {status='ok',record=clone(r)}
                    or (f.fail and {status='unreadable'} or {status='missing'})}
            end},scope,session)
        return f.queue
    end}
local function finish(context)
    f.complete=true
    local recovered=controller:poll()
    local event=controller:take_committed(a.session)
    if event then assert(ledger:commit(context,event)) end
    return recovered,event
end
assert(controller:open(a.scope,a.session))
finish(a);local recovered=finish(a)
assert(ledger:recover(a,recovered,false))
assert(not ledger:ready(a) and not ledger:ready(b))
assert(not ledger:stage(b,{}),'unregistered camp must not mutate settings')
assert(ledger:recover(b,recovered,false))
local route={peer='peer',client='client-incarnation'}
local function meta(id,baseline)
    return {baseline=baseline,request={peer=route.peer,client=route.client,id=id,command='edit-'..id}}
end
local function submit(context,id,baseline,payload)
    local ticket=assert(ledger:stage(context,meta(id,baseline)))
    local receipt=assert(controller:submit(a.session,payload))
    assert(ledger:accept(context,ticket,receipt),'shared-stream generation was incorrectly camp-local')
    return ticket,receipt
end
local ta1,ra1=submit(a,1,true,'A baseline X')
local tb2,rb2=submit(b,2,true,'A baseline X; B baseline OFF')
local ta3,ra3=submit(a,3,false,'A newer 3; B baseline OFF')
assert(ra1.revision==1 and rb2.revision==2 and ra3.revision==3)
assert(ledger:status(a).required==3 and ledger:status(b).required==2)
assert(ledger:status(a).stream_required==3 and ledger:status(b).stream_required==3)
assert(f.writes==1 and not ledger:ready(a) and not ledger:ready(b))
assert(not ledger:accept(b,ta3,ra3),'an existing entry cannot be retagged to another camp')
assert(not ledger:stage(b,meta(3,false)),'duplicate request cannot migrate between camps')

-- Camp A's old completion cannot cover its newer edit or camp B's baseline.
local _,first=finish(b) -- event is stream-wide; any registered camp context works
assert(first.first==1 and first.last==1)
assert(f.pending.record.generation==3 and f.writes==2,'full snapshots should coalesce')
assert(not ledger:ready(a) and not ledger:ready(b))
assert(ledger:status(a).baseline_durable and not ledger:status(b).baseline_durable)
assert(ledger:peek_ack(a,ta1,route).camp=='A')
assert(not ledger:peek_ack(b,ta1,route))
assert(not ledger:peek_ack(b,tb2,route) and not ledger:peek_ack(a,ta3,route))
local _,coalesced=finish(a)
assert(coalesced.first==2 and coalesced.last==3)
assert(ledger:ready(a) and ledger:ready(b))
assert(ledger:peek_ack(b,tb2,route).camp=='B' and ledger:peek_ack(b,tb2,route).revision==2)
assert(ledger:peek_ack(a,ta3,route).revision==3)
assert(not ledger:peek_ack(a,tb2,route) and not ledger:consume_ack(a,tb2,route))

-- Guild rules can affect both camps: staging in B conservatively blocks both
-- permission barriers. A's revision 4 completion still cannot ACK B's revision 5.
local tb5=assert(ledger:stage(b,meta(4,false)))
assert(not ledger:ready(a) and not ledger:ready(b))
assert(ledger:status(a).unsubmitted==0 and ledger:status(b).unsubmitted==1)
assert(ledger:status(a).stream_unsubmitted==1)
local ta4,ra4=submit(a,5,false,'A revision 4; B baseline OFF')
local rb5=assert(controller:submit(a.session,'A revision 4; B newer X'))
assert(rb5.revision==5 and ledger:accept(b,tb5,rb5))
assert(not ledger:ready(a) and not ledger:ready(b))
finish(b)
assert(not ledger:ready(a) and not ledger:ready(b))
assert(ledger:peek_ack(a,ta4,route).revision==4 and not ledger:peek_ack(b,tb5,route))
f.fail=true;local _,failed=finish(a);assert(failed==nil)
assert(ledger:failed(b,rb5,'error') and ledger:status(b,tb5).state=='error')
assert(not ledger:ready(a) and not ledger:ready(b))
assert(ledger:commit(a,first) and not ledger:peek_ack(b,tb5,route))
f.fail=false;assert(controller:retry(a.session));assert(not ledger:ready(b))
finish(a);assert(ledger:ready(a) and ledger:ready(b))
assert(ledger:peek_ack(b,tb5,route).id==4)

-- Registering another camp uses the original decoded recovery evidence and
-- cannot reset or jump the stream's generation accounting after edits.
local c=clone(a);c.camp='C'
local advanced=clone(recovered);advanced.revision=5
assert(not ledger:recover(c,advanced,true))
assert(ledger:recover(c,recovered,true))
assert(ledger:status(c).required==0 and ledger:status(c).stream_required==5)
assert(ledger:status(a).durable==5 and ledger:status(b).required==5)
assert(not ledger:recover(b,recovered,true),'existing baseline cannot be reset')
local d=clone(a);d.camp='D'
assert(not ledger:recover(d,recovered,true) and not ledger:stage(d,{}),'camp bound must reject, never evict')
assert(ledger:status(a).camps==3 and ledger:ready(c))

-- Client routing stays per entry even though durability progresses globally.
assert(not ledger:peek_ack(b,tb5,{peer=route.peer,client='new-client'}))
local foreign=clone(b);foreign.guild='other'
assert(not ledger:ready(foreign) and not ledger:peek_ack(foreign,tb5,route))
assert(ledger:consume_ack(b,tb5,route) and not ledger:peek_ack(b,tb5,route))
ledger:retire()
assert(not ledger:ready(a) and not ledger:ready(b) and not ledger:ready(c))
assert(not ledger:peek_ack(a,ta1,route))
print('durability multicamp: one real guild-stream session, A1/B2/A3 coalescing, camp baselines/routes, failure/retry and bounded registration passed')
