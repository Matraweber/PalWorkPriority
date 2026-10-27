-- KhanKeal's report (2026-09-10): Flambelle with Handiwork 1, Kindling 2,
-- Transporting 3, Ranching 4 "stays ranching". Rerun 2026-10-27 as a planning
-- case (no Flambelle in the test world): while it sits on the ranch, any
-- higher type with work pulls it off; with nothing else to do it may stay.
local planner = require("scheduler_plan")
local cfg = { max_pals_per_work_type = 3, assignment_mode = "spread",
    min_suitability_rank = 1, interval_seconds = 10 }
local HANDIWORK, KINDLING, TRANSPORT, FARMING = 5, 1, 12, 13

local function flambelle()
    local p = { key = "flambelle", base = {}, priorities = {}, ranks = {},
        assignment = { id = "ranch", value = FARMING, state = "occupied", manual = false } }
    for value, prio in pairs({ [HANDIWORK] = 1, [KINDLING] = 2, [TRANSPORT] = 3, [FARMING] = 4 }) do
        p.base[value], p.priorities[value], p.ranks[value] = true, prio, 1
    end
    return p
end

-- Handiwork wanted: Handiwork only, Farming withdrawn.
local plan = planner.plan(cfg, { flambelle() }, { [HANDIWORK] = 1, [FARMING] = 1 }, {}, 100)
assert(plan.flambelle[HANDIWORK] and not plan.flambelle[FARMING], "Handiwork 1 did not beat the ranch it sits on")
-- Only Kindling and Transporting wanted: Kindling, the higher of the two.
plan = planner.plan(cfg, { flambelle() }, { [KINDLING] = 1, [TRANSPORT] = 5 }, {}, 100)
assert(plan.flambelle[KINDLING] and not plan.flambelle[TRANSPORT] and not plan.flambelle[FARMING],
    "Kindling 2 did not win over Transporting 3 and the ranch")
-- Nothing above Ranching wanted: it keeps the ranch (the only job left).
plan = planner.plan(cfg, { flambelle() }, { [FARMING] = 1 }, {}, 100)
assert(plan.flambelle[FARMING], "with no other work the ranch was taken away")
print("flambelle: higher priorities pull it off the ranch, ranch kept only when nothing else is wanted")
