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
    local key, value, prio = line:match("^(%x+)|(%d+)|(%w+)$")
    if not key then return nil end

    value = tonumber(value)
    if not value then return nil end

    if prio == "X" then return key, value, false end

    prio = tonumber(prio)
    if not prio or prio < 1 then return nil end
    return key, value, math.floor(prio)
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

    local f, err = io.open(M.path, "wb")
    if not f then
        log.warn("could not write " .. M.path .. ": " .. tostring(err))
        return false
    end

    f:write("# Pal Work Priority - per-pal edits from the Monitoring Stand.\n")
    f:write("# palkey|worktype|priority   (X = never assign)\n")

    -- Sorted so the file does not reshuffle itself on every save, which makes
    -- it diffable and makes a hand edit survive the next write.
    local keys = {}
    for key in pairs(M.data) do keys[#keys + 1] = key end
    table.sort(keys)

    for _, key in ipairs(keys) do
        local values = {}
        for value in pairs(M.data[key]) do values[#values + 1] = value end
        table.sort(values)

        for _, value in ipairs(values) do
            local prio = M.data[key][value]
            f:write(string.format("%s|%d|%s\n", key, value,
                prio == false and "X" or tostring(prio)))
        end
    end

    f:close()
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

function M.set(key, value, prio)
    if not key then return end
    M.data[key] = M.data[key] or {}
    M.data[key][value] = prio
    dirty_at = os.clock()
end

-- Clears a pal's edit for one work type, dropping it back to config policy.
function M.clear(key, value)
    local byPal = key and M.data[key]
    if byPal == nil then return end
    byPal[value] = nil
    if next(byPal) == nil then M.data[key] = nil end
    dirty_at = os.clock()
end

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
