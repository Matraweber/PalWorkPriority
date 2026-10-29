-- Schema 5 end to end: the server's limit state rides on the storage reply,
-- the client's panel shows the server's verdict and follows its per-item
-- flag. Offline RPC fixtures: no native engine, game, filesystem or network.
local status = require('panel_status')
local time, up, down, value, limit_state, limit_calls
local server, client, comp
os.clock = function() return time end
local function setup()
    time, up, down, limit_calls = 0, {}, {}, 0
    package.loaded.log = {warn=function()end, debug=function()end, say=function()end}
    package.loaded.settings_gate = {blocked=function() return false end, status=function() return 'ok' end}
    local owner = {guild='guild-A'}
    local tx = {GetFullName=function() return 'tx-A' end, GetOwner=function() return owner end,
        GetComponentByClass=function() return comp end}
    comp = {GetFullName=function() return 'component-A' end, GetOuter=function() return tx end,
        Notify_RequestClient_int32=function(_, _, msg) down[#down+1] = msg end}
    local outgoing = {Request_Server_int32=function(_, _, msg) up[#up+1] = msg end}
    FindAllOf = function(class) return class == 'PalNetworkTransmitter' and {tx} or {comp} end
    FName = function(s) return s end
    local function instance(authority)
        package.loaded.palapi = {has_authority=function() return authority end,
            valid=function(o) return type(o) == 'table' end, guild_of=function(o) return o.guild end,
            cdo=function() return {} end, owned_network_component=function() return outgoing end}
        package.loaded.net = nil
        return require('net')
    end
    server, client = instance(true), instance(false)
    server.begin_session(1); client.begin_session(2)
    client.on_snapshot = function() return true end
    server.on_command = function(command, _, c)
        assert(server.push_rules({all=function() return {} end}, {}, c))
        assert(server.push_pals(function() return {} end, c))
    end
    assert(client.hello())
    assert(server.receive_command(comp, table.remove(up, 1), 0))
    assert(client.receive_state(table.remove(down, 1)))
    assert(server.receive_command(comp, table.remove(up, 1), 0))
    for _, msg in ipairs(down) do assert(client.receive_state(msg)) end
    down = {}
    assert(client.status == 'ready')
    value = {scope='camp', camp='camp-A', choices={'camp-A'}, verified=true,
        totals={Stone=1200, Ore=3}, age_ms=1000, remaining_ms=29000}
    limit_state = {per_item=false, verdicts={Mining={capped=1, camps=1, unknown=0}}, stopped={}}
    server.on_storage_interest = function() return true end
    server.on_storage_request = function() return value end
    server.on_limit_state = function(guild, view)
        assert(guild == 'guild-A' and view.camp == 'camp-A')
        limit_calls = limit_calls + 1
        return limit_state
    end
    client.set_storage_open(true)
    -- The panel reads the role and transport where panel.lua does.
    package.loaded.caps = {is_client=true}
    package.loaded.net = client
end
local function fetch()
    assert(client.request_stock('guild-A', 'camp-A'))
    time = time + 0.2; client.storage_tick()
    if #up == 0 then time = time + 10; client.storage_tick() end
    assert(server.receive_command(comp, table.remove(up, 1), 0))
    for _ = 1, 40 do
        time = time + 0.1; server.storage_tick()
        local batch = down; down = {}
        for _, msg in ipairs(batch) do client.receive_state(msg) end
        local view = status.stock({}, {}, 'guild-A', 'camp-A', true, client)
        if view.verified and view.limits then return view end
    end
    error('no verified stock view')
end

setup()
local cfg = {item_limits_on_rocks=true}
assert(status.per_item(cfg) == true, 'before any reply the client uses its own config')
local view = fetch()
assert(limit_calls == 1 and view.totals.Stone == 1200)
-- A client at its limit: the server's verdict, not "No count yet" (nil).
local reached, partly, bases = status.verdict({}, 'Mining', view)
assert(reached == true and partly == nil and bases == 1, 'client still has no verdict at its limit')
assert(status.verdict({}, 'Deforest', view) == nil)
-- The per-item flag follows the server: off here although the client says on.
assert(client.server_item_limits == false and status.per_item(cfg) == false)
assert(status.item_stopped('Stone') == false)

-- Server switches per-item on and holds stone rocks; the client follows.
limit_state = {per_item=true, verdicts={Mining={capped=0, camps=1, unknown=0}}, stopped={Stone=true}}
time = time + 11
client.storage_tick()
assert(#up == 1, 'refresh request not sent')
assert(server.receive_command(comp, table.remove(up, 1), 0))
for _ = 1, 40 do
    time = time + 0.1; server.storage_tick()
    local batch = down; down = {}
    for _, msg in ipairs(batch) do client.receive_state(msg) end
    if client.server_item_limits == true then break end
end
view = status.stock({}, {}, 'guild-A', 'camp-A', true, client)
assert(status.per_item({item_limits_on_rocks=false}) == true, 'server on, client off: follow the server')
assert(status.item_stopped('Stone') == true and status.item_stopped('Ore') == false)
assert(status.verdict({}, 'Mining', view) == false)

-- The count expires: verdict and rock state go with it, the flag stays.
time = view.expires_at
view = status.stock({}, {}, 'guild-A', 'camp-A', true, client)
assert(not view.verified and status.verdict({}, 'Mining', view) == nil)
assert(status.item_stopped('Stone') == false and client.limit_state() == nil)
assert(client.server_item_limits == true)
-- A new session forgets the server's flag.
client.begin_session(3)
assert(client.server_item_limits == nil and status.per_item({item_limits_on_rocks=false}) == false)

-- An oversized or failing limit state never costs the count itself.
setup()
local works = {}
for i = 1, 20 do works['Work' .. i] = {capped=0, camps=1, unknown=0} end
limit_state = {per_item=true, verdicts=works, stopped={}}
view = status.stock({}, {}, 'guild-A', 'camp-A', true, client)
assert(client.request_stock('guild-A', 'camp-A'))
time = time + 0.2; client.storage_tick()
assert(server.receive_command(comp, table.remove(up, 1), 0))
for _ = 1, 40 do
    time = time + 0.1; server.storage_tick()
    local batch = down; down = {}
    for _, msg in ipairs(batch) do client.receive_state(msg) end
end
view = status.stock({}, {}, 'guild-A', 'camp-A', true, client)
assert(view.verified and view.totals.Stone == 1200, 'oversized limit state lost the count')
assert(status.verdict({}, 'Mining', view) == nil and client.server_item_limits == nil)
setup()
server.on_limit_state = function() error('scheduler gone') end
view = (function()
    assert(client.request_stock('guild-A', 'camp-A'))
    time = time + 0.2; client.storage_tick()
    assert(server.receive_command(comp, table.remove(up, 1), 0))
    for _ = 1, 40 do
        time = time + 0.1; server.storage_tick()
        local batch = down; down = {}
        for _, msg in ipairs(batch) do client.receive_state(msg) end
    end
    return status.stock({}, {}, 'guild-A', 'camp-A', true, client)
end)()
assert(view.verified and view.totals.Stone == 1200 and status.verdict({}, 'Mining', view) == nil)

-- 2026-10-29 round 2: after a limit edit the cached verdict described the old
-- limits for up to ten seconds. An acknowledged Set or a committed R snapshot
-- drops it at once, keeps the totals, and asks for a fresh count soon.
local function deliver()
    local batch = down; down = {}
    for _, msg in ipairs(batch) do client.receive_state(msg) end
end
local function edited(how)
    setup()
    local rules = {}
    server.on_command = function(command, _, c)
        local p = server.split(command)
        if p[1] == 'PWP_Set' then
            rules = {[p[2]] = {[p[3]] = tonumber(p[4])}}
            if how == 'snapshot' then
                assert(server.push_rules({all=function() return rules end}, {}, c))
            end
            return true
        end
        assert(server.push_rules({all=function() return rules end}, {}, c))
        assert(server.push_pals(function() return {} end, c))
    end
    local before = fetch()
    assert(status.verdict({}, 'Mining', before) == true, 'fixture has no verdict to go stale')
    local sent_at = time
    time = time + 1.5
    assert(client.request('set', 'Mining', 'Stone', 5000))
    assert(server.receive_command(comp, table.remove(up, 1), 0))
    deliver()
    local after = status.stock({}, {}, 'guild-A', 'camp-A', true, client)
    assert(after.verified and after.totals.Stone == 1200, how .. ': the edit cost the count')
    assert(status.verdict({}, 'Mining', after) == nil, how .. ': stale verdict outlived the edit')
    assert(status.item_stopped('Stone') == false)
    -- A fresh count is due soon, not after the ten second poll.
    time = math.max(time + 0.11, sent_at + 1)
    client.storage_tick()
    assert(#up == 1, how .. ': no fresh count requested after the edit')
    limit_state = {per_item=false, verdicts={Mining={capped=0, camps=1, unknown=0}}, stopped={}}
    assert(server.receive_command(comp, table.remove(up, 1), 0))
    for _ = 1, 40 do time = time + 0.1; server.storage_tick(); deliver() end
    after = status.stock({}, {}, 'guild-A', 'camp-A', true, client)
    assert(status.verdict({}, 'Mining', after) == false, how .. ': fresh verdict not shown')
end
edited('ack')
edited('snapshot')

-- A count already in flight when the limits changed may predate the edit:
-- its verdict is dropped on arrival and another count follows soon.
setup()
fetch()
time = time + 11
client.storage_tick()
assert(#up == 1)
assert(server.receive_command(comp, table.remove(up, 1), 0))
assert(server.push_rules({all=function() return {Mining={Stone=9}} end}, {}, comp))
time = time + 0.1; server.storage_tick(); deliver()
for _ = 1, 40 do time = time + 0.1; server.storage_tick(); deliver() end
view = status.stock({}, {}, 'guild-A', 'camp-A', true, client)
assert(view.verified and status.verdict({}, 'Mining', view) == nil, 'verdict from before the edit shown')
time = time + 1.1
client.storage_tick()
assert(#up == 1, 'no fresh count after a count that predates the edit')
package.loaded.caps, package.loaded.net = nil, nil
print('net limit state: server verdict and per-item flag reach the client panel, expire with the count, never cost it')
