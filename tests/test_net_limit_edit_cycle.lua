-- Live bug 2026-10-29 (integrate-r2 a051f02, GPortal server): after a limit
-- edit with the panel open, the client never accepted a verified count again
-- ("No count yet", storage "?", 7 requests issued, none pending). This drives
-- the real client and server net paths with latency on both legs, a 100 ms
-- storage beat on each side and a server sample that ages like the
-- scheduler's: verified view with verdicts -> edit (ack + R snapshot) ->
-- the next request cycle must again show a verified count with verdicts.
local status = require('panel_status')
local time, up, down
local server, client, comp
os.clock = function() return time end
local LATENCY = 0.15
local sample_at, sample_ttl = 0, 40
local limit_state
-- Seconds the server's Set handler takes: main.lua saves caps.txt and runs a
-- pass in that callback, measured on GPortal at 712 ms mean and 2.5 s worst
-- (docs/save-flush-2026-09-29.md). Zero handles every message instantly.
local busy = 0

local function setup(latency_up)
    time, up, down = 0, {}, {}
    package.loaded.log = {warn=function()end, debug=function()end, say=function()end}
    package.loaded.settings_gate = {blocked=function() return false end, status=function() return 'ok' end}
    local owner = {guild='guild-A'}
    local tx = {GetFullName=function() return 'tx-A' end, GetOwner=function() return owner end,
        GetComponentByClass=function() return comp end}
    comp = {GetFullName=function() return 'component-A' end, GetOuter=function() return tx end,
        Notify_RequestClient_int32=function(_, _, msg) down[#down+1] = {at=time+LATENCY, msg=msg} end}
    local outgoing = {Request_Server_int32=function(_, _, msg)
        up[#up+1] = {at=time+(latency_up and latency_up() or LATENCY), msg=msg} end}
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
    local rules = {Deforest={Wood=1}}
    server.on_command = function(command, _, c)
        local p = server.split(command)
        if p[1] == 'PWP_Set' then
            -- main.lua: save, push R to every peer, run a pass, then ack.
            rules = {[p[2]] = {[p[3]] = tonumber(p[4])}}
            assert(server.push_rules({all=function() return rules end}, {}, nil))
            limit_state = {per_item=true, verdicts={Deforest={capped=0, camps=1, unknown=0}}, stopped={}}
            time = time + busy
            return true
        end
        assert(server.push_rules({all=function() return rules end}, {}, c))
        assert(server.push_pals(function() return {} end, c))
    end
    limit_state = {per_item=true, verdicts={Deforest={capped=1, camps=1, unknown=0}}, stopped={}}
    server.on_storage_interest = function() return true end
    -- The scheduler re-reads chests every 30 s; a published sample lives 40 s.
    server.on_storage_request = function(_, _, t)
        if t - sample_at >= 30 then sample_at = t end
        local age = t - sample_at
        return {scope='camp', camp='camp-A', choices={'camp-A'}, verified=true,
            totals={Wood=500, Stone=1200}, age_ms=math.floor(age*1000),
            remaining_ms=math.floor((sample_ttl-age)*1000)}
    end
    server.on_limit_state = function() return limit_state end
    package.loaded.caps = {is_client=true}
    package.loaded.net = client
end

local function pump(seconds, each)
    local stop = time + seconds
    while time < stop - 1e-9 do
        time = time + 0.05
        local keep = {}
        for _, m in ipairs(up) do
            if m.at <= time then server.receive_command(comp, m.msg, 0) else keep[#keep+1] = m end
        end
        up = keep
        keep = {}
        local batch = down; down = {}
        for _, m in ipairs(batch) do
            if m.at <= time then client.receive_state(m.msg) else keep[#keep+1] = m end
        end
        for _, m in ipairs(down) do keep[#keep+1] = m end
        down = keep
        if math.floor(time*20+0.5) % 2 == 0 then
            server.storage_tick(); client.storage_tick(); client.poll()
        end
        if each then each() end
    end
end
local function view() return status.stock({}, {}, 'guild-A', 'camp-A', true, client) end
local function shown()
    local v = view()
    return v.verified and v.totals.Wood == 500, status.verdict({}, 'Deforest', v)
end
local function connect()
    assert(client.hello())
    pump(1)
    assert(client.status == 'ready', 'fixture never became ready: '..tostring(client.status))
    client.set_storage_open(true)
    local deadline = time + 3
    pump(3, function() view() end)
    assert(time <= deadline + 0.1)
    local counted, verdict = shown()
    assert(counted and verdict == true, 'no verified count with a verdict before the edit')
end

-- Edits at many phases of the 10 s poll, so one lands while a request is in
-- flight, one just after a reply, one while idle. Each must be followed by a
-- verified count with the new verdict within the next request cycle (12 s),
-- and stay verified afterwards.
for _, phase in ipairs({0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 1, 2, 5, 9.5, 9.9}) do
    for _, jitter in ipairs({false, 0, 1}) do
        local n = 0
        -- Up-leg latency varies by up to 40 ms, as a real link does; both
        -- parities, so a later send can arrive sooner after an earlier one.
        setup(jitter and function() n = n + 1; return LATENCY + (n % 2 == jitter and 0.04 or 0) end or nil)
        sample_at = 0
        connect()
        pump(phase, function() view() end)
        -- `pwp limit` reads the stock first, with no base selected (main.lua
        -- stock_across_camps), then sends the edit; the panel keeps its base.
        status.stock({}, {}, 'guild-A', nil, true, client)
        assert(client.request('set', 'Deforest', 'Wood', 9999999))
        local seen_at
        pump(12, function()
            view()
            local counted, verdict = shown()
            if not seen_at and counted and verdict == false then seen_at = time end
        end)
        assert(seen_at, string.format('phase %.2f jitter %s: no verified count with the new verdict '
            .. 'within 12 s of the edit', phase, tostring(jitter)))
        -- And it keeps refreshing: over the next 60 s the count is shown at
        -- least 90 % of the time.
        local good, total = 0, 0
        pump(60, function()
            view()
            local counted, verdict = shown()
            total = total + 1
            if counted and verdict == false then good = good + 1 end
        end)
        assert(good >= total * 0.9, string.format('phase %.2f jitter %s: count shown only %d/%d beats',
            phase, tostring(jitter), good, total))
    end
end
-- Round 3: an edit while the server is busy saving. The client's 10 s poll T
-- arrives during the Set handler's stall, so it is handled late; the request
-- that follows the reply is then under 1 s after it on the server's clock.
-- The server dropped that one unanswered, and the client went without a count
-- for 20 s plus a 10 s poll. It keeps the newest early request now and serves
-- it once the second has passed (phase 7.6 failed without that). At other
-- phases the stall moved the count's expiry just before the 10 s poll, and the
-- client then waited another 10 s; an aged count is asked for soon now (phase
-- 1.4 failed without that).
busy = 1.0
for step = 0, 50 do local phase = step / 5
    setup()
    sample_at = 0
    connect()
    pump(phase, function() view() end)
    assert(client.request('set', 'Deforest', 'Wood', 9999999))
    local seen_at
    pump(12, function()
        view()
        local counted, verdict = shown()
        if not seen_at and counted and verdict == false then seen_at = time end
    end)
    assert(seen_at, string.format('busy server, phase %.2f: no verified count with the new verdict '
        .. 'within 12 s of the edit', phase))
    local good, total = 0, 0
    pump(60, function()
        view()
        local counted, verdict = shown()
        total = total + 1
        if counted and verdict == false then good = good + 1 end
    end)
    assert(good >= total * 0.9, string.format('busy server, phase %.2f: count shown only %d/%d beats',
        phase, good, total))
end
busy = 0
-- Each part on its own. A chat or console read with no base selected
-- (`pwp limit`) must not throw away the panel's base, count and request.
setup()
sample_at = 0
connect()
pump(9.9, function() view() end)
pump(0.2, function() view() end)
local before = view()
status.stock({}, {}, 'guild-A', nil, true, client)
local after = view()
assert(after.verified and after.camp == 'camp-A' and after.totals.Wood == 500,
    'an automatic read reset the chosen base and its count')
assert(before.verified == after.verified)
-- Requests made "soon" (after an edit, or a new selection) keep 1.5 s from
-- the previous send, so link jitter cannot put them under the server's 1 s.
-- The worst case: an edit right after a count came back.
setup()
sample_at = 0
local sends = {}
local function watch()
    view()
    for _, m in ipairs(up) do
        if m.msg:find('|T|', 1, true) and not m.seen then m.seen = true; sends[#sends+1] = time end
    end
end
connect()
for value = 1, 3 do
    local had = #sends
    for _ = 1, 260 do
        if #sends > had then break end
        pump(0.05, watch)
    end
    assert(#sends > had, 'no poll request')
    -- Its reply is back after about 0.45 s; edit just after that.
    pump(0.6, watch)
    assert(client.request('set', 'Deforest', 'Wood', value))
    pump(3, watch)
    assert(#sends >= had + 2, 'the edit brought no fresh count')
    local gap = sends[had + 2] - sends[had + 1]
    assert(gap >= 1.45, string.format('storage requests only %.2f s apart', gap))
end
package.loaded.caps, package.loaded.net = nil, nil
print('net limit edit cycle: after an acknowledged edit and its R snapshot a verified count with the new verdict returns within one request cycle, at every poll phase, with link jitter')
