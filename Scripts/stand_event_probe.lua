-- Explicit diagnostic only: resolve named input functions on freshly supplied
-- widget classes. Never call input functions, enumerate parameter memory, hook
-- an unverified signature, or retain a widget/function wrapper.
local M = {}
local events, stop_at, installed, hook_error = {}, 0, false, nil

-- On-demand layout census of a fresh visible owned panel. This intentionally
-- reports native children, not the Lua cache, so orphan containers are visible.
function M.layout(valid)
    if type(FindAllOf) ~= 'function' then return '' end
    local lines = {'  native panel list children:'}
    local ok, why = pcall(function()
        for _, panel in ipairs(FindAllOf('WBP_WorkRules_C') or {}) do
            if valid(panel) and panel:IsVisible() then
                local root = panel.WidgetTree.RootWidget
                local queue, seen, at = {root}, {}, 1
                while at <= #queue and at <= 2048 do
                    local node = queue[at]; at = at+1
                    if valid(node) then
                        local full = node:GetFullName()
                        if not seen[full] then
                            seen[full] = true
                            local name = node:GetFName():ToString()
                            local counted, count = pcall(function() return node:GetChildrenCount() end)
                            if counted and type(count)=='number' and count>=0 and count<=128 then
                                if name=='ItemList' or name=='RuleList' then
                                    lines[#lines+1] = '    '..name..' children='..count
                                    for i=0, math.min(count,32)-1 do
                                        local child = node:GetChildAt(i)
                                        if valid(child) then
                                            local height, children, inner_children = '?', '?', '?'
                                            pcall(function() height = child.HeightOverride end)
                                            pcall(function() children = child:GetChildrenCount() end)
                                            pcall(function() inner_children = child:GetChildAt(0):GetChildrenCount() end)
                                            lines[#lines+1] = string.format('      %d %s visibility=%s height=%s children=%s inner_children=%s',
                                                i, child:GetFName():ToString(), tostring(child:GetVisibility()),
                                                tostring(height), tostring(children), tostring(inner_children))
                                        end
                                    end
                                else
                                    for i=0,count-1 do
                                        if #queue>=2048 then break end
                                        queue[#queue+1] = node:GetChildAt(i)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    if not ok then lines[#lines+1] = '    unavailable: '..tostring(why) end
    return table.concat(lines, '\n')..'\n'
end

-- Opt-in, one-minute event census. No edits, parameter reflection or event
-- return overrides. The fresh native context is reduced to a class name here.
function M.watch()
    if not installed then
        local ok, err = pcall(function()
            RegisterHook('/Script/UMG.UserWidget:OnMouseButtonDown', function(context)
                if os.clock() >= stop_at then return end
                local read, class = pcall(function()
                    return context:get():GetClass():GetFullName()
                end)
                if not read or type(class) ~= 'string' then class = 'unreadable context' end
                -- Aggregate by class, never instance/pal names; keep bounded.
                if #class > 512 then class = 'oversized class name' end
                if events[class] == nil then
                    local count = 0
                    for _ in pairs(events) do count = count + 1 end
                    if count >= 32 then class = 'other classes' end
                end
                events[class] = (events[class] or 0) + 1
            end)
        end)
        installed, hook_error = ok, not ok and tostring(err) or nil
    end
    if not installed then return 'stand input probe: hook unavailable: '..tostring(hook_error) end
    events, stop_at = {}, os.clock() + 60
    return 'stand input probe: native mouse-down census on for 60s; edits unchanged'
end

function M.report()
    local rows = {}
    for name, n in pairs(events) do rows[#rows+1] = string.format('  %d %s', n, name) end
    table.sort(rows)
    return 'stand input probe: '..(#rows == 0 and 'no native events observed' or table.concat(rows, '\n'))
end

function M.read(cell, valid, find)
    local lines = {'  native input probe (presence only; routing not established):'}
    local function inspect(label, widget)
        local ok, path = pcall(function()
            if not valid(widget) then return nil end
            return widget:GetClass():GetFullName():match('^%S+ (/[^ ]+)$')
        end)
        if not ok or not path then
            lines[#lines+1] = '    '..label..': class unavailable'
            return
        end
        lines[#lines+1] = '    '..label..': '..path
        for _, name in ipairs({'OnMouseButtonDown', 'OnMouseButtonUp',
            'OnPreviewMouseButtonDown', 'OnKeyDown', 'OnPreviewKeyDown'}) do
            local found, present = pcall(function()
                local fn = find(path..':'..name)
                return valid(fn) and fn:GetFullName() == 'Function '..path..':'..name
            end)
            lines[#lines+1] = '      '..name..': '..(not found and 'lookup failed'
                or (present and 'present' or 'absent on this class'))
        end
    end
    inspect('cell', cell)
    local ok, checkbox = pcall(function() return cell.PalCheckBox end)
    if ok then inspect('checkbox', checkbox) end
    return table.concat(lines, '\n')..'\n'..M.layout(valid)
end

return M
