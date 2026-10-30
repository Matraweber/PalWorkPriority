-- Own the panel attachment and input handoff. Lua references do not root
-- Unreal widgets: each callback resolves the owned root afresh before using
-- its current tree. Closing detaches the panel and drops every widget handle.

local log = require("log")
local api = require("palapi")
local trace = require("trace")
local lifecycle = require("panel_lifecycle")
local session = require("session")
local life = lifecycle.new()
local widget_path = nil

local M = {}

M.open = false
M.generation = 0
M.phase = "closed"
M.native_cancel = false

local function input_contract(fresh)
    local ok, version, pending, bound = pcall(function()
        return fresh.PWP_InputContract, fresh.PWP_CancelRequested, fresh.PWP_CancelBindingAttempted
    end)
    if not ok or (version ~= 2 and version ~= 3 and version ~= 4) or type(pending) ~= "boolean" or bound ~= true then return false end
    local active_ok, active = pcall(function() return fresh:IsActivated() end)
    return active_ok and active == true, pending
end

-- Only the Pal action-router contract needs activation. Plain/legacy shells
-- keep their existing lifecycle. Never pass a delegate by value through Lua;
-- binding and its callback live entirely in the generated Blueprint.
local function native_active(fresh, on)
    local known, version = pcall(function() return fresh.PWP_InputContract end)
    if not known or (version ~= 2 and version ~= 3 and version ~= 4) then return true end
    local ok, active = pcall(function()
        if fresh:IsActivated() ~= on then
            if on then
                -- PalActivatableWidget defaults to CapturePermanently. Its
                -- native router applies that config after activation and can
                -- undo our GameAndUIEx cursor setup. Configure the current
                -- owned widget before activation; never fight vanilla focus
                -- with a periodic input-mode reset.
                fresh.GameMouseCaptureMode = 0 -- EMouseCaptureMode::NoCapture
                if fresh.GameMouseCaptureMode ~= 0 then return nil end
                fresh.PWP_CancelRequested = false
                fresh:ActivateWidget()
            else
                fresh:DeactivateWidget()
            end
        end
        return fresh:IsActivated()
    end)
    return ok and active == on
end

-- The caller supplies the widget obtained in this callback's current tree.
-- Clear before dispatch so a cancelled editor cannot become a second close.
function M.take_cancel(fresh)
    if not M.open then M.native_cancel = false return false end
    local supported, pending = input_contract(fresh)
    M.native_cancel = supported
    if not supported then return false end
    if pending == false then return false, true end
    local ok = pcall(function() fresh.PWP_CancelRequested = false end)
    if not ok then return true, false end
    local still_supported, after = input_contract(fresh)
    return true, still_supported and after == false
end

-- Contract 4: a second RadialMenuCancel binding on release sets
-- PWP_CancelReleased. Returns true once per release (and clears it), false
-- when not released yet, nil when the shell cannot tell (older pak).
function M.take_release(fresh)
    local ok, contract, released = pcall(function() return fresh.PWP_InputContract, fresh.PWP_CancelReleased end)
    if not ok or contract ~= 4 or type(released) ~= "boolean" then return nil end
    if not released then return false end
    pcall(function() fresh.PWP_CancelReleased = false end)
    return true
end

-- This is an engine-owned reference on the current shell, not a retained Lua
-- wrapper. Only the amount editor participates in the native Escape preview.
function M.set_amount_editor(editor, return_focus)
    local _, _, fresh = M.resolve_owned()
    if not fresh then return editor == nil end
    local known, version = pcall(function() return fresh.PWP_InputContract end)
    if not known or (version ~= 3 and version ~= 4) then return true end -- Legacy/missing-pak shell.
    local ok, result = pcall(function()
        local restore_focus = false
        if editor == nil and return_focus == true and M.open then
            -- Hiding an editable field does not relinquish its Slate focus.
            -- Return only our editor's focus to the still-open shell; a menu
            -- that already took focus must keep it. All handles are fresh.
            local read, owned = pcall(function()
                local previous = fresh.PWP_AmountEditor
                return fresh:IsActivated() == true
                    and previous and previous:IsValid() == true
                    and (previous:HasAnyUserFocus() == true
                        or previous:HasFocusedDescendants() == true)
            end)
            restore_focus = read and owned == true
        end
        fresh.PWP_AmountEditor = editor
        local bound = fresh.PWP_AmountEditor
        if editor == nil then
            if bound ~= nil and bound:IsValid() == true then return false end
            if restore_focus then fresh:SetKeyboardFocus() end
            return true
        end
        return bound ~= nil and bound:IsValid() == true
            and bound:GetFullName() == editor:GetFullName()
    end)
    return ok and result == true
end

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

-- Controller buttons (contract 4, 2026-10-22). The game's CommonUI keeps the
-- D-pad and A from the player controller while the panel has focus, so the
-- shell's preview key handler sets PWP_PadKey and calls PWP_PadDispatch; this
-- hook reads the code from that same widget and hands it to the panel
-- (M.on_pad, set by panel.lua) on the next game-thread beat. Registered once,
-- after the class is loaded; a shell without the function just never fires.
M.on_pad = false -- set by panel.lua: function(code)

function M.hook_pad()
    if M.pad_hooked then return true end
    local ok = pcall(RegisterHook, BP_PACKAGE .. "." .. BP_ASSET .. ":PWP_PadDispatch", function(context)
        local read, code = pcall(function()
            local widget = context:get()
            if widget.PWP_InputContract ~= 4 then return nil end
            return widget.PWP_PadKey
        end)
        if not read or type(code) ~= "number" or code % 1 ~= 0 or code < 1 or code > 11 then return end
        M.pad_events = (M.pad_events or 0) + 1
        session.enqueue(function()
            if M.open and M.on_pad then M.on_pad(code) end
        end, true)
    end)
    M.pad_hooked = ok
    if not ok then warn_once("padhook", "controller buttons could not be hooked; use mouse and keyboard") end
    return ok
end

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

-- What the panel says it is, set by the panel before the widget is built. The
-- blueprint's own numbers are placeholders; the layout that has to fit is the
-- one drawing into it.
M.width = nil

-- The shell is a stack of rows. Each chrome line has a fixed height SizeBox
-- (XxxRow) wrapping a CanvasPanel (Xxx) that the panel draws into, so Slate
-- owns the vertical order while the panel keeps the X positions it already
-- has. A row the current screen does not want is collapsed and costs no
-- height, which is how one shell serves the rules screen and the picker.
--
-- The first shell had a title, a search box, two lists and a button row, and
-- the panel could use exactly one of them: everything else it draws had
-- nowhere to go and stayed at absolute canvas coordinates. Half the panel in
-- a Slate flow and half in fixed coordinates only holds while the flow
-- contains one thing - adding a second container shifted every sibling below
-- it and scattered the rows.
local BP_NAMES = {
    "Root", "Backdrop", "Body",
    "TabsRow", "Tabs",
    "TitleRow", "Title",
    "SubRow", "Sub",
    "NoticeRow", "Notice",
    "SearchRow", "Search",
    "CaptionRow", "Caption",
    "HeadRow", "Head",
    "RuleList", "ItemList",
    "FootRow", "Foot",
}

-- Chrome rows the panel does not fill yet. Collapsed, so the panel goes on
-- drawing those lines on its own canvas exactly as before and the lists keep
-- the geometry they were aligned to. Each one comes off this list as the
-- panel starts drawing into it instead.
local BP_UNUSED_ROWS = {
    "TabsRow", "TitleRow", "SubRow", "NoticeRow",
    "SearchRow", "CaptionRow", "HeadRow", "FootRow",
}

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

-- Owner name detects ordinary transitions, but is not lifetime evidence.
local built_under = nil


-- The width the backdrop is currently cut to, so fit_width can tell whether
-- there is anything to do. Declared up here with the other module state
-- because host() clears it on a drop, hundreds of lines above where
-- fit_width is defined - and a local declared after its first assignment is
-- not a local at all, it is a silent global. luacheck said so before the
-- game had to, which is the third time that rule has earned its place today.
local fitted = nil

-- The owner check's state. Deleted by accident on 2026-08-24, when a block
-- inserted just above it was removed by cutting from its own first line to
-- owner_name's - which swept up these three declarations on the way past.
-- owner_at then read as a global nil, "nil >= 0" threw on the first host(),
-- and the panel simply stopped drawing with nothing in the log to say why.
-- luacheck is now taught to catch a read of a name that was never declared;
-- it already caught the reverse case, a local declared after its first use.
local owner_cached = nil
local owner_at = -1

-- Only an owner label. The root is separately reacquired on every callback.
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

-- Every panel widget off the viewport, however many there are.
--
-- Each build adds one at ZOrder 9000 and only build_blueprint removed the
-- previous one, by name, one at a time. A session that reloads often - which
-- this mod is built for, and which host() re-asking for the blueprint made
-- more frequent - accumulates them, and any one left parented sits over the
-- game taking hit tests.
--
-- Objects come from FindAllOf inside this call and none is kept.
local function sweep_panels(keep_name)
    local n, failed = 0, 0
    local scanned = pcall(function()
        for _, w in ipairs(FindAllOf("UserWidget") or {}) do
            if alive(w) then
                local full
                pcall(function() full = w:GetFullName() end)
                local ours = type(full) == "string" and lifecycle.owners[full]
                if not ours and type(full) == "string" and full:find("WBP_WorkRules", 1, true) then
                    local class_name
                    pcall(function() class_name = w:GetClass():GetFullName() end)
                    ours = type(class_name) == "string" and class_name:find(BP_PACKAGE, 1, true) ~= nil
                end
                if ours and full ~= keep_name then
                    local ok, result = pcall(function()
                        if not native_active(w, false) then return false end
                        if w:SetVisibility(1) == false then return false end
                        return w:RemoveFromParent()
                    end)
                    if ok and result ~= false then
                        lifecycle.owners[full] = nil
                        n = n + 1
                    else
                        failed = failed + 1
                    end
                end
            end
        end
    end)
    return n, scanned and failed or failed + 1
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

    -- Take any earlier instance off the viewport first.
    --
    -- Every build adds one at ZOrder 9000 and nothing removes it, so a hot
    -- reload - which resets this module's state but leaves the widget on the
    -- screen - left the old one visible underneath the new. That showed up as
    -- faded duplicate rows sitting at the position the list had before it was
    -- aligned, which reads as a layout bug and is not one.
    --
    -- Every object here comes from FindAllOf inside this call, so none of it
    -- is stored, and the one just built is skipped by name.
    local mine
    pcall(function() mine = made:GetFullName() end)
    local _, failed_detach = sweep_panels(mine)
    if failed_detach > 0 then return give_up("bpduplicate", "an earlier panel could not detach") end

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
    local attached = pcall(function() made:AddToViewport(9000) end)
    if not attached then return give_up("bpattach", "the blueprint could not attach") end
    -- Collapsed until the panel opens: this now runs at world load, and a
    -- work-rules screen greeting every spawn would be a bug with a viewport.
    pcall(function() made:SetVisibility(1) end)

    -- Body stays VISIBLE now, because RuleList lives inside it and the panel
    -- has started filling that rather than drawing over it. What goes is only
    -- the chrome the panel draws for itself - a title, a search box and a
    -- button row - which is what made the first hosted screenshot render two
    -- of everything. Collapsed, not removed: the pak would have to be rebuilt
    -- to get any of it back.
    for _, name in ipairs(BP_UNUSED_ROWS) do
        if parts[name] then
            pcall(function() parts[name]:SetVisibility(1) end)
        end
    end

    -- Both lists visible. The commandlet ships ItemList collapsed, so that
    -- the shell looked like the rules screen rather than both at once, and a
    -- collapsed container renders none of its children however many the panel
    -- puts in it - the picker came up with its headings and no tiles at all.
    -- Which list has rows in it is the panel's business, and it empties the
    -- one it is not showing.
    for _, name in ipairs({ "RuleList", "ItemList" }) do
        if parts[name] then
            pcall(function() parts[name]:SetVisibility(0) end)
            -- Automatic, not Fill. The commandlet gave both lists
            -- ESlateSizeRule::Fill, which was right for a shell with nothing
            -- in it and wrong the moment one had rows: two Fill siblings each
            -- take half of Body whatever they contain, so an empty RuleList
            -- still held half the panel and started the picker in the middle
            -- of it. Automatic sizes each to its own content, which is what
            -- makes emptying one actually give the space back.
            pcall(function()
                parts[name].Slot:SetSize({ Value = 1.0, SizeRule = 0 })
            end)
        end
    end

    -- The commandlet sized the backdrop 900 wide because that looked right
    -- for an empty shell. The panel's columns span 1050 and run to a Remove
    -- at the far end, so on the first filled list the status column was cut
    -- off mid word and Remove was missing entirely. Set here rather than in
    -- the pak: it is the panel that knows how wide the panel is, and a number
    -- baked into a cooked asset can only be changed by rebuilding it.
    widget, tree, canvas = made, made_tree, parts.Root
    widget_path = mine and mine:match("%s(.+)$")
    if not widget_path then return give_up("bppath", "the blueprint has no resolvable name") end
    lifecycle.owners[mine] = true
    M.generation = M.generation + 1
    M.parts = parts
    M.fit_width()

    -- Show it if the panel is already open on the widget this just replaced.
    --
    -- Collapsed is right at world load, where this normally runs and nothing
    -- is open. It is wrong when the class arrives mid session - which is what
    -- host() re-asking after a reload now makes possible - because M.open
    -- stays true while the widget carrying it has been swapped for a
    -- collapsed one. The panel then reports open=true with nothing on screen,
    -- and the only way back was another toggle.
    --
    -- The input mode does not need re-asserting: it lives on the player
    -- controller rather than the widget, so it survived the swap. Focus does
    -- not, because focus was given to the widget that is now gone.
    if M.open then
        if not native_active(made, true) then
            M.hide()
            return give_up("bpactivate", "the panel action router did not activate")
        end
        pcall(function() made:SetVisibility(0) end)
        pcall(function() made:SetKeyboardFocus() end)
    end
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
    if not M.open then return end
    local requested = life.generation
    if bp_state ~= "unasked" then return end
    bp_state = "asking"

    M.mod_class(BP_PACKAGE, BP_ASSET, function(class)
        if requested ~= life.generation or not M.open then return end
        if api.has_viewport and api.has_viewport() ~= true then
            M.hide()
            return
        end
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
            -- The class is loaded now, so the hook path resolves.
            M.hook_pad()
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

    local _, failed_detach = sweep_panels()
    if failed_detach > 0 then
        warn_once("duplicate", "an earlier panel could not detach; refusing another attachment")
        return false
    end
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
    local full = made:GetFullName()
    widget_path = full:match("%s(.+)$")
    lifecycle.owners[full] = true
    M.generation = M.generation + 1
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
-- host() reports where its own time goes, worst in a five second window.
--
-- The refresh timer already blamed "setup", but setup is ensure_root and
-- ensure_root is almost entirely this function; 9.6ms of a 22ms setup is the
-- controller lookup, and the other 12 had no name. Guessing which line it is
-- has already cost one wrong attribution today.
local hp_worst, hp_at, hp_parts = 0, 0, ""

local function hp_report(total, parts)
    if total > hp_worst then hp_worst, hp_parts = total, parts end
    local now = os.clock()
    if (now - hp_at) < 5 then return end
    hp_at = now
    if hp_worst > 2 then
        log.say(string.format("overlay: host worst %.1fms  (%s)",
            hp_worst, hp_parts))
    end
    hp_worst, hp_parts = 0, ""
end

-- Resolve the root afresh. A matching controller/name is not evidence that a
-- wrapper retained by Lua survived collection or a world transition.
function M.resolve_owned()
    M.native_cancel = false
    widget, tree, canvas = nil, nil, nil
    M.parts = nil
    if not widget_path then return nil end
    local fresh
    local ok = pcall(function()
        -- Visible roots come from the current viewport, avoiding a full UObject
        -- lookup on every refresh. Closed/detached or unsupported roots retain
        -- the old resolver; an empty viewport is not proof they were destroyed.
        if M.open then fresh = require('widget_lookup').owned(widget_path) end
        if not alive(fresh) then fresh = StaticFindObject(widget_path) end
    end)
    if not ok or not alive(fresh) then return nil end
    local fresh_tree, fresh_canvas
    ok = pcall(function()
        fresh_tree = fresh.WidgetTree
        fresh_canvas = fresh_tree.RootWidget
    end)
    if not ok or not alive(fresh_tree) or not alive(fresh_canvas) then return nil end
    widget, tree, canvas = fresh, fresh_tree, fresh_canvas
    M.native_cancel = M.open and input_contract(fresh)
    if bp_state == "hosted" then M.parts = collect_parts(fresh) end
    return canvas, tree, widget
end

function M.host()
    if not M.open then return nil end
    local started = os.clock()
    local now_owner = owner_name()
    if not now_owner then return nil end
    if built_under ~= nil and now_owner ~= built_under then
        widget_path, built_under = nil, nil
        widget, tree, canvas, M.parts = nil, nil, nil, nil
        fitted = nil
        M.generation = M.generation + 1
        if bp_state == "hosted" then bp_state = "unasked" end
    end
    if M.resolve_owned() then
        if M.parts then M.fit_width() end
        hp_report((os.clock() - started) * 1000, "fresh root and tree (inclusive)")
        return canvas, tree, widget
    end
    widget_path, fitted = nil, nil
    if bp_state == "hosted" then bp_state = "unasked" end
    if bp_state == "unasked" then M.prepare() end
    -- prepare may answer synchronously and close on activation failure.
    -- Do not rebuild a fallback after that close invalidated this opening.
    if not M.open then return nil end
    if M.resolve_owned() then return canvas, tree, widget end
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
-- Stop the character without taking the input mode away.
--
-- This is the whole reason Game-and-UI was rejected. The comment on the shapes
-- table says it plainly: the panel took clicks and the character still ran
-- around behind it, so it read as a decal rather than a screen. True, and the
-- conclusion drawn from it - use UI-only instead - turned out to cost more
-- than it bought. UI-only routes every key and every pad button into Slate,
-- so the PlayerController sees nothing at all, which is why the arrow keys
-- have never worked in this panel and why a controller cannot drive it.
--
-- FreeCam suppresses the PAWN instead and keeps the game's own input mode,
-- which is exactly why it can read a gamepad while this cannot. Same three
-- calls here, under our own flag name.
--
-- SetIgnoreMoveInput is on the controller, the other two are on the pawn, and
-- all three are reflected and proven on this build by FreeCam running beside
-- us. Deliberately NOT SetActorEnableCollision, which FreeCam also calls: it
-- needs the body out of the way of building previews, we only need it to stop
-- walking, and dropping a player's collision to open a menu is the kind of
-- side effect that ends with someone under the map.
local flag_name
local function pwp_flag()
    if flag_name == nil then
        pcall(function() flag_name = FName("PalWorkPriority") end)
        if flag_name == nil then flag_name = false end
    end
    if flag_name == false then return nil end
    return flag_name
end

M.pawn_held = false

local function suppress_pawn(on, force)
    on = (on == true)

    -- Once per state change, never once per call.
    --
    -- SetIgnoreMoveInput is REFERENCE COUNTED in UE, not a boolean:
    -- IgnoreMoveInput = max(IgnoreMoveInput + (b and 1 or -1), 0). And
    -- set_input_now(true) calls this, while reassert_input calls
    -- set_input_now(true) again from the panel refresh whenever it finds the
    -- cursor taken. Every one of those pushed the counter up and only a close
    -- pushed it down, so a session that reasserted more than once left the
    -- count stuck above zero, and the character silently could not walk even
    -- after the panel was shut. The clamp at zero means the surplus never
    -- drains on its own.
    --
    -- Latent rather than active so far, because reassert_input has a guard
    -- that fires rarely. It is the same shape as the bug that cost this
    -- morning, so it goes now rather than when it finally bites.
    --
    -- `force` exists because the two escape hatches must not be silenced by
    -- this. release_pawn and force_release are for the case where these flags
    -- have ALREADY disagreed with the game, and M.pawn_held is the likeliest
    -- one to be wrong: a close that runs while the controller is momentarily
    -- unresolvable returns early, leaving the flag true and the game
    -- suppressed, and a module swap then resets the flag to false while the
    -- game still holds the count. Both hatches were returning their success
    -- strings and doing nothing.
    if M.pawn_held == on and not force then return true end

    local pc = api.player_controller()
    if not alive(pc) then return false end

    -- K2_GetPawn first, the property second. Both are read here, in this call,
    -- and neither is kept.
    local pawn
    pcall(function() pawn = pc:K2_GetPawn() end)
    if not alive(pawn) then pcall(function() pawn = pc.Pawn end) end

    pcall(function() pc:SetIgnoreMoveInput(on) end)

    -- DisableInput on the controller, again, and this time it is safe.
    --
    -- Without it the pad reaches the game while the panel is up: the d-pad
    -- opens the build menu behind an open panel. The overlay gate does not
    -- stop that, because it only REPORTS state and Palworld evidently does
    -- not gate its own actions on that report.
    --
    -- The first attempt at this broke the game: a disabled controller ignores
    -- every menu the game draws, so with the inventory open the player could
    -- not click anything. What makes it safe now is that the two can no
    -- longer coexist. panel.lua closes this panel the moment the game opens
    -- UI of its own, so there is never a game menu sitting under a disabled
    -- controller. Coexistence was the bug, not the call.
    --
    -- That is also BreedingHelper's answer, arrived at from the other end:
    -- it disables input and simply prevents the menus being reachable.
    if on then
        pcall(function() pc:DisableInput(pc) end)
    else
        pcall(function() pc:EnableInput(pc) end)
    end

    -- Kept for the record: the reasoning that took this out.
    --
    -- It was here for one afternoon and it broke the game: with the panel open
    -- the player could not click anything in their own inventory, because a
    -- disabled controller ignores every menu the game draws, not just the pad
    -- buttons that were leaking into gameplay. It did stop the leak. It also
    -- took the game's UI down with it, which is far worse than the leak.
    --
    -- The leak is answered by main.lua's overlay gate instead, which tells the
    -- game an overlay UI is already active while this panel is open. That is
    -- BreedingHelper's shape, and the difference is the whole point: it does
    -- not TAKE input away, it tells the game something true about the state of
    -- the screen and lets the game suppress its own actions. Menus keep
    -- working because nothing was disabled.
    --
    -- EnableInput on release stays, over in set_input_now. It is a no-op when
    -- nothing disabled input, and the morning was spent on a session where
    -- something had.

    if alive(pawn) then
        if on then
            pcall(function() pawn:DisableInput(pc) end)
        else
            pcall(function() pawn:EnableInput(pc) end)
        end
        local f = pwp_flag()
        if f then
            pcall(function() pawn:SetDisablePlayerInput(f, on) end)
        end
    end

    M.pawn_held = on
    return true
end

-- Reachable from outside, because the one thing worse than a panel that will
-- not open is a character that will not walk. force_release calls it too.
function M.release_pawn()
    suppress_pawn(false, true)
    return "pawn input restored"
end

-- Preserve three states even if an integration getter throws. Unknown
-- cannot authorize taking the cursor or focus away from a vanilla menu.
function M.vanilla_ui()
    local ok, value = pcall(function() return api.game_ui_active end)
    if ok and type(value) == "boolean" then return value end
    return nil
end

local function set_input_now(on)
    local game_ui = M.vanilla_ui()
    if not on and life.phase == "handoff" then game_ui = nil end
    local pc = api.player_controller()
    if not alive(pc) then return end

    pcall(function()
        if on then
            if cursor_was == nil then cursor_was = pc.bShowMouseCursor end
            pc.bShowMouseCursor = true
        elseif cursor_was ~= nil then
            -- Not if the game is showing its own UI.
            --
            -- cursor_was is what the cursor was before THIS panel opened, and
            -- restoring it blindly assumes nothing happened in between. Open
            -- the panel, open the inventory, close the panel, and that
            -- assumption puts the cursor back to false while the inventory is
            -- still up - so the menu is there and there is nothing to click it
            -- with. Reported from a real session, not imagined.
            --
            -- api.game_ui_active is the game's own answer to "is an overlay
            -- active", recorded by main.lua's gate before that gate overrides
            -- it. When the game has UI up, the cursor is the game's business
            -- and the honest thing is to leave it alone. cursor_was is still
            -- cleared, because the record has served its purpose either way.
            -- One condition for all three, which is what was wrong before:
            -- the cursor flag was guarded and the two statements that actually
            -- hid the pointer were not.
            if game_ui == false then
                pc.bShowMouseCursor = cursor_was
            end
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
        --
        -- Not while the game has its own UI up, and this is THE bug rather
        -- than a precaution. GameOnly turns on high precision mouse movement,
        -- and Slate hides the platform cursor for that BELOW the level
        -- bShowMouseCursor works at. Proven from a session log: the close path
        -- left the cursor flag true, watch_cursor recorded no change for four
        -- seconds, and the pointer was gone the whole time. Every theory about
        -- restoring the flag was fixing a statement that was never the cause.
        --
        -- So when a menu of the game's own is open, its input mode is its
        -- business and this leaves it alone. With nothing open, GameOnly is
        -- still exactly right and still runs.
        local restored = true
        if game_ui == false then
            local ok, result = pcall(function() return lib:SetInputMode_GameOnly(pc, false) end)
            restored = ok and result ~= false
        end

        -- And the focus, which the input mode does not carry.
        --
        -- show_now calls SetKeyboardFocus on the panel widget, and
        -- build_blueprint does the same when it replaces a widget while the
        -- panel is open. Nothing gave that focus back. SetInputMode_GameOnly
        -- changes the MODE; Slate goes on routing keys and clicks to whatever
        -- last held focus, so a widget that is then collapsed - which closing
        -- the panel does - keeps it, and every menu the game draws afterwards
        -- is unclickable. Escape still works, because that is a raw key, which
        -- is exactly what makes it look like the game rather than the mod.
        --
        -- Taking focus is fine. Not handing it back was the bug, so it is
        -- handed back here, on the one path every close goes through.
        -- And the input itself, which is neither the mode nor the focus.
        --
        -- Measured 25 August, with the panel shut and every flag this module
        -- owns already clean - open false, widget not even alive, cursor
        -- false, route nil - and the game's menus still dead. Nothing here
        -- was holding anything, so nothing here could give it back either.
        --
        -- bInputEnabled on the controller is a third piece of state, separate
        -- from both. SetInputMode says where input is ROUTED and
        -- SetFocusToGameViewport says who HOLDS it, and neither says whether
        -- the controller accepts any, so a controller left with input
        -- disabled ignores the pause menu, the inventory and every click,
        -- while Escape keeps working because it is a raw key. That is the
        -- reported symptom exactly, and it survives closing the panel.
        --
        -- BreedingHelper restores all three on this same build and has never
        -- shown this; we restored two. It is idempotent when input was
        -- already enabled, so it costs nothing on the normal path.
        pcall(function() pc:EnableInput(pc) end)

        -- And the pawn, which was suppressed so the character would stand
        -- still while the panel is up. Released on the same one path every
        -- close goes through, for the same reason EnableInput is here.
        pcall(function() suppress_pawn(false) end)

        -- Same condition: this yanks focus off EVERY widget, including one
        -- the game owns, which is a global assertion this module cannot make
        -- safely while someone else's menu is up.
        if game_ui == false then
            local ok, result = pcall(function() return lib:SetFocusToGameViewport() end)
            restored = restored and ok and result ~= false
        end

        input_route = nil
        life.route = nil
        if restored then life.release = nil end
        return restored
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
    -- Game and UI first now, which reverses what the long comment above
    -- describes. That comment is kept because its reasoning was right and only
    -- its conclusion was wrong: the character really did run around behind an
    -- open panel, and that really is unacceptable. The fix is suppress_pawn,
    -- not UI-only.
    --
    -- Measured 25 August, panel open, watch proven alive by its own heartbeat:
    --
    --   UIOnlyEx      keyboard silent, pad silent
    --   GameAndUIEx   keyboard reads,  pad silent
    --
    -- Under UI-only the PlayerController sees nothing whatsoever, which is
    -- documented UE behaviour rather than a quirk here: a UI-only mode routes
    -- keys and pad buttons into Slate's focus framework instead of the input
    -- stack. That is why the arrow keys this panel advertises have never once
    -- worked, and no amount of rebinding them could have fixed it.
    local shapes = {
        { "GameAndUIEx(pc, widget, 0, false, false)",
          function() return lib:SetInputMode_GameAndUIEx(pc, widget, 0, false, false) end },
        { "UIOnlyEx(pc, widget, 0, false)",
          function() return lib:SetInputMode_UIOnlyEx(pc, widget, 0, false) end },
    }

    if M.prefer_ui_only then
        shapes[1], shapes[2] = shapes[2], shapes[1]
    end

    -- The character stands still while the panel is up. This is what buys back
    -- everything the UI-only route was chosen to provide.
    pcall(function() suppress_pawn(true) end)

    for _, shape in ipairs(shapes) do
        local ok, result = pcall(shape[2])
        if ok and result ~= false then
            local identified, name, address = pcall(function()
                return pc:GetFullName(), pc:GetAddress()
            end)
            life.input_owner = identified and type(name) == "string" and name ~= ""
                and type(address) == "number" and math.tointeger(address) and address > 0
                and {name = name, address = address, epoch = session.epoch} or nil
            if input_route ~= shape[1] then
                input_route = shape[1]
                log.debug("overlay input mode via " .. shape[1])
            end
            return true
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
-- The backdrop, sized to whatever the panel currently says it is.
--
-- This used to run once, inside the build. That is one moment, and it is the
-- wrong one to depend on: M.width is pushed across from panel.lua when its
-- chunk loads, so any build that happened before that - or a widget that
-- survived a reload which replaced the module table under it - kept whatever
-- size it was built with. The visible symptom was the panel's own Remove
-- column hanging off a backdrop still cut for the older, narrower layout.
--
-- Idempotent and guarded on the value, so calling it from host() every time
-- costs one table read on the settled path and repairs itself on any other.
-- Set from panel.lua's input diagnostics to force the UI-only route.
--
-- Declared here for the same reason as icons.on_sweep: overlay owns this table,
-- and a field written by one module and read by another belongs to whoever
-- reads it as state. Undeclared, a rename would have quietly reverted the route
-- to Game-and-UI with nothing said - and the whole input model turns on it.
M.prefer_ui_only = false

-- The height the panel currently needs. Set by panel.lua before it draws.
--
-- 700 was a literal here. Measured on a two rule list, the drawn content ended
-- 451 pixels above the bottom edge - 64% of the panel was empty fill, and the
-- void was nearly twice the content. Two rules floating in the top third of a
-- fixed slab does not read as a spacious design, it reads as the rest having
-- failed to load.
M.height = 700


local fitted_h

function M.fit_width()
    local parts = M.parts
    if not (parts and M.width) then return end

    local want_h = math.floor(M.height or 700)
    if want_h < 220 then want_h = 220 end
    if want_h > 700 then want_h = 700 end

    if fitted == M.width and fitted_h == want_h then return end
    if not alive(parts.Backdrop) then return end

    local ok, result = pcall(function()
        local slot = parts.Backdrop.Slot
        if slot then
            -- Size only. NOT position, and NOT alignment.
            --
            -- The slot is centre ANCHORED and centre ALIGNED, so it grows
            -- equally in both directions and the top edge follows half of any
            -- height change. That does mean the tab strip shifts between a
            -- short list and a tall one - measured at 181 pixels between the
            -- rules list and the picker - and an audit called that out as a
            -- defect worth fixing.
            --
            -- It was fixed, by pinning the top edge, and the result was worse
            -- to actually look at: the panel sat high and the tall picker hung
            -- a long way down the screen. Reverted on the user's say-so, which
            -- outranks the audit here - where a window sits is a matter of
            -- taste and they are the one looking at it.
            --
            -- So the jump stays, knowingly. If it is ever worth another go,
            -- the answer is a shell that reserves its full height and lets the
            -- list scroll inside it, not arithmetic on the slot.
            return slot:SetSize({ X = M.width + 36, Y = want_h })
        end
        return false
    end)
    if ok and result ~= false then
        fitted, fitted_h = M.width, want_h
    end
end


-- The backdrop's size as last fitted, plain numbers. Its slot is centre
-- anchored and aligned at offset 0,0 (the commandlet's), so this is all the
-- panel's pointer map needs to place it. nil before the first fit.
function M.backdrop_size()
    if fitted == nil or fitted_h == nil then return nil end
    return fitted + 36, fitted_h
end

function M.release_input()
    return set_input_now(false)
end

-- Put the game back whatever this module thinks it did.
--
-- set_input_now(false) restores the cursor only "elseif cursor_was ~= nil", so
-- once that record is lost the cursor stays forced on and nothing here will
-- ever put it back. The input mode is separately handed to SetInputMode_GameOnly,
-- which does not care what we remembered - so the two halves can disagree, and
-- the half that strands a player is the cursor.
--
-- This asks for neither and asserts both: cursor off, game-only input, records
-- cleared. It is what "!pwp panel unstick" runs, and it is deliberately not
-- conditional on M.open, because the state it exists to fix is one where those
-- flags already disagree with the game.
function M.force_release()
    M.resolve_owned()
    local pc = api.player_controller()
    if not alive(pc) then return "no player controller" end

    pcall(function() pc.bShowMouseCursor = false end)

    local lib = api.cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
    if lib then
        pcall(function() lib:SetInputMode_GameOnly(pc, false) end)
        -- Focus back to the viewport, explicitly.
        --
        -- This is the half that strands a session. show_now calls
        -- SetKeyboardFocus on the panel widget, and build_blueprint does too
        -- when it replaces a widget while the panel is open. Setting the input
        -- mode does not hand that focus back, so a widget that is then
        -- collapsed or taken off the viewport keeps it - and Slate goes on
        -- routing to a target that draws nothing. Escape still works because
        -- it is a raw key; every click and every menu does not.
        pcall(function() lib:SetFocusToGameViewport() end)
    end

    -- And the input itself. See set_input_now: this is the third piece of
    -- state, and the only one that stays broken after the panel is gone.
    pcall(function() pc:EnableInput(pc) end)

    -- And the pawn. A player who cannot walk is worse off than one who cannot
    -- click, so unstick has to cover this too. Forced, for the same reason
    -- this whole function is not conditional on M.open.
    pcall(function() suppress_pawn(false, true) end)

    -- The widget too: a collapsed widget still holding keyboard focus is the
    -- other way input goes nowhere.
    if alive(widget) then
        pcall(function() widget:SetVisibility(1) end)
    end

    -- Every WBP_WorkRules in memory off the viewport, not just the one this
    -- module currently holds.
    --
    -- build_blueprint already does this for the instance it is replacing, and
    -- the reason is written there: every build adds one at ZOrder 9000 and
    -- nothing removes it. A session that has reloaded twenty times has had
    -- twenty of them built. Any one still parented and visible sits over the
    -- game at ZOrder 9000 taking hit tests, which is a pause menu that draws
    -- and cannot be clicked - and it survives every input mode change, because
    -- the input mode is not what is eating the click.
    --
    -- Objects come from FindAllOf inside this call and none is kept.
    local swept = sweep_panels()

    widget, tree, canvas = nil, nil, nil
    widget_path = nil
    M.parts = nil
    fitted = nil
    built_under = nil
    M.generation = M.generation + 1
    if bp_state == "hosted" then bp_state = "unasked" end

    cursor_was, input_route = nil, nil
    M.open, M.phase = false, "closed"
    life.phase, life.route = "closed", nil
    life.generation = life.generation + 1
    return string.format(
        "input forced back to the game, %d panel widget(s) taken off the "
        .. "viewport", swept)
end

-- Three early returns, so the mark is owned by a wrapper here too.
local function set_input(on)
    return traced("overlay: set_input " .. tostring(on), function()
        return set_input_now(on)
    end)
end

local function show_now()
    if api.has_viewport and api.has_viewport() ~= true then return false end
    if M.phase == "close_failed" and not M.hide() then return false end
    if M.open and M.resolve_owned() then return true end
    life.release = nil
    M.open, M.phase = true, "opening"
    lifecycle.open(life)
    if M.host() == nil or not M.open then
        -- Keep close_failed/handoff when construction already closed itself.
        if M.open then M.hide() end
        return false
    end
    if not native_active(widget, true) then
        warn_once("activate", "panel action routing could not activate")
        M.hide()
        return false
    end
    local ok = pcall(function() widget:SetVisibility(0) end)
    if not ok then M.hide() return false end
    if set_input(true) ~= true then M.hide() return false end
    M.native_cancel = input_contract(widget)
    life.route = input_route
    pcall(function() widget:SetKeyboardFocus() end)
    M.phase = "open"
    return true
end

function M.show()
    return traced("overlay: showing the panel", show_now)
end

function M.hide()
    M.native_cancel = false
    if not M.open and (M.phase == "closed" or M.phase == "handoff") then return false end
    M.open = false
    lifecycle.close(life, M.vanilla_ui())
    M.phase = life.phase
    -- No hidden backdrop remains attached for photo mode to reveal. Resolve
    -- through the current tree, detach, then forget every collectable handle.
    local _, _, fresh = M.resolve_owned()
    local removed = true
    if fresh then
        local name = fresh:GetFullName()
        local detached, result = pcall(function()
            if not native_active(fresh, false) then return false end
            local known, version = pcall(function() return fresh.PWP_InputContract end)
            if known and (version == 3 or version == 4) then
                local cleared = pcall(function() fresh.PWP_AmountEditor = nil end)
                if not cleared then warn_once("editorclear", "editor reference could not clear; detaching its inactive panel") end
            end
            if fresh:SetVisibility(1) == false then return false end
            return fresh:RemoveFromParent()
        end)
        if detached and result ~= false then lifecycle.owners[name] = nil end
        removed = detached and result ~= false
    end
    life.release = nil
    if input_route and life.input_owner and life.phase == "closed" and M.vanilla_ui() == false then
        life.release = {owner = life.input_owner, generation = M.generation + 1, remaining = 3}
    end
    set_input(false)
    widget, tree, canvas, M.parts = nil, nil, nil, nil
    if removed then widget_path = nil end
    built_under, fitted = nil, nil
    M.generation = M.generation + 1
    if bp_state ~= "absent" then bp_state = "unasked" end
    if not removed then
        M.phase = "close_failed"
        warn_once("detach", "panel detachment failed; another panel will not be opened over it")
    end
    return removed
end

-- Retry only an explicitly pending restoration from our own failed close.
-- Cursor visibility or a closed panel alone never authorizes input changes.
-- The scalar record binds controller name/address, session and generation;
-- no engine handle survives callbacks. There are at most three retries.
-- Fresh known gameplay state is required before each write. Unknown state,
-- vanilla UI or lost ownership permanently cancels this record. An old
-- callback may never clear a replacement record created during reentrancy.
function M.recovery_controller(pending)
    local ok, pc = pcall(api.player_controller)
    local identified, name, address = pcall(function()
        if alive(pc) then return pc:GetFullName(), pc:GetAddress() end
    end)
    if not ok or not identified or name ~= pending.owner.name
        or address ~= pending.owner.address or session.epoch ~= pending.owner.epoch
        or life.release ~= pending or M.open or life.phase ~= "closed"
        or M.generation ~= pending.generation or M.vanilla_ui() ~= false then
        if life.release == pending then life.release = nil end
        return nil
    end
    return pc
end

function M.watch_input()
    local pending = life.release
    if not pending then return false end
    if pending.remaining <= 0 or not M.recovery_controller(pending) then
        if life.release == pending then life.release = nil end
        return false
    end
    pending.remaining = pending.remaining - 1
    local got, lib = pcall(api.cdo, "/Script/UMG.Default__WidgetBlueprintLibrary")
    -- Resolving the library and each native call can run other code. Recheck
    -- authority after every boundary and before the next input write.
    local pc = M.recovery_controller(pending)
    if not pc then return false end
    local restored = false
    if got and lib then
        local ok, result = pcall(function() return lib:SetInputMode_GameOnly(pc, false) end)
        restored = ok and result ~= false
        pc = M.recovery_controller(pending)
        if not pc then return false end
        if restored then
            ok, result = pcall(function() return lib:SetFocusToGameViewport() end)
            restored = ok and result ~= false
            if not M.recovery_controller(pending) then return false end
        end
    end
    if restored or pending.remaining <= 0 then if life.release == pending then life.release = nil end end
    return restored
end

-- Apply the current preference now, without closing anything.
function M.reapply_input()
    if not M.resolve_owned() then return "the panel is unavailable" end
    if not M.open then return "the panel is shut" end
    input_route = nil
    pcall(function() set_input_now(true) end)
    return "route is now " .. tostring(input_route)
end

-- Who turns the cursor off, and when.
--
-- The release path now logs its own decision, so if the cursor still vanishes
-- after it decided to leave it alone, something later did it. This says so
-- rather than leaving that as the only remaining theory.
M.cursor_log_last = nil

function M.watch_cursor()
    local pc = api.player_controller()
    if not alive(pc) then return end

    local now
    pcall(function() now = pc.bShowMouseCursor end)
    if now == M.cursor_log_last then return end

    log.debug(string.format("cursor went %s (panel open=%s, game_ui=%s)",
        tostring(now), tostring(M.open), tostring(api.game_ui_active)))
    M.cursor_log_last = now
end

-- The shell takes the keyboard back, from a text box that had it (Escape in
-- the panel's search box ends the typing). Resolved fresh, never kept.
function M.focus_shell()
    local _, _, fresh = M.resolve_owned()
    if not fresh then return false end
    return pcall(function() fresh:SetKeyboardFocus() end)
end

function M.reassert_input()
    if not M.open or M.vanilla_ui() ~= false then return false end
    local pc = api.player_controller()
    if not alive(pc) then return false end

    local cursor
    pcall(function() cursor = pc.bShowMouseCursor end)
    if cursor ~= false then return false end
    if not M.resolve_owned() then return false end

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
    M.native_cancel = false
    life.generation = life.generation + 1
    life.phase, life.route = "closed", nil
    M.phase = "closed"
    M.generation = M.generation + 1
    widget_path = nil
    -- Put the game back BEFORE forgetting how.
    --
    -- This used to clear cursor_was and input_route and set M.open = false
    -- without releasing anything, and reload.lua calls it on every swap. So a
    -- reload with the panel open left the game in UI-only input with the
    -- cursor forced on, and threw away the record needed to undo either -
    -- set_input_now(false) restores the cursor only "elseif cursor_was ~= nil".
    -- After that no amount of opening and closing the panel could fix it,
    -- which is exactly how it presented: a session that worked after a restart
    -- and degraded as reloads accumulated.
    --
    -- Order matters. Release first, sweep second, forget last.
    pcall(function() set_input_now(false) end)
    pcall(sweep_panels)

    widget, tree, canvas = nil, nil, nil
    M.parts = nil
    fitted = nil
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
    ExecuteInGameThread(session.guard(function()
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
    end))
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
    M.resolve_owned()
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
    if widget then
        local ok, detail = pcall(function()
            local editor = widget.PWP_AmountEditor
            return string.format("contract=%s pending=%s held=%s focus=%s descendants=%s editor=%s",
                tostring(widget.PWP_InputContract), tostring(widget.PWP_CancelRequested),
                tostring(widget.PWP_EditorEscapeHeld), tostring(widget:HasAnyUserFocus()),
                tostring(widget:HasFocusedDescendants()), tostring(editor and editor:IsValid()))
        end)
        log.say("  native editor:    " .. (ok and detail or "unavailable"))
    end

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
