-- use_work_priority_for_new_pals (0.5.1, asked for on Nexus 2026-11-08): a new
-- Pal takes the default numbers (config.lua or the DarnMenu page), as in 0.4.1.
-- The first time the setting is on, a fresh install's Pals whose jobs all had
-- the same number take them once; after that a stored number always wins.
-- Cases from the in-game test and the review round of 2026-11-10:
--   * Pal Recruiter set to 1 1 1 1 showed 3 3 4 4 (first build).
--   * An upgraded row {Transport=5, Farming=5} with Handiwork unclicked was
--     "converted", so the Pal hauled first (P1).
--   * A job that is X in config.lua was captured as 1 and then steered (P1).
--   * Off then on converted hand-set equal rows again (P2).
--   * A failed marker write let the next launch convert again (P2).
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
local W, H, S = workdefs.value("Watering"), workdefs.value("Handcraft"), workdefs.value("Seeding")
local cfg = { work_priority = { Transport = 5, Mining = 1, MonsterFarm = 3, Handcraft = 3, Watering = false },
    pal_overrides = { Boss = { Mining = 4 } } }
local ranks = { [T] = 5, [M] = 1, [F] = 3, [H] = 3 }
local xs = { [W] = true }
local MARKER = "config-ranks.txt"

-- A launch: load priorities.txt as saved, become the saving side, set the ranks.
local function launch(defaults)
    store.load("priorities"); store.set_role("authority")
    store.set_rank_defaults(defaults, xs)
    store.rank_marker_pending, store.rank_marker_retry_at, store.rank_converted = false, 0, nil
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
    return (file.read(MARKER, function(t) return t:match("^converted=([01])%s*$") end))
end

-- Off (the default): an untouched Pal reads 1 for every managed job, X stays X.
fresh(); launch(nil)
assert(shown("new", "Lamball", "Transport", T) == 1 and shown("new", "Lamball", "Mining", M) == 1)
assert(shown("new", "Lamball", "Watering", W) == false)
assert(store.reconcile_rank_defaults(MARKER) == 0 and marker() == nil, "off wrote a marker")

-- On: the default numbers for a Pal with no row, X kept, pal_overrides above them.
fresh(); launch(ranks)
assert(shown("new", "Lamball", "Transport", T) == 5 and shown("new", "Lamball", "Mining", M) == 1)
assert(shown("new", "Lamball", "MonsterFarm", F) == 3 and shown("new", "Lamball", "Watering", W) == false)
assert(shown("new", "Boss", "Mining", M) == 4, "pal_overrides lost to the default numbers")

-- An upgraded file (no baseline) stores only clicked cells: never converted,
-- and no marker, so nothing there is decided for later.
fresh({ part = { [T] = 5, [F] = 5 }, all = { [T] = 1, [M] = 1 } }); launch(ranks)
assert(store.reconcile_rank_defaults(MARKER) == 0, "an upgraded file was converted")
assert(store.data.part[T] == 5 and store.data.part[F] == 5 and store.data.part[H] == nil,
    "a partial row lost the player's numbers")
assert(store.data.all[T] == 1 and marker() == nil)
-- Its unclicked jobs show the defaults, so the Pal is ranked as it was meant.
assert(shown("part", "Lamball", "Handcraft", H) == 3 and shown("part", "Lamball", "Transport", T) == 5)

-- A fresh install, first time on: equal Pals take the default numbers once,
-- a config X job becomes X. Ranked Pals and a one-job Pal keep theirs.
fresh({ cap = { [T] = 1, [M] = 1, [F] = false, [W] = 1 }, mine = { [T] = 2, [M] = 1 }, one = { [T] = 2 } }, true)
launch(ranks)
assert(store.baseline == true)
assert(shown("cap", "Lamball", "Transport", T) == 1, "a stored number was replaced before the conversion")
assert(store.reconcile_rank_defaults(MARKER) == 1, "the conversion did not count one Pal")
assert(store.data.cap[T] == 5 and store.data.cap[M] == 1 and store.data.cap[F] == false, "conversion row wrong")
assert(store.data.cap[W] == false, "a config X job kept its number")
assert(store.data.mine[T] == 2 and store.data.mine[M] == 1, "a ranked Pal was converted")
assert(store.data.one[T] == 2 and store.data.one[M] == nil, "a one-job Pal was converted")
assert(store.state == "saved" and marker() == "1", "converted but not saved, or no marker")
assert(store.rank_converted == 1, "the stand's notice has no count")
assert(store.reconcile_rank_defaults(MARKER) == 0, "the conversion ran twice in one launch")

-- On disk: the next launch reads the numbers back and converts nothing.
launch(ranks)
assert(store.data.cap[T] == 5, "the conversion was not saved")
local pal = { key = "cap", base = { [T] = true, [M] = true }, ranks = { [T] = 1, [M] = 1 },
    priorities = { [T] = shown("cap", "Lamball", "Transport", T), [M] = shown("cap", "Lamball", "Mining", M) } }
assert(not planner.unordered(pal), "a Pal with default numbers was still left to the game")

-- The in-game case: with the setting on, a player sets a Pal to equal numbers.
-- It shows what was clicked and stays so on the next launch.
assert(store.apply_set("cap", T, 1) and store.flush(nil, true))
assert(shown("cap", "Lamball", "Transport", T) == 1 and shown("cap", "Lamball", "Mining", M) == 1,
    "an equal row set by hand showed the default numbers")
launch(ranks)
assert(store.reconcile_rank_defaults(MARKER) == 0 and store.data.cap[T] == 1,
    "an equal row set by hand was converted on the next launch")

-- Off, then on again: the marker stays, the hand-set equal row stays.
launch(nil)
assert(store.reconcile_rank_defaults(MARKER) == 0 and marker() == "1", "off changed the marker")
launch(ranks)
assert(store.reconcile_rank_defaults(MARKER) == 0 and store.data.cap[T] == 1, "off then on converted again")

-- Off at first, on later: the first time on is the one that converts.
fresh({ cap = { [T] = 1, [M] = 1 } }, true); launch(nil)
assert(store.reconcile_rank_defaults(MARKER) == 0 and marker() == nil and store.data.cap[T] == 1)
launch(ranks)
assert(store.reconcile_rank_defaults(MARKER) == 1 and store.data.cap[T] == 5 and marker() == "1")

-- Not before the role is decided, and never on a client.
fresh({ cap = { [T] = 1, [M] = 1 } }, true)
store.load("priorities"); store.set_rank_defaults(ranks, xs)
store.rank_marker_pending, store.rank_marker_retry_at = false, 0
store.set_role(nil)
assert(store.reconcile_rank_defaults(MARKER) == nil and store.data.cap[T] == 1)
store.set_role("client")
assert(store.reconcile_rank_defaults(MARKER) == nil and store.data.cap[T] == 1 and marker() == nil)

-- priorities.txt cannot be saved: no marker yet, no second conversion, and
-- the marker follows once the save goes through.
fresh({ cap = { [T] = 1, [M] = 1 } }, true); launch(ranks)
fs.fault = function(op, path) return op == "open" and path:find("^priorities") ~= nil and path ~= "priorities" end
assert(store.reconcile_rank_defaults(MARKER) == nil, "a failed save was reported as done")
assert(marker() == nil, "the marker was written before priorities.txt saved")
fs.fault = nil
assert(store.flush(nil, true))
assert(store.reconcile_rank_defaults(MARKER) == 0 and marker() == "1", "the marker did not follow the save")
launch(ranks)
assert(store.data.cap[T] == 5)

-- The marker cannot be written: tried again later, not given up; a row set
-- equal meanwhile survives the next launch.
fresh({ cap = { [T] = 1, [M] = 1 }, two = { [T] = 4, [M] = 2 } }, true); launch(ranks)
fs.fault = function(op, path) return op == "rename" and path:find("config%-ranks") ~= nil end
assert(store.reconcile_rank_defaults(MARKER, 100) == nil and store.data.cap[T] == 5)
assert(#warned == 1 and warned[1]:find("config-ranks.txt", 1, true), "no warning for a failed marker")
assert(store.reconcile_rank_defaults(MARKER, 110) == nil, "retried at once")
fs.fault = nil
assert(store.reconcile_rank_defaults(MARKER, 131) == 0 and marker() == "1", "the marker was not tried again")
assert(store.apply_set("two", T, 2) and store.flush(nil, true))
launch(ranks)
assert(store.reconcile_rank_defaults(MARKER) == 0 and store.data.two[T] == 2 and store.data.two[M] == 2,
    "a row set equal after the conversion was converted on the next launch")

-- An unreadable marker converts nothing and says where it is.
fresh({ cap = { [T] = 1, [M] = 1 } }, true); launch(ranks)
fs.files[MARKER] = "garbage\n"
assert(store.reconcile_rank_defaults(MARKER) == 0 and store.data.cap[T] == 1)
assert(#warned == 1 and warned[1]:find("next to config.lua", 1, true), "no warning for a bad marker")
-- A hand edit with Windows line endings still reads as done.
fresh({ cap = { [T] = 1, [M] = 1 } }, true); launch(ranks)
fs.files[MARKER] = "converted=1\r\n"
assert(store.reconcile_rank_defaults(MARKER) == 0 and store.data.cap[T] == 1 and #warned == 0,
    "a CRLF marker was not read")

-- A fresh install's capture: the default numbers, X for config X and for
-- unticked jobs, 1 for a job with no default.
fresh(nil, true); launch(ranks)
assert(shown("unseen", "Lamball", "Transport", T) == nil, "an uncaptured Pal got a number")
assert(store.capture_baseline("caught", { [T] = true, [M] = true, [F] = true, [W] = true, [S] = true }, { [F] = true }))
assert(store.data.caught[T] == 5 and store.data.caught[M] == 1 and store.data.caught[F] == false,
    "the capture did not store the default numbers")
assert(store.data.caught[W] == false, "a config X job was captured as a number")
assert(store.data.caught[S] == 1, "a job with no default did not capture as 1")
-- With the setting off it captures 1, and config X is X there too.
fresh(nil, true); launch(nil)
assert(store.capture_baseline("caught", { [T] = true, [M] = true, [W] = true }, {}))
assert(store.data.caught[T] == 1 and store.data.caught[M] == 1 and store.data.caught[W] == false,
    "with the setting off a config X job was captured as 1")

-- A briefly locked marker while the conversion waits for it: tried again,
-- not given up (re-review P3-3).
fresh({ cap = { [T] = 1, [M] = 1 } }, true); launch(ranks)
fs.fault = function(op, path) return op == "rename" and path:find("config%-ranks") ~= nil end
assert(store.reconcile_rank_defaults(MARKER, 100) == nil and store.rank_marker_pending)
fs.fault = function(op, path) return op == "open" and path:find("^config%-ranks") ~= nil end
assert(store.reconcile_rank_defaults(MARKER, 131) == nil and not store.rank_marker_done, "a locked marker gave up")
fs.fault = nil
assert(store.reconcile_rank_defaults(MARKER, 162) == 0 and marker() == "1" and store.rank_marker_done)

-- A job that was X on a fresh install and is a number now: the Pals saved
-- with X keep it, and the mod says how many, once (re-review P2-1).
local XFILE = "config-x.txt"
local function xlist() return fs.files[XFILE] and fs.files[XFILE]:match("x=([%d,]*)") end
fresh({ cap = { [T] = 1, [W] = false }, other = { [T] = 2, [M] = 1 } }, true); launch(ranks)
store.x_lifted = nil
assert(store.reconcile_config_x(XFILE) == true and xlist() == tostring(W), "the X jobs were not kept")
assert(store.x_lifted == nil, "a first launch reported a lifted X")
store.set_rank_defaults(ranks, {}) -- Watering is a number now
assert(store.reconcile_config_x(XFILE) == true and xlist() == "", "the new X list was not written")
assert(store.x_lifted and store.x_lifted.pals == 1 and store.x_lifted.labels[1] == "Watering",
    "lifting an X was not reported")
assert(#warned >= 1 and warned[#warned]:find("Watering was X", 1, true))
store.x_lifted = nil
store.set_rank_defaults(ranks, {})
assert(store.reconcile_config_x(XFILE) == true and store.x_lifted == nil, "reported twice")
-- Upgraded files read X live: nothing kept, nothing said.
fresh({ cap = { [T] = 1, [W] = false } }); launch(ranks)
assert(store.reconcile_config_x(XFILE) == true and fs.files[XFILE] == nil)

print("config ranks: new Pals take default numbers, fresh installs convert once, upgraded rows, X and hand-set numbers hold")
