-- A widget we own, built entirely from Lua.
--
-- Every problem the rules panel has comes from living in widgets the game
-- owns. Two crashes when the HUD rebuilt underneath it, a duplicate when a
-- menu was hidden rather than destroyed, arrow keys and mouse clicks eaten by
-- an input mode we cannot switch. Guarding harder never helped, because the
-- host was always someone else's.
--
-- The blueprint route fixes that by giving us a widget of our own, at the cost
-- of an Unreal install and layout work in the editor. This asks whether the
-- same thing can be built at runtime instead:
--
--   1. construct a UserWidget
--   2. construct a WidgetTree and hand it to that widget
--   3. construct a CanvasPanel and make it the tree's root
--   4. AddToViewport
--
-- If that holds, we own the lifetime outright and no pak is needed. If it does
-- not, the editor spec in docs/widget-spec.md is the answer and this file goes
-- away. Either way the question gets settled by trying rather than by reading.
--
-- Nothing here is wired into the mod. It is a probe with a key on it.

local log = require("log")
local api = require("palapi")

local M = {}

M.widget = nil
M.tree = nil
M.canvas = nil
M.report = {}

local function note(line)
    M.report[#M.report + 1] = line
    log.say("overlay: " .. line)
end

local function alive(o)
    if o == nil then return false end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end

local function class_of(o)
    local n
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n or "?"
end

-- ---------------------------------------------------------------------------
-- Building it
-- ---------------------------------------------------------------------------

function M.build()
    M.report = {}
    note("attempting a self owned widget")

    -- Outer matters. A UserWidget is normally outered to the player, and the
    -- transient package is the fallback when there is nothing better. Both are
    -- tried because which one this build accepts is not knowable from here.
    local pc = api.player_controller()
    note("player controller: " .. tostring(alive(pc)))

    local widget_cls = api.cdo("/Script/UMG.UserWidget")
    local tree_cls   = api.cdo("/Script/UMG.WidgetTree")
    local canvas_cls = api.cdo("/Script/UMG.CanvasPanel")
    local text_cls   = api.cdo("/Script/UMG.TextBlock")
    local border_cls = api.cdo("/Script/UMG.Border")

    note("classes: UserWidget=" .. tostring(widget_cls ~= nil) ..
         " WidgetTree=" .. tostring(tree_cls ~= nil) ..
         " CanvasPanel=" .. tostring(canvas_cls ~= nil))

    if not (widget_cls and tree_cls and canvas_cls) then
        note("a required class did not resolve, stopping")
        return false
    end

    -- 1. the widget
    local outer = alive(pc) and pc or nil
    local widget
    for _, candidate in ipairs({ outer, nil }) do
        pcall(function()
            widget = StaticConstructObject(widget_cls, candidate)
        end)
        if alive(widget) then break end
    end

    if not alive(widget) then
        note("could not construct a UserWidget at all")
        return false
    end
    note("widget constructed: " .. class_of(widget))

    -- 2. its tree. A UserWidget with no WidgetTree renders nothing and may
    --    fault when the layout pass reaches it, so this is the step that
    --    decides whether the whole idea works.
    local tree
    pcall(function() tree = StaticConstructObject(tree_cls, widget) end)
    if not alive(tree) then
        note("could not construct a WidgetTree")
        return false
    end
    note("tree constructed: " .. class_of(tree))

    local assigned = false
    pcall(function()
        widget.WidgetTree = tree
        assigned = true
    end)
    note("tree assigned to widget: " .. tostring(assigned))

    -- 3. a root canvas, owned by the tree
    local canvas
    pcall(function() canvas = StaticConstructObject(canvas_cls, tree) end)
    if not alive(canvas) then
        note("could not construct a CanvasPanel")
        return false
    end

    local rooted = false
    pcall(function()
        tree.RootWidget = canvas
        rooted = true
    end)
    note("canvas set as root: " .. tostring(rooted))

    -- something visible, so success is obvious rather than inferred
    if border_cls then
        local border
        pcall(function() border = StaticConstructObject(border_cls, tree) end)
        if alive(border) then
            local slot
            pcall(function() slot = canvas:AddChildToCanvas(border) end)
            if alive(slot) then
                pcall(function() slot:SetAutoSize(false) end)
                pcall(function() slot:SetPosition({ X = 200, Y = 200 }) end)
                pcall(function() slot:SetSize({ X = 700, Y = 420 }) end)
                pcall(function() border:SetBrushColor(
                    { R = 0.05, G = 0.07, B = 0.11, A = 0.94 }) end)
            end
        end
    end

    if text_cls then
        local tb
        pcall(function() tb = StaticConstructObject(text_cls, tree) end)
        if alive(tb) then
            local slot
            pcall(function() slot = canvas:AddChildToCanvas(tb) end)
            if alive(slot) then
                pcall(function() slot:SetAutoSize(true) end)
                pcall(function() slot:SetPosition({ X = 230, Y = 230 }) end)
                pcall(function() slot:SetZOrder(10) end)
            end
            pcall(function()
                local kismet = api.cdo("/Script/Engine.Default__KismetTextLibrary")
                local ft
                if kismet then
                    ft = kismet:Conv_StringToText("PAL WORK PRIORITY, own widget")
                else
                    ft = FText("PAL WORK PRIORITY, own widget")
                end
                if ft then tb:SetText(ft) end
            end)
            pcall(function() tb:SetColorAndOpacity({
                SpecifiedColor = { R = 0.4, G = 0.9, B = 1.0, A = 1.0 },
                ColorUseRule = 0 }) end)
        end
    end

    -- 4. onto the screen
    local shown = false
    pcall(function()
        widget:AddToViewport(9000)
        shown = true
    end)
    note("AddToViewport: " .. tostring(shown))

    if not shown then
        -- Some builds want the owning player set before the viewport accepts
        -- the widget, which is worth one retry rather than a conclusion.
        pcall(function() widget:SetOwningPlayer(pc) end)
        pcall(function()
            widget:AddToViewport(9000)
            shown = true
        end)
        note("AddToViewport after SetOwningPlayer: " .. tostring(shown))
    end

    M.widget, M.tree, M.canvas = widget, tree, canvas

    if shown then
        note("SUCCESS, look for a dark panel with cyan text")
        note("if nothing is on screen the call worked but the layout did not")
    end
    return shown
end

function M.destroy()
    if alive(M.widget) then
        pcall(function() M.widget:RemoveFromParent() end)
        note("removed from viewport")
    end
    M.widget, M.tree, M.canvas = nil, nil, nil
end

function M.toggle()
    if alive(M.widget) then
        M.destroy()
    else
        M.build()
    end
end

function M.reset()
    -- A world switch takes every wrapper with it. Dropped without touching
    -- them, because asking a freed widget anything is the crash itself.
    M.widget, M.tree, M.canvas = nil, nil, nil
end

return M
