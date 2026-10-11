-- Fresh viewport root resolution plus an explicit diagnostic probe.
-- Native signature: UWidgetBlueprintLibrary::GetAllWidgetsOfClass(context,
-- TArray<UUserWidget*>& out, TSubclassOf<UUserWidget> class, bool top_only).
-- Returned widgets belong to the caller's current callback only.
local api = require('palapi')
local M = {}
local stand_class_path, stand_class_full
local STAND = 'WBP_WorkSuitabilityPreferenceMenu_C'

-- Remember only the generated class's asset path, discovered from a current
-- menu. LoadAsset below must reacquire and prove the class on every call.
function M.remember_stand(menu)
    local ok, full = pcall(function()
        if not api.valid(menu) or not menu:GetFullName():match('^'..STAND..' ') then return end
        return menu:GetClass():GetFullName()
    end)
    local path = ok and type(full)=='string' and full:match('^%S+ (/Game/.+)$')
    if path and path:match('%.'..STAND..'$') then
        stand_class_path, stand_class_full = path, full
        return true
    end
    return false
end

-- Native typed query verified on this runtime by the explicit probe. Missing
-- or unreadable results remain unknown; ui retains its fresh global fallback.
function M.stands()
    if not stand_class_path then return nil end
    local ok, result = pcall(function()
        if api.has_viewport()~=true then return nil end
        local pc=api.local_player_controller()
        local lib=api.cdo('/Script/UMG.Default__WidgetBlueprintLibrary')
        if not api.valid(pc) or not api.valid(lib) then return nil end
        local kind=LoadAsset(stand_class_path)
        if not api.valid(kind) or kind:GetFullName()~=stand_class_full then return nil end
        local out={}
        lib:GetAllWidgetsOfClass(pc,out,kind,false)
        if out.FoundWidgets~=nil then out=out.FoundWidgets end
        local found={}
        local function visit(_,w)
            w=api.unwrap(w)
            if not api.valid(w) or #found>=32 then error('incomplete typed query') end
            local name=w:GetFullName()
            if type(name)~='string' or not name:match('^'..STAND..' ') then error('incorrect typed widget') end
            found[#found+1]=w
        end
        if type(out)=='table' then for k,w in pairs(out) do visit(k,w) end
        elseif type(out)=='userdata' then out:ForEach(visit)
        else error('unsupported typed output') end
        return found
    end)
    if ok then return result end
end

-- Native viewport enumeration, reacquired for every caller. Only /Script/
-- classes/CDOs use palapi's cache; no generated class or widget is retained.
function M.top_level()
    local ok, result = pcall(function()
        if api.has_viewport() ~= true then return nil end
        local pc = api.local_player_controller()
        local lib = api.cdo('/Script/UMG.Default__WidgetBlueprintLibrary')
        local cls = api.cdo('/Script/UMG.UserWidget')
        if not api.valid(pc) or not api.valid(lib) or not api.valid(cls) then return nil end
        local out = {}
        lib:GetAllWidgetsOfClass(pc, out, cls, true)
        if out.FoundWidgets ~= nil then out = out.FoundWidgets end
        local found = {}
        local function visit(_, w)
            w = api.unwrap(w)
            if not api.valid(w) or #found >= 128 then error('incomplete viewport query') end
            found[#found+1] = w
        end
        if type(out)=='table' then
            for _, w in pairs(out) do visit(nil,w) end
        elseif type(out)=='userdata' then out:ForEach(visit)
        else error('unsupported viewport output') end
        return found
    end)
    if ok then return result end
end

function M.owned(path)
    if type(path)~='string' or path=='' then return nil end
    local found
    local ok = pcall(function()
        for _, w in ipairs(M.top_level() or {}) do
            local full = w:GetFullName()
            local current = type(full)=='string' and full:match('^%S+ (.+)$')
            if not current then error('unreadable viewport identity') end
            if current==path then
                if found then error('ambiguous owned root') end
                found = w
            end
        end
    end)
    if ok then return found end
end

function M.probe()
    if api.has_viewport() ~= true then return 'widget lookup: no local viewport' end
    local pc = api.local_player_controller()
    if not api.valid(pc) then return 'widget lookup: no local controller' end
    local lib = api.cdo('/Script/UMG.Default__WidgetBlueprintLibrary')
    local cls = api.cdo('/Script/UMG.UserWidget')
    if not api.valid(lib) or not api.valid(cls) then return 'widget lookup: native UMG types unavailable' end
    local lines = {'widget lookup: explicit probe; all timings inclusive; does not change routing'}
    local function bench(label, fn)
        local started = os.clock()
        local ok, detail = pcall(fn)
        lines[#lines+1] = string.format('  %s: %.3fms %s', label,
            (os.clock()-started)*1000, ok and tostring(detail) or ('FAILED '..tostring(detail)))
    end
    for _, top in ipairs({true, false}) do
        bench(top and 'native top-level widgets' or 'native all user widgets', function()
            local out = {}
            lib:GetAllWidgetsOfClass(pc, out, cls, top)
            if out.FoundWidgets ~= nil then out = out.FoundWidgets end
            local n, stand, owned = 0, 0, 0
            local names = {}
            local function visit(key, w)
                w = api.unwrap(w)
                if not api.valid(w) then error('unrecognized output element '..tostring(key)..'/'..type(w)) end
                n = n+1
                if n > 8192 then error('output exceeds probe budget') end
                local full = w:GetFullName()
                if type(full) ~= 'string' then error('unreadable result') end
                if full:match('^WBP_WorkSuitabilityPreferenceMenu_C ') then stand=stand+1 end
                if full:match('^WBP_WorkRules_C ') then owned=owned+1 end
                if top and #names<16 then names[#names+1]=full end
            end
            if type(out)=='table' then
                for key, w in pairs(out) do visit(key,w) end
            elseif type(out)=='userdata' then
                out:ForEach(visit)
            else error('unrecognized output container '..type(out)) end
            return string.format('%d results, %d stand, %d panel%s', n, stand, owned,
                #names>0 and ('\n    '..table.concat(names,'\n    ')) or '')
        end)
    end
    bench('existing stand class sweep', function()
        return #(FindAllOf('WBP_WorkSuitabilityPreferenceMenu_C') or {})..' results'
    end)
    bench('stand from current viewport tree', function()
        local target
        for _, w in ipairs(FindAllOf('WBP_WorkSuitabilityPreferenceMenu_C') or {}) do
            if api.valid(w) then
                local full=w:GetFullName()
                if not full:find('Default__',1,true) and w:IsVisible() then target=full; break end
            end
        end
        if not target then return 'stand closed' end
        for _, root in ipairs(M.top_level() or {}) do
            local found, complete, hint = require('ui_tree').find(root,target,api.valid)
            if found then
                return 'found, '..tostring(hint and #hint.steps)..' current-tree edges'
            end
        end
        return 'no bounded current-tree route found'
    end)
    -- The class path comes from a fresh native instance, not a guessed asset.
    -- Time warm LoadAsset + typed widget enumeration separately from discovery.
    local class_path, class_full
    pcall(function()
        for _, w in ipairs(FindAllOf('WBP_WorkSuitabilityPreferenceMenu_C') or {}) do
            if api.valid(w) then
                local full=w:GetFullName()
                if not full:find('Default__',1,true) then
                    class_full=w:GetClass():GetFullName()
                    class_path=class_full:match('^%S+ (/Game/.+)$')
                    break
                end
            end
        end
    end)
    if class_path then
        for i=1,3 do
            bench('typed stand query '..i, function()
                local kind=LoadAsset(class_path)
                if not api.valid(kind) or kind:GetFullName()~=class_full then error('class not reacquired') end
                local out={}
                lib:GetAllWidgetsOfClass(pc,out,kind,false)
                if out.FoundWidgets~=nil then out=out.FoundWidgets end
                local n=0
                local function visit(_, w)
                    w=api.unwrap(w)
                    if not api.valid(w) then error('invalid typed widget') end
                    local full=w:GetFullName()
                    if not full:match('^WBP_WorkSuitabilityPreferenceMenu_C ') then error('wrong typed widget') end
                    n=n+1
                end
                if type(out)=='table' then for k,w in pairs(out) do visit(k,w) end
                elseif type(out)=='userdata' then out:ForEach(visit)
                else error('unsupported typed output') end
                return n..' stand result(s), class '..class_path
            end)
        end
    end
    return table.concat(lines, '\n')
end

return M
