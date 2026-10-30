-- Round 4 (multiplayer P2-1, P2-2): a real client and a real server transport.
--
-- P2-1: a player who changes guild while connected kept the old guild in the
-- transport. The panel asked with the live guild and was refused, the server
-- dropped the peer without a word, and only an edit that timed out after 8 s
-- led to a reconnect. A server that stops answering counts does the same.
--
-- P2-2: the server kept one peer entry per join and refused every new modded
-- player once 128 had piled up, until it restarted.
local time = 0
os.clock = function() return time end
local LATENCY = 0.15
package.loaded.log = {warn=function()end, debug=function()end, say=function()end}
package.loaded.settings_gate = {blocked=function() return false end, status=function() return 'ok' end}

local owner = {guild='guild-A'}
local link = {up={}, down={}, sends={}}
local tx, comp
tx = {GetFullName=function() return 'tx-1' end, GetOwner=function() return owner end,
    GetComponentByClass=function() return comp end}
comp = {GetFullName=function() return 'component-1' end, GetOuter=function() return tx end,
    Notify_RequestClient_int32=function(_, _, msg) link.down[#link.down+1] = {at=time+LATENCY, msg=msg} end}
local outgoing = {Request_Server_int32=function(_, _, msg)
    if msg:find('|T|', 1, true) then link.sends[#link.sends+1] = time end
    if msg:sub(1, 9) == 'PWP_Hello' then link.hellos = (link.hellos or 0) + 1 end
    link.up[#link.up+1] = {at=time+LATENCY, msg=msg}
end}
-- What a component scan finds: the connected component only, unless a test
-- makes the scan blind.
local scan_blind = false
FindAllOf = function(class)
    if class == 'PalNetworkTransmitter' then return {tx} end
    if scan_blind then return {} end
    return {comp}
end
FName = function(s) return s end
-- The client's own guild as its PlayerState says it; nil models a build
-- without my_guild, so only the unanswered-count route can notice.
local live_guild = function() return owner.guild end
local function instance(authority)
    package.loaded.palapi = {has_authority=function() return authority end,
        valid=function(o) return type(o) == 'table' end, guild_of=function(o) return o.guild end,
        cdo=function() return {} end, owned_network_component=function() return outgoing end,
        my_guild=not authority and function() return live_guild and live_guild() end or nil}
    package.loaded.net = nil
    return require('net')
end
local server = instance(true)
local client = instance(false)
server.begin_session(1); client.begin_session(2)

local rules = {['guild-A']={Deforest={Wood=1}}, ['guild-C']={Mining={Stone=50}}}
local caps = {all=function(_, guild) return rules[guild] or {} end}
server.on_command = function(_, _, c)
    assert(server.push_rules(caps, {}, c))
    assert(server.push_pals(function() return {} end, c))
end
server.on_storage_interest = function() return true end
server.on_storage_request = function(guild)
    return {scope='camp', camp='camp-' .. guild, choices={'camp-' .. guild}, verified=true,
        totals={Wood=500, Stone=1200}, age_ms=0, remaining_ms=40000}
end
server.on_limit_state = function() return {per_item=true, verdicts={}, stopped={}} end
client.on_snapshot = function() return true end

-- main.lua's beats: storage open while the panel is, the panel asking with
-- the live guild on every draw, the 100 ms poll.
local panel_guild = function() return owner.guild end
local function pump(seconds)
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
            client.request_stock(panel_guild(), nil)
            client.storage_tick(); client.poll()
        end
    end
end
local function counted()
    local view = client.storage_view(panel_guild(), nil)
    return view.verified == true
end

assert(client.hello())
pump(2)
assert(client.status == 'ready' and client.guild == 'guild-A', 'never connected: ' .. tostring(client.status))
assert(counted(), 'no count before the guild change')

-- 1. The player joins guild C. The server sees the new guild at once (it is
-- the server's own state); the client reads it from its PlayerState.
owner.guild = 'guild-C'
local hellos = link.hellos
pump(8)
assert(client.guild == 'guild-C', 'the transport kept the old guild: ' .. tostring(client.guild))
assert(client.status == 'ready', 'the new join did not connect: ' .. tostring(client.status_reason))
assert(link.hellos == hellos + 1, 'a guild change sent ' .. (link.hellos - hellos) .. ' Hellos')
assert(counted(), "the new guild's counts never arrived")
pump(30)
assert(link.hellos == hellos + 1, 'a settled guild kept rejoining')

-- 2. No live guild to compare (an older palapi, or an unreadable
-- PlayerState), and the server forgot this peer. Counts go unanswered; after
-- two in a row the client joins again on its own.
live_guild = nil
pump(5)
server.clients = {}
hellos = link.hellos
pump(70)
assert(link.hellos == hellos + 1, 'two unanswered counts did not lead to a new join: '
    .. (link.hellos - hellos) .. ' Hellos')
assert(client.status == 'ready' and counted(), 'the client did not recover its counts')

-- 3. A peer the server makes again for the same client nonce continues the
-- server's revisions. Starting again at 1 read as stale on a client that
-- still held the old ones, so its invalidated stream never became ready.
server.clients = {}
client.clear_pal_incoming()
assert(client.status == 'connecting')
local same_nonce, nonce = link.hellos, client.local_nonce
for _ = 1, 200 do
    if link.hellos > same_nonce then break end
    pump(0.05)
end
assert(link.hellos == same_nonce + 1 and client.local_nonce == nonce, 'no Hello with the same nonce')
pump(1)
assert(link.hellos == same_nonce + 1)
assert(client.status == 'ready', 'a re-made peer stayed stale: ' .. tostring(client.status_reason))

-- 4. P2-2: 128 entries of joins long gone, then a new player's Hello.
local function fill()
    server.clients = {}
    for i = 1, 128 do
        server.clients['gone-' .. i] = {server=server.local_nonce, client='n' .. i, guild='guild-A',
            at=i, acks={}, order={}, high=0, revisions={P=0,R=0}, next_revision={P=0,R=0}}
    end
end
fill()
client.begin_session(3)
assert(client.hello())
pump(3)
assert(client.status == 'ready', 'a full peer table refused a new player: ' .. tostring(client.status_reason))
local left = 0
for name in pairs(server.clients) do
    left = left + 1
    assert(name == 'component-1', 'a dead entry survived the prune: ' .. name)
end
assert(left == 1)

-- A scan that cannot even see the sender is not trusted: one entry, the one
-- heard from longest ago, makes room, and nothing else is dropped.
fill()
scan_blind = true
client.begin_session(4)
assert(client.hello())
pump(3)
scan_blind = false
assert(client.status == 'ready', 'a blind scan refused a new player')
assert(server.clients['gone-1'] == nil and server.clients['gone-2'] ~= nil
    and server.clients['component-1'] ~= nil, 'the blind fallback did not evict only the oldest')

package.loaded.net = nil
print('net rejoin: guild change and unanswered counts join again, revisions continue, a full peer table is pruned')
