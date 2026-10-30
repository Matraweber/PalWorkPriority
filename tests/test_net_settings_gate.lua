local gate=require('settings_gate')
local wire=require('protocol')
FName=function(s)return s end
package.loaded.log={warn=function()end,debug=function()end,say=function()end}
local up,down={},{}
local comp={guild='guild-A'}
function comp:GetFullName()return 'component-A' end
local on_send
function comp:Notify_RequestClient_int32(_,message)
    down[#down+1]=message
    if on_send then on_send(message)end
end
local tx={Request_Server_int32=function(_,guid,name,value)up[#up+1]={name,value}end}
local function instance(authority)
    package.loaded.palapi={valid=function(o)return type(o)=='table'end,
        has_authority=function()return authority end,owned_network_component=function()return tx end}
    package.loaded.net=nil
    local n=require('net');n.guild_of_sender=function(c)return c.guild end
    return n
end
local server,client=instance(true),instance(false)
local applied,edits=0,0
client.on_snapshot=function()applied=applied+1;return true end
server.on_command=function()edits=edits+1;return true end
local function handshake()
    server.begin_session(1);client.begin_session(2);up,down={},{}
    assert(client.hello())
    assert(server.receive_command(comp,up[1][1],0));up={}
    assert(client.receive_state(down[1]));down={}
    assert(server.receive_command(comp,up[1][1],0));up={}
end
local function push(stream)
    if stream=='P' then return server.push_pals(function()
        return {{key='PAL-A',ranks={[1]=1},prios={[1]=2}}}
    end,comp) end
    return server.push_rules({all=function()return {Mining={Stone=100}}end},{},comp)
end
for _,stream in ipairs({'P','R'})do
    for _,mid in ipairs({false,true})do
        handshake();down={}
        local token
        if not mid then token=assert(gate.acquire());assert(gate.require_restart(token))end
        on_send=function(message)
            if mid and not token then token=assert(gate.acquire());assert(gate.require_restart(token))end
        end
        assert(push(stream)==false,'blocked snapshot reported success')
        on_send=nil
        assert(server.clients['component-A'].revisions[stream]==0,'blocked revision committed')
        local unavailable
        for _,msg in ipairs(down)do
            if msg:find('PWP_V2|L|',1,true)==1 then unavailable=msg end
            client.receive_state(msg)
        end
        assert(unavailable,'authenticated peer received no unavailable message')
        assert(client.status=='unavailable' and client.status_reason=='settings_restart_required')
        assert(not client.request_prio('PAL-A',1,3))
        assert(not client.request('set','Mining','Stone',200))
        local seen=applied
        for _,s in ipairs({'P','R'})do
            local rows=s=='P' and {'PAL-A|11111111111111|22222222222222'} or {'Mining|Stone|100'}
            for _,msg in ipairs(assert(wire.snapshot(server.local_nonce,client.local_nonce,'guild-A',s,99,'F',rows)))do
                assert(client.receive_state(msg)==false,'snapshot cleared lock')
            end
        end
        assert(client.receive_state(wire.envelope('A',server.local_nonce,client.local_nonce,'guild-A')..'|1|1|applied|99|99')==false)
        assert(applied==seen and client.status=='unavailable')
        local before=edits
        server.receive_command(comp,wire.envelope('Q',server.local_nonce,client.local_nonce,'guild-A')..'|1|Set|Mining|Stone|200',0)
        assert(edits==before,'blocked request reached mutation handler')
        assert(gate.release(token))
        client.begin_session(3)
        assert(client.status=='connecting' and not client.receive_state(unavailable),'old unavailable crossed session')
        handshake();down={};assert(push('P'));assert(push('R'))
        for _,msg in ipairs(down)do client.receive_state(msg)end
        assert(client.status=='ready','reset did not clear session lock')
    end
end
-- Unconfirmed/old-schema peers receive no lock or snapshots.
handshake();down={};assert(push('P'));assert(push('R'))
for _,message in ipairs(down)do assert(client.receive_state(message))end
down={};up={}
assert(client.request('set','Mining','Stone',200))
assert(server.receive_command(comp,up[1][1],0))
local delayed_ack=down[#down]
assert(delayed_ack:find('PWP_V2|A|',1,true)==1)
assert(client.request_prio('PAL-A',1,4)) -- queued overlay must also disappear
local pending_token=assert(gate.acquire());down={};assert(not push('R'))
assert(client.receive_state(down[#down]))
assert(not client.receive_state(delayed_ack) and client.status=='unavailable')
assert(select(2,client.pending_priority('PAL-A',1))==false)
assert(gate.release(pending_token))

handshake();down={}
local token=assert(gate.acquire())
local edits_before=edits
local notified,real_notify=0,server.notify_old_client
server.notify_old_client=function(c) assert(c==comp); notified=notified+1 end
assert(not server.receive_command(comp,'PWP_Hello|2|14|old-client',0))
assert(#down==1 and down[1]:find('PWP_Incompatible|'..wire.SCHEMA..'|14',1,true)==1)
assert(notified==1,'an old Hello did not trigger the in-game update notice')
server.notify_old_client=real_notify
assert(edits==edits_before)
down={}
local nonce=client.local_nonce
for _,message in ipairs({
    wire.envelope('L','wrong-server',nonce,'guild-A')..'|settings_recovering',
    wire.envelope('L',server.local_nonce,'wrong-client','guild-A')..'|settings_recovering',
    wire.envelope('L',server.local_nonce,nonce,'wrong-guild')..'|settings_recovering',
    wire.envelope('L',server.local_nonce,nonce,'guild-A')..'|unknown_reason',
    wire.envelope('L',server.local_nonce,nonce,'guild-A')..'|settings_recovering|extra'
})do assert(not client.receive_state(message));assert(client.status~='unavailable')end
assert(not push('R'));assert(client.receive_state(down[#down]))
assert(client.status_reason=='settings_recovering')
assert(client.receive_state('PWP_Welcome|'..wire.SCHEMA..'|14|'..nonce..'|'..server.local_nonce..'|guild-A|99'))
assert(client.status=='unavailable' and client.status_reason=='settings_recovering',
    'same-session Welcome cleared recovery lock')
assert(gate.require_restart(token));down={};assert(not push('P'))
assert(client.receive_state(down[#down]) and client.status_reason=='settings_restart_required')
assert(client.receive_state(wire.envelope('L',server.local_nonce,nonce,'guild-A')..'|settings_recovering'))
assert(client.status_reason=='settings_restart_required','late recovering downgraded terminal lock')
assert(client.receive_state('PWP_Welcome|'..wire.SCHEMA..'|14|'..nonce..'|'..server.local_nonce..'|guild-A|100'))
assert(client.status_reason=='settings_restart_required','same-session handshake cleared terminal lock')
assert(gate.release(token))

-- A new server nonce invalidates the old receiver and rotates the client
-- nonce. The triggering Welcome itself cannot supply a ready replacement.
local old_lock=wire.envelope('L',server.local_nonce,nonce,'guild-A')..'|settings_restart_required'
assert(not client.receive_state('PWP_Welcome|'..wire.SCHEMA..'|14|'..nonce..'|new-server|guild-A|101'))
assert(client.local_nonce~=nonce and client.status=='connecting')
assert(not client.receive_state(old_lock))
assert(not client.request('set','Mining','Stone',200))

-- A synchronous send may replace the server session. No old continuation,
-- revision commit or handler call may follow the unavailable notification.
for _,stream in ipairs({'P','R'})do
    handshake();down={};token=assert(gate.acquire())
    local peer=server.clients['component-A'];local fired=0
    on_send=function(message)
        if message:find('PWP_V2|L|',1,true)==1 then
            fired=fired+1;server.begin_session(99)
        end
    end
    assert(not push(stream));on_send=nil
    assert(fired==1 and #down==1 and peer.revisions[stream]==0)
    assert(next(server.clients)==nil)
    assert(gate.release(token))
end
print('network gate: both streams, midstream fence, session-bound lock and reset passed')

-- ACK construction invokes native FName: fencing there must send L, never A.
handshake();down={};up={}
local ack_token,ack_boundary
FName=function(s)
    if s:find('PWP_V2|A|',1,true)==1 then
        ack_boundary=true;ack_token=assert(gate.acquire());assert(gate.require_restart(ack_token))
    end
    return s
end
server.receive_command(comp,wire.envelope('Q',server.local_nonce,client.local_nonce,'guild-A')..'|1|Set|Mining|Stone|200',0)
FName=function(s)return s end
assert(ack_boundary,'ACK boundary never exercised')
local locks=0
for _,msg in ipairs(down)do
    assert(msg:find('PWP_V2|A|',1,true)~=1,'ACK escaped FName fence')
    if msg:find('PWP_V2|L|',1,true)==1 then locks=locks+1 end
end
assert(locks==1,'fenced ACK did not report unavailable')
assert(gate.release(ack_token))

local real_clock=os.clock
local time=1000
os.clock=function()return time end
handshake();down={};up={}
local retry_token=assert(gate.acquire())
assert(not push('R'));local stale_lock=down[#down];assert(client.receive_state(stale_lock))
local function finish_handshake()
    assert(#up==1);local hello=up[1][1];up={};down={}
    assert(server.receive_command(comp,hello,0))
    assert(client.receive_state(down[1]));down={}
    assert(#up==1);server.receive_command(comp,up[1][1],0);up={}
    for _,msg in ipairs(down)do client.receive_state(msg)end
    down={}
end
for _,delay in ipairs({5,10,20,30,30})do
    local old_nonce=client.local_nonce
    time=time+delay-0.01;client.poll();assert(#up==0,'recovering retried early')
    time=time+0.02;client.poll()
    -- Round 5 (multiplayer P3-2): the retry keeps showing the lock until the
    -- server answers; it said "connecting" for that moment before.
    assert(client.local_nonce~=old_nonce and client.status=='unavailable'
        and client.status_reason=='settings_recovering')
    assert(not client.receive_state(stale_lock) and not client.request_prio('PAL-A',1,3))
    finish_handshake()
    assert(client.status=='unavailable' and client.status_reason=='settings_recovering')
end
-- When the server becomes ready, retry negotiates normally, but it still
-- cannot grant editing before BOTH full snapshot streams have arrived.
assert(gate.release(retry_token));time=time+31;client.poll();finish_handshake()
-- Round 5 (multiplayer P3-2): still the lock, not "connecting", until both
-- snapshots prove it lifted.
assert(client.status=='unavailable')
assert(push('P'));for _,msg in ipairs(down)do client.receive_state(msg)end;down={}
assert(client.status=='unavailable' and not client.request_prio('PAL-A',1,3))
assert(push('R'));for _,msg in ipairs(down)do client.receive_state(msg)end;down={}
assert(client.status=='ready')
retry_token=assert(gate.acquire());assert(gate.require_restart(retry_token))
assert(not push('R'));assert(client.receive_state(down[#down]));up={}
local terminal_nonce=client.local_nonce
time=time+1000;client.poll()
assert(#up==0 and client.local_nonce==terminal_nonce and client.status_reason=='settings_restart_required')
assert(gate.release(retry_token));os.clock=real_clock
print('ACK FName fencing and bounded recovering-only fresh handshake retries passed')
