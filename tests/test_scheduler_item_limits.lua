-- Per-item Mining limits through the whole pass, with two bases (review
-- 2026-10-28, bundles A2/A3/A4/F): held rocks go back on restore, off and
-- test mode; a stone-only base stops Mining while Ore is short elsewhere;
-- failed and partial works reads keep what they cannot see; one camp_works
-- read per camp per pass; an empty base keeps the panel verdict.
local workdefs = require("workdefs")
local MINING, LUMBERING = workdefs.value("Mining"), workdefs.value("Deforest")

local store = { MAX = 5, decided = true, state = "saved", baseline = false, data = {} }
store.flush = function() store.state = "saved"; return true end
store.durable_key = function(key) return type(key) == "string" end
store.effective = function(cfg, pal, name, value)
    local row = store.data[pal.key]
    if row and row[value] ~= nil then return row[value] end
    return cfg.work_priority[name]
end
store.capture_baseline = function() return true end
store.apply_set = function() return true end

local rules, demand_live, required = {}, true, {}
local camps, pals_of, works_of, totals_of = {}, {}, {}, {}
local works_calls, typed_calls, component = {}, 0, true
local works_override = {} -- camp -> function returning works, err, keys

local function idname(s) return { ToString = function() return s end } end
local function rock(key, item)
    local list = { ForEach = function(_, fn)
        fn(1, { get = function() return { ItemId = { StaticId = idname(item) }, Num = 50 } end })
    end }
    return { key = key, value = MINING, class = "PalWorkCollectResource", CurrentState = 1,
        CachedOwnerMapObjectConcreteModel = { class = "PalMapObjectItemDropOnDamagModel", DropItemInfos = list },
        IsExistAssignableSlot = function() return true end }
end
local function pit(key, item)
    return { key = key, value = MINING, class = "PalWorkProgress", CurrentState = 1,
        CachedOwnerMapObjectConcreteModel = { class = "PalMapObjectProductItemModel",
            GetProductItemId = function() return idname(item) end },
        IsExistAssignableSlot = function() return true end }
end
local function list_of(camp)
    local works, keys = works_of[camp] or {}, {}
    for i, w in ipairs(works) do keys[i] = w.key end
    return works, nil, keys
end

local api = {
    camps_available = true,
    base_camps = function() return camps end,
    camp_id = function(camp) return camp.id end,
    camp_guild = function() return "guild" end,
    guid_key = function(id) return id end,
    latch_authority = function() return true end,
    has_authority = function() return true end,
    owned_network_component = function() if component then return "component" end end,
    current_work_suitability = function(param) return param.current end,
    suitability_rank = function(param, value) return param.ranks[value] or 0 end,
    work_off_set = function(param)
        local out = {}
        for k, v in pairs(param.off) do out[k] = v end
        return out
    end,
    camp_pals = function(camp)
        local out = {}
        for _, p in ipairs(pals_of[camp.id] or {}) do
            out[#out + 1] = { key = p.key, id = p.key, param = p, name = p.key }
        end
        return out
    end,
    camp_works = function(camp)
        works_calls[camp.id] = (works_calls[camp.id] or 0) + 1
        if works_override[camp.id] then return works_override[camp.id]() end
        return list_of(camp.id)
    end,
    work_suitability = function(w) typed_calls = typed_calls + 1; return w.value end,
    request_work_replication = function() end,
    camp_item_totals = function(key)
        return totals_of[key] or {}, 1, { complete = true, deduplicated = true, unknown_scope = 0 }
    end,
    chest_totals_by_camp = function()
        local by, counts = {}, {}
        for _, c in ipairs(camps) do by[c.id], counts[c.id] = totals_of[c.id] or {}, 1 end
        return by, counts, { complete = true, deduplicated = true, unknown_scope = 0 }
    end,
    set_work_enabled = function(id, value, on)
        for _, list in pairs(pals_of) do
            for _, p in ipairs(list) do if p.key == id then p.off[value] = not on end end
        end
        return true
    end,
    work_full_name = function(w) return w.class and (w.class .. " /Game/Test.Work") or "<unknown work>" end,
    prop = function(o, n) return o[n] end,
    unwrap = function(v) return v end,
    valid = function(o) return o ~= nil end,
    as_int = function(v) return type(v) == "number" and math.floor(v) or nil end,
}
local function noop() end
package.loaded.palapi = api
package.loaded.store = store
package.loaded.caps = { state = "saved", decided = true, any = function() return next(rules) ~= nil end,
    all = function() return rules end, for_work = function(_, name) return rules[name] end, offer_adopt = noop }
package.loaded.demand = { live = function() return demand_live end,
    for_camp = function() local out = {}; for v, n in pairs(required) do out[v] = n end; return out, 0, {} end }
package.loaded.stations = { KINDS = { { value = MINING, needing = function(list) return #list end } } }
package.loaded.log = { info = noop, debug = noop, warn = noop }
package.loaded.trace = { at = noop, done = noop }
package.loaded.item_sources, package.loaded.scheduler = nil, nil
local sources = require("item_sources")
local scheduler = require("scheduler")
local verdict = require("panel_status").verdict

local cfg = { work_priority = {}, max_pals_per_work_type = 3, leave_unordered_pals_to_game = false,
    min_suitability_rank = 1, assignment_mode = "fill", interval_seconds = 10,
    storage_scope = "camp", dry_run = false }
for _, name in ipairs(workdefs.ORDER) do cfg.work_priority[name] = 1 end

local function miner(key) return { key = key, ranks = { [MINING] = 1 }, off = {} } end
-- Base A gives only stone (rock + Stone Pit), base B only copper ore.
local function setup(scope)
    camps = { { id = "A" }, { id = "B" } }
    pals_of = { A = { miner("a") }, B = { miner("b") } }
    works_of = { A = { rock("a-stone", "Stone"), pit("a-pit", "Stone") }, B = { rock("b-ore", "CopperOre") } }
    totals_of = { A = { Stone = 50 }, B = { CopperOre = 5 } }
    rules = { Mining = { Stone = 10, CopperOre = 100 } }
    works_calls, typed_calls, works_override, component = {}, 0, {}, true
    demand_live, required = true, { [MINING] = 2 }
    cfg.storage_scope, cfg.dry_run, cfg.item_limits_on_rocks = scope or "camp", false, nil
    scheduler.want_totals = false
    scheduler.assignment_reader = function() return { state = "ready", manual = false } end
    scheduler.prepare_pal = nil
    scheduler.forget()
    -- forget() keeps held rocks (a respawn must not lose them), so each
    -- case starts from an empty list by hand.
    sources.blocked = {}
end
local function off(camp) return pals_of[camp][1].off[MINING] == true end
local function state(camp, i) return works_of[camp][i].CurrentState end

-- A3: the stone-only base stops Mining although Ore is short guild-wide; the
-- ore base keeps mining. In both storage scopes. Stone Pit never written.
for _, scope in ipairs({ "camp", "global" }) do
    setup(scope)
    local stats = scheduler.run_pass(cfg)
    assert(off("A"), scope .. ": stone-only base kept Mining while its Stone is reached")
    assert(not off("B"), scope .. ": ore base lost Mining")
    assert(state("A", 1) == 2 and state("A", 2) == 1 and state("B", 1) == 1, scope .. ": wrong works switched")
    assert(stats.rocks_held == 1)
    local seen = scheduler.last_capped.Mining
    assert(seen.camps == 2 and seen.capped == 1, scope .. ": per-camp verdict not published")
    -- Schema 5: the same verdict per camp, and held items per camp, so a
    -- server answers one client's scope without other camps mixed in.
    local camps_seen, capped_camps, held = 0, 0, {}
    for key, entry in pairs(scheduler.last_capped_by_camp) do
        assert(entry.pass == scheduler.pass_id, scope .. ": stale per-camp verdict")
        camps_seen = camps_seen + 1
        if entry.works.Mining == true then capped_camps = capped_camps + 1 end
        for item in pairs(require("item_sources").held_items(key)) do held[item] = (held[item] or 0) + 1 end
    end
    assert(camps_seen == 2 and capped_camps == 1, scope .. ": per-camp verdicts wrong")
    assert(held.Stone == 1 and held.CopperOre == nil, scope .. ": held items per camp wrong")
end

-- F: one camp_works read per camp per pass with a Mining limit, shared by
-- the item block and the station counter, and typing only new works.
setup()
scheduler.run_pass(cfg)
assert(works_calls.A == 1 and works_calls.B == 1, "camp_works read more than once per camp")
assert(typed_calls == 3, "first pass typed " .. typed_calls .. " works for 3")
works_calls, typed_calls = {}, 0
scheduler.run_pass(cfg)
assert(works_calls.A == 1 and works_calls.B == 1 and typed_calls == 0, "remembered works typed again")
-- The same with the pulse index off (estimated fallback demand).
setup()
demand_live = false
scheduler.run_pass(cfg)
assert(works_calls.A == 1 and works_calls.B == 1, "fallback read camp_works again")
assert(typed_calls == 3, "fallback typed the works again (" .. typed_calls .. ")")
assert(off("A") and not off("B"), "fallback mode lost the per-item decision")
works_calls, typed_calls = {}, 0
scheduler.run_pass(cfg)
assert(works_calls.A == 1 and works_calls.B == 1 and typed_calls == 0, "fallback retyped remembered works")

-- A4(d): a failed works read keeps the base's last decision and its rocks.
setup()
scheduler.run_pass(cfg)
assert(off("A") and sources.count("A") == 1)
works_override.A = function() return {}, "WorkCollection has no WorkIds" end
scheduler.run_pass(cfg)
assert(off("A"), "a failed works read gave Mining back at the stone-only base")
assert(sources.count("A") == 1 and state("A", 1) == 2, "a failed works read forgot a held rock")
-- With no earlier decision, the group rule decides (Ore short: Mining on).
scheduler.forget_policy()
scheduler.run_pass(cfg)
assert(not off("A"), "no earlier decision should fall back to the group rule")
assert(sources.count("A") == 1, "forget_policy dropped held rocks")

-- A4(a): a partial list carries held rocks it did not reach; once the
-- limit is removed a complete list releases them.
setup()
works_of.A[3] = rock("a-stone2", "Stone")
scheduler.run_pass(cfg)
assert(sources.count("A") == 2 and state("A", 3) == 2)
works_override.A = function()
    return { works_of.A[1] }, "WorkIds sweep threw", { "a-stone" }
end
scheduler.run_pass(cfg)
assert(sources.count("A") == 2 and state("A", 3) == 2, "partial list forgot a held rock")
assert(off("A"), "partial list changed the decision")
works_override.A = nil
rules = {}
local stats = scheduler.run_pass(cfg)
assert(state("A", 1) == 1 and state("A", 3) == 1 and sources.count("A") == 0, "removed limit kept rocks off")
assert(stats.rocks_started == 2 and not off("A"))

-- A2: restore (pwp off / pwp restore) releases every held rock, at both bases.
setup()
works_of.B[2] = rock("b-stone", "Stone")
totals_of.B.Stone = 50
scheduler.run_pass(cfg)
assert(sources.count("A") == 1 and sources.count("B") == 1)
works_calls = {}
stats = scheduler.restore(cfg)
assert(state("A", 1) == 1 and state("B", 2) == 1 and sources.count("A") == 0 and sources.count("B") == 0,
    "restore left rocks held")
assert(stats.rocks_started == 2 and works_calls.A == 1 and works_calls.B == 1)
-- Nothing held: restore reads no works.
works_calls = {}
scheduler.restore(cfg)
assert(next(works_calls) == nil, "restore read works with no rock held")
-- In test mode too (they are the mod's own writes), and without a network
-- component (a rock's state needs none).
scheduler.run_pass(cfg)
assert(sources.count("A") == 1)
cfg.dry_run = true
scheduler.restore(cfg)
assert(state("A", 1) == 1 and sources.count("A") == 0, "restore in test mode left a rock held")
cfg.dry_run = false
scheduler.run_pass(cfg)
assert(sources.count("A") == 1)
component = false
stats = scheduler.restore(cfg)
assert(stats.blocked and state("A", 1) == 1 and sources.count("A") == 0, "restore without a component kept rocks")
component = true

-- A2: a test-mode pass releases held rocks instead of freezing them, and
-- holds none; the decision about Mining is still worked out.
setup()
scheduler.run_pass(cfg)
assert(state("A", 1) == 2)
cfg.dry_run = true
stats = scheduler.run_pass(cfg)
assert(state("A", 1) == 1 and sources.count("A") == 0 and stats.rocks_started == 1, "test mode froze a held rock")
stats = scheduler.run_pass(cfg)
assert(state("A", 1) == 1 and sources.count("A") == 0, "test mode switched a rock off")
assert(scheduler.last_capped.Mining.capped == 1, "test mode lost the Mining decision")
cfg.dry_run = false

-- Per-item switched off in config: released, and the group rule decides.
setup()
scheduler.run_pass(cfg)
cfg.item_limits_on_rocks = false
stats = scheduler.run_pass(cfg)
assert(state("A", 1) == 1 and sources.count("A") == 0 and not off("A"), "config switch kept the rock or the item rule")

-- forget() is main's ClientRestart reset, which runs on every local
-- respawn and same-map reconnect, where the rocks still read NotWorkable.
-- It keeps held rocks, like forget_policy(), so a limit removed after a
-- respawn still releases them (review 2026-10-29, P1).
setup()
scheduler.run_pass(cfg)
scheduler.forget_policy()
assert(sources.count("A") == 1, "forget_policy dropped held rocks")
scheduler.forget()
assert(sources.count("A") == 1 and state("A", 1) == 2, "forget dropped held rocks")
rules = {}
stats = scheduler.run_pass(cfg)
assert(state("A", 1) == 1 and sources.count("A") == 0, "a respawn left a held rock off for good")
assert(stats.rocks_started == 1)
-- The same through off/restore after a respawn.
setup()
scheduler.run_pass(cfg)
scheduler.forget()
scheduler.restore(cfg)
assert(state("A", 1) == 1 and sources.count("A") == 0, "restore after a respawn left a rock off")

-- Restore releases held rocks while settings cannot be saved: undoing the
-- mod's own rock writes needs no saved settings, only the authority. The
-- Pals still wait (review 2026-10-29).
setup()
scheduler.run_pass(cfg)
assert(sources.count("A") == 1)
local caps_mock = package.loaded.caps
caps_mock.state = "error"
stats = scheduler.restore(cfg)
caps_mock.state = "saved"
assert(stats.blocked and stats.blocked_reason:find("not durable", 1, true), "restore did not report the settings gate")
assert(state("A", 1) == 1 and sources.count("A") == 0, "settings in error kept a held rock off")
assert(stats.rocks_started == 1 and stats.toggles == 0, "restore changed Pals without saved settings")
-- Not on a machine that is not the authority.
setup()
scheduler.run_pass(cfg)
caps_mock.state = "error"
api.latch_authority = function() return false end
scheduler.restore(cfg)
api.latch_authority = function() return true end
caps_mock.state = "saved"
assert(state("A", 1) == 2 and sources.count("A") == 1, "a non-authority wrote a rock")

-- A base whose rocks are all mined out has no Mining source. That is not
-- "every limit reached": the group rule decides (Ore short: Mining stays),
-- also after an earlier per-item "not wanted" (review 2026-10-29).
setup()
works_of.A = {}
scheduler.run_pass(cfg)
assert(not off("A"), "a base with no Mining source lost Mining")
setup()
scheduler.run_pass(cfg)
assert(off("A"))
works_of.A = {}
scheduler.run_pass(cfg)
assert(not off("A"), "an earlier decision outlived the base's last rock")

-- A partial list that sees a source still short proves "wanted"; it cannot
-- prove "not wanted" (review 2026-10-29).
setup()
scheduler.run_pass(cfg)
assert(off("A"))
local short_ore = rock("a-ore", "CopperOre")
works_override.A = function() return { short_ore }, "WorkIds sweep threw", { "a-ore" } end
scheduler.run_pass(cfg)
assert(not off("A"), "a partial list that saw a short source kept Mining off")
-- ... and the partial list that sees only reached sources keeps the last answer.
setup()
scheduler.run_pass(cfg)
works_override.A = function() return { works_of.A[1] }, "WorkIds sweep threw", { "a-stone" } end
scheduler.run_pass(cfg)
assert(off("A"), "a partial list proved not wanted")

-- Entries the sweep skipped (camp_works' fourth value) and works without an
-- id make the list partial: the held rock among them is not dropped as gone
-- while it still reads NotWorkable (review 2026-10-29, engine P2-3).
setup()
scheduler.run_pass(cfg)
assert(sources.count("A") == 1 and state("A", 1) == 2)
works_override.A = function() return { works_of.A[2] }, nil, { "a-pit" }, 1 end
scheduler.run_pass(cfg)
assert(sources.count("A") == 1, "skipped entries read as a complete list")
works_override.A = function() return { works_of.A[1], works_of.A[2] }, nil, { [2] = "a-pit" }, 0 end
scheduler.run_pass(cfg)
assert(sources.count("A") == 1, "a work without an id read as a complete list")
-- A keyless work of another type cannot be a held rock: the list stays
-- complete, so the held rock it no longer lists is dropped as gone.
local bench = { value = LUMBERING, class = "PalWorkProgress", CurrentState = 1 }
works_override.A = function() return { bench, works_of.A[2] }, nil, { [2] = "a-pit" }, 0 end
scheduler.run_pass(cfg)
assert(sources.count("A") == 0, "a keyless work of another type made the list partial")
works_of.A[1].CurrentState = 2
sources.blocked.A = { ["a-stone"] = true }
works_override.A = nil
rules = {}
scheduler.run_pass(cfg)
assert(sources.count("A") == 0 and state("A", 1) == 1)
-- restore uses the same rule.
setup()
scheduler.run_pass(cfg)
works_override.A = function() return { works_of.A[2] }, nil, { "a-pit" }, 1 end
scheduler.restore(cfg)
assert(sources.count("A") == 1, "restore read skipped entries as a complete list")
works_override.A = nil

-- A base with no Pals gives held rocks back in test mode and with per-item
-- switched off; with the limit still there they wait for its Pals.
for _, how in ipairs({ "dry_run", "per_item_off", "limit_kept" }) do
    setup()
    scheduler.run_pass(cfg)
    assert(sources.count("A") == 1)
    pals_of.A = {}
    if how == "dry_run" then cfg.dry_run = true end
    if how == "per_item_off" then cfg.item_limits_on_rocks = false end
    stats = scheduler.run_pass(cfg)
    cfg.dry_run, cfg.item_limits_on_rocks = false, nil
    if how == "limit_kept" then
        assert(sources.count("A") == 1 and state("A", 1) == 2 and stats.rocks_held == 1, how .. ": released early")
    else
        assert(sources.count("A") == 0 and state("A", 1) == 1, how .. ": an empty base kept a held rock")
    end
end

-- Per-camp memos of camps no longer visited are pruned at the end of a pass.
setup()
scheduler.run_pass(cfg)
assert(scheduler.last_capped_by_camp.B ~= nil)
camps = { { id = "A" } }
scheduler.run_pass(cfg)
assert(scheduler.last_capped_by_camp.B == nil, "an unloaded camp's verdict was kept")
-- A failed read still keeps the visited camp's decision across passes.
works_override.A = function() return {}, "WorkCollection has no WorkIds" end
scheduler.run_pass(cfg)
scheduler.run_pass(cfg)
assert(off("A"), "the prune dropped a visited camp's Mining decision")
works_override.A = nil

-- main's restore_all calls restore up to twelve times in one go: a rock
-- that cannot be released is reported once per run, not once per call. A
-- later run says it again (review 2026-10-29).
setup()
scheduler.run_pass(cfg)
local raw = works_of.A[1]
raw.CurrentState = 2
works_of.A[1] = setmetatable({}, { __index = raw, __newindex = function() end }) -- writes do not stick
local warned, real_warn, real_clock = 0, package.loaded.log.warn, os.clock
package.loaded.log.warn = function(msg) if msg:find("still held off", 1, true) then warned = warned + 1 end end
local now = 100
os.clock = function() return now end
for _ = 1, 3 do scheduler.restore(cfg) end
assert(warned == 1, "one restore run warned " .. warned .. " times about the same rocks")
now = now + 30
scheduler.restore(cfg)
os.clock, package.loaded.log.warn = real_clock, real_warn
assert(warned == 2, "a later restore run did not say the rock is still held")
works_of.A[1] = raw

-- One caps.all copy per camp, not one per work type.
setup()
local all_calls, real_all = 0, caps_mock.all
caps_mock.all = function(...) all_calls = all_calls + 1; return real_all(...) end
local for_work_calls, real_for_work = 0, caps_mock.for_work
caps_mock.for_work = function(...) for_work_calls = for_work_calls + 1; return real_for_work(...) end
scheduler.run_pass(cfg)
caps_mock.all, caps_mock.for_work = real_all, real_for_work
assert(for_work_calls == 0 and all_calls <= 2 * 2, "caps copied per work type: all " .. all_calls ..
    ", for_work " .. for_work_calls)

-- Only Mining touches rocks: a Lumbering limit with a rock-shaped tree work
-- leaves it Workable, beside an active Mining limit.
setup()
local tree = rock("a-tree", "Wood")
tree.value = LUMBERING
works_of.A[3] = tree
totals_of.A.Wood = 500
rules.Deforest = { Wood = 10 }
scheduler.run_pass(cfg)
assert(tree.CurrentState == 1 and state("A", 1) == 2, "a Lumbering limit wrote a work")

-- An unreadable Mining product under a limit counts as wanted: the base
-- keeps Mining rather than guessing.
setup()
works_of.A[2].CachedOwnerMapObjectConcreteModel.GetProductItemId = function() error("unreadable") end
scheduler.run_pass(cfg)
assert(not off("A"), "an unreadable pit product was read as not wanted")

-- A4(e): a base with no Pals keeps the panel verdict (global scope, where
-- the verdict covers every base of the guild).
setup("global")
camps[3] = { id = "C" }
pals_of.C, works_of.C, totals_of.C = {}, {}, {}
scheduler.want_totals = true
scheduler.run_pass(cfg)
local view = { verified = true, guild = "guild", scope = "guild" }
local stopped, partial, of = verdict(scheduler, "Mining", view)
assert(stopped ~= nil, "a base with no Pals blanked the verdict")
assert(of == 3 and stopped == false, "verdict should count all three bases")
assert(scheduler.last_storage_by_camp.C and scheduler.last_storage_by_camp.C.pass == scheduler.pass_id)
assert(partial == 1, "expected Mining reached at one base of three")
scheduler.want_totals = false

print("scheduler item limits: stone-only base capped, one works read, failed/partial reads, restore/test-mode release, empty base verdict")
