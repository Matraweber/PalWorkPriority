local planner = require("scheduler_plan")
local function cfg(cap, mode)
    return { max_pals_per_work_type = cap, assignment_mode = mode or "fill",
        min_suitability_rank = 1, interval_seconds = 10 }
end
local function pal(key, entries, assignment)
    local p = { key = key, base = {}, priorities = {}, ranks = {},
        assignment = assignment or {state="ready", manual=false} }
    for value, e in pairs(entries) do
        p.base[value], p.priorities[value], p.ranks[value] = true, e[1], e[2]
    end
    return p
end
local function count(plan, value)
    local n = 0
    for _, permissions in pairs(plan) do if permissions[value] then n = n + 1 end end
    return n
end
local function occupied(key, value, manual)
    if manual == nil then manual = false end
    return { id = key, value = value, state = "occupied", manual = manual }
end

-- A weaker pal encountered first cannot claim the last seat. Unallocated
-- specialists cannot bypass the hard cap through the fallback permission set.
local miners = {}
for i = 1, 4 do miners[i] = pal("p" .. i, { [8] = {1, i} }) end
local plan = planner.plan(cfg(3), miners, {[8] = 99}, {}, 100)
assert(count(plan, 8) == 3 and not plan.p1[8] and plan.p4[8])
plan = planner.plan(cfg(3), miners, {}, {}, 100)
assert(count(plan, 8) == 3 and not plan.p1[8], "idle fallback must also count seats")
for _, p in ipairs(miners) do p.assignment = occupied("job" .. p.key, 8) end
local report
plan, report = planner.plan(cfg(3), miners, {}, {}, 100)
assert(count(plan, 8) == 3 and report.held == 3, "existing workers consume seats")

-- Roster enumeration cannot alter equally strong candidates' outcome.
local a = pal("a", {[8] = {1, 2}})
local b = pal("b", {[8] = {1, 2}})
local p1 = planner.plan(cfg(1), {b, a}, {[8] = 3}, {}, 100)
local p2 = planner.plan(cfg(1), {a, b}, {[8] = 3}, {}, 100)
assert(p1.a[8] and p2.a[8] and not p1.b[8] and not p2.b[8])

-- Widening retains priority 1 only while a seat remains. It cannot turn four
-- eligible specialists into four workers when the configured maximum is 3.
local mixed = {}
for i = 1, 4 do mixed[i] = pal("m" .. i, {[8] = {1, 2}, [12] = {2, 1}}) end
plan = planner.plan(cfg(3), mixed, {[12] = 99}, {}, 100)
assert(count(plan, 8) == 3 and count(plan, 12) <= 3)
local generator = pal("generator", {[4] = {1, 4}, [12] = {2, 2}})
plan = planner.plan(cfg(3), {generator}, {[12] = 99}, {}, 100)
assert(plan.generator[4], "a manned non-pulsing generator's higher priority remains permitted")

-- Balanced staffing gives the lower priority type a turn before filling the
-- higher one. Strict fill reaches its cap first. Neither mode is relabeled.
local spread = planner.plan(cfg(3, "spread"), mixed, {[8] = 99, [12] = 99}, {}, 100)
local fill = planner.plan(cfg(3, "fill"), mixed, {[8] = 99, [12] = 99}, {}, 100)
assert(count(spread, 12) == 2 and count(fill, 12) == 1)

-- Same-type demand from an unrelated job cannot refresh an assignment hold.
local holds = {}
local worker = pal("worker", {[5] = {1, 3}}, occupied("job-a", 5))
plan, report = planner.plan(cfg(3), {worker}, {}, holds, 100)
assert(report.held == 1)
worker.assignment.state = "unknown"
plan, report = planner.plan(cfg(3), {worker}, {[5] = 10}, holds, 150)
assert(report.held == 0, "a sampling gap cannot revalidate an old assignment")
worker.assignment = occupied("job-a", 5)
planner.plan(cfg(3), {worker}, {}, holds, 200)
worker.assignment.state = "unknown"
for t = 210, 280, 10 do
    plan, report = planner.plan(cfg(3), {worker}, {[5] = 10}, holds, t)
    assert(report.held == 1)
end
plan, report = planner.plan(cfg(3), {worker}, {[5] = 10}, holds, 291)
assert(report.held == 0 and holds.worker == nil, "other jobs cannot renew the 90s grace")
worker.assignment = occupied("job-a", 5)
planner.plan(cfg(3), {worker}, {}, holds, 300)
worker.assignment = { id = "job-b", value = 5, state = "unknown" }
plan, report = planner.plan(cfg(3), {worker}, {}, holds, 310)
assert(report.held == 0, "same suitability is not the same assignment")
worker.assignment = occupied("job-c", 5)
planner.plan(cfg(3), {worker}, {}, holds, 320)
worker.assignment.state = "completed"
plan, report = planner.plan(cfg(3), {worker}, {}, holds, 330)
assert(report.held == 0)
worker.assignment = nil
worker.current = 5
plan, report = planner.plan(cfg(3), {worker}, {}, holds, 340)
assert(report.held == 0 and report.assignment_unknown == 1)

-- Deliberate fixed assignments are respected; their conflicts are explicit.
local fixed = pal("fixed", {[5] = {1, 2}, [8] = {2, 2}}, occupied("mine", 8, true))
plan = planner.plan(cfg(3), {fixed}, {[5] = 10}, {}, 100)
assert(plan.fixed[8] and not plan.fixed[5])
fixed.base[8] = nil -- explicit X or a legacy production cap
plan, report = planner.plan(cfg(3), {fixed}, {[5] = 10}, {}, 100)
assert(not plan.fixed[8] and report.manual_conflicts == 1)
local fixed_roster = {}
for i = 1, 3 do
    fixed_roster[i] = pal("f" .. i, {[8] = {1, 1}}, occupied("j" .. i, 8, true))
end
fixed_roster[4] = pal("auto", {[8] = {1, 4}})
plan, report = planner.plan(cfg(2), fixed_roster, {[8] = 10}, {}, 100)
assert(report.manual_limit_conflicts == 1 and not plan.auto[8])

-- Unknown manual status must stay unknown. Preserve an enabled current type,
-- reserve its capacity, and show excess instead of silently cancelling a
-- potentially deliberate assignment. This is not an occupied/held verdict.
local unknown = pal("unknown", {[8] = {1, 1}})
unknown.assignment = nil
unknown.current, unknown.current_permitted = 8, true
local stronger = pal("stronger", {[8] = {1, 4}})
stronger.assignment = {state = "ready", manual = false}
plan, report = planner.plan(cfg(1), {unknown, stronger}, {[8] = 10}, {}, 100)
assert(plan.unknown[8] and not plan.stronger[8])
assert(report.held == 0 and report.manual_unavailable == 1)
stronger.current, stronger.current_permitted = 8, true
stronger.assignment = nil
plan, report = planner.plan(cfg(1), {unknown, stronger}, {[8] = 10}, {}, 100)
assert(report.unverified_limit_conflicts == 1)
local minimum = cfg(3)
minimum.min_suitability_rank = 2
plan = planner.plan(minimum, {pal("low", {[8] = {1, 1}})}, {[8] = 10}, {}, 100)
assert(not plan.low[8], "fallback cannot bypass the minimum suitability rank")

-- Property regression: automatic permissions never exceed capacity, never
-- introduce a barred type, and are invariant to reversing the roster.
math.randomseed(3371)
for scenario = 1, 100 do
    local roster, reversed, demand = {}, {}, {}
    for value = 1, 6 do demand[value] = math.random(0, 8) end
    for i = 1, 8 do
        local entries = {}
        for value = 1, 6 do
            if math.random() > 0.25 then entries[value] = {math.random(1, 5), math.random(1, 4)} end
        end
        roster[i] = pal("pal" .. i, entries)
        if entries[1] and math.random() > 0.5 then roster[i].assignment = occupied("j" .. i, 1) end
    end
    for i = #roster, 1, -1 do reversed[#reversed + 1] = roster[i] end
    local config = cfg(math.random(1, 4), scenario % 2 == 0 and "spread" or "fill")
    local first = planner.plan(config, roster, demand, {}, 100)
    local second = planner.plan(config, reversed, demand, {}, 100)
    for value = 1, 6 do assert(count(first, value) <= config.max_pals_per_work_type) end
    for _, p in ipairs(roster) do
        for value = 1, 6 do
            assert(first[p.key][value] == second[p.key][value])
            assert(not first[p.key][value] or p.base[value])
        end
    end
end
