-- use_work_priority_for_new_pals (0.5.1, asked for on Nexus 2026-11-08): a Pal
-- nobody ranked takes the config.lua numbers again, as in 0.4.1; one edit keeps
-- what the Pal showed; ranked Pals, X and pal_overrides keep winning.
local noop = function() end
package.loaded.log = {info = noop, debug = noop, warn = noop, error = noop, say = noop}
package.loaded.trace = {at = noop, done = noop}
local file = require("datafile")
local fs = require("memory_fs")()
file.fs = fs
local store = require("store")
local workdefs = require("workdefs")
local planner = require("scheduler_plan")

local T, M, F = workdefs.value("Transport"), workdefs.value("Mining"), workdefs.value("MonsterFarm")
local cfg = { work_priority = { Transport = 5, Mining = 1, MonsterFarm = 3, Watering = false },
    pal_overrides = { Boss = { Mining = 4 } } }
local ranks = { [T] = 5, [M] = 1, [F] = 3 }

local function fresh(rows)
    fs.files = {}
    assert(file.write("priorities", "# saved\n", 0))
    store.load("priorities"); store.set_role("authority")
    store.baseline = false
    for key, row in pairs(rows or {}) do store.data[key] = row end
end
local function shown(key, name, work, value)
    return store.effective(cfg, { key = key, name = name }, work, value)
end

-- Off (the default): an untouched Pal reads 1 for every managed job, X stays X.
fresh()
store.set_rank_defaults(nil)
assert(shown("new", "Lamball", "Transport", T) == 1 and shown("new", "Lamball", "Mining", M) == 1)
assert(shown("new", "Lamball", "Watering", workdefs.value("Watering")) == false)

-- On: the config numbers, for a Pal with no row at all.
store.set_rank_defaults(ranks)
assert(shown("new", "Lamball", "Transport", T) == 5, tostring(shown("new", "Lamball", "Transport", T)))
assert(shown("new", "Lamball", "Mining", M) == 1 and shown("new", "Lamball", "MonsterFarm", F) == 3)
assert(shown("new", "Lamball", "Watering", workdefs.value("Watering")) == false, "config X was lost")

-- A fresh install's captured all-1 row is unranked too, and its X stays X.
fresh({ cap = { [T] = 1, [M] = 1, [F] = false } })
store.set_rank_defaults(ranks)
assert(shown("cap", "Lamball", "Transport", T) == 5 and shown("cap", "Lamball", "Mining", M) == 1)
assert(shown("cap", "Lamball", "MonsterFarm", F) == false, "a captured X became a number")

-- The scheduler steers it now: its numbers differ.
local pal = { key = "cap", base = { [T] = true, [M] = true }, ranks = { [T] = 1, [M] = 1 },
    priorities = { [T] = shown("cap", "Lamball", "Transport", T), [M] = shown("cap", "Lamball", "Mining", M) } }
assert(not planner.unordered(pal), "a Pal with config numbers was still left to the game")

-- One click keeps what it showed: the other jobs keep their config numbers.
assert(store.apply_set("cap", M, 2))
assert(store.data.cap[T] == 5 and store.data.cap[M] == 2 and store.data.cap[F] == false,
    "an edit dropped the other jobs back to 1")
assert(shown("cap", "Lamball", "Transport", T) == 5 and shown("cap", "Lamball", "Mining", M) == 2)

-- A ranked Pal keeps its own numbers.
fresh({ mine = { [T] = 2, [M] = 1 } })
store.set_rank_defaults(ranks)
assert(shown("mine", "Lamball", "Transport", T) == 2 and shown("mine", "Lamball", "Mining", M) == 1)

-- One numbered job is the player's own number; the jobs it lacks take config.
fresh({ one = { [T] = 2 } })
store.set_rank_defaults(ranks)
assert(shown("one", "Lamball", "Transport", T) == 2, "a single edit was replaced")
assert(shown("one", "Lamball", "Mining", M) == 1 and shown("one", "Lamball", "MonsterFarm", F) == 3)

-- pal_overrides still sit above config numbers for an unranked Pal.
fresh({ boss = { [T] = 1, [M] = 1 } })
store.set_rank_defaults(ranks)
assert(shown("boss", "Boss", "Mining", M) == 4, "pal_overrides lost to config numbers")
assert(shown("boss", "Boss", "Transport", T) == 5)

-- A fresh install before the capture still knows nothing: no number, no permission.
fresh()
store.baseline = true
store.set_rank_defaults(ranks)
assert(shown("unseen", "Lamball", "Transport", T) == nil, "an uncaptured Pal got a number")
store.baseline = false

-- Off again: the stored numbers come back unchanged.
fresh({ cap = { [T] = 1, [M] = 1 } })
store.set_rank_defaults(nil)
assert(shown("cap", "Lamball", "Transport", T) == 1)
assert(store.apply_set("cap", M, 2) and store.data.cap[T] == 1, "an edit with the setting off changed other jobs")

print("config ranks: unranked Pals take config numbers when asked; edits, X, overrides and ranked Pals hold")
