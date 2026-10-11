-- User configuration lives beside the saves, outside replaceable Scripts.
local file = require('datafile')
local workdefs = require('workdefs')
local M = {}
function M.validate(c)
    if type(c) ~= 'table' then return nil, 'configuration must return a table' end
    local function integer(n, low, high)
        local value = math.tointeger(tonumber(n))
        return value and value >= low and value <= high
    end
    for _, key in ipairs({'enabled','dry_run','run_on_world_load'}) do
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

local function parse(text, name)
    local chunk, err = load(text, '@' .. name, 't', {})
    if not chunk then return nil, err end
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= 'table' then return nil, 'configuration must return a table' end
    return M.validate(value)
end

function M.load(root, scripts)
    local target = root .. 'config.lua'
    local text, err, code = file.read_raw(target)
    if text then
        local cfg, why = parse(text,target)
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
    local cfg, why = parse(original, source)
    if not cfg then return nil, why end
    local fresh = true
    for _, name in ipairs({'priority.log','priorities.txt','caps.txt','config.migration.bak','remote.txt'}) do
        local previous, _, missing = file.read_raw(root .. name)
        if previous ~= nil or missing ~= 2 then fresh = false end
    end
    -- Preserve the exact original before creating the editable copy.
    local backup = root .. 'config.migration.bak'
    local existing, _, missing = file.read_raw(backup)
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
