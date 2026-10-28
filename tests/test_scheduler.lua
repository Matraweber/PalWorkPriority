local workdefs = require("workdefs")
local fixture, sends, capture_count, captures_ok, synchronous
local component_reads, component_available, replication_requests
local demand_available, required, work_error, works, rules
local store = { MAX = 5, decided = true, state = "saved", baseline = false, data = {} }
store.flush = function() store.state = "saved"; return true end
store.durable_key = function(key)
    return type(key) == "string" and not key:lower():match("^slot%d+$")
end
store.effective = function(cfg, pal, name, value)
    local row = store.data[pal.key]
    if row and row[value] ~= nil then return row[value] end
    if store.baseline then return nil end
    return cfg.work_priority[name]
end
store.capture_baseline = function(key, capable, off)
    assert(#sends == 0, "vanilla choices must be captured before the first fence")
    capture_count = capture_count + 1
    local row = {}
    for value in pairs(capable) do
        if off[value] then row[value] = false else row[value] = 1 end
    end
    store.data[key] = row
    return captures_ok
end
store.apply_set = function(key, value, p)
    store.data[key] = store.data[key] or {}
    store.data[key][value] = p
    return true
end
local function noop() end
local api = {
    camps_available = true,
    base_camps = function() return { { id = "camp" } } end,
    camp_id = function(camp) return camp.id end,
    camp_guild = function() return "guild" end,
    guid_key = function(id) return id end,
    latch_authority = function() return true end,
    has_authority = function() return true end,
    owned_network_component = function()
        component_reads = component_reads + 1
        if component_available then return "component" end
    end,
    current_work_suitability = function(param) return param.current end,
    suitability_rank = function(param, value) return param.ranks[value] or 0 end,
    work_off_set = function(param)
        if param.unreadable then return nil end
        local result = {}
        for key, value in pairs(param.off) do result[key] = value end
        return result
    end,
    camp_pals = function()
        local out = {}
        for _, p in ipairs(fixture) do
            out[#out + 1] = { key = p.key, id = p.key, param = p, name = p.key }
        end
        return out
    end,
    camp_works = function() return works, work_error end,
    work_suitability = function(work) return work.value end,
    request_work_replication = function(_, _, comp)
        assert(comp == "component", "replication bypassed the pass route")
        replication_requests = replication_requests + 1
    end,
    camp_item_totals = function()
        return { Stone = 10 }, 1, {complete = true, deduplicated = true, unknown_scope = 0}
    end,
    all_chest_totals = function()
        return { Stone = 10 }, 1, {complete = true, deduplicated = true, unknown_scope = 0}
    end,
    set_work_enabled = function(id, value, on, comp)
        assert(comp == "component")
        sends[#sends + 1] = { id = id, value = value, on = on }
        if synchronous then
            for _, p in ipairs(fixture) do if p.key == id then p.off[value] = not on end end
        end
        return true
    end,
}
package.loaded.palapi = api
package.loaded.store = store
package.loaded.caps = { state = "saved", decided = true, any = function() return next(rules) ~= nil end,
    all = function() return rules end,
    for_work = function(_, name) return rules[name] end, offer_adopt = noop }
package.loaded.demand = { live = function() return demand_available end,
    for_camp = function()
        local out, n = {}, 0
        for value, count in pairs(required) do out[value], n = count, n + count end
        return out, n, {unknown_scope = 0, unknown_type = 0}
    end }
local station_needing, cooler_needing, rocks_needing = 0, 0, 0
package.loaded.stations = { GENERATOR = 4, COOLER = 11, KINDS = {
    { value = 4, needing = function() return station_needing end },
    { value = 11, needing = function() return cooler_needing end },
    { value = 8, needing = function() return rocks_needing end } } }
package.loaded.log = { info = noop, debug = noop, warn = noop }
package.loaded.trace = { at = noop, done = noop }
local scheduler = require("scheduler")
assert(scheduler.assignment_reader == require("assignments").read,
    "production scheduler must use the verified native reader by default")
local config = { work_priority = {}, max_pals_per_work_type = 3, leave_unordered_pals_to_game = false,
    min_suitability_rank = 1, assignment_mode = "fill", interval_seconds = 10,
    storage_scope = "camp", dry_run = false }
for _, name in ipairs(workdefs.ORDER) do config.work_priority[name] = 1 end
local function reset(pals)
    fixture, sends, capture_count, captures_ok, synchronous = pals, {}, 0, true, true
    component_reads, component_available = 0, true
    replication_requests = 0
    demand_available, required, work_error, works, rules = true, {}, nil, {}, {}
    station_needing, cooler_needing, rocks_needing = 0, 0, 0
    store.baseline, store.decided, store.state, store.data = false, true, "saved", {}
    config.max_pals_per_work_type, config.dry_run = 3, false
    api.camps_available, api.camps_error = true, nil
    api.latch_authority = function() return true end
    scheduler.assignment_reader = function() return {state = "ready", manual = false} end
    scheduler.prepare_pal = nil
    scheduler.forget()
end

-- No write needs no transport lookup. Misses are bounded to one per pass and
-- must not create pending-write receipts, so a later pass can retry promptly.
reset({{key="a",ranks={[8]=1},off={}}})
local lazy = scheduler.run_pass(config)
assert(component_reads==0 and lazy.toggles==0, "unchanged pass resolved transport")
store.data.a = {[8]=false}
component_available=false
lazy=scheduler.run_pass(config)
assert(component_reads==1 and lazy.blocked and #sends==0 and lazy.pending_writes==0)
component_available=true
lazy=scheduler.run_pass(config)
assert(component_reads==2 and lazy.toggles==1 and fixture[1].off[8], "missing route poisoned retry")
lazy=scheduler.run_pass(config)
assert(component_reads==2, "settled pass resolved transport again")
reset({{key="a",ranks={[8]=1,[5]=1},off={[5]=true}}})
store.data.a={[8]=false}
lazy=scheduler.run_pass(config)
assert(component_reads==1 and lazy.toggles==2, "withdraw/enable must share this pass's route")
reset({{key="a",ranks={[8]=1},off={}}})
store.data.a={[8]=false};config.dry_run=true
lazy=scheduler.run_pass(config)
assert(component_reads==0 and lazy.would_toggle==1, "dry run resolved write transport")
reset({{key="a",ranks={[8]=1},off={}}})
demand_available,work_error,component_available=false,"missing work data",false
lazy=scheduler.run_pass(config)
assert(component_reads==1 and replication_requests==0 and #sends==0)
component_available=true;store.data.a={[8]=false}
lazy=scheduler.run_pass(config)
assert(component_reads==2 and replication_requests==1 and lazy.toggles==1,
    "replication and permission writes must share one owned lookup")

-- Before this fix the empty-demand return skipped both changes indefinitely.
reset({ {key = "a", ranks = {[5] = 1, [8] = 1}, off = {[5] = true}} })
store.data.a = {[8] = false}
local stats = scheduler.run_pass(config)
assert(fixture[1].off[8] and not fixture[1].off[5], "idle X edits and obsolete restrictions must reconcile")
assert(stats.idle_reconciled == 1 and stats.toggles == 2)
assert(fixture[1].off[8] and not fixture[1].off[5])
assert(sends[1].on == false and sends[2].on == true)

-- Removing the last legacy ceiling while idle restores the withdrawn type.
reset({ {key = "a", ranks = {[8] = 1}, off = {}} })
rules.Mining = {Stone = 10}
stats = scheduler.run_pass(config)
assert(fixture[1].off[8] and stats.toggles == 1)
rules, sends = {}, {}
stats = scheduler.run_pass(config)
assert(not fixture[1].off[8] and stats.toggles == 1)

-- A missing work list is not permission to ignore an explicit X update.
reset({ {key = "a", ranks = {[8] = 1}, off = {}} })
store.data.a = {[8] = false}
demand_available, work_error = false, "work data unavailable"
stats = scheduler.run_pass(config)
assert(stats.demand_unavailable == 1 and fixture[1].off[8])

-- Failed/unknown vacancy reads must not fabricate demand.
reset({ {key = "a", ranks = {[8] = 1}, off = {}} })
demand_available = false
works = {
    {value = 8, IsExistAssignableSlot = function() error("unreadable") end},
    {value = 8, IsExistAssignableSlot = function() return nil end},
    {value = 8, IsExistAssignableSlot = function() return false end},
    {value = 8, IsExistAssignableSlot = function() return true end},
}
stats = scheduler.run_pass(config)
assert(stats.unknown_work == 2 and stats.needed == 1 and stats.covered == 1)
assert(stats.demand_by_name.Mining == 1)

-- Fresh installs persist checked=1 / unchecked=X before touching a toggle.
reset({ {key = "a", ranks = {[5] = 2, [8] = 1}, off = {[5] = true}} })
store.baseline = true
stats = scheduler.run_pass(config)
assert(capture_count == 1 and store.data.a[5] == false and store.data.a[8] == 1)
assert(stats.toggles == 0)
reset({ {key = "a", ranks = {[5] = 2, [8] = 1}, off = {[5] = true}} })
store.baseline, captures_ok = true, false
stats = scheduler.run_pass(config)
assert(capture_count == 1 and #sends == 0 and stats.baseline_unavailable == 1)
store.state = "error"
stats = scheduler.run_pass(config)
assert(#sends == 0 and stats.blocked)
reset({ {key = "a", ranks = {[8] = 1}, off = {}, unreadable = true} })
store.baseline = true
stats = scheduler.run_pass(config)
assert(capture_count == 0 and #sends == 0 and stats.baseline_unavailable == 1)
reset({ {key = "slot1", ranks = {[8] = 1}, off = {}} })
stats = scheduler.run_pass(config)
assert(#sends == 0 and stats.baseline_unavailable == 1)
reset({ {key = "a", ranks = {[8] = 1}, off = {}} })
store.decided = false
stats = scheduler.run_pass(config)
assert(#sends == 0)

-- Strong replacement cannot be enabled until the old permission is observed
-- off. Returning success from a network send is not an acknowledgement.
reset({ {key = "weak", ranks = {[8] = 1}, off = {}},
    {key = "strong", ranks = {[8] = 4}, off = {[8] = true}} })
required[8], config.max_pals_per_work_type, synchronous = 9, 1, false
stats = scheduler.run_pass(config)
assert(#sends == 1 and sends[1].id == "weak" and not sends[1].on)
assert(stats.awaiting_withdrawal == 1 and fixture[2].off[8])
synchronous, sends = true, {}
stats = scheduler.run_pass(config)
assert(#sends == 0 and stats.pending_writes == 1, "an unacknowledged RPC must not be repeatedly sent")
fixture[1].off[8] = true -- actual delivery, rather than changing send's return value
stats = scheduler.run_pass(config)
assert(#sends == 1 and sends[1].on == true)
assert(fixture[1].off[8] and not fixture[2].off[8])

-- An unreadable existing worker blocks new enables, rather than silently
-- disappearing from capacity accounting.
reset({ {key = "weak", ranks = {[8] = 1}, off = {}, unreadable = true},
    {key = "strong", ranks = {[8] = 4}, off = {[8] = true}} })
required[8], config.max_pals_per_work_type = 9, 1
stats = scheduler.run_pass(config)
assert(#sends == 0 and stats.awaiting_withdrawal == 1 and fixture[2].off[8])

-- The withdrawal phase keeps the existing per-camp RPC budget. A partially
-- processed large camp must not admit the replacement before the remaining
-- obsolete permission is confirmed off on the following pass.
local large = {}
for i = 1, 41 do large[i] = {key = "weak" .. i, ranks = {[8] = 1}, off = {}} end
large[42] = {key = "strong", ranks = {[8] = 4}, off = {[8] = true}}
reset(large)
required[8], config.max_pals_per_work_type = 99, 1
stats = scheduler.run_pass(config)
assert(#sends == 40 and stats.deferred > 0 and stats.awaiting_withdrawal == 1)
assert(fixture[42].off[8])
sends = {}
stats = scheduler.run_pass(config)
assert(#sends == 2 and not sends[1].on and sends[2].on and not fixture[42].off[8])

-- Fixed assignment evidence is injected only by a verified native adapter.
reset({ {key = "fixed", ranks = {[5] = 2, [8] = 2}, off = {}} })
required[5] = 10
scheduler.assignment_reader = function()
    return { id = "mine", value = 8, state = "occupied", manual = true }
end
stats = scheduler.run_pass(config)
assert(fixture[1].off[5] and not fixture[1].off[8])
assert(stats.assignment_unknown == 0)

-- A changed native checkbox is not proof of a deliberate priority edit. The
-- stand's own mouse path, late native UI events and other mods can change it.
reset({ {key = "a", ranks = {[8] = 1}, off = {}} })
store.data.a = {[8] = 4}
scheduler.run_pass(config) -- confirm the already applied allowed permission
fixture[1].off[8], sends = true, {}
stats = scheduler.run_pass(config)
assert(store.data.a[8] == 4 and stats.vanilla_edits == 1,
    'native checkbox disable overwrote numeric priority with X')
fixture[1].off[8], sends = false, {}
stats = scheduler.run_pass(config)
assert(store.data.a[8] == 4,'native checkbox enable reset numeric priority to 1')

-- Model the measured interleaving: user chooses 3->4; a native checkbox
-- disable lands before reconciliation; next right click must still use 4.
store.data.a[8] = 3
for expected=4,5 do
    store.apply_set('a',8,store.data.a[8]+1)
    fixture[1].off[8]=true
    scheduler.run_pass(config)
    assert(store.data.a[8]==expected,'interleaved native UI event changed the next click base')
end
store.apply_set('a',8,false)
fixture[1].off[8]=false
scheduler.run_pass(config)
assert(store.data.a[8]==false,'external enable overwrote explicit X')

-- Missing authority/camp data is blocked unknown, not "no camp" or "client".
reset({ {key = "a", ranks = {[8] = 1}, off = {}} })
api.camps_available, api.camps_error = false, "enumeration threw"
stats = scheduler.run_pass(config)
assert(stats.blocked and stats.blocked_reason:find("unavailable", 1, true) and #sends == 0)
api.camps_available = true
api.latch_authority = function() return nil end
stats = scheduler.run_pass(config)
assert(stats.blocked and stats.blocked_reason:find("authority data is unavailable", 1, true))
api.latch_authority = function() return false end
stats = scheduler.run_pass(config)
assert(stats.blocked and stats.blocked_reason:find("not the authority", 1, true))

-- The roster reader can return partial rows along with an error; neither a
-- normal pass nor restoration may operate on that incomplete camp.
reset({ {key = "a", ranks = {[8] = 1}, off = {[8] = true}} })
local complete_roster = api.camp_pals
api.camp_pals = function() return complete_roster(), "slot read failed; roster incomplete" end
stats = scheduler.run_pass(config)
assert(stats.blocked and stats.unreadable == 1 and #sends == 0)
stats = scheduler.restore(config)
assert(stats.blocked and stats.unreadable == 1 and #sends == 0)
assert(stats.camps == 0 and stats.pals == 0, "a partial roster cannot count as a complete camp")
api.camp_pals = complete_roster

stats = scheduler.restore(config)
assert(stats.camps == 1 and stats.pals == 1 and not stats.blocked)
assert(stats.pending_writes == 0 and not fixture[1].off[8])
reset({})
stats = scheduler.restore(config)
assert(stats.camps == 1 and stats.pals == 0 and not stats.blocked,
    "a known empty roster is readable but provides no Pal restoration evidence")
reset({ {key = "a", ranks = {[8] = 1}, off = {}, unreadable = true} })
stats = scheduler.restore(config)
assert(stats.camps == 1 and stats.pals == 1 and stats.unreadable > 0 and stats.failed > 0)
assert(#sends == 0, "roster counts must not hide an unreadable Pal's permissions")
reset({ {key = "a", ranks = {[8] = 1}, off = {[8] = true}} })
config.dry_run = true
stats = scheduler.restore(config)
assert(stats.camps == 1 and stats.pals == 1 and stats.would_toggle == 1 and #sends == 0)
assert(stats.blocked and stats.blocked_reason:find("dry run", 1, true),
    "dry-run roster counts are not evidence that restoration landed")

-- Unknown manual evidence includes an unreadable current suitability. The
-- stronger candidate cannot evict a possibly fixed worker or bypass its seat.
reset({ {key = "weak", ranks = {[8] = 1}, off = {}},
    {key = "strong", ranks = {[8] = 4}, off = {[8] = true}} })
scheduler.assignment_reader = nil
required[8], config.max_pals_per_work_type = 9, 1
stats = scheduler.run_pass(config)
assert(#sends == 0 and stats.manual_unavailable == 2 and stats.held == 0)
store.data.weak = {[8] = false} -- explicit X still overrides preserved permission
stats = scheduler.run_pass(config)
assert(#sends == 1 and not sends[1].on,
    "X withdraws the old permission, but unknown replacement cannot gain work")

-- A failed prepare hook must not remove an unknown worker from the capacity
-- ledger and thereby authorize a new worker in the same camp.
reset({ {key = "weak", ranks = {[8] = 1}, off = {}},
    {key = "strong", ranks = {[8] = 4}, off = {[8] = true}} })
scheduler.prepare_pal = function(_, p) return p.key ~= "weak" end
required[8], config.max_pals_per_work_type = 9, 1
stats = scheduler.run_pass(config)
assert(#sends == 0 and stats.awaiting_withdrawal == 1)

-- A delayed enable reserves potential capacity even while its last readback
-- is OFF. A changed ranking cannot admit someone else into that same seat.
reset({ {key = "a", ranks = {[8] = 4}, off = {[8] = true}},
    {key = "b", ranks = {[8] = 1}, off = {[8] = true}} })
required[8], config.max_pals_per_work_type, synchronous = 9, 1, false
stats = scheduler.run_pass(config)
assert(#sends == 1 and sends[1].id == "a" and sends[1].on and stats.pending_writes == 1)
fixture[2].ranks[8], sends = 5, {}
scheduler.forget_policy() -- a mode/limit change does not cancel the in-flight enable
local original_clock, later = os.clock, os.clock() + 31
os.clock = function() return later end
stats = scheduler.run_pass(config)
os.clock = original_clock
assert(#sends == 0 and stats.expired_writes == 1 and stats.awaiting_withdrawal == 1)
assert(scheduler.format_stats(config, stats):find("delivery unresolved", 1, true))
fixture[1].off[8], synchronous = false, true -- the old enable finally arrives
stats = scheduler.run_pass(config)
assert(#sends == 2 and sends[1].id == "a" and not sends[1].on and sends[2].id == "b" and sends[2].on)
assert(store.data.a == nil and stats.vanilla_edits == 0 and stats.pending_writes == 0)

-- Restore is also a mod writer. Its confirmed restoration must not be
-- adopted as an external enable and silently replace a saved numeric rank.
reset({ {key = "a", ranks = {[8] = 1}, off = {}},
    {key = "b", ranks = {[8] = 4}, off = {}} })
store.data.a = {[8] = 4}
config.max_pals_per_work_type, required[8] = 1, 9
stats = scheduler.run_pass(config)
assert(fixture[1].off[8] and not fixture[2].off[8])
sends, synchronous = {}, false
stats = scheduler.restore(config)
assert(#sends == 1 and sends[1].id == "a" and sends[1].on and stats.pending_writes == 1)
sends = {}
stats = scheduler.restore(config)
assert(#sends == 0 and stats.pending_writes == 1 and stats.deferred > 0)
fixture[1].off[8], synchronous = false, true -- restored readback arrives
stats = scheduler.run_pass(config)
assert(store.data.a[8] == 4 and stats.vanilla_edits == 0)

-- Bad limits cannot silently become "no limits" on a direct/public pass.
reset({ {key = "a", ranks = {[8] = 1}, off = {[8] = true}} })
package.loaded.caps.state = "error"
stats = scheduler.run_pass(config)
assert(stats.blocked and #sends == 0)
stats = scheduler.restore(config)
assert(stats.blocked and #sends == 0)
package.loaded.caps.state = "saved"

-- Global storage means this guild's loaded camps, never every guild on the
-- authority. One source scan is shared, and the legacy unscoped UI total is
-- withheld when more than one guild would make it ambiguous.
reset({ {key = "a1", camp = "a1", ranks = {[8] = 1}, off = {}},
    {key = "a2", camp = "a2", ranks = {[8] = 1}, off = {}},
    {key = "b", camp = "b", ranks = {[8] = 1}, off = {}} })
local scan_verified = true
api.base_camps = function()
    return { {id = "a1", guild = "ga"}, {id = "a2", guild = "ga"}, {id = "b", guild = "gb"} }
end
api.camp_guild = function(camp) return camp.guild end
api.camp_pals = function(camp)
    local result = {}
    for _, p in ipairs(fixture) do
        if p.camp == camp.id then result[#result + 1] = {key = p.key, id = p.key, name = p.key, param = p} end
    end
    return result
end
api.all_chest_totals = function() error("unscoped global storage must not be used") end
api.chest_totals_by_camp = function()
    return {a1 = {Stone = 6}, a2 = {Stone = 6}, b = {Stone = 2}},
        {a1 = 1, a2 = 1, b = 1}, {complete = scan_verified, deduplicated = scan_verified}
end
config.storage_scope, rules.Mining = "global", {Stone = 10}
stats = scheduler.run_pass(config)
assert(fixture[1].off[8] and fixture[2].off[8] and not fixture[3].off[8])
assert(scheduler.last_totals_by_guild.ga.Stone == 12 and scheduler.last_totals_by_guild.gb.Stone == 2)
assert(next(scheduler.last_totals) == nil and stats.storage_unverified == 0)

-- An incomplete/non-deduplicated scan cannot turn a numerical guess into a
-- production decision. Explicit X edits still reconcile during that gap.
scan_verified, sends = false, {}
store.data.b = {[8] = false}
scheduler.forget_stock()
stats = scheduler.run_pass(config)
assert(stats.storage_unverified == 3 and scheduler.last_capped.Mining.unknown == 3)
assert(fixture[1].off[8] and fixture[2].off[8] and fixture[3].off[8])
assert(#sends == 1 and sends[1].id == "b" and not sends[1].on)

-- Camp-mode preloaded storage must preserve the same incomplete-read proof
-- as the direct reader, including on cache hits. It cannot turn a failed slot
-- read into an ordinary numerical zero/nonzero limit decision.
reset({ {key = "a1", camp = "a1", ranks = {[8] = 1}, off = {}},
    {key = "a2", camp = "a2", ranks = {[8] = 1}, off = {}},
    {key = "b", camp = "b", ranks = {[8] = 1}, off = {}} })
config.storage_scope, rules.Mining, scan_verified = "camp", {Stone = 5}, false
store.data.b = {[8] = false}
api.camp_item_totals = function() error("preloaded evidence must be reused") end
stats = scheduler.run_pass(config)
assert(stats.storage_unverified == 3 and not fixture[1].off[8] and not fixture[2].off[8])
assert(fixture[3].off[8] and #sends == 1)
stats = scheduler.run_pass(config)
assert(stats.storage_unverified == 3 and not fixture[1].off[8])
scan_verified = true
scheduler.forget_stock()
stats = scheduler.run_pass(config)
assert(stats.storage_unverified == 0 and fixture[1].off[8] and fixture[2].off[8])

reset({ {key = "a1", camp = "a1", ranks = {[8] = 1}, off = {}} })
api.base_camps = function() return { {id = "a1", guild = "ga"} } end
local direct_calls, direct_verified = 0, false
api.camp_item_totals = function()
    direct_calls = direct_calls + 1
    return {Stone = 100}, 1, {complete = direct_verified, deduplicated = true, unknown_scope = 0}
end
rules.Mining = {Stone = 5}
stats = scheduler.run_pass(config)
assert(direct_calls == 1 and stats.storage_unverified == 1 and not fixture[1].off[8])
stats = scheduler.run_pass(config)
assert(direct_calls == 1 and stats.storage_unverified == 1, "cached incomplete storage must stay unknown")
direct_verified = true
scheduler.forget_stock()
stats = scheduler.run_pass(config)
assert(stats.storage_unverified == 0 and fixture[1].off[8])

-- A complete direct storage scan does not resolve a missing guild. With any
-- legacy rules present, neither a guessed cap nor guessed uncapping is safe.
reset({ {key = "a1", camp = "a1", ranks = {[8] = 1}, off = {}} })
api.camp_guild = function() return nil end
rules.Mining = {Stone = 5}
stats = scheduler.run_pass(config)
assert(stats.storage_unverified == 1 and #sends == 0 and not fixture[1].off[8])
assert(scheduler.last_storage_by_camp.a1.verified == false)
store.data.a1 = {[8] = false}
stats = scheduler.run_pass(config)
assert(#sends == 1 and not sends[1].on, "unknown ownership must not prevent a known explicit X")
api.camp_guild = function(camp) return camp.guild end

-- Real scheduler storage scheduling: only a readable, prepared roster can use
-- a scan. Idle demand is deliberately different from an empty roster.
do
    local clock_before, now = os.clock, 100
    local api_before = {}
    for name, value in pairs(api) do api_before[name] = value end
    os.clock = function() return now end
    local failures = {}
    local function check(name, fn)
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
    end
    local function setup(scope, pals)
        reset(pals)
        config.storage_scope = scope
        scheduler.stock_ttl, scheduler.want_totals = 30, false
        rules.Mining = {Stone = 10}
        now = 100
        local state = {scans = 0, verified = true, a = 15, b = 15}
        api.base_camps = function() return {{id="a", guild="g"}, {id="b", guild="g"}} end
        api.camp_guild = function(camp) return camp.guild end
        api.camp_pals = function(camp)
            if state.unreadable then return nil, "roster unavailable" end
            local out = {}
            for _, p in ipairs(fixture) do
                if p.camp == camp.id then out[#out+1] = {key=p.key, id=p.key, name=p.key, param=p} end
            end
            return out
        end
        api.chest_totals_by_camp = function()
            state.scans = state.scans + 1
            if state.fail then error("storage unavailable") end
            -- Each read returns a new plain snapshot, never a mutable live view.
            return {a={Stone=state.a}, b={Stone=state.b}}, {a=1,b=1},
                {complete=state.verified, deduplicated=true, unknown_scope=0}
        end
        api.camp_item_totals = function() error("shared scan fell through to a per-camp scan") end
        return state
    end
    local function pals()
        return {{key="a-pal", camp="a", ranks={[8]=1}, off={}},
            {key="b-pal", camp="b", ranks={[8]=1}, off={}}}
    end
    check("empty rosters do not enumerate storage or publish fake zero", function()
        for _, scope in ipairs({"camp", "global"}) do
            local s = setup(scope, {})
            scheduler.last_totals = {Stone=7}
            local result = scheduler.run_pass(config)
            assert(s.scans == 0, scope .. " scanned despite all rosters being empty")
            assert(result.camps == 0 and #sends == 0 and scheduler.last_totals.Stone == 7)
            assert(next(scheduler.last_storage_by_camp) == nil)
        end
    end)
    check("unknown rosters remain blocked without an unused storage scan", function()
        for _, scope in ipairs({"camp", "global"}) do
            local s = setup(scope, pals()); s.unreadable = true
            local result = scheduler.run_pass(config)
            assert(s.scans == 0, scope .. " scanned before proving a readable roster")
            assert(result.blocked and result.unreadable == 2 and #sends == 0)
        end
    end)
    check("unprepared baselines cannot trigger an unused storage scan", function()
        for _, scope in ipairs({"camp", "global"}) do
            local s = setup(scope, pals())
            scheduler.prepare_pal = function() return false end
            local result = scheduler.run_pass(config)
            assert(s.scans == 0, scope .. " scanned when no Pal could be prepared")
            assert(result.baseline_unavailable == 2 and #sends == 0)
        end
    end)
    check("idle X, unknown retry and cap resume retain their deadlines", function()
        for _, scope in ipairs({"camp", "global"}) do
            local s = setup(scope, pals()); s.verified = false
            local result = scheduler.run_pass(config)
            assert(s.scans == 1 and result.storage_unverified == 2 and #sends == 0)
            now = 104; store.data["a-pal"] = {[8]=false}
            result = scheduler.run_pass(config)
            assert(s.scans == 1 and fixture[1].off[8] and not fixture[2].off[8], "idle X did not reconcile")
            assert(result.storage_unverified == 2 and result.idle_reconciled == 2)
            now = 105; s.verified = true
            result = scheduler.run_pass(config)
            assert(s.scans == 2 and result.storage_unverified == 0 and fixture[2].off[8], "5s unknown retry changed")
            now = 134; s.a, s.b = 0, 0
            scheduler.run_pass(config)
            assert(s.scans == 2 and fixture[2].off[8], "verified cache expired before 30s")
            now = 135
            result = scheduler.run_pass(config)
            assert(s.scans == 3 and fixture[1].off[8] and not fixture[2].off[8], "cap resume or explicit X was skipped")
            assert(result.idle_reconciled == 2)
        end
    end)
    check("a later roster gets one shared scan with the correct camp or guild scope", function()
        for _, scope in ipairs({"camp", "global"}) do
            local s = setup(scope, {{key="b-pal", camp="b", ranks={[8]=1}, off={}}})
            s.a, s.b = 20, 0 -- The first, empty camp supplies all stock.
            local result = scheduler.run_pass(config)
            assert(s.scans == 1 and result.storage_unverified == 0)
            assert((fixture[1].off[8] == true) == (scope == "global"), "empty camp stock crossed the wrong scope")
            if scope == "global" then assert(scheduler.last_totals_by_guild.g.Stone == 20) end
        end
    end)
    check("zero TTL still forces fresh storage on every pass", function()
        for _, scope in ipairs({"camp", "global"}) do
            local s = setup(scope, pals())
            scheduler.stock_ttl = 0
            local direct = 0
            api.camp_item_totals = function(key)
                direct = direct + 1
                return {Stone=s[key]}, 1, {complete=true,deduplicated=true,unknown_scope=0}
            end
            scheduler.run_pass(config)
            assert(fixture[2].off[8])
            s.a, s.b = 0, 0
            scheduler.run_pass(config) -- Same clock value: TTL=0 must still refresh.
            assert(not fixture[2].off[8], "forced fresh scan did not resume production")
            if scope == "global" then assert(s.scans == 2 and direct == 0)
            else assert(s.scans == 0 and direct == 4) end
        end
        scheduler.stock_ttl = 30
    end)
    check("panel demand, authority and session reset preserve scan freshness", function()
        local s = setup("camp", pals())
        rules = {}; scheduler.want_totals = true
        scheduler.run_pass(config)
        assert(s.scans == 1 and scheduler.last_totals_by_camp.a.Stone == 15)
        now = 101; api.latch_authority = function() return false end
        scheduler.forget_stock()
        assert(scheduler.run_pass(config).blocked and s.scans == 1)
        api.latch_authority = function() return true end
        scheduler.run_pass(config)
        assert(s.scans == 2)
        scheduler.forget() -- Same camp IDs in a new session must be read again.
        scheduler.run_pass(config)
        assert(s.scans == 3)
    end)
    check("a failed shared scan is attempted once and cannot permit edits", function()
        local s = setup("camp", pals()); s.fail = true
        local result = scheduler.run_pass(config)
        assert(s.scans == 1 and result.failed > 0 and #sends == 0)
    end)
    check("role loss during preparation prevents the deferred scan", function()
        local s = setup("camp", pals())
        local prepared = 0
        scheduler.prepare_pal = function()
            prepared = prepared + 1
            store.is_client = true
            return true
        end
        local result = scheduler.run_pass(config)
        store.is_client = nil
        assert(result.blocked and s.scans == 0 and prepared == 1 and #sends == 0,
            "deferred storage or another Pal preparation ran after authority ownership changed")
    end)
    check("unknown storage preserves numeric policy without forcing an observed enable", function()
        local s = setup("camp", pals()); s.verified = false
        store.data["b-pal"] = {[8]=4}
        scheduler.run_pass(config)
        fixture[2].off[8] = true
        local result = scheduler.run_pass(config)
        assert(result.storage_unverified == 2 and result.vanilla_edits == 1)
        assert(store.data["b-pal"][8] == 4 and fixture[2].off[8] and #sends == 0)
    end)
    check("storage diagnostics clear with cache and context invalidation", function()
        for _, forget in ipairs({scheduler.forget_stock, scheduler.forget_policy, scheduler.forget}) do
            api.last_storage_scan={complete=false,failed_reads=1,reasons={scope=1}}
            forget()
            assert(api.last_storage_scan==nil,'old scan diagnostic survived context invalidation')
        end
    end)
    os.clock = clock_before
    for name, value in pairs(api_before) do api[name] = value end
    scheduler.want_totals = false
    assert(#failures == 0, table.concat(failures, "\n\n"))
end

-- Unreadable suitability is not rank zero and must not produce a truncated
-- first-install baseline that would permanently discard that work type.
reset({ {key = "a1", camp = "a1", ranks = {[8] = 1}, off = {}} })
store.baseline = true
api.suitability_rank = function(_, value) if value == 8 then return nil end return 0 end
stats = scheduler.run_pass(config)
assert(stats.baseline_unavailable == 1 and capture_count == 0 and #sends == 0)

-- Continuous stations never announce work. A built, not-full generator is a
-- vacancy that pulls an Electricity-1 Pal off lower work; a full/unbuilt one
-- (station_needing 0) adds nothing; a Pal already on it is not counted twice.
-- Earlier blocks replace these engine stubs without restoring them.
api.suitability_rank = function(param, value) return param.ranks[value] or 0 end
api.base_camps = function() return { { id = "camp" } } end
api.camp_guild = function() return "guild" end
config.storage_scope = "camp"
reset({ {key = "g", camp = "camp", ranks = {[4] = 1, [5] = 1}, off = {}, current = 5} })
store.data.g = {[4] = 1, [5] = 3}
required = {[5] = 1}
station_needing = 1
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == 1, "empty generator was not counted as a vacancy")
assert(fixture[1].off[5] and not fixture[1].off[4], "Electricity 1 did not beat Handiwork 3 at an empty generator")

reset({ {key = "g", camp = "camp", ranks = {[4] = 1, [5] = 1}, off = {}, current = 5} })
store.data.g = {[4] = 1, [5] = 3}
required = {[5] = 1}
station_needing = 0
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == nil, "a full or unbuilt generator became demand")
assert(not fixture[1].off[5], "Pal was pulled off Handiwork with no generator needing it")

reset({ {key = "g", camp = "camp", ranks = {[4] = 1, [5] = 1}, off = {}, current = 4} })
store.data.g = {[4] = 1, [5] = 3}
station_needing = 1
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == nil, "a manned generator was counted twice")

-- A ranch worker reads no current suitability, only an occupied assignment
-- (2026-10-27). That record mans the station; a ready one does not.
reset({ {key = "g", camp = "camp", ranks = {[4] = 1, [5] = 1}, off = {}} })
store.data.g = {[4] = 1, [5] = 3}
station_needing = 1
scheduler.assignment_reader = function() return {id = "gen", value = 4, state = "occupied", manual = false} end
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == nil, "a station manned only by assignment evidence was still a vacancy")
reset({ {key = "g", camp = "camp", ranks = {[4] = 1, [5] = 1}, off = {}} })
store.data.g = {[4] = 1, [5] = 3}
station_needing = 1
scheduler.assignment_reader = function() return {id = "gen", value = 4, state = "ready", manual = false} end
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == 1, "a ready (not occupied) record manned the station")

-- Coolers are silent the same way: a built cooler holding spoilable food is a
-- vacancy that pulls a Cooling-1 Pal off Watering 2 (the 2026-10-16 Penking
-- case). An empty or unbuilt one (cooler_needing 0) adds nothing, a Pal
-- already cooling is not counted twice, and both kinds add up independently.
reset({ {key = "c", camp = "camp", ranks = {[11] = 1, [2] = 1}, off = {}, current = 2} })
store.data.c = {[11] = 1, [2] = 2}
required = {[2] = 1}
cooler_needing = 1
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == 1, "a cooler with food was not counted as a vacancy")
assert(fixture[1].off[2] and not fixture[1].off[11], "Cooling 1 did not beat Watering 2 at a cooler with food")

reset({ {key = "c", camp = "camp", ranks = {[11] = 1, [2] = 1}, off = {}, current = 2} })
store.data.c = {[11] = 1, [2] = 2}
required = {[2] = 1}
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == nil, "an empty or unbuilt cooler became demand")
assert(not fixture[1].off[2], "Pal was pulled off Watering with no cooler needing it")

reset({ {key = "c", camp = "camp", ranks = {[11] = 1, [2] = 1}, off = {}, current = 11} })
store.data.c = {[11] = 1, [2] = 2}
cooler_needing = 1
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == nil, "a manned cooler was counted twice")

reset({ {key = "g", camp = "camp", ranks = {[4] = 1, [5] = 1}, off = {}, current = 5},
        {key = "c", camp = "camp", ranks = {[11] = 1, [2] = 1}, off = {}, current = 2} })
store.data.g = {[4] = 1, [5] = 3}
store.data.c = {[11] = 1, [2] = 2}
station_needing, cooler_needing = 1, 1
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == 2, "generator and cooler vacancies did not add up")

-- Rocks and trees are silent as well (announced once at world load). With
-- Workable rocks in the camp a Mining-1 Pal leaves Planting 2; with none it
-- stays; three Workable rocks and two miners already on them leave one seat.
reset({ {key = "m", camp = "camp", ranks = {[8] = 1, [3] = 1}, off = {}, current = 3} })
store.data.m = {[8] = 1, [3] = 2}
required = {[3] = 1}
rocks_needing = 36
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == 36, "Workable rocks were not counted as mining demand")
assert(fixture[1].off[3] and not fixture[1].off[8], "Mining 1 did not beat Planting 2 with rocks to mine")

reset({ {key = "m", camp = "camp", ranks = {[8] = 1, [3] = 1}, off = {}, current = 3} })
store.data.m = {[8] = 1, [3] = 2}
required = {[3] = 1}
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == nil and not fixture[1].off[3], "no Workable rocks still created mining demand")

reset({ {key = "a", camp = "camp", ranks = {[8] = 1}, off = {}, current = 8},
        {key = "b", camp = "camp", ranks = {[8] = 1}, off = {}, current = 8} })
store.data.a, store.data.b = {[8] = 1}, {[8] = 1}
rocks_needing = 3
stats = scheduler.run_pass(config)
assert(stats.station_vacancies == 1, "miners already on rocks were not subtracted")

-- The works are typed once per camp, not once per station kind, and each
-- counter sees only its own kind (2026-10-19: 1454 works after a load were
-- typed four times per pass). An untypable work belongs to no kind.
reset({ {key = "m", camp = "camp", ranks = {[8] = 1, [3] = 1}, off = {}, current = 3} })
store.data.m = {[8] = 1, [3] = 2}
required = {[3] = 1}
works = { {value = 4}, {value = 11}, {value = 8}, {value = 8}, {value = 2}, {value = nil} }
local typed_calls, seen = 0, {}
local plain_typing = api.work_suitability
api.work_suitability = function(work) typed_calls = typed_calls + 1; return work.value end
local kinds = package.loaded.stations.KINDS
local plain_needing = {}
for i, kind in ipairs(kinds) do
    plain_needing[i] = kind.needing
    kind.needing = function(list)
        seen[kind.value] = #list
        for _, w in ipairs(list) do assert(w.value == kind.value, "a counter got another kind's work") end
        return 0
    end
end
stats = scheduler.run_pass(config)
assert(typed_calls == #works, "works were typed " .. typed_calls .. " times for " .. #works .. " works")
assert(seen[4] == 1 and seen[11] == 1 and seen[8] == 2, "counters did not get exactly their own works")
-- With work ids, a typed work is remembered: the next pass types only new
-- works and works that could not be typed; vanished works are forgotten;
-- forget() (world change) starts over.
local work_keys = {"w4", "w11", "w8a", "w8b", "w2", "wnil"}
api.camp_works = function() return works, work_error, work_keys end
scheduler.forget()
typed_calls = 0
stats = scheduler.run_pass(config)
assert(typed_calls == 6, "first pass did not type every work")
typed_calls = 0
stats = scheduler.run_pass(config)
assert(typed_calls == 1, "remembered works were typed again (" .. typed_calls .. " calls; only the untyped one should be)")
assert(seen[4] == 1 and seen[11] == 1 and seen[8] == 2, "remembered types did not reach the counters")
works[#works + 1], work_keys[#work_keys + 1] = {value = 4}, "w4b"
typed_calls = 0
stats = scheduler.run_pass(config)
assert(typed_calls == 2 and seen[4] == 2, "a new work was not typed once")
table.remove(works, 1); table.remove(work_keys, 1)
typed_calls = 0
stats = scheduler.run_pass(config)
assert(seen[4] == 1 and typed_calls == 1, "a vanished work was still counted")
scheduler.forget()
typed_calls = 0
stats = scheduler.run_pass(config)
assert(typed_calls == #works, "forget() kept remembered work types")
api.camp_works = function() return works, work_error end
-- A throw while typing drops the station counts for the pass, nothing else.
api.work_suitability = function() error("unreadable work") end
seen = {}
stats = scheduler.run_pass(config)
assert(next(seen) == nil and stats.station_vacancies == nil, "a typing failure still reached the counters")
api.work_suitability = plain_typing
for i, kind in ipairs(kinds) do kind.needing = plain_needing[i] end

-- 2026-10-28: a reached Mining limit switches off only the rocks whose main
-- drop is that item (item_sources.lua); Mining stays allowed while ore rocks
-- are wanted, and the rock comes back when the limit goes.
do
    local function idname(s) return { ToString = function() return s end } end
    local function rock(item, n)
        local list = { ForEach = function(_, fn)
            fn(1, { get = function() return { ItemId = { StaticId = idname(item) }, Num = n } end })
        end }
        return { value = 8, class = "PalWorkCollectResource", CurrentState = 1,
            CachedOwnerMapObjectConcreteModel = { class = "PalMapObjectItemDropOnDamagModel", DropItemInfos = list } }
    end
    local saved = { camp_works = api.camp_works }
    api.work_full_name = function(w) return w.class .. " /Game/Test.Work" end
    api.prop = function(o, n) return o[n] end
    api.unwrap = function(v) return v end
    api.valid = function(o) return o ~= nil end
    api.as_int = function(v) return type(v) == "number" and math.floor(v) or nil end
    reset({ {key = "a", camp = "camp", ranks = {[8] = 1}, off = {}} })
    works = { rock("Stone", 50), rock("CopperOre", 40) }
    api.camp_works = function() return works, nil, {"stone-rock", "ore-rock"} end
    rules.Mining = {Stone = 10}
    stats = scheduler.run_pass(config)
    assert(works[1].CurrentState == 2 and works[2].CurrentState == 1, "only the stone rock should be off")
    assert(not fixture[1].off[8], "Mining was switched off although an ore rock is wanted")
    assert(stats.rocks_held == 1 and stats.capped == 0)
    rules = {}
    stats = scheduler.run_pass(config)
    assert(works[1].CurrentState == 1 and stats.rocks_started == 1, "removed limit kept the rock off")
    -- Switched off in config: held rocks are released and the whole Mining
    -- work type stops as before.
    rules.Mining = {Stone = 10}
    stats = scheduler.run_pass(config)
    assert(works[1].CurrentState == 2, "rock not held before the switch")
    config.item_limits_on_rocks = false
    stats = scheduler.run_pass(config)
    assert(fixture[1].off[8] and works[1].CurrentState == 1 and stats.rocks_started == 1,
        "config switch did not release the rock and restore group limits")
    config.item_limits_on_rocks = nil
    api.camp_works = saved.camp_works
end
