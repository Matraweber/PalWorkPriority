-- use_work_priority_for_new_pals (0.5.1, asked for on Nexus 2026-11-08): a new
-- Pal takes the config.lua numbers again, as in 0.4.1. Switching the setting
-- on gives them once to every Pal whose jobs all had the same number; after
-- that a stored number always wins, so equal numbers set by hand stay equal.
-- The first build re-read every all-equal row as "not ranked" on each refresh:
-- Pal Recruiter set to 1 1 1 1 on the stand showed 3 3 4 4 (in-game test
-- 2026-11-10). That case is checked below.
local noop = function() end
local warned = {}
package.loaded.log = {info = noop, debug = noop, error = noop, say = noop,
    warn = function(m) warned[#warned + 1] = tostring(m) end}
package.loaded.trace = {at = noop, done = noop}
local file = require("datafile")
local fs = require("memory_fs")()
file.fs = fs
local store = require("store")
local workdefs = require("workdefs")
local planner = require("scheduler_plan")

local T, M, F = workdefs.value("Transport"), workdefs.value("Mining"), workdefs.value("MonsterFarm")
local W = workdefs.value("Watering")
local cfg = { work_priority = { Transport = 5, Mining = 1, MonsterFarm = 3, Watering = false },
    pal_overrides = { Boss = { Mining = 4 } } }
local ranks = { [T] = 5, [M] = 1, [F] = 3 }
local MARKER = "config-ranks.txt"

-- A launch: load priorities.txt as saved, become the saving side, set the ranks.
local function launch(defaults)
    store.load("priorities"); store.set_role("authority")
    store.set_rank_defaults(defaults)
end
local function fresh(rows, baseline)
    fs.files, fs.fault, warned = {}, nil, {}
    local body = baseline and "# baseline=vanilla\n" or "# saved\n"
    for key, row in pairs(rows or {}) do
        for value, p in pairs(row) do
            body = body .. string.format("%s|%d|%s\n", key, value, p == false and "X" or tostring(p))
        end
    end
    assert(file.write("priorities", body, 0))
end
local function shown(key, name, work, value)
    return store.effective(cfg, { key = key, name = name }, work, value)
end
local function marker()
    local v = file.read(MARKER, function(t) return t:match("^converted=([01])\n$") end)
    return v
end

-- Off (the default): an untouched Pal reads 1 for every managed job, X stays X.
fresh(); launch(nil)
assert(shown("new", "Lamball", "Transport", T) == 1 and shown("new", "Lamball", "Mining", M) == 1)
assert(shown("new", "Lamball", "Watering", W) == false)
assert(store.reconcile_rank_defaults(MARKER) == 0 and marker() == nil, "off wrote a marker it did not need")

-- On: the config numbers for a Pal with no row, X kept.
fresh(); launch(ranks)
assert(shown("new", "Lamball", "Transport", T) == 5 and shown("new", "Lamball", "Mining", M) == 1)
assert(shown("new", "Lamball", "MonsterFarm", F) == 3 and shown("new", "Lamball", "Watering", W) == false)
-- pal_overrides still sit above them.
assert(shown("new", "Boss", "Mining", M) == 4, "pal_overrides lost to config numbers")

-- Switched on: every all-equal Pal takes the config numbers once, X kept.
-- Ranked Pals and a Pal with one numbered job keep theirs.
fresh({ cap = { [T] = 1, [M] = 1, [F] = false }, mine = { [T] = 2, [M] = 1 }, one = { [T] = 2 } })
launch(ranks)
assert(shown("cap", "Lamball", "Transport", T) == 1, "a stored number was replaced before the conversion")
assert(store.reconcile_rank_defaults(MARKER) == 1, "the conversion did not count one Pal")
assert(store.data.cap[T] == 5 and store.data.cap[M] == 1 and store.data.cap[F] == false, "conversion row wrong")
assert(store.data.mine[T] == 2 and store.data.mine[M] == 1, "a ranked Pal was converted")
assert(store.data.one[T] == 2 and store.data.one[M] == nil, "a one-job Pal was converted")
assert(store.state == "saved" and marker() == "1", "converted but not saved, or no marker")
assert(store.reconcile_rank_defaults(MARKER) == 0, "the conversion ran twice in one launch")

-- It is on disk: the next launch reads the numbers back and converts nothing.
launch(ranks)
assert(store.data.cap[T] == 5, "the conversion was not saved")
-- The scheduler steers it now: its numbers differ.
local pal = { key = "cap", base = { [T] = true, [M] = true }, ranks = { [T] = 1, [M] = 1 },
    priorities = { [T] = shown("cap", "Lamball", "Transport", T), [M] = shown("cap", "Lamball", "Mining", M) } }
assert(not planner.unordered(pal), "a Pal with config numbers was still left to the game")

-- The in-game case: with the setting on, a player sets a Pal to equal numbers.
-- It shows what was clicked and stays so after the next launch.
assert(store.apply_set("cap", T, 1) and store.flush(nil, true))
assert(shown("cap", "Lamball", "Transport", T) == 1 and shown("cap", "Lamball", "Mining", M) == 1,
    "an equal row set by hand showed the config numbers")
launch(ranks)
assert(store.reconcile_rank_defaults(MARKER) == 0 and store.data.cap[T] == 1,
    "an equal row set by hand was converted on the next launch")
-- One click on a Pal with missing jobs changes only that job.
assert(store.apply_set("one", M, 3) and store.data.one[T] == 2 and store.data.one[F] == nil)

-- Off at a launch: the marker goes back to 0, numbers stay. On again later
-- converts the Pals that became all-equal meanwhile.
launch(nil)
assert(store.reconcile_rank_defaults(MARKER) == 0 and marker() == "0")
assert(store.data.cap[T] == 1 and shown("new", "Lamball", "Transport", T) == 1)
launch(ranks)
assert(store.reconcile_rank_defaults(MARKER) == 1 and store.data.cap[T] == 5 and marker() == "1",
    "switching on again did not convert")

-- Not before the role is decided, and never on a client.
fresh({ cap = { [T] = 1, [M] = 1 } })
store.load("priorities"); store.set_rank_defaults(ranks)
store.set_role(nil)
assert(store.reconcile_rank_defaults(MARKER) == nil and store.data.cap[T] == 1)
store.set_role("client")
assert(store.reconcile_rank_defaults(MARKER) == nil and store.data.cap[T] == 1 and marker() == nil)

-- priorities.txt cannot be saved: no marker yet, no second conversion, and
-- the marker follows once the save goes through.
fresh({ cap = { [T] = 1, [M] = 1 } }); launch(ranks)
fs.fault = function(op, path) return op == "open" and path:find("^priorities") ~= nil and path ~= "priorities" end
assert(store.reconcile_rank_defaults(MARKER) == nil, "a failed save was reported as done")
assert(marker() == nil, "the marker was written before priorities.txt saved")
fs.fault = nil
assert(store.flush(nil, true))
assert(store.reconcile_rank_defaults(MARKER) == 0 and marker() == "1", "the marker did not follow the save")
launch(ranks)
assert(store.data.cap[T] == 5)

-- An unreadable marker converts nothing and says so.
fresh({ cap = { [T] = 1, [M] = 1 } }); launch(ranks)
fs.files[MARKER] = "garbage\n"
assert(store.reconcile_rank_defaults(MARKER) == 0 and store.data.cap[T] == 1)
assert(#warned == 1 and warned[1]:find("config-ranks.txt", 1, true), "no warning for a bad marker")

-- A fresh install's capture stores the config numbers, X as X.
fresh(nil, true); launch(ranks)
assert(store.baseline == true)
assert(shown("unseen", "Lamball", "Transport", T) == nil, "an uncaptured Pal got a number")
assert(store.capture_baseline("caught", { [T] = true, [M] = true, [F] = true, [W] = true }, { [F] = true }))
assert(store.data.caught[T] == 5 and store.data.caught[M] == 1 and store.data.caught[F] == false,
    "the capture did not store the config numbers")
assert(store.data.caught[W] == 1, "a job with no config number did not capture as 1")
-- With the setting off it still captures 1.
fresh(nil, true); launch(nil)
assert(store.capture_baseline("caught", { [T] = true, [M] = true }, {}))
assert(store.data.caught[T] == 1 and store.data.caught[M] == 1)

print("config ranks: new Pals take config numbers, the switch converts equal Pals once, hand-set equal numbers stay")
