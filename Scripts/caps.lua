-- Resource ceilings per work type, editable in game.
--
-- config.lua owns the defaults in work_caps. This is the layer on top, one
-- entry per ceiling set with "!pwp limit", and it outranks config the same
-- way store.lua outranks it for priorities.
--
-- A ceiling suspends a work type once the base already holds that much of
-- the item, so the pals fenced to it fall through to the next priority
-- instead of producing something nobody needs.

local log = require("log")

local M = {}

M.path = nil
M.data = {}          -- work name -> { [item id] = ceiling }

-- One record per line: WorkType|ItemId|Ceiling. Flat text for the same
-- reason priorities.txt is flat: a truncated line costs one ceiling where
-- half a written Lua table costs the whole file.
local function parse_line(line)
    local work, item, ceiling = line:match("^(%a+)|([%w_%.%-]+)|(%d+)$")
    if not work then return nil end

    ceiling = tonumber(ceiling)
    if not ceiling or ceiling < 1 then return nil end
    return work, item, math.floor(ceiling)
end

function M.load(path)
    M.path = path
    M.data = {}

    local f = io.open(path, "r")
    if not f then return 0 end

    local count = 0
    for line in f:lines() do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local work, item, ceiling = parse_line(line)
            if work then
                M.data[work] = M.data[work] or {}
                M.data[work][item] = ceiling
                count = count + 1
            end
        end
    end
    f:close()

    log.debug("loaded " .. count .. " stock limit(s)")
    return count
end

-- Written on every edit rather than debounced. Priorities are clicked in
-- bursts and batch nicely; a ceiling is one typed command at a time, and
-- the debounce only buys a lost write if the game closes first.
function M.save()
    if not M.path then return false end

    local f, err = io.open(M.path, "wb")
    if not f then
        log.warn("could not write " .. M.path .. ": " .. tostring(err))
        return false
    end

    f:write("# Pal Work Priority - stock limits set with !pwp limit.\n")
    f:write("# WorkType|ItemId|Ceiling\n")

    -- Sorted so the file does not reshuffle on every write.
    local works = {}
    for work in pairs(M.data) do works[#works + 1] = work end
    table.sort(works)

    for _, work in ipairs(works) do
        local items = {}
        for item in pairs(M.data[work]) do items[#items + 1] = item end
        table.sort(items)

        for _, item in ipairs(items) do
            f:write(string.format("%s|%s|%d\n", work, item, M.data[work][item]))
        end
    end

    f:close()
    return true
end

function M.set(work_name, item, ceiling)
    M.data[work_name] = M.data[work_name] or {}
    M.data[work_name][item] = ceiling
    M.save()
end

function M.clear(work_name, item)
    local by_work = M.data[work_name]
    if by_work == nil or by_work[item] == nil then return false end

    by_work[item] = nil
    if next(by_work) == nil then M.data[work_name] = nil end
    M.save()
    return true
end

-- ---------------------------------------------------------------------------
-- The merged view the scheduler reads
-- ---------------------------------------------------------------------------

-- Ceilings for one work type, config first and in-game edits over the top.
-- Returns nil when nothing caps this work type at all, so the caller can
-- skip the check entirely rather than walking an empty table.
function M.for_work(cfg, work_name)
    local from_cfg = (cfg.work_caps or {})[work_name]
    local from_edit = M.data[work_name]

    if from_edit == nil then
        return type(from_cfg) == "table" and from_cfg or nil
    end
    if type(from_cfg) ~= "table" then
        return from_edit
    end

    local merged = {}
    for item, ceiling in pairs(from_cfg) do merged[item] = ceiling end
    for item, ceiling in pairs(from_edit) do merged[item] = ceiling end
    return merged
end

-- Whether anything caps anything at all.
--
-- The scheduler only pays to read chest contents when this is true, so a
-- limit set in game has to be visible here. Reading only cfg.work_caps would
-- leave totals empty and the new ceiling would never fire, which looks
-- exactly like the ceiling being broken.
function M.any(cfg)
    if next(M.data) ~= nil then return true end
    local from_cfg = cfg.work_caps
    return type(from_cfg) == "table" and next(from_cfg) ~= nil
end

-- Every ceiling in force, work name -> item -> ceiling, for listing.
function M.all(cfg)
    local out = {}

    for work, items in pairs((cfg or {}).work_caps or {}) do
        if type(items) == "table" then
            out[work] = {}
            for item, ceiling in pairs(items) do out[work][item] = ceiling end
        end
    end

    for work, items in pairs(M.data) do
        out[work] = out[work] or {}
        for item, ceiling in pairs(items) do out[work][item] = ceiling end
    end

    return out
end

return M
