local function fixture(authority)
    local f = { now = 0, up = {}, down = {}, events = {}, lines = {}, amount = 100,
        priority = 1, outcome = true, apply = true, calls = 0 }
    os.clock = function() return f.now end
    FName = function(s) return s end
    FindAllOf = function() return {} end
    package.loaded.log = { warn = function(s) f.lines[#f.lines+1] = s end,
        say = function(s) f.lines[#f.lines+1] = s end, debug = function() end,
        count = function() return {ms=0} end }
    f.component = {guild="guild-A"}
    function f.component:GetFullName() return "comp-A" end
    function f.component:Notify_RequestClient_int32(_, name) f.down[#f.down+1] = name end
    local sender = {}
    function sender:Request_Server_int32(_, name) f.up[#f.up+1] = name end
    local function module(role)
        local api = {has_authority=function() return role end,
            valid=function(o) return type(o)=="table" end,
            owned_network_component=function() return sender end}
        package.loaded.palapi = api
        package.loaded.net = nil
        local n = require("net")
        n.guild_of_sender = function(c) return c.guild end
        return n, api
    end
    f.server, f.server_api = module(true)
    f.client, f.client_api = module(authority)
    f.client.begin_session(77)
    f.rows = function() return {{key="PAL-A", ranks={[1]=3}, prios={[1]=f.priority}}} end
    f.caps = {all=function() return {Mining={Stone=f.amount}} end}
    f.client.on_snapshot = function(rows, meta)
        assert(meta.epoch==77 and meta.server_session==f.server.local_nonce and meta.guild=="guild-A")
        if not f.apply then return false end
        f.view = rows
        return true
    end
    f.client.on_edit = function(key, _, status, reason)
        f.events[#f.events+1] = {key=key,status=status,reason=reason}
        if key==nil then f.remote_status, f.remote_error=status, reason end
    end
    f.client.on_status=function(status,reason) f.remote_status,f.remote_error=status,reason end
    f.server.on_command = function(command, _, comp)
        local p = f.server.split(command)
        if p[1]=="PWP_Hello" then
            assert(f.server.push_rules(f.caps,{},comp))
            assert(f.server.push_pals(f.rows,comp))
            return true
        end
        f.calls = f.calls + 1
        if p[1]=="PWP_Set" then
            f.amount=tonumber(p[4]); assert(f.server.push_rules(f.caps,{},comp))
        else
            f.priority=require("protocol").decode_priority(p[4])
            assert(f.server.push_pals(f.rows,comp,p[2]))
        end
        return f.outcome
    end
    function f.to_server()
        local q=f.up; f.up={}
        for _,m in ipairs(q) do f.server.receive_command(f.component,m,0) end
        return q
    end
    function f.to_client()
        local q=f.down; f.down={}
        for _,m in ipairs(q) do f.client.receive_state(m) end
        return q
    end
    function f.advance(seconds) f.now=f.now+seconds; f.client.poll() end
    if authority==false then
        assert(f.client.hello()); f.to_server(); f.to_client(); f.to_server(); f.to_client()
        assert(f.client.status=="ready")
    end
    return f
end

local f=fixture(false)
local peer=f.server.clients["comp-A"]
local revision=peer.next_revision.P
assert(not f.server.push_pals(function() return nil,"camp enumeration unavailable" end,f.component))
assert(#f.down==0 and peer.next_revision.P==revision and peer.revisions.P==revision,
    "unavailable roster emitted or consumed a full snapshot")
assert(f.lines[#f.lines]:find("stand data unavailable",1,true))
assert(not f.server.push_pals(function() return false end,f.component) and #f.down==0)
assert(f.server.push_pals(function() return {} end,f.component))
assert(#f.down==2, "proven empty roster did not produce a complete empty snapshot")
f.to_client()
assert(next(f.client.pals)==nil and f.client.status=="ready")

f=fixture(false)
f.apply=false
assert(f.client.request("set","Mining","Stone",200))
f.to_server(); local failed=f.to_client()
assert(f.client.status_reason=="snapshot_apply_failed" and f.view[1].amount==100)
assert(f.events[#f.events].status=="acknowledged", "failed application completed the edit")
f.apply=true
for _,m in ipairs(failed) do if not m:match("^PWP_V2|A|") then f.client.receive_state(m) end end
assert(f.view[1].amount==200 and f.client.status=="ready")
assert(f.events[#f.events].status=="accepted", "same revision could not retry after apply failure")

f=fixture(false)
f.client.on_snapshot=function() end
assert(f.server.push_rules(f.caps,{},f.component)); f.to_client()
assert(f.client.status_reason=="snapshot_apply_failed", "nil callback return counted as an applied snapshot")

f=fixture(false)
local p=require("protocol")
local gap=assert(p.snapshot(f.server.local_nonce,f.client.local_nonce,"guild-A","P",3,"D",
    {"PAL-A|"..string.rep("1",14).."|"..string.rep("4",14)}))
f.client.receive_state(gap[1]); assert(f.client.status_reason=="delta_revision_gap")
assert(f.server.push_rules(f.caps,{},f.component)); f.to_client()
assert(f.client.status=="connecting", "unrelated rules snapshot concealed a missing Pal update")
f.priority=4; assert(f.server.push_pals(f.rows,f.component)); f.to_client()
assert(f.client.status=="ready" and f.client.pals["PAL-A"].prios[1]==4)

-- An edit timeout leaves that stream uncertain even when another stream is
-- healthy. Cover missing ACKs and ACKs whose state never arrived, for both files.
for _, stream in ipairs({"P", "R"}) do
    for _, acknowledged in ipairs({false, true}) do
        f=fixture(false)
        if stream=="P" then
            assert(f.client.request_prio("PAL-A",1,4)); f.advance(0.2)
        else
            assert(f.client.request("set","Mining","Stone",200))
        end
        f.to_server()
        local delayed=f.down; f.down={}
        local ack=delayed[#delayed]
        assert(ack:match("^PWP_V2|A|"))
        if acknowledged then assert(f.client.receive_state(ack)) end
        f.advance(8.1)
        assert(f.client.status=="connecting")
        assert(f.events[#f.events].status=="timed_out")
        assert(f.events[#f.events].reason==(acknowledged and "snapshot_timeout" or "ack_timeout"))
        assert(not select(2,f.client.pending_priority("PAL-A",1)))

        if stream=="P" then
            assert(f.server.push_rules(f.caps,{},f.component))
        else
            assert(f.server.push_pals(f.rows,f.component))
        end
        f.to_client()
        assert(f.client.status=="connecting",
            stream.." edit timeout was concealed by an unrelated full snapshot")
        assert(not f.client.request_prio("PAL-A",1,5))
        assert(not f.client.request("set","Mining","Stone",300))
        assert(f.client.pals["PAL-A"].prios[1]==1 and f.view[1].amount==100)
        assert(not f.client.receive_state(ack), "late ACK revived a timed-out edit")
        if stream=="P" then
            assert(not f.client.receive_state(delayed[1]), "delta repaired an uncertain roster")
            assert(f.client.pals["PAL-A"].prios[1]==1)
            assert(f.server.push_pals(f.rows,f.component))
        else
            assert(f.server.push_rules(f.caps,{},f.component))
        end
        local repair=f.down; f.down={}
        for i=1,#repair-1 do assert(f.client.receive_state(repair[i])) end
        assert(f.client.status=="connecting", "partial repair reopened editing")
        assert(f.client.receive_state(repair[#repair]))
        assert(f.client.status=="ready")
        assert(stream=="P" and f.client.pals["PAL-A"].prios[1]==4
            or stream=="R" and f.view[1].amount==200)
        assert(f.events[#f.events].status=="timed_out", "repair fabricated edit acceptance")
        assert(f.client.request_prio("PAL-A",1,5))
        assert(f.client.request("set","Mining","Stone",300))
    end
end

f=fixture(false)
assert(f.client.request_prio("PAL-A",1,2))
local invalid="PWP_V2|B|"..f.server.local_nonce.."|"..f.client.local_nonce.."|guild-A|P|3|F|513"
f.client.receive_state(invalid)
f.advance(9)
assert(not select(2,f.client.pending_priority("PAL-A",1)))
assert(f.events[#f.events].status=="timed_out" and f.events[#f.events].reason=="queue_timeout")
f.advance(100)
assert(f.server.push_pals(f.rows,f.component)); f.to_client(); f.advance(1)
for _,m in ipairs(f.up) do assert(not m:find("|Prio|",1,true), "expired queue entry was sent on recovery") end

f=fixture(false); f.outcome="applied_unsaved"
assert(f.client.request_prio("PAL-A",1,3)); f.advance(0.2)
local requests=f.to_server(); f.to_client()
assert(f.client.pals["PAL-A"].prios[1]==3 and not select(2,f.client.pending_priority("PAL-A",1)))
assert(f.events[#f.events].status=="applied_unsaved" and f.events[#f.events].reason=="save_failed")
local calls=f.calls
assert(f.server.receive_command(f.component,requests[1],0)=="applied_unsaved")
assert(f.calls==calls, "unsaved acknowledgement replay reapplied the mutation")

-- Rules persistence errors survive both kinds of unrelated snapshot and a
-- successful PRIORITY save. Only a later durable RULE ack clears that file.
f=fixture(false); f.outcome="applied_unsaved"
assert(f.client.request("set","Mining","Stone",200)); f.to_server(); f.to_client()
assert(f.client.save_failures.R and f.client.status=="applied_unsaved")
assert(f.server.push_rules(f.caps,{},f.component)); f.to_client()
assert(f.server.push_pals(f.rows,f.component)); f.to_client()
assert(f.remote_status=="applied_unsaved" and f.remote_error=="save_failed")
f.outcome=true
assert(f.client.request_prio("PAL-A",1,4)); f.advance(0.2); f.to_server(); f.to_client()
assert(f.client.save_failures.R and f.remote_status=="applied_unsaved")
assert(f.client.request("set","Mining","Stone",300))
assert(f.remote_status=="applied_unsaved" and f.remote_error=="save_failed",
    "a retry's pending callback hid the previous save failure")
f.to_server()
local retry=f.down; f.down={}
assert(f.client.receive_state(retry[#retry])) -- ACK before its snapshot.
assert(f.client.save_failures.R and f.remote_status=="applied_unsaved" and f.remote_error=="save_failed",
    "an acknowledgement awaiting its snapshot hid the save failure")
for _,m in ipairs(retry) do if not m:match("^PWP_V2|A|") then f.client.receive_state(m) end end
assert(not f.client.save_failures.R and f.client.status=="ready" and not f.remote_error)

-- Both files can be dirty together. A durable rules write clears just R;
-- the remaining priorities error must survive main's accepted-rule callback.
f=fixture(false); f.outcome="applied_unsaved"
assert(f.client.request_prio("PAL-A",1,2)); f.advance(0.2); f.to_server(); f.to_client()
assert(f.client.request("set","Mining","Stone",200)); f.to_server(); f.to_client()
assert(f.client.save_failures.P and f.client.save_failures.R)
f.outcome=true
assert(f.client.request("set","Mining","Stone",300)); f.to_server(); f.to_client()
assert(f.client.save_failures.P and not f.client.save_failures.R)
assert(f.remote_status=="applied_unsaved" and f.remote_error=="save_failed")
assert(f.client.request_prio("PAL-A",1,3)); f.advance(0.2); f.to_server(); f.to_client()
assert(next(f.client.save_failures)==nil and f.client.status=="ready" and f.remote_status=="ready")

-- Delivering an older successful ack after a newer failed save cannot erase
-- the failure. Both acknowledgements are real and have applied snapshots.
f=fixture(false)
assert(f.client.request("set","Mining","Stone",200)); f.to_server()
local old=f.down; f.down={}
f.outcome="applied_unsaved"
assert(f.client.request("set","Mining","Stone",300)); f.to_server()
local newer=f.down; f.down={}
for _,m in ipairs(old) do if not m:match("^PWP_V2|A|") then f.client.receive_state(m) end end
for _,m in ipairs(newer) do f.client.receive_state(m) end
f.client.receive_state(old[#old])
assert(f.client.status=="applied_unsaved" and f.client.save_failures.R==2)
assert(f.remote_status=="applied_unsaved" and f.remote_error=="save_failed",
    "older on_edit accepted notification hid the limits save failure")
f.client.begin_session(78)
assert(next(f.client.save_failures)==nil and f.client.status=="connecting")

-- The converse order is safe too: a late historical unsaved ack cannot relatch
-- an error after a newer durable ack for that SAME file has been reconciled.
f=fixture(false); f.outcome="applied_unsaved"
assert(f.client.request("set","Mining","Stone",200)); f.to_server()
old=f.down; f.down={}
f.outcome=true
assert(f.client.request("set","Mining","Stone",300)); f.to_server()
newer=f.down; f.down={}
for _,m in ipairs(old) do if not m:match("^PWP_V2|A|") then f.client.receive_state(m) end end
for _,m in ipairs(newer) do f.client.receive_state(m) end
f.client.receive_state(old[#old])
assert(not f.client.save_failures.R and f.client.status=="ready")

for _, lost in ipairs({false,"unknown"}) do
    f=fixture(false)
    f.server.on_command=function()
        f.server_api.has_authority=function() if lost=="unknown" then return nil end return false end
        return false
    end
    assert(f.client.request_prio("PAL-A",1,2)); f.advance(0.2); f.to_server()
    assert(#f.down==0, "lost authority still issued a server acknowledgement")
end

-- Reuse only the actual incoming invocation's lookup, with no retained wrapper.
f=fixture(false)
local lookups, held_token=0,nil
f.server.guild_of_sender=function(c) lookups=lookups+1; return c.guild end
f.server.on_command=function(_,_,comp,token)
    held_token=token
    assert(f.server.command_guild(token,comp,f.server.epoch)=='guild-A')
    assert(f.server.command_guild({},comp,f.server.epoch)==nil,'forged token accepted')
    local forged=setmetatable({}, {__eq=function() return true end})
    assert(f.server.command_guild(forged,comp,f.server.epoch)==nil,'metatable forged token accepted')
    assert(f.server.command_guild(token,comp,'wrong-epoch')==nil)
    local other={GetFullName=function() return 'other' end}
    assert(f.server.command_guild(token,other,f.server.epoch)==nil)
    return true
end
for _,prio in ipairs({2,3}) do
    local peer=f.server.clients['comp-A']
    local command=require('protocol').envelope('Q',peer.server,peer.client,peer.guild)
        ..'|'..prio..'|Prio|PAL-A|1|'..prio
    assert(f.server.receive_command(f.component,command,0)==true)
    assert(f.server.command_guild(held_token,f.component,f.server.epoch)==nil,
        'completed invocation left its lookup reusable')
end
assert(lookups==2,'expected one fresh lookup per edit, got '..lookups)

for _, mode in ipairs({'reentrant','throw','nonce','peer','session','name_reentry'}) do
    f=fixture(false)
    local held
    f.server.on_command=function(_,_,comp,token)
        held=token
        assert(f.server.command_guild(token,comp,f.server.epoch)=='guild-A')
        if mode=='throw' then error('intentional handler error') end
        if mode=='name_reentry' then
            local who=f.server.who
            f.server.who=function(c)
                f.server.who=who
                f.server.receive_command(c,'invalid',0)
                return who(c)
            end
        elseif mode=='reentrant' then f.server.receive_command(comp,'invalid',0)
        elseif mode=='nonce' then f.server.local_nonce='replacement'
        elseif mode=='peer' then f.server.clients['comp-A']={}
        else f.server.begin_session(f.server.epoch) end
        assert(f.server.command_guild(token,comp,f.server.epoch)==nil)
        return false
    end
    assert(f.client.request_prio('PAL-A',1,2)); f.advance(0.2); f.to_server()
    assert(f.server.command_guild(held,f.component,f.server.epoch)==nil)
end

-- A handler can synchronously replace its session/peer, even while authority
-- remains true. The old request must not write a receipt or send an ACK.
for _, transition in ipairs({'session','nonce','peer'}) do
    f=fixture(false)
    local peer=f.server.clients['comp-A']
    f.server.on_command=function()
        if transition=='session' then f.server.begin_session(f.server.epoch)
        elseif transition=='nonce' then f.server.local_nonce='replacement'
        else f.server.clients['comp-A']={} end
        return true
    end
    assert(f.client.request_prio('PAL-A',1,2)); f.advance(0.2); f.to_server()
    assert(#f.down==0 and next(peer.acks)==nil,
        'replaced session/peer received an old request acknowledgement: '..transition)
end

-- Unknown role is reported honestly and cannot send an echo or increment it.
f=fixture(nil); f.client.installed=true
f.client.report()
assert(table.concat(f.lines,"\n"):find("role: unknown",1,true))
assert(not f.client.selftest() and f.client.stats.echo_sent==0 and #f.up==0)
assert(table.concat(f.lines,"\n"):find("authority is unknown",1,true))

-- Engine hook errors reach the log aggregator, remain contained, and include
-- failure logging in the measured callback interval.
f=fixture(true)
local hooks, buckets = {}, {}
RegisterHook=function(path,fn) hooks[path]=fn end
local log=package.loaded.log
log.perf=true
log.count=function(label)
    buckets[label]=buckets[label] or {ms=0}
    return buckets[label]
end
log.warn=function(message) f.lines[#f.lines+1]=message; f.now=f.now+0.002 end
local function fail() f.now=f.now+0.005; error("deliberate hook failure") end
f.client.receive_command=fail
assert(f.client.install())
local context={get=function() return f.component end}
local name={get=function() return {ToString=function() return "PWP_Hello" end} end}
local value={get=function() return 0 end}
local hook_up=hooks["/Script/Pal.PalNetworkBaseCampComponent:Request_Server_int32"]
local hook_down=hooks["/Script/Pal.PalNetworkBaseCampComponent:Notify_RequestClient_int32"]
assert(pcall(hook_up,context,nil,name,value))
assert(f.lines[#f.lines]:find("network up hook failed",1,true))
assert(math.abs(buckets["hook: net up"].ms-7)<0.001)
package.loaded.palapi.has_authority=function() return false end
f.client.receive_state=fail
assert(pcall(hook_down,context,nil,name,value))
assert(f.lines[#f.lines]:find("network down hook failed",1,true))
assert(math.abs(buckets["hook: net down"].ms-7)<0.001)
local healthy=false
f.client.receive_state=function() healthy=true end
hook_down(context,nil,name,value)
assert(healthy, "a failed callback poisoned the next callback")

-- Freeze both stream revisions for every outcome, including failed delivery and
-- callback reentry during the post-handler authority proof or FName conversion.
for _,outcome in ipairs({true,false,"applied_unsaved"}) do
    for _,boundary in ipairs({'later','authority','fname','lost'}) do
        f=fixture(false)
        local peer=f.server.clients['comp-A']
        local normal=f.server.on_command
        local expected, armed
        f.outcome=outcome
        f.server.on_command=function(...)
            local result=normal(...)
            expected={P=peer.revisions.P,R=peer.revisions.R}
            armed=true
            return result
        end
        local function newer()
            peer.revisions.P=peer.revisions.P+10
            peer.revisions.R=peer.revisions.R+20
        end
        local authority=f.server_api.has_authority
        f.server_api.has_authority=function()
            if armed and boundary=='authority' then armed=false;newer() end
            return authority()
        end
        FName=function(s)
            if armed and s:match('^PWP_V2|A|') and boundary=='fname' then armed=false;newer() end
            return s
        end
        local original_send=f.server.to_client
        local attempted
        f.server.to_client=function(comp,msg,...)
            if boundary=='lost' and msg:match('^PWP_V2|A|') then
                attempted=msg;return false
            end
            return original_send(comp,msg,...)
        end
        assert(f.client.request_prio('PAL-A',1,2));f.advance(0.2)
        local requests=f.to_server()
        local original=attempted or f.down[#f.down]
        local parts=require('protocol').parts(original)
        assert(parts[2]=='A' and tonumber(parts[9])==expected.P and tonumber(parts[10])==expected.R,
            'initial acknowledgement borrowed newer publication: '..boundary)
        newer();f.down={};f.server.to_client=original_send
        assert(f.server.receive_command(f.component,requests[1],0)==outcome)
        assert(f.down[#f.down]==original,'retry changed original result/revisions: '..boundary)
        assert(f.calls==1,'duplicate reapplied mutation')
    end
end

-- A duplicate delivered synchronously during its first handler is still in
-- progress, not stale/rejected. A premature negative ACK would clear the
-- client's pending edit before the original handler finishes.
for _,outcome in ipairs({true,false,"applied_unsaved"}) do
    f=fixture(false)
    local peer=f.server.clients['comp-A']
    local command=require('protocol').envelope('Q',peer.server,peer.client,peer.guild)
        ..'|1|Prio|PAL-A|1|2'
    local normal=f.server.on_command
    f.outcome=outcome
    local duplicate_result,premature
    f.server.on_command=function(...)
        local before=#f.down
        duplicate_result=f.server.receive_command(f.component,command,0)
        premature=#f.down-before
        return normal(...)
    end
    assert(f.server.receive_command(f.component,command,0)==outcome)
    assert(duplicate_result==false and premature==0,'in-flight duplicate emitted premature rejection')
    assert(f.calls==1,'reentrant duplicate invoked mutation twice')
    local acknowledgements=0
    for _,message in ipairs(f.down)do
        if message:match('^PWP_V2|A|')then acknowledgements=acknowledgements+1 end
    end
    assert(acknowledgements==1,'original edit did not produce exactly one result')
end

-- An exception can happen AFTER the mutation. It is not proof of rejection.
-- Keep the request unknown, never replay its mutator, and let client timeout
-- force a fresh complete snapshot instead of trusting a negative ACK.
f=fixture(false)
local thrown_calls=0
f.server.on_command=function(command)
    if command:match('^PWP_Prio|')then
        thrown_calls=thrown_calls+1;f.priority=4
        error('simulated failure after mutation')
    end
end
assert(f.client.request_prio('PAL-A',1,4));f.advance(0.2)
local unknown_request=f.to_server()[1]
assert(f.priority==4 and thrown_calls==1)
assert(#f.down==0,'handler exception falsely acknowledged rejection')
assert(f.server.receive_command(f.component,unknown_request,0)==false)
assert(#f.down==0 and thrown_calls==1,'unknown outcome replayed or became rejected')
assert(select(2,f.client.pending_priority('PAL-A',1)))
f.advance(9)
assert(f.client.status=='connecting' and f.client.status_reason=='ack_timeout')
assert(f.events[#f.events].status=='timed_out')
assert(f.server.push_pals(f.rows,f.component));f.to_client()
assert(f.client.pals['PAL-A'].prios[1]==4)
assert(f.events[#f.events].status=='timed_out','resync invented an edit acknowledgement')

-- Reservation lasts through post-handler callbacks, not just the mutator.
for _,boundary in ipairs({'authority','logging','malformed','other_id','role','session','peer'})do
    f=fixture(false)
    local peer=f.server.clients['comp-A']
    local wire=require('protocol')
    local request=wire.envelope('Q',peer.server,peer.client,peer.guild)..'|1|Prio|PAL-A|1|2'
    local second=wire.envelope('Q',peer.server,peer.client,peer.guild)..'|2|Prio|PAL-A|1|3'
    local normal=f.server.on_command
    local armed,observed,premature=false,false,0
    local function nested(message)
        local count=#f.down
        f.server.receive_command(f.component,message,0)
        premature=premature+#f.down-count;observed=true
    end
    local real_authority=f.server_api.has_authority
    f.server_api.has_authority=function()
        if armed and boundary=='authority'then armed=false;nested(request) end
        return real_authority()
    end
    local logger=package.loaded.log
    local warn=logger.warn
    logger.warn=function(message)
        if armed and boundary=='logging'then armed=false;nested(request)end
        warn(message)
    end
    local marker={}
    f.server.on_command=function(...)
        if boundary=='malformed'then nested(request..'|invalid')
        elseif boundary=='other_id'then
            local high=peer.high;nested(second);assert(peer.high==high)
        end
        local result=normal(...);armed=true
        if boundary=='logging'then error('after mutation')
        elseif boundary=='role'then f.server_api.has_authority=function()return false end
        elseif boundary=='session'then f.server.begin_session(f.server.epoch)
        elseif boundary=='peer'then f.server.clients['comp-A']={inflight=marker}end
        return result
    end
    f.server.receive_command(f.component,request,0)
    assert(peer.inflight==nil,'reservation leaked: '..boundary)
    assert(premature==0,'premature reply across '..boundary)
    assert(f.calls==1,'overlapping mutation admitted: '..boundary)
    if boundary=='peer'then assert(f.server.clients['comp-A'].inflight==marker)end
    if boundary=='authority' or boundary=='logging' or boundary=='malformed' or boundary=='other_id'then
        assert(observed,'fault boundary was not exercised: '..boundary)
    end
    if boundary=='other_id'then
        f.server.on_command=normal
        assert(f.server.receive_command(f.component,second,0)==true and f.calls==2,
            'unadmitted request could not run after original completed')
    end
end

-- Completed results stay replayable during another edit, using frozen revisions.
f=fixture(false)
local peer=f.server.clients['comp-A']
local prefix=require('protocol').envelope('Q',peer.server,peer.client,peer.guild)
local first=prefix..'|1|Prio|PAL-A|1|2'
local second=prefix..'|2|Prio|PAL-A|1|3'
assert(f.server.receive_command(f.component,first,0)==true)
local first_ack=f.down[#f.down]
local normal=f.server.on_command
local replayed
f.server.on_command=function(...)
    local result=normal(...)
    assert(f.server.receive_command(f.component,first,0)==true)
    replayed=f.down[#f.down]
    return result
end
assert(f.server.receive_command(f.component,second,0)==true)
assert(replayed==first_ack and f.calls==2 and peer.inflight==nil)

-- Diagnostic failures and a throwing post-handler authority probe cannot strand
-- the reservation or turn an uncertain write into a rejection.
for _,fault in ipairs({'format','logger','authority_throw'})do
    f=fixture(false)
    local peer=f.server.clients['comp-A']
    local base=require('protocol').envelope('Q',peer.server,peer.client,peer.guild)
    local first=base..'|1|Prio|PAL-A|1|4'
    local second=base..'|2|Prio|PAL-A|1|3'
    local normal=f.server.on_command
    local calls=0
    f.server.on_command=function(...)
        calls=calls+1;f.priority=4
        if fault=='authority_throw'then
            local old=f.server_api.has_authority
            f.server_api.has_authority=function()f.server_api.has_authority=old;error('authority failed')end
            return true
        end
        if fault=='logger'then package.loaded.log.warn=function()error('logger failed')end;error('handler failed')end
        error(setmetatable({}, {__tostring=function()error('formatter failed')end}))
    end
    local safe=pcall(f.server.receive_command,f.component,first,0)
    assert(safe and peer.inflight==nil,'diagnostic/probe failure stranded reservation: '..fault)
    assert(#f.down==0,'uncertain handler produced an ACK: '..fault)
    assert(f.server.receive_command(f.component,first,0)==false and calls==1)
    f.server.on_command=normal
    assert(f.server.receive_command(f.component,second,0)==true and f.calls==1,
        'next distinct request blocked by stranded reservation: '..fault)
end

-- Pending memory acceptance has no final ACK. Client keeps its old confirmed
-- view, then times out; duplicate delivery never invokes the mutator again.
for _,stream in ipairs({'P','R'})do
    f=fixture(false)
    local calls=0
    f.server.on_command=function()
        calls=calls+1
        if stream=='P'then f.priority=4 else f.amount=400 end
        return false,'pending',{revision=1}
    end
    if stream=='P'then assert(f.client.request_prio('PAL-A',1,4));f.advance(0.2)
    else assert(f.client.request('set','Mining','Stone',400))end
    local request=f.to_server()[1]
    assert(#f.down==0 and calls==1,'pending memory generated final ACK')
    local record=f.server.clients['comp-A'].acks[1]
    assert(record.unknown==true and record.reason=='pending')
    assert(f.client.pals['PAL-A'].prios[1]==1 and f.view[1].amount==100)
    assert(f.server.receive_command(f.component,request,0)==false)
    assert(#f.down==0 and calls==1)
    f.advance(9)
    assert(f.client.status_reason=='ack_timeout' and f.events[#f.events].status=='timed_out')
end

-- Publication policy covers both streams and every send boundary, including
-- reconnect/full broadcasts. Denial is not an empty snapshot or a revision.
for _,stream in ipairs({'P','R'})do
    for _,boundary in ipairs({'denied','provider_throw','build','fname','send','provider_replace','guard_session','guard_peer'})do
        f=fixture(false)
        local peer=f.server.clients['comp-A']
        local revision=peer.revisions[stream]
        local valid=boundary~='denied'
        local guard_armed=false
        f.server.publication_guard=function(which)
            assert(which==stream)
            if boundary=='provider_throw'then error('guard unavailable')end
            return function()
                if guard_armed then
                    guard_armed=false
                    if boundary=='guard_session'then f.server.begin_session(f.server.epoch)
                    elseif boundary=='guard_peer'then f.server.clients['comp-A']={}end
                end
                return valid
            end
        end
        local rows=f.rows
        local caps={all=function(...)
            if boundary=='build'then valid=false end
            return f.caps.all(...)
        end}
        local function roster(...)
            if boundary=='build'then valid=false end
            return rows(...)
        end
        FName=function(message)
            if message:match('^PWP_V2|[BDEU]|')then
                guard_armed=true
                if boundary=='fname'then valid=false end
                if boundary=='provider_replace'then f.server.publication_guard=function()return function()return true end end end
            end
            return message
        end
        local notify=f.component.Notify_RequestClient_int32
        f.component.Notify_RequestClient_int32=function(self,...)
            notify(self,...)
            if boundary=='send'then valid=false end
        end
        local result
        if stream=='P'then result=f.server.push_pals(roster,f.component)
        else result=f.server.push_rules(caps,{},f.component)end
        assert(not result and peer.revisions[stream]==revision,'invalidated snapshot committed: '..stream..' '..boundary)
        assert(#f.down==(boundary=='send' and 1 or 0),'unexpected packet count: '..boundary)
    end
end
