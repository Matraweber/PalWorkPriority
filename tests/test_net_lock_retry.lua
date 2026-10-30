-- Round 5 (multiplayer P3-2): a client locked out by the server's refused
-- config.lua keeps saying so while it asks again.
--
-- The retry started a new session, which set "connecting" until the next
-- lock message arrived. For that moment the stand legend and the panel
-- dropped "config.lua was rejected" and showed the normal legend or
-- "Connecting...", every 30 s. Each retry is also four RPCs, each a new
-- FName the engine never frees, for a lock only the host can lift.
local time = 0
os.clock = function() return time end
local LATENCY = 0.15
package.loaded.log = {warn=function()end, debug=function()end, say=function()end}
package.loaded.settings_gate = {blocked=function() return false end, status=function() return 'ok' end}

local owner = {guild='guild-A'}
local link = {up={}, down={}, hello_at={}, cut=false}
local tx, comp
tx = {GetFullName=function() return 'tx-1' end, GetOwner=function() return owner end,
    GetComponentByClass=function() return comp end}
comp = {GetFullName=function() return 'component-1' end, GetOuter=function() return tx end,
    Notify_RequestClient_int32=function(_, _, msg)
        if not link.cut then link.down[#link.down+1] = {at=time+LATENCY, msg=msg} end
    end}
local outgoing = {Request_Server_int32=function(_, _, msg)
    if msg:sub(1, 9) == 'PWP_Hello' then link.hello_at[#link.hello_at+1] = time end
    if not link.cut then link.up[#link.up+1] = {at=time+LATENCY, msg=msg} end
end}
FindAllOf = function(class)
    if class == 'PalNetworkTransmitter' then return {tx} end
    return {comp}
end
FName = function(s) return s end
local function instance(authority)
    package.loaded.palapi = {has_authority=function() return authority end,
        valid=function(o) return type(o) == 'table' end, guild_of=function(o) return o.guild end,
        cdo=function() return {} end, owned_network_component=function() return outgoing end,
        my_guild=not authority and function() return owner.guild end or nil}
    package.loaded.net = nil
    return require('net')
end
local server = instance(true)
local client = instance(false)
server.begin_session(1); client.begin_session(2)

local LOCK = 'server_config_rejected'
local lock = LOCK
server.server_lock = function() return lock end
local caps = {all=function() return {Deforest={Wood=1}} end}
server.on_command = function(_, _, c)
    assert(server.push_rules(caps, {}, c))
    assert(server.push_pals(function() return {} end, c))
end
server.on_storage_interest = function() return true end
server.on_storage_request = function()
    return {scope='camp', camp='camp-A', choices={'camp-A'}, verified=true,
        totals={Wood=500}, age_ms=0, remaining_ms=40000}
end
client.on_snapshot = function() return true end
-- main.lua's two callbacks, as far as the panel sees them: on_status sets
-- caps.remote_state, a new session resets it to "connecting".
local remote_state
client.on_status = function(status) remote_state = status end
client.on_session = function() remote_state = 'connecting' end

local function pump(seconds, each)
    local stop = time + seconds
    while time < stop - 1e-9 do
        time = time + 0.05
        local keep = {}
        for _, m in ipairs(link.up) do
            if m.at <= time then server.receive_command(comp, m.msg, 0) else keep[#keep+1] = m end
        end
        link.up = keep
        local batch = link.down
        link.down = {}
        for _, m in ipairs(batch) do
            if m.at <= time then client.receive_state(m.msg) else link.down[#link.down+1] = m end
        end
        if math.floor(time*20+0.5) % 2 == 0 then
            server.storage_tick()
            client.set_storage_open(true)
            client.request_stock('guild-A', nil)
            client.storage_tick(); client.poll()
        end
        if each then each() end
    end
end

assert(client.hello())
pump(2)
assert(client.status == 'unavailable' and client.status_reason == LOCK,
    'the client was not locked: ' .. tostring(client.status) .. ' ' .. tostring(client.status_reason))

-- 1. Through several retries, every beat: the stand (net.status) and the
-- panel (remote_state) both still say why.
local first = #link.hello_at
pump(200, function()
    assert(client.status == 'unavailable' and client.status_reason == LOCK,
        'the lock flickered to ' .. tostring(client.status) .. ' ' .. tostring(client.status_reason)
        .. ' at ' .. time)
    assert(remote_state == 'unavailable', 'the panel flickered to ' .. tostring(remote_state) .. ' at ' .. time)
end)
local retries = #link.hello_at - first
assert(retries >= 3, 'the locked client stopped asking: ' .. retries .. ' retries')
-- A lock only the host can lift is asked about once a minute at most.
local gap = link.hello_at[#link.hello_at] - link.hello_at[#link.hello_at - 1]
assert(gap >= 59, 'a config.lua lock was retried after ' .. gap .. ' s')

-- 2. The host fixes the file: the next retry gets in, without "connecting"
-- on the way.
lock = nil
local states = {}
pump(65, function()
    if states[#states] ~= client.status then states[#states+1] = client.status end
end)
assert(client.status == 'ready', 'the client never got back in: ' .. tostring(client.status_reason))
assert(table.concat(states, ',') == 'unavailable,ready', 'on the way in: ' .. table.concat(states, ','))
assert(remote_state == 'ready')

-- 3. Locked again, and then the server stops answering: the lock is not
-- held for good. The usual handshake timeout follows.
lock = LOCK
pump(15)
assert(client.status == 'unavailable' and client.status_reason == LOCK, 'not locked again')
link.cut = true
pump(160)
assert(client.status == 'connecting' and client.status_reason == 'handshake_timeout',
    'a silent server left the lock shown: ' .. tostring(client.status) .. ' ' .. tostring(client.status_reason))

package.loaded.net = nil
print('net lock retry: the lock stays shown through retries, once a minute, ready without flicker, a silent server times out')
