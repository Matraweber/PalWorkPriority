-- Temporary read-only probe (2026-10-27, per-item limits research): for
-- Mining, Lumbering and converter works list the product, the owner model,
-- AssignableFixedType and state. Optional write mode via product_cmd.txt:
--   set <AssignDefineDataId substring> <0-3>   sets AssignableFixedType
-- (0 Both, 1 FreeOnly, 2 FixedOnly, 3 Cannot) on every matching work and
-- prints old -> new.
local M = {}
local SCR = 'C:/Users/matra/AppData/Local/Temp/claude/C--Users-matra-Desktop-Uni-olat-scorm-2026--claude-worktrees-palworld-mod-status-1a1ada/4a537cfd-5e32-46d0-a3a0-ef2f7fabb19f/scratchpad/'

local function str(v)
    if v == nil then return 'nil' end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and s then return s end
    return tostring(v)
end

function M.read()
    local api = require('palapi')
    local workdefs = require('workdefs')
    local rows = {'product probe'}
    local cmd
    local f = io.open(SCR .. 'product_cmd.txt', 'r')
    if f then cmd = f:read('*l'); f:close() end
    local set_sub, set_val
    local st_sub, st_val
    if cmd then set_sub, set_val = cmd:match('^set (%S+) (%d)$') end
    if cmd then st_sub, st_val = cmd:match('^state (%S+) (%d)$') end
    local seen = {}
    local ok, why = pcall(function()
        for ci, camp in ipairs(api.base_camps()) do
            for _, w in ipairs(api.camp_works(camp)) do
                local v = api.work_suitability(w)
                local name = v and workdefs.name(v) or 'nil'
                local cls = (api.work_full_name(w) or '?'):gsub('%s.*$', '')
                local model = api.unwrap(api.prop(w, 'CachedOwnerMapObjectConcreteModel'))
                local mcls, mapid, product, recipe = '-', '-', '-', '-'
                if model ~= nil and api.valid(model) then
                    pcall(function() mcls = model:GetFullName():gsub('%s.*$', '') end)
                    pcall(function() mapid = str(model:TryGetMapObjectId()) end)
                    pcall(function() product = str(model:GetProductItemId()) .. ' bIsWorkable=' .. tostring(model.bIsWorkable) end)
                    pcall(function() recipe = str(model:GetCurrentRecipeId()) end)
                    pcall(function()
                        local list = model.DropItemInfos
                        if list == nil then return end
                        local parts = {}
                        list:ForEach(function(_, entry)
                            local e = entry:get()
                            local id = '?'
                            pcall(function() id = e.ItemId.StaticId:ToString() end)
                            local n = '?'
                            pcall(function() n = tostring(e.Num) end)
                            parts[#parts + 1] = id .. ':' .. n
                        end)
                        product = 'drops ' .. table.concat(parts, ',')
                    end)
                end
                local interesting = name == 'Mining' or name == 'Deforest'
                    or mcls:find('Convert') or mcls:find('ProductItem')
                if interesting then
                    local aid = str(api.prop(w, 'AssignDefineDataId'))
                    local fixed = api.as_int(api.prop(w, 'AssignableFixedType'))
                    local st = api.as_int(api.prop(w, 'CurrentState'))
                    if set_sub and aid:find(set_sub, 1, true) then
                        local okw, err = pcall(function() w.AssignableFixedType = tonumber(set_val) end)
                        local now = api.as_int(api.prop(w, 'AssignableFixedType'))
                        rows[#rows + 1] = string.format('  SET %s %s -> %s (%s)', aid, tostring(fixed),
                            tostring(now), okw and 'ok' or tostring(err))
                        fixed = now
                    end
                    local wid = '?'
                    pcall(function() wid = api.guid_key(api.prop(w, 'ID')) end)
                    if st_sub and aid:find(st_sub, 1, true) then
                        local okw, err = pcall(function() w.CurrentState = tonumber(st_val) end)
                        local now = api.as_int(api.prop(w, 'CurrentState'))
                        rows[#rows + 1] = string.format('  STATE %s %s -> %s (%s)', aid, tostring(st),
                            tostring(now), okw and 'ok' or tostring(err))
                        st = now
                    end
                    local key = string.format('camp %d | %s | %s | %s | %s | map=%s | product=%s | recipe=%s | fixed=%s | state=%s',
                        ci, name, aid, cls, mcls, mapid, product, recipe, tostring(fixed), tostring(st))
                    if name == 'Mining' then key = key .. ' | id=' .. tostring(wid) end
                    seen[key] = (seen[key] or 0) + 1
                end
            end
        end
    end)
    local keys = {}
    for k in pairs(seen) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do rows[#rows + 1] = string.format('  x%d %s', seen[k], k) end
    if not ok then rows[#rows + 1] = 'error: ' .. tostring(why) end
    return table.concat(rows, '\n')
end
return M
