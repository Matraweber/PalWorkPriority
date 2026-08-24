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
local trace = require("trace")

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

-- The widget blueprint out of our own pak, when it is there.
--
-- Everything below still works without it. The hand built canvas is what has
-- been drawing the panel all along and remains the fallback, because a pak
-- that failed to mount should degrade to the panel we had rather than to no
-- panel at all.
local BP_PACKAGE = "/Game/Mods/PalWorkPriority/UI/WBP_WorkRules"
local BP_ASSET = "WBP_WorkRules_C"

-- No stored class. The first version kept the wrapper GetAsset handed the
-- callback and used it from host() a second later - and a Lua wrapper is not
-- a GC reference, so a class nothing in the engine references is collectable
-- the moment the callback returns. Probed after today's clean refusal:
-- "class resident: false" minutes after "the blueprint widget is available".
-- Yesterday the same stored wrapper met a different GC timing inside Create,
-- which is the best-sourced theory yet for the crash. Rule one of this
-- codebase, violated in the one place it looked exempt: a CLASS is an engine
-- object like any other. It is used inside the callback that receives it,
-- never after.
local bp_state = "unasked"       -- unasked | asking | hosted | absent

-- Named widgets from the blueprint, once one is hosted. nil when the panel is
-- drawing on its own canvas, which is how the panel tells the two apart.
M.parts = nil

local BP_NAMES = {
    "Root", "Backdrop", "Body", "Title", "Search",
    "RuleList", "ItemList", "Actions", "NewRuleButton", "CloseButton",
}

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

-- The controller the widget was built under, by name.
--
-- The UserWidget is outered to the PlayerController, which the engine
-- destroys on a world or level change. ClientRestart fires on the NEW
-- controller - after the old one is gone - so between those two moments the
-- clock keeps beating and, if the panel is open, host() would ask a widget
-- whose owner had already been freed whether it is still valid. A name is a
-- string and cannot dangle; comparing it costs one engine call and closes the
-- window without needing an unload hook.
local built_under = nil

-- Asked at most once a second, not ten times.
--
-- This is a FindFirstOf plus a GetFullName, and host() runs it on every
-- refresh - measured at 11ms of a 100ms frame, spent re-answering a question
-- whose answer only changes when the world does. A world switch is not going
-- to happen and be acted on inside one second, and the whole point of the
-- check is to be ahead of the next beat rather than the next microsecond.
local owner_cached = nil
local owner_at = -1
-- No cache at all. This was 1.0, then 5.0, and both were wrong.
--
-- The reasoning for widening it was that host() validates the canvas, the
-- tree and the widget anyway, so this was only an early warning. That is
-- backwards: those validations are alive() calls on wrappers stored since an
-- earlier frame, and alive() on a freed object IS the crash. This check is
-- the only thing that decides whether they are safe to make, so it cannot be
-- staler than they are.
--
-- A cache made the failure worse rather than rarer. The nil case - no
-- controller yet - was already handled. What a TTL adds is a window where the
-- controller has been freed and this still returns its NAME, so the names
-- match, the drop is skipped, and the widget outered to that freed controller
-- is asked whether it is valid. At a 100ms beat, five seconds of that is up
-- to fifty attempts per world transition.
--
-- The price is one FindFirstOf plus one GetFullName per refresh, measured at
-- 9ms, and only while the panel is open. That is the cost of holding widgets
-- across frames at all; the alternative is not a cheaper check, it is an
-- unguarded dereference.
local OWNER_TTL = 0.0

local function owner_name()
    local now = os.clock()
    if owner_at >= 0 and (now - owner_at) < OWNER_TTL then return owner_cached end

    local pc = api.player_controller()
    local n
    if alive(pc) then pcall(function() n = pc:GetFullName() end) end

    owner_cached, owner_at = n, now
    return n
end

local function collect_parts(made)
    local parts, found = {}, 0

    for _, name in ipairs(BP_NAMES) do
        local w
        pcall(function() w = made[name] end)
        if alive(w) then
            parts[name] = w
            found = found + 1
        end
    end
    if found == #BP_NAMES then return parts, found end

    local wanted = {}
    for _, name in ipairs(BP_NAMES) do
        if parts[name] == nil then wanted[name] = true end
    end

    local root
    pcall(function() root = made.WidgetTree.RootWidget end)
    if not alive(root) then return parts, found end

    local visited, depth = {}, 0
    local function walk(w)
        if depth > 64 or not alive(w) then return end
        local id
        pcall(function() id = w:GetFullName() end)
        if type(id) ~= "string" or visited[id] then return end
        visited[id] = true

        local name
        pcall(function() name = w:GetFName():ToString() end)
        if name and wanted[name] then
            parts[name] = w
            wanted[name] = nil
            found = found + 1
        end

        local n = 0
        pcall(function() n = w:GetChildrenCount() end)
        depth = depth + 1
        for i = 0, (tonumber(n) or 0) - 1 do
            local child
            pcall(function() child = w:GetChildAt(i) end)
            if child ~= nil then walk(child) end
        end
        depth = depth - 1
    end
    walk(root)

    return parts, found
end

-- Construct the blueprint widget and take its parts.
--
-- Create rather than StaticConstructObject, because a UserWidget wants
-- initialising with a player and an owning world, and one built raw is a
-- widget that exists without being alive.
--
-- ONE attempt per session. The first version left bp_state at "ready" on
-- every failure, so a fault in here would have been retried once a second
-- with warn_once swallowing every repeat - whatever went wrong was set up to
-- go wrong forever, silently. Any failure now latches "absent" and the
-- session runs on the hand built canvas, which is a look, not a loss.
local function build_blueprint(class)
    if class == nil then return false end

    local function give_up(key, why)
        bp_state = "absent"
        warn_once(key, why .. ", drawing on our own canvas for this session")
        return false
    end

    local pc = api.player_controller()
    if not alive(pc) then return give_up("bppc", "no player controller yet") end

    local made
    local lib = api.cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
    if lib then
        pcall(function() made = lib:Create(pc, class, pc) end)
    end
    if not alive(made) then
        return give_up("bpmake", "the blueprint widget would not construct")
    end

    local made_tree
    pcall(function() made_tree = made.WidgetTree end)
    if not alive(made_tree) then
        return give_up("bptree", "the blueprint widget has no widget tree")
    end

    local parts, found = collect_parts(made)
    if parts.Root == nil then
        return give_up("bproot", "the blueprint Root did not resolve (" ..
            found .. " of " .. #BP_NAMES .. " names found)")
    end

    pcall(function() made:SetIsFocusable(true) end)
    pcall(function() made:AddToViewport(9000) end)
    -- Collapsed until the panel opens: this now runs at world load, and a
    -- work-rules screen greeting every spawn would be a bug with a viewport.
    pcall(function() made:SetVisibility(1) end)

    -- The blueprint's Body is a placeholder: a title, a search box, two empty
    -- lists and a button row, laid out by Slate so that the shell could be
    -- looked at before anything drove it. The panel draws all four of those
    -- itself, onto Root, so leaving Body visible renders both at once - which
    -- is exactly what the first hosted screenshot showed.
    --
    -- Collapsed rather than removed: this is the layout the panel will
    -- eventually fill instead of drawing over, and taking it out now would
    -- mean rebuilding the pak to get it back.
    if parts.Body then
        pcall(function() parts.Body:SetVisibility(1) end)
    end

    widget, tree, canvas = made, made_tree, parts.Root
    M.parts = parts
    -- Stamped here as well as in the hand built path, and this was missing.
    -- built_under is what host() compares the current controller against to
    -- notice a world change; left nil, that guard can never fire, and the
    -- first world switch would have had host() validate a widget outered to
    -- a freed controller. alive() on that is the crash, not the check for it.
    built_under = owner_name()

    log.say(string.format("overlay: hosted on the blueprint, %d of %d " ..
        "named widgets found", found, #BP_NAMES))

    for _, name in ipairs(BP_NAMES) do
        if parts[name] == nil then
            log.warn("  missing from the blueprint: " .. name)
        end
    end

    return true
end

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

        -- Built HERE, while the class is an object of the current call. Once
        -- AddToViewport succeeds the instance roots the class, so from then
        -- on neither can be collected under us. The widget waits collapsed
        -- until the panel wants it.
        if build_blueprint(class) then
            bp_state = "hosted"
        else
            bp_state = "absent"
        end
    end)
end

-- The named children of a blueprint instance, WITHOUT GetWidgetFromName.
--
-- That call is what sank the first attempt. It looks like the obvious API and
-- it is not callable from here: UserWidget.h:1122 declares it plain C++, no
-- UFUNCTION, so UE4SS has nothing to reflect and every lookup came back nil
-- against a perfectly healthy tree - the cooked asset was extracted from the
-- pak afterwards and string-checked, all twelve names present. Those ten
-- unknown-member misses were also the only novel engine interaction in the
-- minute before the crash, so this path stays off unreflected names entirely.
--
-- Two passes, both lifted from mods proven on this machine:
--
-- Pass 1 is BreedingHelper's collect_parts: the commandlet set bIsVariable on
-- every named widget, and a compiled variable widget IS a property of the
-- generated class, so made.Root is a plain property read - the cheapest and
-- best-trodden access this environment has.
--
-- Pass 2 is PerfectPlacement's find_widget: walk WidgetTree.RootWidget by
-- GetFName, children through GetChildrenCount and GetChildAt, which unlike
-- GetWidgetFromName are real UFUNCTIONs (PanelWidget.h:27 and :35). The
-- visited set is not decoration - their walker guards cycles, which is how
-- you know cycles happen.

local function build_now()
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
    built_under = owner_name()
    return true
end

-- One mark around a whole call, popped however the call leaves.
--
-- The guard is not decoration. This module hot-reloads and trace.lua does
-- not, so a session that reloads the overlay after trace gained around()
-- gets the NEW overlay talking to the OLD trace, where the field is nil -
-- and calling it throws inside M.host, which takes the entire panel down
-- silently, because the refresh that reaches it sits under a pcall. That
-- cost a diagnosis; the fallback costs a line. The breadcrumb is simply
-- less precise until the game restarts.
local function traced(where, fn)
    if trace.around then return trace.around(where, fn) end
    return fn()
end

-- The mark lives out here rather than inside, because the body has ten exits
-- and one of them used to carry the only done(). trace.around unwinds to the
-- depth it started at whichever way the body leaves.
local function build()
    return traced("overlay: building the panel widget", build_now)
end

-- The canvas panels draw into, and the tree that must own anything they
-- construct. Builds on first use.
function M.host()
    -- A different controller than the one this was built under means the
    -- world moved. Everything is dropped without being touched.
    -- A nil owner counts as moved, and that is the whole point.
    --
    -- The guard used to require now_owner ~= nil, which skipped the drop in
    -- exactly the interval it was written for: the old PlayerController freed
    -- and the new one not yet made. In that window there is no controller to
    -- compare, so the check passed, and the next line asked a widget outered
    -- to freed memory whether it was still valid. That is the crash, not a
    -- guard against it, and it is the LONGER half of the transition.
    local now_owner = owner_name()
    if built_under ~= nil and now_owner ~= built_under then
        widget, tree, canvas = nil, nil, nil
        M.parts = nil
        -- Re-armed, so the next world's ClientRestart loads and builds again.
        if bp_state == "hosted" then bp_state = "unasked" end
        built_under = nil
        -- The input mode goes back with it. Dropping the widget while the UI
        -- mode was still set left the cursor forced on and the panel's own
        -- open flag true, so reopening took two presses.
        M.open = false
        pcall(function() M.release_input() end)
    end

    -- Nothing to build onto yet. Said plainly rather than falling through to
    -- a construct that would be outered to nil.
    if now_owner == nil then return nil end

    if alive(widget) and alive(tree) and alive(canvas) then
        return canvas, tree, widget
    end

    -- Dropped without touching them. Whatever they pointed at is gone, and
    -- asking a freed widget whether it is valid is the crash rather than the
    -- check for it.
    widget, tree, canvas = nil, nil, nil
    -- The parts go with the widget they came out of: handles into a tree that
    -- was just let go of, and a flag that describes an engine object has to
    -- share that object's lifetime.
    M.parts = nil

    -- The blueprint widget is built at world load, inside the callback that
    -- receives its class, and the alive(widget) fast path above returns it.
    -- Reaching here means there is none this session - never built, given up,
    -- or dropped with a world - so the hand built canvas takes over, which is
    -- the canvas that has drawn this panel all along.
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
local function set_input_now(on)
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

-- Exposed so host() can hand the input mode back when it drops the widget.
-- host() is declared above set_input_now, so it cannot call it directly.
function M.release_input()
    return set_input_now(false)
end

-- Three early returns, so the mark is owned by a wrapper here too.
local function set_input(on)
    return traced("overlay: set_input " .. tostring(on), function()
        return set_input_now(on)
    end)
end

local function show_now()
    if M.host() == nil then
        return false
    end

    pcall(function() widget:SetVisibility(0) end)
    set_input(true)

    -- Focus after the mode switch, or the mode switch takes it back.
    pcall(function() widget:SetKeyboardFocus() end)

    M.open = true
    return true
end

function M.show()
    return traced("overlay: showing the panel", show_now)
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

-- Take the cursor back when something else has helped itself to it.
--
-- Measured on 24 August, over an open panel: Esc opens the game's own menu and
-- changes nothing here, cursor included. The SECOND Esc, the one that closes
-- that menu, sets bShowMouseCursor to false - and set_input_now runs on show
-- and on hide and at no other time, so nothing noticed. The panel was left on
-- screen holding a UI-only input route with no pointer to drive it, and the
-- only way back was to close and reopen it.
--
-- The condition is deliberately "open AND the cursor is gone", not "open".
-- That same measurement is what makes it safe: while the game's menu is up the
-- cursor is ON, so this cannot be true then, and this cannot end up fighting
-- that menu for the pointer. A blunter re-assert on every tick would, and
-- would trade a lost cursor for an unusable pause menu.
--
-- Polled rather than hooked because there is no event for "someone took your
-- input mode away". Once a second, off the refresh that already runs.
function M.reassert_input()
    if not M.open then return false end

    local pc = api.player_controller()
    if not alive(pc) then return false end

    local cursor
    pcall(function() cursor = pc.bShowMouseCursor end)
    if cursor ~= false then return false end

    -- set_input_now leaves cursor_was alone when it is already set, so the
    -- state to restore on close is still the one captured when the panel
    -- opened, not the false the game just wrote.
    log.debug("overlay: the cursor was taken, putting it back")
    set_input_now(true)
    pcall(function() if alive(widget) then widget:SetKeyboardFocus() end end)
    return true
end


-- A world switch takes every wrapper with it. Dropped without touching them.
function M.reset()
    widget, tree, canvas = nil, nil, nil
    M.parts = nil
    if bp_state == "hosted" then bp_state = "unasked" end
    built_under = nil
    owner_cached, owner_at = nil, -1
    cursor_was, input_route = nil, nil
    M.open = false
    warned = {}
end

-- Restored verbatim from fb9be28, the last commit before the runtime was
-- rolled back on 21 August. The rollback was not because this failed - it
-- worked end to end and there is a screenshot - but because five runtime
-- changes were stacked at once and none could be told apart afterwards.
-- This is one of the five, brought back by itself and nothing else with it.
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

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

-- What the input state IS, as against what this module last set it to.
--
-- The two come apart whenever something else takes the mode away, and the
-- game's own menus do exactly that. set_input_now runs on show and on hide and
-- at no other time, so nothing here notices the theft or puts it back: the
-- panel is left on screen with no cursor and no route for a click, which is
-- the reported symptom of Esc pressed twice over an open panel.
--
-- Reads only, and only reads already proven on this build. bShowMouseCursor is
-- the same property set_input_now writes three lines apart. Deliberately does
-- NOT call widget:GetVisibility(): it is very likely fine, and an unverified
-- name is exactly what has taken this game down before, so a diagnostic is the
-- last place to spend that risk.
function M.input_report()
    local pc = api.player_controller()

    local cursor = "no controller"
    if alive(pc) then
        cursor = "unreadable"
        pcall(function() cursor = tostring(pc.bShowMouseCursor) end)
    end

    log.say("overlay input:")
    log.say("  overlay.open:     " .. tostring(M.open))
    log.say("  widget alive:     " .. tostring(alive(widget)))
    log.say("  bShowMouseCursor: " .. cursor)
    log.say("  cursor_was:       " .. tostring(cursor_was))
    log.say("  input_route:      " .. tostring(input_route))

    return string.format("open=%s cursor=%s route=%s",
        tostring(M.open), cursor, tostring(input_route))
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



return M
