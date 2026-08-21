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

-- The widget blueprint out of our own pak, when it is there.
--
-- Everything below still works without it. The hand built canvas is what has
-- been drawing the panel all along and remains the fallback, because a pak
-- that failed to mount should degrade to the panel we had rather than to no
-- panel at all.
local BP_PACKAGE = "/Game/Mods/PalWorkPriority/UI/WBP_WorkRules"
local BP_ASSET = "WBP_WorkRules_C"

local bp_class = nil
local bp_state = "unasked"       -- unasked | asking | ready | absent

-- Named widgets from the blueprint, once one is hosted. nil when the panel is
-- drawing on its own canvas, which is how the panel tells the two apart.
M.parts = nil

local BP_NAMES = {
    "Root", "Backdrop", "Body", "Title", "Search",
    "RuleList", "ItemList", "Actions", "NewRuleButton", "CloseButton",
}

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

-- Ask for the blueprint class once, early, so that by the time the panel is
-- opened the answer is already in hand. The lookup is asynchronous because it
-- has to happen on the game thread, and a panel that opened while waiting for
-- it would open on the wrong host.
function M.prepare()
    if bp_state ~= "unasked" then return end
    bp_state = "asking"

    M.mod_class(BP_PACKAGE, BP_ASSET, function(class)
        if class == nil then
            bp_state = "absent"
            log.say("overlay: no blueprint widget in the pak, " ..
                "drawing on our own canvas")
            return
        end

        bp_class = class
        bp_state = "ready"
        log.say("overlay: the blueprint widget is available")
    end)
end

-- Construct the blueprint widget and take its parts.
--
-- Create rather than StaticConstructObject, because a UserWidget wants
-- initialising with a player and an owning world, and one built raw is a
-- widget that exists without being alive. StaticConstructObject stays as the
-- fallback since it is what the hand built host uses successfully.
local function build_blueprint()
    if bp_class == nil then return false end

    local pc = api.player_controller()
    if not alive(pc) then return false end

    local made
    local lib = api.cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
    if lib then
        pcall(function() made = lib:Create(pc, bp_class, pc) end)
    end
    if not alive(made) then
        pcall(function() made = StaticConstructObject(bp_class, pc) end)
    end
    if not alive(made) then
        warn_once("bpmake", "the blueprint widget would not construct")
        return false
    end

    local made_tree
    pcall(function() made_tree = made.WidgetTree end)
    if not alive(made_tree) then
        warn_once("bptree", "the blueprint widget has no widget tree")
        return false
    end

    -- Every name the commandlet gave a widget, collected once. A name that
    -- comes back nil here is one the cook dropped, and saying so now beats
    -- finding out when a row fails to appear.
    local parts, found = {}, 0
    for _, name in ipairs(BP_NAMES) do
        local w
        pcall(function() w = made:GetWidgetFromName(FName(name)) end)
        if alive(w) then
            parts[name] = w
            found = found + 1
        end
    end

    if parts.Root == nil then
        warn_once("bproot", "the blueprint widget has no Root canvas")
        return false
    end

    pcall(function() made:SetIsFocusable(true) end)
    pcall(function() made:AddToViewport(9000) end)

    widget, tree, canvas = made, made_tree, parts.Root
    M.parts = parts

    log.say(string.format("overlay: hosted on the blueprint, %d of %d " ..
        "named widgets found", found, #BP_NAMES))

    for _, name in ipairs(BP_NAMES) do
        if parts[name] == nil then
            log.warn("  missing from the blueprint: " .. name)
        end
    end

    return true
end

local function build_own()
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
    M.parts = nil

    -- The blueprint if it is there, our own canvas if it is not.
    if bp_state == "ready" and build_blueprint() then
        return canvas, tree, widget
    end

    if not build_own() then return nil end
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
        -- Two parameters, not one. The second is bFlushInput.
        pcall(function() lib:SetInputMode_GameOnly(pc, false) end)
        return
    end

    -- Five parameters:
    --
    --   SetInputMode_GameAndUIEx(PlayerController, InWidgetToFocus,
    --                            InMouseLockMode, bHideCursorDuringCapture,
    --                            bFlushInput)
    --
    -- Every previous attempt tried four, three, two and one, so all of them
    -- failed and it read as the function being wrong. It was the arity, and
    -- the arity came from asking the UFunction what it declares rather than
    -- from trying shapes until one stuck, which is what the last two rounds
    -- amounted to.
    --
    -- UI only, not Game and UI.
    --
    -- Game and UI was a deliberate choice to keep the camera usable, and it
    -- worked exactly as designed: the panel took clicks and the character
    -- still ran around behind it. That is not a menu. Creative Menu takes the
    -- input, and a panel you can walk away from while it is open reads as a
    -- decal rather than a screen.
    --
    -- Mouse lock 0 is DoNotLock, so the pointer is free to leave the window.
    local shapes = {
        { "UIOnlyEx(pc, widget, 0, false)",
          function() lib:SetInputMode_UIOnlyEx(pc, widget, 0, false) end },
        { "GameAndUIEx(pc, widget, 0, false, false)",
          function() lib:SetInputMode_GameAndUIEx(pc, widget, 0, false, false) end },
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

-- Take the overlay off the screen and forget it.
--
-- For a reload, not for a world switch. The code that built these widgets is
-- about to be replaced, and a widget that outlives the module which made it is
-- one nothing can reach to close: that is where this mod's duplicate panel
-- came from, and two of its crashes.
--
-- One call, RemoveFromParent, which is the UE5 name.
--
-- The first version made both calls, "because an extra call on a widget being
-- discarded costs nothing". That is the same reasoning that produced the
-- white tiles: a second call on a wrapper whose object has just been detached
-- is a member access on something that may no longer be there, and an access
-- violation is not a Lua error, so the pcall around it catches nothing.
--
-- The one thing that must not happen here is a crash, because this runs while
-- swapping code and a crash at that moment looks like the new code being at
-- fault rather than the teardown before it.
function M.teardown()
    if alive(widget) then
        pcall(function() widget:RemoveFromParent() end)
    end

    set_input(false)
    M.reset()
end

-- A world switch takes every wrapper with it. Dropped without touching them.
function M.reset()
    widget, tree, canvas = nil, nil, nil
    M.parts = nil
    -- The class itself survives a world switch, but a widget built from it
    -- does not, so only the instance is dropped.
    if bp_state == "asking" then bp_state = "unasked" end
    cursor_was, input_route = nil, nil
    M.open = false
    warned = {}
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

-- Two things are wrong and both are "the API is not shaped how I assumed".
-- The panel draws its boxes but no text, so SetText is being handed something
-- it will not take. And every SetInputMode shape failed, so that function is
-- not where or what I think it is. Rather than guess twice, ask.
-- Four TextBlocks, differing by one call each, left on screen to be looked at.
--
-- Twice now I have reasoned about why the panel's text does not draw and been
-- wrong twice, while a nearly identical TextBlock in build() renders fine. So
-- stop reasoning: put the variants side by side and read the answer off the
-- screen. Whichever labels appear tell us which call is doing it.
function M.text_variants()
    local host, host_tree = M.host()
    if not alive(host) or not alive(host_tree) then
        log.say("no overlay host, cannot test text")
        return
    end

    local cls = api.cdo("/Script/UMG.TextBlock")
    if not cls then
        log.say("no TextBlock class")
        return
    end

    local variants = {
        { label = "A plain, no visibility call",   vis = false, shadow = false, z = 10 },
        { label = "B with SetVisibility(0)",       vis = true,  shadow = false, z = 10 },
        { label = "C with ShadowOffset",           vis = false, shadow = true,  z = 10 },
        { label = "D with ZOrder 9000",            vis = false, shadow = false, z = 9000 },
    }

    for i, v in ipairs(variants) do
        local tb
        pcall(function() tb = StaticConstructObject(cls, host_tree) end)
        if alive(tb) then
            local slot
            pcall(function() slot = host:AddChildToCanvas(tb) end)
            if alive(slot) then
                pcall(function() slot:SetAutoSize(true) end)
                pcall(function()
                    slot:SetPosition({ X = 300, Y = 240 + i * 40 })
                end)
                pcall(function() slot:SetZOrder(v.z) end)
            end

            if v.vis then pcall(function() tb:SetVisibility(0) end) end
            if v.shadow then
                pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)
            end

            local ft
            pcall(function()
                local kismet = api.cdo("/Script/Engine.Default__KismetTextLibrary")
                if kismet then ft = kismet:Conv_StringToText(v.label) end
            end)
            if ft then pcall(function() tb:SetText(ft) end) end
            pcall(function() tb:SetColorAndOpacity({
                SpecifiedColor = { R = 1, G = 1, B = 0.3, A = 1 },
                ColorUseRule = 0 }) end)
        end
    end

    log.say("four text variants placed, look at the screen and say which appear")
end

-- What arguments does the input mode function actually want? Every shape has
-- failed, twice under two different names, so ask the UFunction itself rather
-- than trying arities until one sticks.
function M.input_signature()
    local lib = api.cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not lib then
        log.say("no WidgetBlueprintLibrary")
        return
    end

    for _, want in ipairs({ "SetInputMode_GameAndUIEx", "SetInputMode_UIOnlyEx",
                            "SetInputMode_GameOnly" }) do
        pcall(function()
            lib:GetClass():ForEachFunction(function(fn)
                local n
                pcall(function() n = fn:GetFName():ToString() end)
                if n ~= want then return end

                local params = {}
                pcall(function()
                    fn:ForEachProperty(function(prop)
                        local pn, pc = "?", "?"
                        pcall(function() pn = prop:GetFName():ToString() end)
                        pcall(function() pc = prop:GetClass():GetFName():ToString() end)
                        params[#params + 1] = pc .. " " .. pn
                    end)
                end)
                log.say("  " .. n .. "(" .. table.concat(params, ", ") .. ")")
            end)
        end)
    end
end

-- Where item icons live, and what they are called.
--
-- The picker should be a grid of icons rather than a column of internal ids,
-- which is what Creative Menu does and is most of the difference between
-- reading a menu and parsing one. That needs a texture for an item id.
--
-- The path is not guessable and grepping the pak does not answer it either:
-- its index is compressed, so only the handful of paths embedded in
-- uncompressed asset data show up, and the item icons are not among them.
--
-- So ask the running game. Every icon it has drawn is in memory under its
-- real name, and the folder those names share is the convention. Open your
-- inventory first, which is what makes the game load them.
function M.icon_probe()
    log.say("icon probe")

    -- Can Lua load an asset that is not in memory yet, and can an Image take
    -- one. Without both, knowing the path would not be enough to use it.
    log.say("  LoadAsset is a " .. type(LoadAsset))
    log.say("  UMG.Image resolves: " ..
        tostring(api.cdo("/Script/UMG.Image") ~= nil))

    local textures = FindAllOf("Texture2D") or {}
    log.say("  textures in memory: " .. #textures)

    -- Real ids from a real base, so a hit is proof rather than a guess about
    -- what the name might contain.
    local WANTED = { "Stone", "Wood", "Coal", "Fiber", "PalFluids",
                     "CopperIngot", "Berries", "Leather" }

    local folders, matched, shown = {}, {}, 0

    for _, tex in ipairs(textures) do
        if alive(tex) then
            local full
            pcall(function() full = tex:GetFullName() end)

            if type(full) == "string" then
                -- GetFullName is "Class /Path/To/Package.Object", and the
                -- folder is what every icon will have in common.
                local path = full:match("%s(/[%w_/]+)/") or ""
                if path ~= "" then
                    folders[path] = (folders[path] or 0) + 1
                end

                for _, id in ipairs(WANTED) do
                    if full:find(id, 1, true) and not matched[id] then
                        matched[id] = full
                    end
                end
            end
        end
    end

    log.say("  named after a real item:")
    for _, id in ipairs(WANTED) do
        if matched[id] then
            shown = shown + 1
            log.say("    " .. id .. "  ->  " .. matched[id])
        end
    end
    if shown == 0 then
        log.say("    none. Open your inventory, then press this again.")
    end

    -- Ranked, because the folder holding hundreds of textures is the one the
    -- icons live in and a single example could be a one off.
    local ranked = {}
    for path, count in pairs(folders) do
        ranked[#ranked + 1] = { path = path, count = count }
    end
    table.sort(ranked, function(a, b) return a.count > b.count end)

    log.say("  busiest texture folders:")
    for i = 1, math.min(12, #ranked) do
        log.say(string.format("    %5d  %s", ranked[i].count, ranked[i].path))
    end
end

-- What an Image will actually answer to.
--
-- SetBrushFromTexture reported success and drew nothing, which is the oldest
-- trap in this codebase: a pcall around a call on a wrapper succeeds whether
-- or not the method exists, so "it worked" and "there is no such function"
-- are the same result. Asking the class what it has is the only answer that
-- means anything.
function M.image_probe()
    log.say("image probe")

    local cdo = api.cdo("/Script/UMG.Image")
    if not cdo then
        log.say("  no UMG.Image default object")
        return
    end

    local interesting = { "Brush", "Size", "Opacity", "Color", "Texture" }
    local found = 0

    pcall(function()
        cdo:GetClass():ForEachFunction(function(fn)
            local name
            pcall(function() name = fn:GetFName():ToString() end)
            if type(name) ~= "string" then return end

            local keep = false
            for _, word in ipairs(interesting) do
                if name:find(word, 1, true) then keep = true break end
            end
            if not keep then return end

            local params = {}
            pcall(function()
                fn:ForEachProperty(function(prop)
                    local pn, pc = "?", "?"
                    pcall(function() pn = prop:GetFName():ToString() end)
                    pcall(function()
                        pc = prop:GetClass():GetFName():ToString()
                    end)
                    params[#params + 1] = pc .. " " .. pn
                end)
            end)

            found = found + 1
            log.say("  " .. name .. "(" .. table.concat(params, ", ") .. ")")
        end)
    end)

    if found == 0 then
        log.say("  the class reports no brush or size functions at all")
    end
end

-- Can we use the game's own item slot instead of building one?
--
-- Creative Menu is a blueprint mod. Its menus are widget blueprints authored
-- in the editor, and its item tiles are almost certainly the game's own slot
-- widgets rather than an Image with a texture hunted down by hand. That is
-- why it looks like part of the game and why hovering, focus and layout
-- behave: Slate does them, not arithmetic in Lua at ten frames a second.
--
-- The toolchain to ship a widget blueprint was set aside as too heavy. Reusing
-- a class the game already has needs none of it, if such a class can be
-- constructed from here and told which item to show. That is two questions
-- and this asks both.
function M.slot_probe()
    log.say("slot probe")

    local wanted = { "ItemSlot", "CommonItemSlot", "ItemIcon" }
    local classes, shown = {}, 0

    pcall(function()
        for _, cls in ipairs(FindAllOf("BlueprintGeneratedClass") or {}) do
            if shown >= 6 then break end
            if alive(cls) then
                local full
                pcall(function() full = cls:GetFullName() end)
                if type(full) == "string" then
                    for _, word in ipairs(wanted) do
                        if full:find(word, 1, true) and not classes[full] then
                            classes[full] = cls
                            shown = shown + 1
                            log.say("  " .. full)
                            break
                        end
                    end
                end
            end
        end
    end)

    if shown == 0 then
        log.say("  no item slot class is loaded right now")
        log.say("  open your inventory once, then reopen this menu")
        return
    end

    -- What such a class will answer to. A setter taking an item id is the
    -- whole point; without one the class is no use to us however pretty it is.
    for full, cls in pairs(classes) do
        log.say("  functions on " .. (full:match("([^/.]+)$") or full) .. ":")

        local found = 0
        pcall(function()
            cls:ForEachFunction(function(fn)
                if found >= 14 then return end

                local name
                pcall(function() name = fn:GetFName():ToString() end)
                if type(name) ~= "string" then return end

                local low = name:lower()
                if not (low:find("set") or low:find("item")
                    or low:find("update") or low:find("init")) then
                    return
                end

                local params = {}
                pcall(function()
                    fn:ForEachProperty(function(prop)
                        local pn, pc = "?", "?"
                        pcall(function() pn = prop:GetFName():ToString() end)
                        pcall(function()
                            pc = prop:GetClass():GetFName():ToString()
                        end)
                        params[#params + 1] = pc .. " " .. pn
                    end)
                end)

                found = found + 1
                log.say("    " .. name .. "(" ..
                    table.concat(params, ", ") .. ")")
            end)
        end)

        if found == 0 then
            log.say("    none that look like a setter")
        end
        break   -- one class is enough to judge the approach
    end
end

-- A class out of our own cooked pak.
--
-- LoadAsset does not reach it, and that is not a bug in the pak. UnrealPak
-- lists UI/WBP_WorkRules.uasset inside it at the right mount point, the
-- cooked package names WBP_WorkRules_C and WidgetBlueprintGeneratedClass
-- outright, and ModActor sits beside it and loads. Three spellings of
-- LoadAsset found none of it.
--
-- The route that works is the one BPModLoaderMod uses on our own ModActor,
-- which is the proof that it works: ask the asset registry, not the loader.
-- Read out of its source rather than guessed, which is the only reason this
-- took one attempt instead of five.
local registry = nil

local function helpers()
    if registry ~= nil then return registry end

    local found
    pcall(function()
        found = StaticFindObject(
            "/Script/AssetRegistry.Default__AssetRegistryHelpers")
    end)

    if found ~= nil then
        local ok = false
        pcall(function() ok = found:IsValid() end)
        if ok then registry = found end
    end
    return registry
end

-- FindOrAddFName, borrowed rather than reimplemented.
--
-- A name merely looked up comes back as None when the game has never seen it,
-- and a name out of a mod's own pak is exactly the kind it has never seen. My
-- version guessed at the argument order; this is the one the working loader
-- uses, and there is no reason to have two.
local UEHelpers = nil
pcall(function() UEHelpers = require("UEHelpers") end)

local function name_of(text)
    if UEHelpers and UEHelpers.FindOrAddFName then
        local made
        pcall(function() made = UEHelpers.FindOrAddFName(text) end)
        if made ~= nil then return made end
    end

    local made
    pcall(function() made = FName(text, EFindName.FNAME_Add) end)
    if made == nil then pcall(function() made = FName(text) end) end
    return made
end

-- Ask the registry for a class out of a mounted mod pak, on the game thread,
-- and hand it back through a callback.
--
-- On the game thread because the last attempt hung the mod outright. ModActor
-- came back and the widget never did, and the tick stopped with it: GetAsset
-- on a package that is not loaded yet does a synchronous load, and a
-- synchronous load off the game thread waits for a thread that is waiting for
-- it. ModActor answered instantly only because BPModLoaderMod had loaded it
-- moments earlier.
--
-- A callback rather than a return value, because that is what asking on
-- another thread costs and pretending otherwise is what caused the hang.
function M.mod_class(package, asset, done)
    ExecuteInGameThread(function()
        local reg = helpers()
        if reg == nil then return done(nil) end

        local data = {
            PackageName = name_of(package),
            AssetName = name_of(asset),
        }

        local class
        pcall(function() class = reg:GetAsset(data) end)

        local ok = false
        if class ~= nil then pcall(function() ok = class:IsValid() end) end

        done(ok and class or nil)
    end)
end

function M.widget_probe()
    log.say("widget probe")
    log.say("  asset registry helpers: " .. tostring(helpers() ~= nil))

    local function try(package, asset)
        M.mod_class(package, asset, function(class)
            local full
            if class ~= nil then
                pcall(function() full = class:GetFullName() end)
            end
            log.say(string.format("  %-22s %s", asset,
                full or "not found through the registry"))
        end)
    end

    -- ModActor first as the control, since it is known to resolve.
    try("/Game/Mods/PalWorkPriority/ModActor", "ModActor_C")

    -- Spaced out rather than fired together, because each of these can be a
    -- synchronous load and nine at once is what killed the game over the
    -- icons.
    ExecuteWithDelay(1500, function()
        try("/Game/Mods/PalWorkPriority/UI/WBP_WorkRules", "WBP_WorkRules_C")
    end)
end

function M.diagnose()
    local host, host_tree = M.host()
    log.say("overlay diagnostics")
    log.say("  host canvas: " .. tostring(host ~= nil))

    -- 1. what does each FText route actually produce
    local direct, kismet
    local ok_direct = pcall(function() direct = FText("probe") end)
    log.say(string.format("  FText('probe')            ok=%s type=%s",
        tostring(ok_direct), type(direct)))

    local lib_text = api.cdo("/Script/Engine.Default__KismetTextLibrary")
    log.say("  KismetTextLibrary CDO     " .. tostring(lib_text ~= nil))
    if lib_text then
        local ok_k = pcall(function()
            kismet = lib_text:Conv_StringToText("probe")
        end)
        log.say(string.format("  Conv_StringToText         ok=%s type=%s",
            tostring(ok_k), type(kismet)))
    end

    -- 2. does SetText actually take either of them
    if alive(host_tree) and alive(host) then
        local cls = api.cdo("/Script/UMG.TextBlock")
        local tb
        if cls then pcall(function() tb = StaticConstructObject(cls, host_tree) end) end

        if alive(tb) then
            pcall(function() host:AddChildToCanvas(tb) end)
            for name, ft in pairs({ direct = direct, kismet = kismet }) do
                if ft ~= nil then
                    local ok = pcall(function() tb:SetText(ft) end)
                    local back
                    pcall(function()
                        local got = tb:GetText()
                        if got then back = got:ToString() end
                    end)
                    log.say(string.format("  SetText via %-8s      ok=%s reads back %s",
                        name, tostring(ok), tostring(back)))
                end
            end
            pcall(function() tb:RemoveFromParent() end)
        else
            log.say("  could not construct a TextBlock to test with")
        end
    end

    -- 3. where does input mode actually live
    local ui_lib = api.cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
    log.say("  WidgetBlueprintLibrary    " .. tostring(ui_lib ~= nil))
    if ui_lib then
        local found = {}
        pcall(function()
            ui_lib:GetClass():ForEachFunction(function(fn)
                local n
                pcall(function() n = fn:GetFName():ToString() end)
                if type(n) == "string" and n:find("Input") then
                    found[#found + 1] = n
                end
            end)
        end)
        log.say("  functions mentioning Input: " ..
            (#found > 0 and table.concat(found, ", ") or "none"))
    end

    local pc = api.player_controller()
    if alive(pc) then
        local found = {}
        pcall(function()
            pc:GetClass():ForEachFunction(function(fn)
                local n
                pcall(function() n = fn:GetFName():ToString() end)
                if type(n) == "string" and
                    (n:find("InputMode") or n:find("ShowMouse") or
                     n:find("IgnoreLook") or n:find("SetInput")) then
                    found[#found + 1] = n
                end
            end)
        end)
        log.say("  controller input functions: " ..
            (#found > 0 and table.concat(found, ", ") or "none"))
    end
end

return M
