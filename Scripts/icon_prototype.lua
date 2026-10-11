-- Opt-in experiment. Only names/tokens survive a panel callback; widget
-- ownership and fresh resolution remain with panel_runtime's current snapshot.
local api = require("palapi")
local logic = require("panel_runtime")
local M = { enabled = false }
local PACKAGE = "/Game/Mods/PalWorkPriorityPrototype/WBP_LazyItemIcon"
local function added_name(value)
    return FName(value, EFindName.FNAME_Add)
end

local function prototype_class()
    -- Same mounted-pak route as overlay.mod_class. Already inside the panel's
    -- game-thread callback; do not queue a callback retaining the parent widget.
    local registry = api.cdo("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not api.valid(registry) then return nil end
    return registry:GetAsset({PackageName=added_name(PACKAGE),
        AssetName=added_name("WBP_LazyItemIcon_C")})
end

function M.new(runtime)
    local state = { widgets = runtime:cache(), tokens = {}, parent = {}, placed = {}, used = {} }
    function state:draw(key, into, anchors, x, y, size, item)
        self.stage = "current snapshot"
        self.used[key] = true
        local w = self.widgets[key]
        if not w then
            self.stage = "local controller"
            local pc = api.local_player_controller()
            if not api.valid(pc) then return false end
            self.stage = "load prototype class"
            local cls = prototype_class()
            if not api.valid(cls) then return false end
            self.stage = "widget library"
            local lib = api.cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
            if not api.valid(lib) then return false end
            self.stage = "create prototype widget"
            w = lib:Create(pc, cls, pc)
            if not api.valid(w) then return false end
            self.widgets[key] = w
            self.tokens[key], self.parent[key], self.placed[key] = nil, nil, nil
        end
        self.stage = "attach prototype widget"
        local slot, changed = logic.place(self.parent, key, w, into, anchors, false, 8998)
        if not slot then return false end
        if changed then self.placed[key] = nil end
        local position = x .. ":" .. y .. ":" .. size
        if not logic.write(self.placed, key, position, function()
            if slot:SetPosition({X=x,Y=y}) == false then return false end
            return slot:SetSize({X=size,Y=size})
        end) then return false end
        self.stage = "set item"
        if not logic.write(self.tokens, key, item, function()
            -- Native Blueprint accepts the identifier and owns the soft ref.
            if w:SetItem(FName(item)) == false then return false end
            return w:SetVisibility(4) -- visible, self hit-test invisible
        end) then return false end
        return true
    end
    function state:finish()
        for key,w in pairs(self.widgets) do
            if not self.used[key] and self.tokens[key] ~= nil then
                local ok = pcall(function()
                    -- None clears/cancels before the Blueprint's data guard.
                    w:SetItem(FName("None"))
                    w:SetVisibility(1)
                end)
                if ok then self.tokens[key] = nil end
            end
        end
        self.used = {}
    end
    return state
end
return M
