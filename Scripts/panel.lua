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
local overlay = require("overlay")
local scheduler = require("scheduler")

local M = {}

M.open = false
M.wants_pass = false

-- "list"  the rules themselves
-- "item"  choosing what a new rule is about
local mode = "list"
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

local placed = {}               -- key -> where it was last put, to skip no-op moves
local stripes = {}              -- key -> Border drawn behind a row
local search_box = nil          -- EditableTextBox, only possible in a widget we own
local search_text = ""
local want_focus = false
local sel = 1                   -- which row the keyboard is on

local ftext_mode = nil
local warned = {}

-- LINE has to clear the font, which is about 20 tall at 1440p. At 22 the
-- rows drew through each other.
-- Laid out like Creative Menu: a dark slab, a row of tabs, one boxed row per
-- entry, a cyan accent on whatever is current. Those are the parts that make
-- it read as a menu rather than as text over a game.
-- Every slot is anchored to the middle of the screen, so these are offsets
-- from centre rather than from the top left corner. That keeps the panel
-- centred at any resolution without ever asking how big the viewport is,
-- which is a question with an awkward answer in UE4SS.
local CENTRE = { Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } }
local X, Y = -410, -300
local W = 820
local LINE = 34
local ROW_H = 30
local PAD = 18
local COL2 = 470
local COL3 = 690
local TAB_H = 34
local PER_PAGE = 12

local COLOUR = {
    title  = { R = 1.00, G = 1.00, B = 1.00, A = 1.00 },
    dim    = { R = 0.52, G = 0.57, B = 0.64, A = 1.00 },
    item   = { R = 0.86, G = 0.89, B = 0.95, A = 1.00 },
    met    = { R = 0.35, G = 0.92, B = 0.48, A = 1.00 },
    unmet  = { R = 1.00, G = 0.70, B = 0.24, A = 1.00 },
    action = { R = 0.42, G = 0.80, B = 1.00, A = 1.00 },
    hover  = { R = 0.60, G = 1.00, B = 1.00, A = 1.00 },
    tab_on = { R = 0.55, G = 0.95, B = 1.00, A = 1.00 },
}

local BACKDROP  = { R = 0.035, G = 0.055, B = 0.080, A = 0.94 }
local ROW_BG    = { R = 0.075, G = 0.100, B = 0.135, A = 0.90 }
local ROW_HOVER = { R = 0.110, G = 0.200, B = 0.260, A = 0.95 }
local TAB_BAR   = { R = 0.055, G = 0.080, B = 0.110, A = 0.95 }
local CLEAR     = { R = 0.00, G = 0.00, B = 0.00, A = 0.00 }

-- Registers a row as clickable and, in the same breath, as reachable by the
-- arrow keys. Two lists that could disagree would be a bug waiting.
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

-- The panel draws into the overlay, a widget the mod constructs and owns.
--
-- It used to live in the Monitoring Stand's menu, and before that in the HUD.
-- Both belong to the game, which is the root of everything that went wrong:
-- the HUD rebuilt itself and freed our widgets mid-frame, twice, and the stand
-- menu turned out to be hidden rather than destroyed, so closing it orphaned
-- our rows and reopening drew a second set over them.
--
-- Nothing in Palworld holds a reference to the overlay, so nothing can free it
-- or hide it behind our back. It also means the panel is no longer tied to a
-- Monitoring Stand, which was a real loss when it was hosted there.
local function ensure_root()
    local host, host_tree = overlay.host()

    if not alive(host) or not alive(host_tree) then
        root, root_owner, root_tree, backdrop = nil, nil, nil, nil
        blocks, drawn, stripes, placed = {}, {}, {}, {}
        search_box = nil
        return nil
    end

    if root == host and alive(root_tree) then
        return root
    end

    -- A different canvas than last time means the overlay was rebuilt, and
    -- everything we made belonged to the old one and went with it. References
    -- are dropped rather than unparented: asking a freed widget anything is
    -- the crash, not the check for it.
    root, root_owner, root_tree = host, host, host_tree
    backdrop = nil
    blocks, drawn, stripes, placed = {}, {}, {}, {}
    search_box = nil
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

        pcall(function() slot:SetAnchors(CENTRE) end)
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

-- The box behind a row. Creative Menu draws every entry as a bordered slab
-- that lights up under the pointer, and that alone is most of the difference
-- between a menu and a wall of text.
local function stripe(key, row, from, width)
    local host = ensure_root()
    if not host then return end

    used["s:" .. key] = true

    local border = stripes[key]
    if not alive(border) then
        local cls = api.cdo("/Script/UMG.Border")
        if not cls or not alive(root_tree) then return end

        pcall(function() border = StaticConstructObject(cls, root_tree) end)
        if not alive(border) then return end

        local slot
        local ok = pcall(function() slot = host:AddChildToCanvas(border) end)
        if not ok or not alive(slot) then return end

        pcall(function() slot:SetAnchors(CENTRE) end)
        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetZOrder(8995) end)
        -- Hit test invisible: the row's text is what reports hover, and a
        -- border on top of it would swallow that.
        pcall(function() border:SetVisibility(3) end)
        stripes[key] = border
    end

    local at = from .. ":" .. row .. ":" .. width
    if placed["s:" .. key] ~= at then
        local slot
        pcall(function() slot = border.Slot end)
        if alive(slot) then
            pcall(function()
                slot:SetPosition({ X = X + from - 6, Y = Y + row * LINE - 3 })
            end)
            pcall(function() slot:SetSize({ X = width, Y = ROW_H }) end)
            placed["s:" .. key] = at
        end
    end

    local on = (key == (hover_key or was_sel))
    local want = on and "on" or "off"
    if drawn["s:" .. key] ~= want then
        pcall(function() border:SetBrushColor(on and ROW_HOVER or ROW_BG) end)
        drawn["s:" .. key] = want
    end
end

-- Font size, which is what makes a heading read as a heading.
--
-- Font is a struct property, so it is read out, changed and written back
-- rather than poked in place. If this build will not take it the panel simply
-- stays one size, which is what it looked like before, so there is nothing to
-- lose by trying.
local function set_size(tb, points)
    pcall(function()
        local font = tb.Font
        if font == nil then return end
        font.Size = points
        tb.Font = font
    end)
end

local function line(key, row, col, text, colour_key, points)
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

        -- Auto sized, because that is what demonstrably renders here.
        -- Sizing the slot explicitly, which is what this did, produced widgets
        -- that were positioned correctly and drew nothing at all, while the
        -- identically constructed text in overlay.lua's probe showed fine. The
        -- only difference between them was this call.
        pcall(function() slot:SetAnchors(CENTRE) end)
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetZOrder(9000) end)
        pcall(function() tb:SetVisibility(0) end)
        pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)
        if points then set_size(tb, points) end

        blocks[key] = tb
        drawn[key] = nil
    end

    -- Position every frame, not only at construction: a row moves when the
    -- screen above it changes length.
    -- Ten times a second, so a move that changes nothing is worth skipping.
    local at = col .. ":" .. row
    if placed[key] ~= at then
        local slot
        pcall(function() slot = tb.Slot end)
        if alive(slot) then
            pcall(function()
                slot:SetPosition({ X = X + col, Y = Y + row * LINE })
            end)
            placed[key] = at
        end
    end

    -- Exactly one row is current. The pointer wins when it is over
    -- something, otherwise the keyboard position stands. Treating both as
    -- selected marked two rows at once, which the video shows plainly.
    local current = hover_key or was_sel
    local selected = (key == current)
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

    -- A stripe with nothing on it is a floating box, so anything not drawn
    -- this frame goes transparent rather than staying behind.
    --
    -- Recorded in the cache, not merely done. The cache exists to skip
    -- redundant work by remembering what is on screen, so anything that
    -- changes the screen behind its back makes it lie. Clearing without
    -- recording is exactly how rows came back invisible: the stripe was
    -- transparent, the cache still said "off", and the recolour that would
    -- have fixed it was skipped as redundant. Switching tabs reuses these
    -- keys, which is why it took a couple of presses to show up.
    for key, border in pairs(stripes) do
        if not used["s:" .. key] and alive(border)
            and drawn["s:" .. key] ~= "clear" then
            pcall(function() border:SetBrushColor(CLEAR) end)
            drawn["s:" .. key] = "clear"
        end
    end
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

-- An EditableTextBox the player can actually type into.
--
-- This is the thing that was impossible before. A text box injected into a
-- widget the game owns never receives keystrokes, because focus follows
-- ownership; that is why the picker paged through items instead of filtering
-- them. In a widget we construct ourselves the engine will hand it the
-- keyboard.
local function ensure_search(row)
    local host = ensure_root()
    if not host then return nil end

    used["search"] = true

    if not alive(search_box) then
        local cls = api.cdo("/Script/UMG.EditableTextBox")
        if not cls or not alive(root_tree) then return nil end

        pcall(function() search_box = StaticConstructObject(cls, root_tree) end)
        if not alive(search_box) then
            warn_once("nosearch", "no EditableTextBox on this build, " ..
                "so the picker pages instead of filtering")
            return nil
        end

        local slot
        local ok = pcall(function() slot = host:AddChildToCanvas(search_box) end)
        if not ok or not alive(slot) then
            search_box = nil
            return nil
        end

        pcall(function() slot:SetAnchors(CENTRE) end)
        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetZOrder(9010) end)
        pcall(function() search_box:SetVisibility(0) end)
        pcall(function() search_box:SetHintText(make_ftext("type to filter")) end)
    end

    local slot
    pcall(function() slot = search_box.Slot end)
    if alive(slot) then
        pcall(function() slot:SetPosition({ X = X + PAD, Y = Y + row * LINE }) end)
        pcall(function() slot:SetSize({ X = W - PAD * 2, Y = 30 }) end)
    end
    pcall(function() search_box:SetVisibility(0) end)

    -- Focus is taken once on entering the picker, not every frame: stealing it
    -- each tick would fight anything else that wants it and make typing feel
    -- like it is being interrupted, which it would be.
    if want_focus then
        want_focus = false
        pcall(function() search_box:SetKeyboardFocus() end)
    end

    local text
    pcall(function()
        local ft = search_box:GetText()
        if ft then text = ft:ToString() end
    end)
    if type(text) == "string" then search_text = text end

    return search_box
end

local function hide_search()
    if alive(search_box) then
        -- Collapsed rather than destroyed, so the same box comes back with
        -- whatever was typed in it.
        pcall(function() search_box:SetVisibility(1) end)
    end
end

-- ---------------------------------------------------------------------------
-- Stock
-- ---------------------------------------------------------------------------

-- What the bases hold, taken from the last scheduler pass.
--
-- The panel used to work this out itself, scanning every container on every
-- loaded camp. That is the most expensive thing this mod does and it was
-- happening every three seconds on the game thread for as long as the panel
-- was open, which is what made it lag.
--
-- The pass already computes these numbers every ten seconds. Reading them
-- costs nothing, and being up to ten seconds stale is invisible for a stock
-- count that moves by a handful at a time.
--
-- The scan below is a fallback for the first seconds after a world loads,
-- before any pass has published, and it is throttled hard.
local scanned_once = nil
local scanned_at = 0

local function stock_totals(cfg)
    if next(scheduler.last_totals or {}) ~= nil then
        return scheduler.last_totals
    end

    local now = os.clock()
    if scanned_once and (now - scanned_at) < 15.0 then
        return scanned_once
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

    scanned_once, scanned_at = totals, now
    return totals
end

-- ---------------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------------

-- A tab bar, the first thing Creative Menu shows and the clearest way to say
-- what screen you are on and what else there is.
local function draw_tabs(active)
    stripe("tabbar", 0, 0, W)

    local tabs = {
        { key = "tab_rules", label = "RULES", mode = "list" },
        { key = "tab_new",   label = "ADD",   mode = "item" },
    }

    local x = PAD
    for _, tab in ipairs(tabs) do
        local on = (active == tab.mode)
        hit(tab.key, { kind = "tab", mode = tab.mode })
        line(tab.key, 0, x, tab.label, on and "tab_on" or "dim", 20)
        x = x + 130
    end

    hit("tab_close", { kind = "close" })
    line("tab_close", 0, W - 90, "CLOSE", "dim", 20)
end

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

    draw_tabs("list")
    local row = 2

    line("sub", row, PAD,
        "click a job to change it, a number to adjust it, remove to delete",
        "dim", 13)
    row = row + 1

    if #rules == 0 then
        line("empty", row, PAD, "no rules yet, every job runs unlimited", "dim")
        row = row + 2
    else
        for i, rule in ipairs(rules) do
            local have = totals[rule.item] or 0
            local met = have >= rule.amount
            local key = "rule" .. i

            stripe(key, row, PAD, W - PAD * 2)
            line(key, row, PAD, workdefs.label(rule.work), "action")
            line("itm" .. i, row, 190, rule.item, "item")
            line("amt" .. i, row, COL2, string.format("%d / %d%s",
                have, rule.amount, met and "   done" or ""),
                met and "met" or "unmet")

            -- The job is clickable separately from the amount. Rules no
            -- longer ask which job makes a thing, they guess, so there has to
            -- be somewhere to correct the guess.
            line("del" .. i, row, COL3, "remove", "dim")

            hit(key, { kind = "job", rule = rule })
            hit("amt" .. i, { kind = "rule", rule = rule })
            hit("del" .. i, { kind = "drop", rule = rule })
            row = row + 1
        end
        row = row + 1
    end

    hit("new", { kind = "new" })
    stripe("new", row, PAD, W - PAD * 2)
    line("new", row, PAD, "+   add a rule", "action")

    return row + 2
end

-- A rule caps what a base produces, so an item the base cannot produce has
-- nothing to cap and does not belong in the picker at all. FireOrgan is the
-- case that showed it: a pal drop, sitting in storage, and picking it led to
-- a screen asking which job makes it, a question with no honest answer.
--
-- Producible is defined as "we can name the job that makes it", which is the
-- same question a rule has to answer anyway. That is what removes the job
-- screen rather than merely hiding it: everything reaching the picker already
-- knows its job, so there is nothing left to ask.
local function producible(id)
    return workdefs.work_for_item(id) ~= nil
end

local function only_producible(list)
    local out = {}
    for _, id in ipairs(list or {}) do
        if producible(id) then out[#out + 1] = id end
    end
    return out
end

local function picker_source(totals)
    -- Searching casts wider than the base holds, but still only over things
    -- the base could make. Asked for more rows than before, because the
    -- filter takes most of them away again.
    if search_text ~= "" then
        return only_producible(items.search(search_text, 400)), true
    end

    if show_all then
        return only_producible(items.load()), true
    end

    -- What the base holds, minus what it cannot make. Sorted by quantity, so
    -- the things worth capping are at the top.
    local out = {}
    for id in pairs(totals) do
        if producible(id) then out[#out + 1] = id end
    end
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

    draw_tabs("item")
    local row = 2

    ensure_search(row)
    row = row + 1

    line("sub", row, PAD, string.format("%s,  %d item(s),  page %d of %d",
        search_text ~= "" and ("matching " .. search_text)
            or (everything and "everything your base can make"
                or "what your storage holds"),
        #source, page + 1, pages), "dim")
    row = row + 1

    local from = page * PER_PAGE + 1
    for i = from, math.min(from + PER_PAGE - 1, #source) do
        local id = source[i]
        local have = totals[id] or 0
        local key = "pick" .. i

        stripe(key, row, PAD, W - PAD * 2)
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
        everything and "show only what I have"
            or "show everything your base can make",
        "action")
    hit("all", { kind = "toggle_all" })
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
    else
        hide_search()
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
    for key, border in pairs(stripes) do
        if alive(border) then
            pcall(function() border:SetBrushColor(CLEAR) end)
            drawn["s:" .. key] = "clear"
        end
    end
    hide_search()
    hits, hover_key = {}, nil
end

function M.toggle()
    M.open = not M.open

    if not M.open then
        blank_everything()
        overlay.hide()
        mode, page, show_all = "list", 0, false
        return
    end

    if not overlay.show() then
        M.open = false
        log.say("could not put the overlay on screen, see priority.log")
        return
    end
    log.say("work rules open, Ctrl+F9 again to close")
end

function M.reset()
    M.open = false
    scanned_once, scanned_at = nil, 0
    root, root_owner, root_tree, backdrop = nil, nil, nil, nil
    blocks, drawn, hits, used = {}, {}, {}, {}
    stripes, placed, search_box, search_text, want_focus = {}, {}, nil, "", false
    was_hit, was_sel, hover_key = {}, nil, nil
    mode, page, show_all = "list", 0, false
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
        want_focus = true
        sel = 1
        log.say("picking an item, type to filter or click one")
        return true
    end

    if what.kind == "tab" then
        mode, page = what.mode, 0
        want_focus = (what.mode == "item")
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
        mode, page = "list", 0
        return true
    end

    if what.kind == "item" then
        -- The job is never asked for. Only items with a known job reach the
        -- picker, so this fallback is for an id the filter let through rather
        -- than a real choice, and it lands on a rule that can be corrected in
        -- place instead of on a dead end.
        local work = workdefs.work_for_item(what.item) or workdefs.DEFAULT_WORK

        caps.set(work, what.item, LADDER[1])
        log.say(string.format("rule added: %s until %d %s",
            workdefs.label(work), LADDER[1], what.item))
        M.wants_pass = true
        mode, sel = "list", 1
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
