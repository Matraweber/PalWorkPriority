-- Round 3 (performance P2-1, engine-safety P2-1, multiplayer P3-1): every
-- limit edit makes the server send every peer a fresh R snapshot of its own
-- guild, most of them unchanged. Each one made the client drop its verdict
-- and request a new count within 0.1 s, so one player stepping a limit made
-- every open panel on the server flicker and cost the server two transmitter
-- walks (about 50 ms) per panel per edit. Two real clients in two guilds
-- against a real server: guild A's edit must leave guild B's panel alone.
local status = require('panel_status')
local time = 0
os.clock = function() return time end
local LATENCY = 0.15
package.loaded.log = {warn=function()end, debug=function()end, say=function()end}
package.loaded.settings_gate = {blocked=function() return false end, status=function() return 'ok' end}

local links, comps, txs = {}, {}, {}
for _, g in ipairs({'A', 'B'}) do
    local owner = {guild='guild-' .. g}
    local link = {up={}, down={}, sends={}}
    links[g] = link
    txs[g] = {GetFullName=function() return 'tx-' .. g end, GetOwner=function() return owner end,
        GetComponentByClass=function() return comps[g] end}
    comps[g] = {GetFullName=function() return 'component-' .. g end, GetOuter=function() return txs[g] end,
        Notify_RequestClient_int32=function(_, _, msg) link.down[#link.down+1] = {at=time+LATENCY, msg=msg} end}
    link.outgoing = {Request_Server_int32=function(_, _, msg)
        if msg:find('|T|', 1, true) then link.sends[#link.sends+1] = time end
        link.up[#link.up+1] = {at=time+LATENCY, msg=msg}
    end}
end
FindAllOf = function(class)
    if class == 'PalNetworkTransmitter' then return {txs.A, txs.B} end
    return {comps.A, comps.B}
end
FName = function(s) return s end
local function instance(authority, outgoing)
    package.loaded.palapi = {has_authority=function() return authority end,
        valid=function(o) return type(o) == 'table' end, guild_of=function(o) return o.guild end,
        cdo=function() return {} end, owned_network_component=function() return outgoing end}
    package.loaded.net = nil
    return require('net')
end
local server = instance(true)
local clients = {A=instance(false, links.A.outgoing), B=instance(false, links.B.outgoing)}
server.begin_session(1); clients.A.begin_session(2); clients.B.begin_session(3)

-- The server's rules per guild, as caps.all(cfg, guild) returns them.
local rules = {['guild-A']={Deforest={Wood=1}}, ['guild-B']={Mining={Stone=50}}}
local caps = {all=function(_, guild) return rules[guild] or {} end}
local verdicts = {['guild-A']={Deforest={capped=1, camps=1, unknown=0}},
    ['guild-B']={Mining={capped=1, camps=1, unknown=0}}}
server.on_command = function(command, _, c)
    local p = server.split(command)
    if p[1] == 'PWP_Set' then
        -- main.lua: apply in the sender's guild, push R to every peer, ack.
        local guild = server.guild_of_sender(c)
        rules[guild] = {[p[2]] = {[p[3]] = tonumber(p[4])}}
        verdicts[guild] = {[p[2]] = {capped=0, camps=1, unknown=0}}
        assert(server.push_rules(caps, {}, nil))
        return true
    end
    assert(server.push_rules(caps, {}, c))
    assert(server.push_pals(function() return {} end, c))
end
server.on_storage_interest = function() return true end
server.on_storage_request = function(guild)
    return {scope='camp', camp='camp-' .. guild, choices={'camp-' .. guild}, verified=true,
        totals={Wood=500, Stone=1200}, age_ms=0, remaining_ms=40000}
end
server.on_limit_state = function(guild)
    return {per_item=true, verdicts=verdicts[guild], stopped={}}
end
for _, c in pairs(clients) do c.on_snapshot = function() return true end end

local function pump(seconds, each)
    local stop = time + seconds
    while time < stop - 1e-9 do
        time = time + 0.05
        for g, link in pairs(links) do
            local keep = {}
            for _, m in ipairs(link.up) do
                if m.at <= time then server.receive_command(comps[g], m.msg, 0) else keep[#keep+1] = m end
            end
            link.up = keep
        end
        for g, link in pairs(links) do
            local batch, keep = link.down, {}
            link.down = {}
            for _, m in ipairs(batch) do
                if m.at <= time then clients[g].receive_state(m.msg) else keep[#keep+1] = m end
            end
            for _, m in ipairs(link.down) do keep[#keep+1] = m end
            link.down = keep
        end
        if math.floor(time*20+0.5) % 2 == 0 then
            server.storage_tick()
            for _, c in pairs(clients) do c.storage_tick(); c.poll() end
        end
        if each then each() end
    end
end

for _, c in pairs(clients) do assert(c.hello()) end
pump(1)
for g, c in pairs(clients) do
    assert(c.status == 'ready', g .. ' never became ready: ' .. tostring(c.status))
    c.set_storage_open(true)
    assert(c.request_stock('guild-' .. g, 'camp-guild-' .. g))
end
pump(2)
for g, c in pairs(clients) do assert(c.limit_state(), g .. ' has no verdict before the edit') end
-- B's next poll is due 10 s after its count came back.
local b_sends = #links.B.sends
local b_poll = links.B.sends[b_sends] + 10

package.loaded.caps = {is_client=true}
assert(clients.A.request('set', 'Deforest', 'Wood', 9999999))
local lost_at
pump(5, function()
    if not lost_at and clients.B.limit_state() == nil then lost_at = time end
end)
assert(#links.B.sends == b_sends, string.format('guild B asked for a new count %.2f s after an edit '
    .. 'in guild A, before its own poll', (links.B.sends[b_sends + 1] or 0) - (b_poll - 10)))
assert(not lost_at, 'guild B lost its verdict over an edit in guild A')
package.loaded.net = clients.B
local view = status.stock({}, {}, 'guild-B', 'camp-guild-B', true, clients.B)
assert(view.verified and status.verdict({}, 'Mining', view) == true)
-- A itself still gets its fresh count with the new verdict.
package.loaded.net = clients.A
view = status.stock({}, {}, 'guild-A', 'camp-guild-A', true, clients.A)
assert(view.verified and status.verdict({}, 'Deforest', view) == false, 'the editing guild lost its refresh')
-- B polls on its own schedule as before.
pump(b_poll - time + 1)
assert(#links.B.sends == b_sends + 1, 'guild B stopped polling')
package.loaded.caps, package.loaded.net = nil, nil
print('net limit other guild: an edit in one guild leaves the other guilds\' panels and requests alone')
