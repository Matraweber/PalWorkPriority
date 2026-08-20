-- The work rules panel.
--
-- A rule is "work this job until the base holds N of an item, then move on".
-- No rule means unlimited, which is what every work type starts as.
--
-- This is a separate surface from the grid on the Monitoring Stand. The grid
-- answers "who does what first", the panel answers "how much is enough", and
-- the two need different shapes: a rule names an item, and there is nowhere
-- in a per-pal-per-work grid for an item to live.
--
-- Styled after the Creative Menu mod: a dark slab, one row per entry, a cyan
-- accent on whatever the mouse is over. That mod ships as a pak of
-- blueprints, so none of its widgets can be reused, only the look.
--
-- Widgets are constructed against the WidgetTree, never against the canvas
-- they are parented into. A UMG widget belongs to a tree; giving one a canvas
-- as its outer leaves it owned by something that does not keep widgets alive,
-- and the renderer then walks a freed object and takes the game with it.

local log = require("log")
local api = require("palapi")
local caps = require("caps")
local items = require("items")
local workdefs = require("workdefs")
local ui = require("ui")

local M = {}

M.open = false
M.wants_pass = false

-- "list"  the rules themselves
-- "item"  choosing what a new rule is about
-- "work"  choosing which job that rule gates
local mode = "list"
local draft = nil               -- { item = string } while a rule is being made
local page = 0
local show_all = false          -- the picker starts on what the base holds

local root = nil                -- the canvas we hang off
local root_owner = nil          -- the layout it belongs to, to spot a swap
local root_tree = nil           -- that layout's WidgetTree, our outer
local backdrop = nil
local blocks = {}               -- key -> TextBlock
local drawn = {}                -- key -> last token drawn
local hits = {}                 -- key -> what clicking it means
local order = {}                -- the same keys in draw order, for the arrows
local used = {}                 -- keys touched this frame, so the rest blank
local hover_key = nil

-- Last frame's answers. A row is registered as clickable AFTER it is drawn,
-- so asking about this frame during the draw always returns nothing. One
-- frame of lag on a marker is invisible; reordering every call site and
-- trusting nobody ever adds one in the wrong order is not.
local was_hit = {}
local was_sel = nil
local sel = 1                   -- which row the keyboard is on

local ftext_mode = nil
local warned = {}

-- LINE has to clear the font, which is about 20 tall at 1440p. At 22 the
-- rows drew through each other.
local X, Y = 80, 130
local W = 760
local LINE = 34
local PAD = 16
local COL2 = 420
local PER_PAGE = 12

local COLOUR = {
    title  = { R = 1.00, G = 1.00, B = 1.00, A = 1.00 },
    dim    = { R = 0.58, G = 0.62, B = 0.70, A = 1.00 },
    item   = { R = 0.86, G = 0.89, B = 0.95, A = 1.00 },
    met    = { R = 0.30, G = 0.95, B = 0.40, A = 1.00 },
    unmet  = { R = 1.00, G = 0.70, B = 0.20, A = 1.00 },
    action = { R = 0.40, G = 0.82, B = 1.00, A = 1.00 },
    hover  = { R = 0.35, G = 1.00, B = 1.00, A = 1.00 },
}

-- Amounts run into the thousands, so a step walks a ladder that coarsens as
-- the numbers grow rather than moving by one.
local LADDER = {
    100, 250, 500, 1000, 2000, 3000, 5000,
    7500, 10000, 15000, 20000, 30000, 50000,
}

local BACKDROP = { R = 0.03, G = 0.05, B = 0.08, A = 0.90 }
local CLEAR = { R = 0.00, G = 0.00, B = 0.00, A = 0.00 }

-- Registers a row as clickable and, in the same breath, as reachable by the
-- arrow keys. Two lists that could disagree would be a bug waiting, and the
-- mouse turned out to be awkward enough on a moving cursor that the keyboard
-- is not a nicety.
local function hit(key, what)
    hits[key] = what
    order[#order + 1] = key
end

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

local function class_name(o)
    local n
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

local function make_ftext(str)
    if ftext_mode == "direct" or ftext_mode == nil then
        local ft
        if pcall(function() ft = FText(str) end) and ft then
            ftext_mode = "direct"
            return ft
        end
    end

    local ft
    local ok = pcall(function()
        local kismet = api.cdo("/Script/Engine.Default__KismetTextLibrary")
        if kismet then ft = kismet:Conv_StringToText(str) end
    end)
    if ok and ft then
        ftext_mode = "kismet"
        return ft
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Attaching to the game's UI
-- ---------------------------------------------------------------------------

-- Depth-first search for the first CanvasPanel, which is what a widget can be
-- added to by coordinates.
local function first_canvas(node, budget)
    budget = budget or { n = 0 }
    if budget.n > 400 or not alive(node) then return nil end
    budget.n = budget.n + 1

    if class_name(node) == "CanvasPanel" then return node end

    local count = 0
    pcall(function() count = node:GetChildrenCount() end)
    if type(count) == "number" then
        for i = 0, count - 1 do
            local child
            pcall(function() child = node:GetChildAt(i) end)
            local found = first_canvas(child, budget)
            if found then return found end
        end
    end
    return nil
end

-- The panel lives on the Monitoring Stand's own menu.
--
-- It used to hang off WBP_PalOverallUILayout_C, the persistent HUD, so it
-- could be opened anywhere. That cost two crashes, both inside UE4SS and both
-- within seconds of the panel being opened, and the reason is that the HUD is
-- rebuilt as its own state changes. When it is, every widget we parented into
-- it is destroyed, and the next refresh reaches a freed object. alive() is no
-- defence there, because IsValid is itself a call on the dead wrapper and a
-- call on a freed object is exactly what pcall cannot catch.
--
-- A menu is the opposite kind of host: built when the stand opens, torn down
-- when it closes, and nothing rebuilds it underneath while it is up. The
-- priority grid has injected into it for weeks without incident, and
-- PalPriorityUI injects only there too rather than into the HUD.
--
-- The cost is that rules are set at a Monitoring Stand rather than anywhere.
-- Rules are per base, so that is close to where they belong anyway.
local function ensure_root()
    local menu, tree, base = ui.host()

    if not alive(menu) or not alive(tree) or not alive(base) then
        -- The stand is shut. Keep every reference exactly as it is.
        --
        -- Clearing here was the duplicate: Palworld hides this menu rather
        -- than destroying it, so the widgets stayed parented in a canvas that
        -- outlived our pointers to them. Reopening then found no references,
        -- built a second set, and drew it over the first.
        --
        -- Nothing is touched either, only left alone, so a menu that really
        -- was destroyed cannot be dereferenced from here.
        return nil
    end

    if root_owner == menu and alive(root) and alive(root_tree) then
        return root
    end

    -- Genuinely a different menu object. Whatever we made belonged to the old
    -- one and died with it, so the references are dropped rather than
    -- unparented: asking a freed widget anything is the crash, not the check.
    root, root_owner, root_tree, backdrop = nil, nil, nil, nil
    blocks, drawn = {}, {}

    local canvas = first_canvas(base)
    if not alive(canvas) then
        warn_once("nocanvas", "no canvas on the stand menu, so no rules panel")
        return nil
    end

    root, root_owner, root_tree = canvas, menu, tree
    return root
end

-- A dark slab behind the text. Without one the panel is white words floating
-- over grass, which is exactly what the first version looked like.
local function ensure_backdrop(rows)
    if not ensure_root() then return end

    if not alive(backdrop) then
        local cls = api.cdo("/Script/UMG.Border")
        if not cls or not alive(root_tree) then return end

        pcall(function() backdrop = StaticConstructObject(cls, root_tree) end)
        if not alive(backdrop) then return end

        local slot
        local ok = pcall(function() slot = root:AddChildToCanvas(backdrop) end)
        if not ok or not alive(slot) then
            backdrop = nil
            return
        end

        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetPosition({ X = X - PAD, Y = Y - PAD }) end)
        -- Under the text, over the world.
        pcall(function() slot:SetZOrder(8990) end)
        -- Hit test invisible, so the slab cannot swallow a click meant for a
        -- row sitting on top of it.
        pcall(function() backdrop:SetVisibility(3) end)
    end

    pcall(function() backdrop:SetBrushColor(BACKDROP) end)

    local slot
    pcall(function() slot = backdrop.Slot end)
    if alive(slot) then
        pcall(function()
            slot:SetSize({ X = W + PAD * 2, Y = rows * LINE + PAD * 2 })
        end)
    end
end

local function line(key, row, col, text, colour_key)
    local canvas = ensure_root()
    if not canvas then return end

    used[key] = true

    local tb = blocks[key]
    if not alive(tb) then
        local cls = api.cdo("/Script/UMG.TextBlock")
        if not cls or not alive(root_tree) then return end

        pcall(function() tb = StaticConstructObject(cls, root_tree) end)
        if not alive(tb) then return end

        local slot
        local ok = pcall(function() slot = canvas:AddChildToCanvas(tb) end)
        if not ok or not alive(slot) then return end

        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetSize({ X = W - col, Y = LINE }) end)
        pcall(function() slot:SetZOrder(9000) end)
        pcall(function() tb:SetVisibility(0) end)
        pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)

        blocks[key] = tb
        drawn[key] = nil
    end

    -- Position every frame, not only at construction: a row moves when the
    -- screen above it changes length.
    local slot
    pcall(function() slot = tb.Slot end)
    if alive(slot) then
        pcall(function() slot:SetPosition({ X = X + col, Y = Y + row * LINE }) end)
    end

    local selected = (key == hover_key or key == was_sel)
    local shown = selected and "hover" or colour_key

    -- A marker as well as a colour. Colour alone was not enough to see where
    -- the selection was, least of all on a row that is already blue.
    if was_hit[key] then
        text = (selected and "> " or "  ") .. text
    end

    local token = text .. "|" .. shown
    if drawn[key] ~= token then
        local ft = make_ftext(text)
        if ft then
            pcall(function() tb:SetText(ft) end)
            pcall(function()
                tb:SetColorAndOpacity({
                    SpecifiedColor = COLOUR[shown],
                    ColorUseRule = 0,
                })
            end)
            drawn[key] = token
        end
    end
end

-- Anything not drawn this frame is emptied rather than destroyed. A destroyed
-- widget leaves a dead wrapper behind; an empty one costs nothing. The first
-- version cleared only keys matching one prefix, which is how an item name
-- was left stranded across the rules list.
local function blank_unused()
    for key, tb in pairs(blocks) do
        if not used[key] and drawn[key] ~= "" and alive(tb) then
            local ft = make_ftext("")
            if ft then
                pcall(function() tb:SetText(ft) end)
                drawn[key] = ""
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Stock
-- ---------------------------------------------------------------------------

-- Cached: the panel redraws every second, and reading every container on
-- every loaded base is the most expensive thing this mod does.
local totals_cache = nil
local totals_at = 0
local TOTALS_TTL = 3.0

local function stock_totals(cfg)
    local now = os.clock()
    if totals_cache and (now - totals_at) < TOTALS_TTL then
        return totals_cache
    end

    local opts = {
        include = cfg.counted_containers,
        exclude = cfg.uncounted_containers,
    }

    local totals
    if cfg.storage_scope == "global" then
        totals = (api.all_chest_totals(opts))
    else
        totals = {}
        for _, camp in ipairs(api.base_camps()) do
            local camp_id = api.camp_id(camp)
            if camp_id then
                local part = api.camp_item_totals(api.guid_key(camp_id), opts)
                for id, n in pairs(part or {}) do
                    totals[id] = (totals[id] or 0) + n
                end
            end
        end
    end

    totals_cache, totals_at = totals, now
    return totals
end

-- ---------------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------------

local function rule_list(cfg)
    local out = {}
    for work, by_item in pairs(caps.all(cfg)) do
        for item, amount in pairs(by_item) do
            out[#out + 1] = { work = work, item = item, amount = amount }
        end
    end
    table.sort(out, function(a, b)
        if a.work ~= b.work then return a.work < b.work end
        return a.item < b.item
    end)
    return out
end

local function draw_list(cfg, totals)
    local rules = rule_list(cfg)
    local row = 0

    line("title", row, 0, "WORK RULES", "title")
    row = row + 1
    line("sub", row, 0,
        "click the job to change it, the number to adjust it, remove to delete",
        "dim")
    row = row + 2

    if #rules == 0 then
        line("empty", row, PAD, "no rules yet, every job runs unlimited", "dim")
        row = row + 2
    else
        for i, rule in ipairs(rules) do
            local have = totals[rule.item] or 0
            local met = have >= rule.amount
            local key = "rule" .. i

            line(key, row, PAD, workdefs.label(rule.work), "action")
            line("itm" .. i, row, 190, rule.item, "item")
            line("amt" .. i, row, COL2, string.format("%d / %d%s",
                have, rule.amount, met and "   done" or ""),
                met and "met" or "unmet")

            -- The job is clickable separately from the amount. Rules no
            -- longer ask which job makes a thing, they guess, so there has to
            -- be somewhere to correct the guess.
            line("del" .. i, row, COL2 + 180, "remove", "dim")

            hit(key, { kind = "job", rule = rule })
            hit("amt" .. i, { kind = "rule", rule = rule })
            hit("del" .. i, { kind = "drop", rule = rule })
            row = row + 1
        end
        row = row + 1
    end

    line("new", row, PAD, "+   new rule", "action")
    hit("new", { kind = "new" })
    row = row + 1

    line("close", row, PAD, "x   close", "dim")
    hit("close", { kind = "close" })

    return row + 2
end

local function picker_source(totals)
    if show_all then
        return items.load(), true
    end

    -- What the base actually holds: a dozen or so rather than 2466, and what
    -- a rule is nearly always about. Sorted by quantity, so the things worth
    -- capping are at the top.
    local out = {}
    for id in pairs(totals) do out[#out + 1] = id end
    table.sort(out, function(a, b)
        if totals[a] ~= totals[b] then return totals[a] > totals[b] end
        return a < b
    end)
    return out, false
end

local function draw_item_picker(cfg, totals)
    local source, everything = picker_source(totals)
    local pages = math.max(1, math.ceil(#source / PER_PAGE))
    if page >= pages then page = pages - 1 end
    if page < 0 then page = 0 end

    local row = 0
    line("title", row, 0, "NEW RULE   pick an item", "title")
    row = row + 1
    line("sub", row, 0, string.format("%s,  %d item(s),  page %d of %d",
        everything and "every item in the game" or "what your storage holds",
        #source, page + 1, pages), "dim")
    row = row + 2

    local from = page * PER_PAGE + 1
    for i = from, math.min(from + PER_PAGE - 1, #source) do
        local id = source[i]
        local have = totals[id] or 0
        local key = "pick" .. i

        line(key, row, PAD, id, "item")
        line("cnt" .. i, row, COL2,
            have > 0 and (have .. " in storage") or "", "dim")

        hit(key, { kind = "item", item = id })
        row = row + 1
    end
    row = row + 1

    if pages > 1 then
        line("prev", row, PAD, "<   previous", page > 0 and "action" or "dim")
        line("next", row, 220, "next   >",
            page < pages - 1 and "action" or "dim")
        if page > 0 then hit("prev", { kind = "page", by = -1 }) end
        if page < pages - 1 then hit("next", { kind = "page", by = 1 }) end
        row = row + 1
    end

    line("all", row, PAD,
        everything and "show only what I have" or "show every item in the game",
        "action")
    hit("all", { kind = "toggle_all" })
    row = row + 1

    line("back", row, PAD, "<   back", "action")
    hit("back", { kind = "back" })

    return row + 2
end

local function draw_work_picker(cfg)
    local row = 0
    line("title", row, 0, "NEW RULE   which job makes it", "title")
    row = row + 1
    line("sub", row, 0, draft and draft.item or "", "dim")
    row = row + 2

    local i = 0
    for _, name in ipairs(workdefs.ORDER) do
        if name ~= workdefs.ANYONE then
            i = i + 1
            local key = "job" .. i
            line(key, row, PAD, workdefs.label(name), "item")
            hit(key, { kind = "work", work = name })
            row = row + 1
        end
    end
    row = row + 1

    line("back", row, PAD, "<   back", "action")
    hit("back", { kind = "back" })

    return row + 2
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

function M.refresh(cfg)
    if not M.open then return end
    if not ensure_root() then return end

    -- Which row the mouse is on, decided from last frame's map before it is
    -- rebuilt. One frame of lag on a highlight is invisible; drawing the whole
    -- screen twice to avoid it is not.
    hover_key = nil
    for key in pairs(hits) do
        local tb = blocks[key]
        local over = false
        pcall(function()
            if alive(tb) then over = tb:IsHovered() end
        end)
        if over == true then
            hover_key = key
            break
        end
    end

    was_hit, was_sel = hits, order[sel]
    hits, order, used = {}, {}, {}
    local totals = stock_totals(cfg)

    local rows
    if mode == "item" then
        rows = draw_item_picker(cfg, totals)
    elseif mode == "work" then
        rows = draw_work_picker(cfg)
    else
        rows = draw_list(cfg, totals)
    end

    -- Clamped after the draw, since the row count is only known then.
    if sel > #order then sel = #order end
    if sel < 1 then sel = 1 end

    ensure_backdrop(rows)
    blank_unused()
end

local function blank_everything()
    for key, tb in pairs(blocks) do
        if alive(tb) then
            local ft = make_ftext("")
            if ft then
                pcall(function() tb:SetText(ft) end)
                drawn[key] = ""
            end
        end
    end
    if alive(backdrop) then
        pcall(function() backdrop:SetBrushColor(CLEAR) end)
    end
    hits, hover_key = {}, nil
end

-- Opened on a hotkey, which means it can come up during ordinary play where
-- there is no mouse cursor at all. Nothing can be hovered without one, and
-- IsHovered is the whole of the hit testing, so the cursor comes on with the
-- panel and goes back as it was on close.
local cursor_was = nil
local input_route = nil

-- Showing a cursor is not enough on its own.
--
-- bShowMouseCursor only draws the pointer. Slate routes mouse events to
-- widgets only when the input mode is UI or Game and UI; in plain game mode
-- the cursor is visible while every click still goes to the player
-- controller, so IsHovered never becomes true and nothing in the panel can be
-- pressed. That is why the first version looked clickable and was not.
--
-- The argument list for these differs between engine versions, so each shape
-- is tried and the one that takes is remembered and logged.
local function set_input_mode(on)
    local pc = api.player_controller()
    if not alive(pc) then return end

    local lib = api.cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not lib then
        warn_once("noinputlib",
            "WidgetBlueprintLibrary not found, so the panel may not take clicks")
        return
    end

    if not on then
        pcall(function() lib:SetInputMode_GameOnly(pc) end)
        return
    end

    -- EMouseLockMode 0 is DoNotLock, which leaves the camera usable.
    local shapes = {
        { "GameAndUI(pc, nil, 0, false)",
          function() lib:SetInputMode_GameAndUI(pc, nil, 0, false) end },
        { "GameAndUI(pc, nil, 0)",
          function() lib:SetInputMode_GameAndUI(pc, nil, 0) end },
        { "GameAndUI(pc)",
          function() lib:SetInputMode_GameAndUI(pc) end },
    }

    for _, shape in ipairs(shapes) do
        if pcall(shape[2]) then
            if input_route ~= shape[1] then
                input_route = shape[1]
                log.debug("input mode set via " .. shape[1])
            end
            return
        end
    end

    warn_once("noinputmode",
        "could not switch to Game and UI input, so clicks may not reach the panel")
end

local function set_cursor(on)
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

    set_input_mode(on)
end

function M.toggle()
    M.open = not M.open

    if not M.open then
        blank_everything()
        set_cursor(false)
        mode, draft, page, show_all = "list", nil, 0, false
        return
    end

    set_cursor(true)

    if ensure_root() == nil then
        log.say("work rules need the Monitoring Stand open. " ..
            "Open it and press Ctrl+F9 again")
    else
        log.say("work rules open, Ctrl+F9 again to close")
    end
end

function M.reset()
    M.open = false
    cursor_was = nil
    totals_cache, totals_at = nil, 0
    root, root_owner, root_tree, backdrop = nil, nil, nil, nil
    blocks, drawn, hits, used = {}, {}, {}, {}
    was_hit, was_sel, hover_key = {}, nil, nil
    mode, draft, page, show_all = "list", nil, 0, false
    ftext_mode = nil
    warned = {}
end

-- ---------------------------------------------------------------------------
-- Clicking
-- ---------------------------------------------------------------------------

local function step(current, dir)
    if dir < 0 then
        if current == nil then return LADDER[1] end
        for _, n in ipairs(LADDER) do
            if n > current then return n end
        end
        return LADDER[#LADDER]
    end

    if current == nil then return nil end
    local below = nil
    for _, n in ipairs(LADDER) do
        if n < current then below = n end
    end
    return below
end

local function hovered()
    for key, what in pairs(hits) do
        local tb = blocks[key]
        local over = false
        pcall(function()
            if alive(tb) then over = tb:IsHovered() end
        end)
        if over == true then
            -- Moving the mouse moves the keyboard position with it, so the
            -- two never disagree about which row is current.
            for i, k in ipairs(order) do
                if k == key then sel = i break end
            end
            return what
        end
    end
    return nil
end

-- Arrow keys. The mouse works, but the cursor sits over a live game world and
-- the rows are thin, so this is the reliable way in.
function M.move(delta)
    if not M.open or #order == 0 then return false end

    sel = sel + delta
    if sel > #order then sel = 1 end
    if sel < 1 then sel = #order end
    return true
end

-- Enter and backspace stand in for left and right click on the selected row.
function M.activate(cfg, dir)
    if not M.open then return false end

    local what = hits[order[sel] or ""]
    if what == nil then return false end
    return M.apply(cfg, what, dir)
end

-- Returns true when the click was ours, so the caller leaves the grid alone.
function M.handle_click(cfg, dir)
    if not M.open then return false end

    local what = hovered()
    if what == nil then return false end
    return M.apply(cfg, what, dir)
end

-- What a row does, whichever way it was reached.
function M.apply(cfg, what, dir)
    if what.kind == "close" then
        M.toggle()
        return true
    end

    if what.kind == "new" then
        mode, page, show_all = "item", 0, false
        return true
    end

    if what.kind == "page" then
        page = page + what.by
        return true
    end

    if what.kind == "toggle_all" then
        show_all = not show_all
        page = 0
        return true
    end

    if what.kind == "back" then
        if mode == "work" then
            mode, draft = "item", nil
        else
            mode, page = "list", 0
        end
        return true
    end

    if what.kind == "item" then
        -- Guess the job from the item rather than asking. Thirteen choices for
        -- a question that usually has one obvious answer is a screen nobody
        -- wants, and a wrong guess shows on the rule and is one click to fix.
        local guess = workdefs.work_for_item(what.item)

        if guess then
            caps.set(guess, what.item, LADDER[1])
            log.say(string.format("rule added: %s until %d %s",
                workdefs.label(guess), LADDER[1], what.item))
            M.wants_pass = true
            mode, draft, sel = "list", nil, 1
        else
            draft = { item = what.item }
            mode, sel = "work", 1
        end
        return true
    end

    -- Correcting a guess. Walks the work types in order rather than opening
    -- another screen for it.
    if what.kind == "job" then
        local rule = what.rule
        local at = 1
        for i, name in ipairs(workdefs.ORDER) do
            if name == rule.work then at = i break end
        end

        local step = (dir < 0) and 1 or -1
        for _ = 1, #workdefs.ORDER do
            at = at + step
            if at > #workdefs.ORDER then at = 1 end
            if at < 1 then at = #workdefs.ORDER end
            if workdefs.ORDER[at] ~= workdefs.ANYONE then break end
        end

        local moved = workdefs.ORDER[at]
        caps.clear(rule.work, rule.item)
        caps.set(moved, rule.item, rule.amount)
        log.say(rule.item .. " is now made by " .. workdefs.label(moved))
        M.wants_pass = true
        return true
    end

    if what.kind == "work" then
        if draft and draft.item then
            -- A new rule starts at the bottom of the ladder. Starting it at
            -- current stock would read as already satisfied and do nothing,
            -- which looks like the rule not working.
            caps.set(what.work, draft.item, LADDER[1])
            log.say(string.format("rule added: %s until %d %s",
                workdefs.label(what.work), LADDER[1], draft.item))
            M.wants_pass = true
        end
        mode, draft = "list", nil
        return true
    end

    if what.kind == "drop" then
        caps.clear(what.rule.work, what.rule.item)
        log.say("rule removed: " .. workdefs.label(what.rule.work) ..
            " " .. what.rule.item)
        M.wants_pass = true
        return true
    end

    if what.kind == "rule" then
        local rule = what.rule
        local next_amount = step(rule.amount, dir)

        if next_amount == nil then
            caps.clear(rule.work, rule.item)
            log.say("rule removed: " .. workdefs.label(rule.work) ..
                " " .. rule.item)
        else
            caps.set(rule.work, rule.item, next_amount)
        end
        M.wants_pass = true
        return true
    end

    return false
end

return M
