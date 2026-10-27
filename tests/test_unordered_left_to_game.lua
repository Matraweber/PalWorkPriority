-- A Pal with no order is left to the game (user's decision 2026-10-27): every
-- job it may do stays allowed and it takes no seat. Ordered Pals are steered
-- as before, and the switch restores 0.4.1's steer-everyone behaviour.
local planner = require("scheduler_plan")
local store = require("store")
local MINING, TRANSPORT, FARMING = 8, 12, 13

local function cfg(leave)
    return { max_pals_per_work_type = 1, assignment_mode = "spread", min_suitability_rank = 1,
        interval_seconds = 10, leave_unordered_pals_to_game = leave }
end
local function pal(key, priorities)
    local p = { key = key, base = {}, priorities = {}, ranks = {},
        assignment = { state = "ready", manual = false } }
    for value, prio in pairs(priorities) do
        p.priorities[value], p.ranks[value] = prio, 1
        if prio ~= false then p.base[value] = true end -- X is never in base
    end
    return p
end

-- All 1: no fence, every allowed job stays on, even with demand elsewhere.
local plan, report = planner.plan(cfg(nil), { pal("all1", { [MINING] = 1, [TRANSPORT] = 1, [FARMING] = 1 }) },
    { [TRANSPORT] = 50 }, {}, 100)
assert(plan.all1[MINING] and plan.all1[TRANSPORT] and plan.all1[FARMING], "an all-1 Pal was fenced")
assert(report.unsteered == 1 and report.fenced == 0)
assert(planner.unordered(pal("same3", { [MINING] = 3, [TRANSPORT] = 3 })), "all 3 is no order either")

-- X still applies: an X job is not allowed back.
plan = planner.plan(cfg(nil), { pal("x", { [MINING] = 1, [TRANSPORT] = false }) }, { [TRANSPORT] = 5 }, {}, 100)
assert(plan.x[MINING] and not plan.x[TRANSPORT], "X was lifted for an unordered Pal")

-- An unordered Pal takes no seat: the steered Pal still gets the only one.
local free = pal("free", { [MINING] = 1 })
local ordered = pal("ordered", { [MINING] = 1, [TRANSPORT] = 2 })
plan, report = planner.plan(cfg(nil), { free, ordered }, { [MINING] = 3 }, {}, 100)
assert(plan.ordered[MINING] and not plan.ordered[TRANSPORT], "an ordered Pal was not steered")
assert(plan.free[MINING] and report.unsteered == 1 and report.fenced == 1)

-- One different number makes an order: Rey's Lamball with Farming 1.
local lamball = pal("lamball", { [TRANSPORT] = 2, [FARMING] = 1 })
assert(not planner.unordered(lamball))
plan = planner.plan(cfg(nil), { lamball }, { [TRANSPORT] = 50, [FARMING] = 1 }, {}, 100)
assert(plan.lamball[FARMING] and not plan.lamball[TRANSPORT], "Farming 1 did not win")

-- The switch off steers every Pal, as before.
plan, report = planner.plan(cfg(false), { pal("all1", { [MINING] = 1, [TRANSPORT] = 1 }) },
    { [TRANSPORT] = 50 }, {}, 100)
assert(report.unsteered == 0 and report.fenced == 1 and plan.all1[TRANSPORT], "switch off still left it alone")

-- A Pal nobody edited reads 1 for every managed job, not the config ranking;
-- a config X stays X, and an edit or species override still wins.
local saved_data, saved_baseline = store.data, store.baseline
store.data, store.baseline = {}, false
local config = { work_priority = { Transport = 1, MonsterFarm = 5, Mining = 4, OilExtraction = false },
    pal_overrides = { SheepBall = { MonsterFarm = 2 } } }
local untouched = { key = "untouched", name = "Pengullet" }
assert(store.effective(config, untouched, "MonsterFarm", FARMING) == 1, "config ranking still applied")
assert(store.effective(config, untouched, "Transport", TRANSPORT) == 1)
assert(store.effective(config, untouched, "OilExtraction", 9) == false, "config X was lost")
assert(store.effective(config, untouched, "Anyone", 14) == nil, "an unmanaged job became managed")
assert(store.effective(config, { key = "s", species = "SheepBall" }, "MonsterFarm", FARMING) == 2)
store.data = { edited = { [FARMING] = 4 } }
assert(store.effective(config, { key = "edited" }, "MonsterFarm", FARMING) == 4)
store.data, store.baseline = saved_data, saved_baseline
print("unordered Pals: left to the game, X kept, no seat taken; ordered Pals steered; switch restores steering")
