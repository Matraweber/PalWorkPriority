local storage = require("scheduler_storage")
local camps = { {id = "a", guild = "guild-a"}, {id = "b", guild = "guild-a"},
    {id = "c", guild = "guild-b"}, {id = "a", guild = "guild-a"} }
local totals = {a = {Stone = 6}, b = {Stone = 6, Ore = 3}, c = {Stone = 100}}
local counts = {a = 1, b = 1, c = 1}
local evidence = {complete = true, deduplicated = true}
local grouped = storage.group(camps, totals, counts, evidence)
assert(grouped["guild-a"].totals.Stone == 12 and grouped["guild-a"].totals.Ore == 3)
assert(grouped["guild-a"].chests == 2, "duplicate camp records must not duplicate storage")
assert(grouped["guild-b"].totals.Stone == 100 and grouped["guild-a"].verified)

grouped = storage.group(camps, totals, counts)
assert(not grouped["guild-a"].verified, "aggregate totals cannot prove container deduplication")
grouped = storage.group(camps, totals, counts, {complete = true, deduplicated = false})
assert(not grouped["guild-a"].verified)
grouped = storage.group(camps, nil, nil, evidence)
assert(not grouped["guild-a"].verified, "nil scan must not count as empty storage")
totals.unowned = {Stone = 999}
local unknown
grouped, unknown = storage.group(camps, totals, counts, evidence)
assert(unknown == 1 and not grouped["guild-a"].verified)
assert(grouped["guild-a"].totals.Stone == 12, "unknown ownership must never inflate a known guild")
totals.unowned = nil
camps[#camps + 1] = {id = "a", guild = "guild-b"}
grouped, unknown = storage.group(camps, totals, counts, evidence)
assert(unknown == 1 and not grouped["guild-a"].verified)
assert(grouped["guild-a"].totals.Stone == 6 and grouped["guild-b"].totals.Stone == 100)
