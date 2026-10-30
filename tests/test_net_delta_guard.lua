-- Round 5 (multiplayer P3-1): a delta is never the first priority table a
-- peer gets.
--
-- The guard tested peer.revisions.P == 0. A new peer starts at the server's
-- running count (round 4, so a re-made peer is not read as stale), so once
-- any push had happened the guard never held. A peer that is listed but
-- whose full table never went out (the Hello budget refused it, its guild
-- did not resolve, the roster build failed) then got a delta for the next
-- stand change.
local time = 0
os.clock = function() return time end
package.loaded.log = {warn=function()end, debug=function()end, say=function()end}
package.loaded.settings_gate = {blocked=function() return false end, status=function() return 'ok' end}

local owner = {guild='guild-A'}
local down = {}
local tx, comp
tx = {GetFullName=function() return 'tx-1' end, GetOwner=function() return owner end,
    GetComponentByClass=function() return comp end}
comp = {GetFullName=function() return 'component-1' end, GetOuter=function() return tx end,
    Notify_RequestClient_int32=function(_, _, msg) down[#down+1] = msg end}
FindAllOf = function(class)
    if class == 'PalNetworkTransmitter' then return {tx} end
    return {comp}
end
FName = function(s) return s end
package.loaded.palapi = {has_authority=function() return true end,
    valid=function(o) return type(o) == 'table' end, guild_of=function(o) return o.guild end,
    cdo=function() return {} end}
package.loaded.net = nil
local server = require('net')
local wire = require('protocol')
server.begin_session(1)

local function rows()
    return {{key='PAL-A', ranks={1,1,1,1,1,1,1,1,1,1,1,1,1,1}, prios={}}}
end
-- What main's Hello handler does: the full table, unless the announcement
-- budget (or an unresolved guild) refuses this Hello.
local announce = true
server.on_command = function(_, _, c)
    if announce then assert(server.push_pals(rows, c)) end
end
local function join(nonce)
    down = {}
    assert(server.receive_command(comp, 'PWP_Hello|' .. server.SCHEMA .. '|' .. server.WORKS .. '|' .. nonce, 0))
    local p = wire.parts(down[#down])
    assert(p and p[1] == 'PWP_Welcome', 'no Welcome')
    time = time + 0.2
    assert(server.receive_command(comp, wire.envelope('C', p[5], p[4], p[6]) .. '|' .. p[7], 0), 'no confirm')
    return server.clients['component-1']
end
local function deltas()
    local n = 0
    for _, msg in ipairs(down) do
        local p = wire.parts(msg)
        if p and p[1] == 'PWP_V2' and p[6] == 'P' and (p[2] == 'U' or (p[2] == 'B' and p[8] == 'D')) then
            n = n + 1
        end
    end
    return n
end

-- A peer that got its full table takes deltas as before.
local first = join('nonce-1')
assert(first and first.revisions.P > 0, 'the full table never went out')
down = {}
assert(server.push_pals(rows, nil, 'PAL-A'), 'a peer with a full table got no delta')
assert(deltas() == 1, 'expected one delta, saw ' .. deltas())
assert(server.revisions.P > 0)

-- The entry is pruned; the same player's next Hello is listed, but this
-- time the budget refuses the announcement, so no full table goes out.
server.clients = {}
announce = false
time = time + 2
local peer = join('nonce-1')
assert(peer and peer ~= first, 'the peer was not made again')
assert(peer.revisions.P > 0, 'the new peer did not continue the server revision')
down = {}
server.push_pals(rows, nil, 'PAL-A')
assert(deltas() == 0, 'a peer with no full table was sent a delta')
assert(#down == 0, 'a peer with no full table was sent ' .. #down .. ' packets')

-- Its full table goes out later (a second Hello the budget allows): deltas
-- follow again.
assert(server.push_pals(rows, comp))
down = {}
assert(server.push_pals(rows, nil, 'PAL-A'))
assert(deltas() == 1, 'deltas did not resume after the full table')

-- The rules stream has no delta: every R push is a full table.
local caps = {all=function() return {Mining={Stone=50}} end}
down = {}
assert(server.push_rules(caps, {}, nil))
for _, msg in ipairs(down) do
    local p = wire.parts(msg)
    assert(not (p[2] == 'B' and p[8] == 'D'), 'a rules delta went out')
end

package.loaded.net = nil
print('net delta guard: no priority delta before a full table, deltas resume after it')
