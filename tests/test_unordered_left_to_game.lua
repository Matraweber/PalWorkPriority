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

-- Every numbered job counts, capped or not, X does not (review round 4,
-- scheduler P3-1). One numbered job is no order: it stays with the game.
assert(planner.unordered(pal("one", { [MINING] = 1 })), "one numbered job was steered")
assert(planner.unordered(pal("xed", { [MINING] = 1, [TRANSPORT] = 1, [FARMING] = false })),
    "an X made equal numbers an order")
-- Mining 1 and the rest 2 with Mining stopped by a limit: base no longer
-- holds Mining, yet the stand shows an order, so the scheduler steers it.
local capped = pal("capped", { [MINING] = 1, [TRANSPORT] = 2, [FARMING] = 2 })
capped.base[MINING] = nil
capped.capable = { [MINING] = true, [TRANSPORT] = true, [FARMING] = true }
assert(not planner.unordered(capped), "a stock limit decided whether the Pal is ordered")
plan, report = planner.plan(cfg(nil), { capped }, { [TRANSPORT] = 5, [FARMING] = 5 }, {}, 100)
assert(report.unsteered == 0 and report.fenced == 1 and not plan.capped[MINING], "capped Pal was left to the game")
-- Four Pals that can only farm under a staffing maximum of 1: none of them
-- loses its only job (round-4 regression review, P1: the 4th Chikipi stood idle).
local chikipis = {}
for i = 1, 4 do chikipis[i] = pal("chikipi" .. i, { [FARMING] = 1 }) end
plan, report = planner.plan(cfg(nil), chikipis, { [FARMING] = 9 }, {}, 100)
for i = 1, 4 do assert(plan["chikipi" .. i][FARMING], "chikipi" .. i .. " lost its only job") end
assert(report.unsteered == 4 and report.fenced == 0, "one-job Pals were steered")
-- The same with X on the other jobs: one numbered job left is still no order.
plan, report = planner.plan(cfg(nil), { pal("lx", { [FARMING] = 1, [TRANSPORT] = false }),
    pal("ly", { [FARMING] = 1, [TRANSPORT] = false }) }, { [FARMING] = 9 }, {}, 100)
assert(plan.lx[FARMING] and plan.ly[FARMING] and not plan.lx[TRANSPORT] and report.unsteered == 2)

-- "Lowest work level to dedicate" (min_suitability_rank) as shipped, pinned
-- (review round 4, scheduler P2-1): it switches a low-level job off for an
-- edited Pal, and a Pal with equal numbers is left to the game untouched.
local function ranked(key, priorities, ranks)
    local p = pal(key, priorities)
    for value, r in pairs(ranks) do p.ranks[value] = r end
    return p
end
local strict = cfg(nil)
strict.min_suitability_rank, strict.max_pals_per_work_type = 2, 3
local equal = ranked("equal", { [MINING] = 1, [TRANSPORT] = 1 }, { [MINING] = 1, [TRANSPORT] = 3 })
local edited = ranked("edited", { [MINING] = 1, [TRANSPORT] = 2 }, { [MINING] = 1, [TRANSPORT] = 3 })
plan, report = planner.plan(strict, { equal, edited }, { [MINING] = 5, [TRANSPORT] = 5 }, {}, 100)
assert(plan.equal[MINING] and plan.equal[TRANSPORT] and report.unsteered == 1,
    "the minimum level reached a Pal with equal numbers")
assert(not plan.edited[MINING] and plan.edited[TRANSPORT], "a job below the minimum stayed on for an edited Pal")

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
