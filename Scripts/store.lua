-- Per-pal, per-work-type priority edits made from the Monitoring Stand.
--
-- config.lua remains the policy layer: it decides what a pal gets when
-- nobody has said otherwise. This is the exception layer, one entry per
-- cell actually clicked, and it outranks everything in config.
--
-- It also owns the single effective-priority function. The scheduler and the
-- stand UI both call it, because when they each had their own the two
-- silently disagreed about species-keyed overrides and the grid showed a
-- policy the scheduler was not following.

local log = require("log")

local M = {}

-- Priorities run 1 (first) to MAX (last), with false meaning never assign.
M.MAX = 5

-- The widest work-type index the file may name.
--
-- workdefs.ORDER has 14 entries and store deliberately does not require
-- workdefs, so this is written down rather than derived. Generous on purpose:
-- it exists to refuse absurd values, not to police the work list.
local MAX_WORK = 64

M.path = nil
M.data = {}          -- pal key -> { [work value] = number | false }

local dirty_at = nil
local SAVE_DEBOUNCE = 2.0   -- one file write per burst of clicks

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

-- One record per line: palkey|workvalue|priority, priority being 1..MAX or X.
-- Flat text rather than a Lua table because it is written from a click
-- handler, and a
-- half-written Lua table would fail to load on next start where a truncated
-- line just drops one cell.
local function parse_line(line)
    -- Word characters and dashes, not hex.
    --
    -- The reader demanded ^(%x+) while the writer wrote whatever key it held,
    -- and palapi's fallbacks produce keys hex cannot express: guid_key gives
    -- "123-456-789-012", and a pal with no id at all gets "slot3". Both saved
    -- cleanly and were silently dropped by the next load, so priorities set on
    -- those pals vanished at restart with nothing said.
    local key, value, prio = line:match("^([%w%-]+)|(%d+)|(%w+)$")
    if not key then return nil end

    -- Whole numbers in range, or the line is dropped.
    --
    -- `tonumber` alone was not enough. "99999999999999999999" matches (%d+),
    -- overflows Lua 5.4's integer parse and comes back as a FLOAT - and
    -- math.floor of a float that large is still a float. It loaded cleanly and
    -- then killed the next save: the file was already truncated by the time
    -- string.format("%d", ...) threw, dirty_at was never cleared, the handle
    -- leaked, and flush retried the whole cycle every tick. One hand-edited
    -- digit cost every priority on the machine, for the session, silently.
    --
    -- math.tointeger answers nil for anything with no integer representation,
    -- which is exactly the question the writer is about to ask.
    value = math.tointeger(tonumber(value))
    if value == nil or value < 1 or value > MAX_WORK then return nil end

    if prio == "X" then return key, value, false end

    prio = math.tointeger(tonumber(prio))
    if prio == nil or prio < 1 or prio > M.MAX then return nil end
    return key, value, prio
end

function M.load(path)
    M.path = path
    M.data = {}
    dirty_at = nil

    local f = io.open(path, "r")
    if not f then return 0 end

    local count = 0
    for line in f:lines() do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, value, prio = parse_line(line)
            if key then
                M.data[key] = M.data[key] or {}
                M.data[key][value] = prio
                count = count + 1
            end
        end
    end
    f:close()

    log.debug("loaded " .. count .. " priority edit(s)")
    return count
end

function M.save()
    if not M.path then return false end

    -- Built in memory, written to a temp file, then renamed into place.
    --
    -- The old shape opened the real file "wb" - truncating it - and formatted
    -- each row as it went, so anything that threw mid-loop left the file
    -- destroyed and the handle open. Not hypothetical: this process has died
    -- mid-operation before, which is what docs/the-crash.md is about, and
    -- discover.lua already calls unbuffered() so a dump survives it. The data
    -- files never got the same treatment.
    --
    -- Now a row that cannot be formatted costs that row and a warning, and a
    -- crash costs nothing: the real file is untouched until the rename.
    local out = {
        "# Pal Work Priority - per-pal edits from the Monitoring Stand.\n",
        "# palkey|worktype|priority   (X = never assign)\n",
    }

    -- Sorted so the file does not reshuffle itself on every save, which makes
    -- it diffable and makes a hand edit survive the next write.
    local keys = {}
    for key in pairs(M.data) do keys[#keys + 1] = key end
    table.sort(keys)

    local dropped = 0
    for _, key in ipairs(keys) do
        local values = {}
        for value in pairs(M.data[key]) do values[#values + 1] = value end
        table.sort(values)

        for _, value in ipairs(values) do
            local prio = M.data[key][value]
            local n = math.tointeger(value)
            local p = (prio == false) and false or math.tointeger(prio)

            if n == nil or p == nil then
                dropped = dropped + 1
            else
                out[#out + 1] = string.format("%s|%d|%s\n", key, n,
                    p == false and "X" or tostring(p))
            end
        end
    end

    if dropped > 0 then
        log.warn(dropped .. " priority row(s) could not be written and were " ..
            "dropped. A value that is not a whole number is the usual cause.")
    end

    local tmp = M.path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then
        log.warn("could not write " .. tmp .. ": " .. tostring(err))
        return false
    end

    local wrote = pcall(function() f:write(table.concat(out)) end)
    f:close()

    if not wrote then
        os.remove(tmp)
        log.warn("could not write " .. tmp .. ", the existing file is intact")
        return false
    end

    -- Remove then rename, because Lua's os.rename will not replace an existing
    -- file on Windows. The gap between the two is the one unsafe moment, and
    -- the temp file still holds the new content if the process dies inside it.
    os.remove(M.path)
    local moved, mv_err = os.rename(tmp, M.path)
    if not moved then
        -- Put it back by hand rather than leave nothing there.
        --
        -- The remove has already happened by this point, so returning here
        -- would delete the live file outright - worse than the truncating
        -- write this replaced. Nothing ever reads .tmp back, so it is not a
        -- recovery path on its own.
        log.warn("could not move " .. tmp .. " into place: " ..
            tostring(mv_err) .. ", writing the priorities directly")

        local back = io.open(M.path, "wb")
        if not back then return false end
        local ok_back = pcall(function() back:write(table.concat(out)) end)
        back:close()
        if not ok_back then return false end
        os.remove(tmp)
    end

    dirty_at = nil
    return true
end

-- Called from the UI tick. Batches a burst of clicks into one write.
function M.flush(now)
    if dirty_at == nil then return end
    if (now or os.clock()) - dirty_at < SAVE_DEBOUNCE then return end
    M.save()
end

-- ---------------------------------------------------------------------------
-- Reading and writing one cell
-- ---------------------------------------------------------------------------

function M.get(key, value)
    local byPal = key and M.data[key]
    if byPal == nil then return nil end
    return byPal[value]
end

-- Set when this machine owns no priorities file, exactly as caps.submit is.
--
-- A client's clicks used to write M.data and priorities.txt here, which the
-- server never reads - so the numbers changed on screen and nothing else
-- happened. With this set the write becomes a request instead, and the only
-- copy that counts is the one that comes back down.
M.submit = nil

-- Which machine this is, decided after the world loads.
--
-- false means not yet asked, and that is deliberately not the same as "I am
-- the authority". Undecided used to fall through to the local write, so for
-- the twenty seconds between a world loading and main.lua working out where
-- it was, a client's grid click wrote a file the server never reads. The change
-- showed on screen, went nowhere, and was overwritten by the next push from
-- the server, which reads exactly like the feature being broken.
--
-- A refused click with a reason is a far better twenty seconds than a
-- silently discarded one.
M.decided = false

local function undecided()
    if M.decided then return false end
    log.say("still working out whether this is a server or a client, " ..
        "try that again in a moment")
    return true
end

function M.set(key, value, prio)
    if not key then return end
    if undecided() then return false end
    if M.submit then return M.submit("set", key, value, prio) end
    return M.apply_set(key, value, prio)
end

-- The write itself, with no opinion about who asked. The authority reaches it
-- directly; a client only ever through a message coming back down.
function M.apply_set(key, value, prio)
    if not key then return end
    M.data[key] = M.data[key] or {}
    M.data[key][value] = prio
    dirty_at = os.clock()
    if M.on_change then pcall(M.on_change, key) end
end

-- Clears a pal's edit for one work type, dropping it back to config policy.
function M.clear(key, value)
    if not key then return end
    if undecided() then return false end
    if M.submit then return M.submit("clear", key, value, nil) end
    return M.apply_clear(key, value)
end

function M.apply_clear(key, value)
    local byPal = key and M.data[key]
    if byPal == nil then return end
    byPal[value] = nil
    if next(byPal) == nil then M.data[key] = nil end
    dirty_at = os.clock()
    if M.on_change then pcall(M.on_change, key) end
end

-- Called after any applied write, so the authority can tell everyone. Set by
-- main.lua once there is a world, for the same reason submit is.
M.on_change = nil

-- ---------------------------------------------------------------------------
-- Effective priority
-- ---------------------------------------------------------------------------

-- The one place that decides what priority a pal has for a work type.
--   1. a click made on the stand
--   2. config pal_overrides, nickname first then species
--   3. config work_priority
-- Returns a number, false for never, or nil when the work type has no policy
-- at all.
function M.effective(cfg, pal, work_name, work_value)
    if pal.key and work_value then
        local edit = M.get(pal.key, work_value)
        if edit ~= nil then return edit end
    end

    local overrides = cfg.pal_overrides or {}
    local entry = pal.name and overrides[pal.name] or nil
    if entry == nil and pal.species then entry = overrides[pal.species] end

    if type(entry) == "table" and entry[work_name] ~= nil then
        return entry[work_name]
    end

    return cfg.work_priority[work_name]
end

-- ---------------------------------------------------------------------------
-- Cycling
-- ---------------------------------------------------------------------------

-- dir -1 raises a cell towards priority 1, dir +1 lowers it towards never.
--
-- Both ends clamp rather than wrap. Wrapping means one click too many on a
-- priority-1 cell silently excludes the pal from that work entirely, and the
-- number gives no hint it happened. X sits below MAX, so the whole run reads
-- 1, 2, ... MAX, X from most to least wanted.
function M.cycle(current, dir)
    if current == nil then current = 3 end

    if dir < 0 then
        if current == false then return M.MAX end
        if current <= 1 then return 1 end
        return current - 1
    end

    if current == false then return false end
    if current >= M.MAX then return false end
    return current + 1
end

return M
