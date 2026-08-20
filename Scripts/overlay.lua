-- A widget we own, built from Lua, and the host every panel draws into.
--
-- Everything that went wrong with the old panel came from living in widgets
-- the game owns. Two crashes when the HUD rebuilt underneath it, a duplicate
-- when a menu was hidden rather than destroyed, arrow keys and clicks eaten
-- by an input mode we could not switch. Guarding harder never helped, because
-- the host was always someone else's.
--
-- So we make our own:
--
--   1. construct a UserWidget
--   2. construct a WidgetTree and hand it to that widget
--   3. construct a CanvasPanel and make it the tree's root
--   4. AddToViewport
--
-- Proven in game before anything was built on it. Nothing in Palworld holds a
-- reference to this widget, so nothing can free it under us, and a widget we
-- own is one the engine will give keyboard focus to. That second part is why
-- a search box is possible at all.

local log = require("log")
local api = require("palapi")

local M = {}

M.open = false

local widget = nil
local tree = nil
local canvas = nil

local warned = {}
local cursor_was = nil
local input_route = nil

local function warn_once(key, message)
    if warned[key] then return end
    warned[key] = true
    log.warn(message)
end

local function alive(o)
    if o == nil then return false end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

local function build()
    local pc = api.player_controller()

    local widget_cls = api.cdo("/Script/UMG.UserWidget")
    local tree_cls = api.cdo("/Script/UMG.WidgetTree")
    local canvas_cls = api.cdo("/Script/UMG.CanvasPanel")

    if not (widget_cls and tree_cls and canvas_cls) then
        warn_once("cls", "UMG classes did not resolve, so no overlay")
        return false
    end

    -- Outered to the player controller where there is one. A UserWidget with
    -- no owner still constructs, but the viewport is likelier to take it when
    -- it knows whose screen it belongs on.
    local made
    for _, outer in ipairs({ alive(pc) and pc or false, false }) do
        pcall(function()
            made = StaticConstructObject(widget_cls, outer or nil)
        end)
        if alive(made) then break end
    end
    if not alive(made) then
        warn_once("widget", "could not construct the overlay widget")
        return false
    end

    -- A UserWidget with no WidgetTree renders nothing and can fault when the
    -- layout pass reaches it, so this is the step the whole idea rests on.
    local made_tree
    pcall(function() made_tree = StaticConstructObject(tree_cls, made) end)
    if not alive(made_tree) then
        warn_once("tree", "could not construct the overlay widget tree")
        return false
    end
    pcall(function() made.WidgetTree = made_tree end)

    local made_canvas
    pcall(function() made_canvas = StaticConstructObject(canvas_cls, made_tree) end)
    if not alive(made_canvas) then
        warn_once("canvas", "could not construct the overlay canvas")
        return false
    end
    pcall(function() made_tree.RootWidget = made_canvas end)

    -- Focusable, or the engine will not hand it the keyboard however hard the
    -- input mode is set.
    pcall(function() made:SetIsFocusable(true) end)

    local shown = false
    pcall(function()
        made:AddToViewport(9000)
        shown = true
    end)

    if not shown and alive(pc) then
        -- Some builds want the owning player before the viewport accepts it.
        pcall(function() made:SetOwningPlayer(pc) end)
        pcall(function()
            made:AddToViewport(9000)
            shown = true
        end)
    end

    if not shown then
        warn_once("viewport", "the overlay would not go on the viewport")
        return false
    end

    widget, tree, canvas = made, made_tree, made_canvas
    return true
end

-- The canvas panels draw into, and the tree that must own anything they
-- construct. Builds on first use.
function M.host()
    if alive(widget) and alive(tree) and alive(canvas) then
        return canvas, tree, widget
    end

    -- Dropped without touching them. Whatever they pointed at is gone, and
    -- asking a freed widget whether it is valid is the crash rather than the
    -- check for it.
    widget, tree, canvas = nil, nil, nil

    if not build() then return nil end
    return canvas, tree, widget
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

-- Showing a cursor was never enough on its own. Slate routes mouse events to
-- widgets only in a UI input mode; in game mode the pointer is drawn and every
-- click still goes to the player controller. That is why the old panel looked
-- clickable and was not.
--
-- It failed before because the mode wants a widget to focus and we had none of
-- our own to give it. Now we do.
local function set_input(on)
    local pc = api.player_controller()
    if not alive(pc) then return end

    pcall(function()
        if on then
            if cursor_was == nil then cursor_was = pc.bShowMouseCursor end
            pc.bShowMouseCursor = true
        elseif cursor_was ~= nil then
            pc.bShowMouseCursor = cursor_was
            cursor_was = nil
        end
    end)

    local lib = api.cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not lib then
        warn_once("inputlib", "WidgetBlueprintLibrary missing, overlay input " ..
            "will not capture")
        return
    end

    if not on then
        pcall(function() lib:SetInputMode_GameOnly(pc) end)
        return
    end

    -- Game and UI rather than UI only: the camera stays usable, which is what
    -- the Creative Menu does and what makes an overlay feel like part of the
    -- game rather than a modal dialog over it. Argument counts differ between
    -- engine versions, so each shape is tried and the one that takes is kept.
    local shapes = {
        { "GameAndUI(pc, widget, 0, false)",
          function() lib:SetInputMode_GameAndUI(pc, widget, 0, false) end },
        { "GameAndUI(pc, widget, 0)",
          function() lib:SetInputMode_GameAndUI(pc, widget, 0) end },
        { "GameAndUI(pc, widget)",
          function() lib:SetInputMode_GameAndUI(pc, widget) end },
        { "GameAndUI(pc)",
          function() lib:SetInputMode_GameAndUI(pc) end },
    }

    for _, shape in ipairs(shapes) do
        if pcall(shape[2]) then
            if input_route ~= shape[1] then
                input_route = shape[1]
                log.debug("overlay input mode via " .. shape[1])
            end
            return
        end
    end

    warn_once("inputmode", "could not switch input mode, so the overlay may " ..
        "not take clicks")
end

-- ---------------------------------------------------------------------------
-- Showing
-- ---------------------------------------------------------------------------

function M.show()
    if M.host() == nil then return false end

    pcall(function() widget:SetVisibility(0) end)
    set_input(true)

    -- Focus after the mode switch, or the mode switch takes it back.
    pcall(function() widget:SetKeyboardFocus() end)

    M.open = true
    return true
end

function M.hide()
    if alive(widget) then
        -- Collapsed rather than removed. Removing would drop the whole tree
        -- and everything panels have built into it, and building it again on
        -- every open is how the old panel ended up with two of everything.
        pcall(function() widget:SetVisibility(1) end)
    end
    set_input(false)
    M.open = false
end

function M.toggle()
    if M.open then M.hide() else M.show() end
    return M.open
end

-- A world switch takes every wrapper with it. Dropped without touching them.
function M.reset()
    widget, tree, canvas = nil, nil, nil
    cursor_was, input_route = nil, nil
    M.open = false
    warned = {}
end

return M
