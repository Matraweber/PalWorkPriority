-- User configuration lives beside the saves, outside replaceable Scripts.
local file = require('datafile')
local workdefs = require('workdefs')
local log = require('log')
local M = {}
-- True once the shipped defaults replaced a config.lua an earlier install had:
-- the Workshop and Vortex loaders delete every file they installed before an
-- update (LESSONS, 2026-10-20). A marker file in the mod folder keeps it true
-- on later launches until the panel has shown it and calls ack_upgrade_reset
-- (review round 2: a notice held only in memory was gone after one session).
M.upgrade_reset = false
M.UPGRADE_MESSAGE = "Your earlier config.lua was not found (the Workshop or Vortex update removed it). "
    .. "Default settings are in use; options page settings are kept."
-- The root config.lua is ours, outside the shipped Scripts, so no loader
-- removes it. Gone while config.migration.bak exists means it was deleted.
M.MISSING_MESSAGE = "config.lua was missing, defaults are in use. Options page settings are kept."
-- What the panel shows while upgrade_reset is true.
M.upgrade_message = nil
M.MARKER = 'config.reset.txt'
local marker_path = nil
local BOM = '\239\187\191'
local MAX_INTEGER = 2147483647
function M.validate(c)
    if type(c) ~= 'table' then return nil, 'configuration must return a table' end
    local function integer(n, low, high)
        local value = math.tointeger(tonumber(n))
        return value and value >= low and value <= high
    end
    for _, key in ipairs({'enabled','dry_run','run_on_world_load','leave_unordered_pals_to_game','item_limits_on_rocks'}) do
        if c[key] ~= nil and type(c[key]) ~= 'boolean' then return nil, key .. ' must be true or false' end
    end
    for _, key in ipairs({'work_priority','pal_overrides','work_caps','uncounted_containers','counted_containers'}) do
        if c[key] ~= nil and type(c[key]) ~= 'table' then return nil, key .. ' must be a table' end
    end
    for work, value in pairs(c.work_priority or {}) do
        if not workdefs.is_known(work) or (value ~= false and not integer(value,1,5)) then
            return nil, 'invalid work priority: ' .. tostring(work)
        end
    end
    for who, priorities in pairs(c.pal_overrides or {}) do
        if type(who) ~= 'string' or type(priorities) ~= 'table' then return nil, 'invalid Pal overrides' end
        for work, value in pairs(priorities) do
            if not workdefs.is_known(work) or (value ~= false and not integer(value,1,5)) then
                return nil, 'invalid Pal priority: ' .. who .. '/' .. tostring(work)
            end
        end
    end
    for work, items in pairs(c.work_caps or {}) do
        if not workdefs.is_known(work) or type(items) ~= 'table' then return nil, 'invalid legacy work limits' end
        for item, amount in pairs(items) do
            if type(item) ~= 'string' or item == '' or #item > 64 or item:find('[^%w_%.%-]')
                or not integer(amount,1,9999999) then return nil, 'invalid legacy item limit' end
        end
    end
    for _, key in ipairs({'uncounted_containers','counted_containers'}) do
        local count, highest = 0, 0
        for index, name in pairs(c[key] or {}) do
            if type(index) ~= 'number' or not integer(index,1,1000) or type(name) ~= 'string'
                or name == '' then return nil, key .. ' must be a list of class names' end
            count, highest = count + 1, math.max(highest,index)
        end
        if count ~= highest then return nil, key .. ' must not contain gaps' end
    end
    for key, values in pairs({assignment_mode={spread=true,fill=true},storage_scope={camp=true,global=true},
        log_level={debug=true,info=true,warn=true,error=true}}) do
        if c[key] ~= nil and not values[c[key]] then return nil, 'invalid ' .. key end
    end
    for key, minimum in pairs({interval_seconds=5,min_suitability_rank=1,max_pals_per_work_type=1}) do
        if c[key] ~= nil and not (key=='max_pals_per_work_type' and c[key]==false)
            and not integer(c[key],minimum,2147483647) then return nil, 'invalid ' .. key end
    end
    if c.chat_prefix ~= nil and (type(c.chat_prefix) ~= 'string' or c.chat_prefix == ''
        or #c.chat_prefix > 32 or c.chat_prefix:find('[%c]')) then return nil, 'invalid chat_prefix' end
    return c
end

-- 0.4.1's own leniency, for the files 0.4.1 accepted (review round 2, P1).
-- 0.4.1 warned and clamped or dropped a bad value where validate refuses the
-- whole file, so an upgrade that kept such a file stopped the mod. Only used
-- for the legacy Scripts/config.lua and for a root copy still byte-identical
-- to config.migration.bak; a file the user edits under 0.5 is checked strictly.
local function whole(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return math.tointeger(n)
end

local function priorities(entries, where)
    for work, value in pairs(entries) do
        if not workdefs.is_known(work) then
            log.warn(where .. " has unknown work type '" .. tostring(work)
                .. "' (use the names in workdefs.lua, not the in-game labels). Ignoring it.")
            entries[work] = nil
        elseif value ~= false then
            local n = whole(value)
            if n == nil or n < 1 or n > 5 then
                log.warn(where .. "['" .. work .. "'] should be a whole number from 1 to 5, or false. Ignoring "
                    .. tostring(value) .. ".")
                entries[work] = nil
            else
                entries[work] = n
            end
        end
    end
end

function M.lenient(c)
    if type(c) ~= 'table' then return c end
    for _, key in ipairs({'work_priority','pal_overrides','work_caps'}) do
        if c[key] ~= nil and type(c[key]) ~= 'table' then
            log.warn('config.' .. key .. ' is not a table. Ignoring it.')
            c[key] = nil
        end
    end
    priorities(c.work_priority or {}, 'config.work_priority')
    for who, entry in pairs(c.pal_overrides or {}) do
        if type(who) ~= 'string' or type(entry) ~= 'table' then
            log.warn("config.pal_overrides['" .. tostring(who) .. "'] should be a table of work = priority. Ignoring it.")
            c.pal_overrides[who] = nil
        else
            priorities(entry, "config.pal_overrides['" .. who .. "']")
        end
    end
    for work, items in pairs(c.work_caps or {}) do
        if not workdefs.is_known(work) or type(items) ~= 'table' then
            log.warn("config.work_caps has an unknown work type or no item table: '" .. tostring(work) .. "'. Ignoring it.")
            c.work_caps[work] = nil
        else
            for item, amount in pairs(items) do
                local n = whole(amount)
                if n == nil or n < 1 or n > 9999999 or type(item) ~= 'string' or item == ''
                    or #item > 64 or item:find('[^%w_%.%-]') then
                    log.warn("config.work_caps['" .. work .. "']['" .. tostring(item)
                        .. "'] should be a whole number from 1 to 9999999. Ignoring " .. tostring(amount) .. ".")
                    items[item] = nil
                else
                    items[item] = n
                end
            end
        end
    end
    -- false and nil both mean no limit; 0 or less meant no limit in 0.4.1 too.
    local cap = c.max_pals_per_work_type
    if cap ~= nil and cap ~= false then
        local n = tonumber(cap)
        if n == nil or n ~= n or n < 1 or n > MAX_INTEGER then
            log.warn('config.max_pals_per_work_type should be a number of 1 or more, or false. '
                .. 'Using no limit instead of ' .. tostring(cap) .. '.')
            c.max_pals_per_work_type = false
        else
            c.max_pals_per_work_type = math.tointeger(math.floor(n))
        end
    end
    for key, minimum in pairs({interval_seconds=5, min_suitability_rank=1}) do
        local value = c[key]
        if value ~= nil then
            local n = tonumber(value)
            if n == nil or n ~= n then
                log.warn('config.' .. key .. ' should be a number. Using the default instead of ' .. tostring(value) .. '.')
                c[key] = nil
            else
                local fixed = math.tointeger(math.floor(math.max(minimum, math.min(n, MAX_INTEGER))))
                if fixed ~= value then
                    log.warn('config.' .. key .. ' should be a whole number of ' .. minimum .. ' or more. Using '
                        .. fixed .. ' instead of ' .. tostring(value) .. '.')
                end
                c[key] = fixed
            end
        end
    end
    -- Anything else validate refuses on its own falls back to its default.
    for key, value in pairs(c) do
        if not M.validate({[key] = value}) then
            log.warn('config.' .. tostring(key) .. ' = ' .. tostring(value) .. ' is not valid. Using the default.')
            c[key] = nil
        end
    end
    return c
end

-- loadfile, which 0.4.1 used, skips a leading UTF-8 byte order mark; load
-- does not, and an editor that adds one stopped the mod (review round 2).
local function parse(text, name, lenient)
    if text:sub(1, 3) == BOM then text = text:sub(4) end
    local chunk, err = load(text, '@' .. name, 't', {})
    if not chunk then return nil, err end
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= 'table' then return nil, 'configuration must return a table' end
    if lenient then M.lenient(value) end
    return M.validate(value)
end

-- Called by the panel once it has shown the reset notice.
function M.ack_upgrade_reset()
    M.upgrade_reset, M.upgrade_message = false, nil
    if marker_path == nil then return true end
    local removed, err, code = file.fs.remove(marker_path)
    if removed or code == 2 then return true end
    log.warn('could not remove ' .. marker_path .. ': ' .. tostring(err))
    return false
end

local function remember_reset(message)
    M.upgrade_reset, M.upgrade_message = true, message
    local saved, err = file.write_raw(marker_path, message .. '\n')
    if not saved then
        log.warn('could not write ' .. tostring(marker_path) .. ' (the notice is shown this session only): '
            .. tostring(err))
    end
end

function M.load(root, scripts)
    local target = root .. 'config.lua'
    local backup = root .. 'config.migration.bak'
    marker_path = root .. M.MARKER
    local pending = file.read_raw(marker_path)
    if pending then
        local said = pending:match('^([^\r\n]+)')
        M.upgrade_reset = true
        M.upgrade_message = (said == M.MISSING_MESSAGE) and said or M.UPGRADE_MESSAGE
    end
    local text, err, code = file.read_raw(target)
    if text then
        -- Still the migrated bytes: 0.4.1 accepted them, so 0.4.1's rules apply.
        local cfg, why = parse(text, target, file.read_raw(backup) == text)
        return cfg, why, false
    end
    if code ~= 2 then return nil, 'cannot read user config: ' .. tostring(err) end
    local original, read_err, legacy_code = file.read_raw(scripts .. 'config.lua')
    local source = scripts .. 'config.lua'
    if original == nil and legacy_code == 2 then
        source = scripts .. 'default_config.lua'
        original, read_err = file.read_raw(source)
    end
    if not original then return nil, read_err end
    local cfg, why = parse(original, source, source == scripts .. 'config.lua')
    if not cfg then return nil, why end
    local fresh = true
    for _, name in ipairs({'priority.log','priorities.txt','caps.txt','config.migration.bak','remote.txt'}) do
        local previous, _, missing = file.read_raw(root .. name)
        if previous ~= nil or missing ~= 2 then fresh = false end
    end
    local existing, _, missing = file.read_raw(backup)
    if source == scripts .. 'default_config.lua' and fresh == false then
        local message = existing ~= nil and M.MISSING_MESSAGE or M.UPGRADE_MESSAGE
        remember_reset(message)
        log.warn(message)
    end
    -- Preserve the exact original before creating the editable copy.
    if existing == nil and missing == 2 then
        local saved, save_err = file.write_raw(backup, original)
        if not saved then return nil, 'config backup failed: ' .. tostring(save_err) end
    elseif existing == nil then return nil, 'config backup unavailable' end
    local saved, save_err = file.write_raw(target .. '.tmp', original)
    if not saved then return nil, 'config migration failed: ' .. tostring(save_err) end
    if file.read_raw(target .. '.tmp') ~= original then return nil, 'config migration verification failed' end
    local moved, move_err = file.fs.rename(target .. '.tmp',target)
    if not moved then return nil, 'config migration replacement failed: ' .. tostring(move_err) end
    return cfg, nil, fresh
end

return M
