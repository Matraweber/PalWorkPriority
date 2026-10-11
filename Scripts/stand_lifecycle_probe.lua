-- Explicit read-only class-name/presence probe. No function calls, hooks,
-- parameter/property enumeration, or wrappers retained between invocations.
local M = {}
function M.read()
    local rows={'stand lifecycle: explicit class/function presence probe'}
    local ok,why=pcall(function()
        for _,menu in ipairs(require('widget_lookup').stands() or {}) do
            if menu:IsVisible()==true then
                local class=menu:GetClass()
                for _=1,8 do
                    local full=class:GetFullName()
                    if type(full)~='string' then rows[#rows+1]='unknown class; stopped'; break end
                    rows[#rows+1]=full
                    if full:match('^WidgetBlueprintGeneratedClass ') then
                        local count=0
                        class:ForEachFunction(function(fn)
                            count=count+1
                            if count<=128 then rows[#rows+1]='  declared: '..tostring(fn:GetFName():ToString()) end
                        end)
                    end
                    local path=full:match('^Class (/.+)$') or full:match('^BlueprintGeneratedClass (/.+)$')
                        or full:match('^WidgetBlueprintGeneratedClass (/.+)$')
                    if not path then rows[#rows+1]='unexpected class; stopped'; break end
                    if path=='/Script/CoreUObject.Object' then break end
                    for _,name in ipairs({'GetId','GetID','Close','OnClose','OnPreClose','OnClosed',
                        'ActivateWidget','DeactivateWidget','BP_OnActivated','BP_OnDeactivated'}) do
                        local found=StaticFindObject(path..':'..name)
                        if found and found:IsValid() then
                            local named=found:GetFullName()
                            if type(named)=='string' and named:match('^Function ') then rows[#rows+1]='  '..named end
                        end
                    end
                    class=class:GetSuperStruct()
                    if not class then break end
                end
            end
        end
    end)
    if not ok then rows[#rows+1]='probe unavailable: '..tostring(why) end
    return table.concat(rows,'\n')
end
return M
