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
-- Everything is drawn as TextBlocks on a canvas we own, positioned by hand.
-- That is more code than a proper UMG layout, but it reuses the one injection
-- route already proven to work on this build, and it keeps hit testing to
-- IsHovered, which the priority cells already rely on.

local log = require("log")
local api = require("palapi")
local caps = require("caps")
local items = require("items")
local workdefs = require("workdefs")

local M = {}

M.open = false
M.wants_pass = false

-- "list"  the rules themselves
-- "item"  choosing what a new rule is about
-- "work"  choosing which job that rule gates
local mode = "list"
local draft = nil               -- { item = string } while a rule is being made
local search = ""

local root = nil                -- our canvas, child of the game's UI layout
local root_owner = nil          -- the layout we hung it off, to spot a swap
local root_tree = nil           -- that layout's WidgetTree, the construction outer
local blocks = {}               -- key -> TextBlock
local drawn = {}                -- key -> last string drawn, to skip no-op sets
local hits = {}                 -- key -> what clicking that line means

local ftext_mode = nil
local warned = {}

-- Geometry. One column of lines, so there is only ever one number to change
-- when something needs to move.
local X, Y = 80, 140
local W, LINE = 560, 22
local ROWS = 16                 -- lines of content before paging kicks in

local COLOUR = {
    title   = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 },
    dim     = { R = 0.55, G = 0.57, B = 0.62, A = 1.0 },
    item    = { R = 0.85, G = 0.88, B = 0.95, A = 1.0 },
    met     = { R = 0.30, G = 0.95, B = 0.40, A = 1.0 },
    unmet   = { R = 1.00, G = 0.70, B = 0.20, A = 1.0 },
    action  = { R = 0.40, G = 0.78, B = 1.00, A = 1.0 },
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

-- The panel opens on a hotkey rather than from a menu, so it cannot hang off
-- the Monitoring Stand the way the grid does. It goes on the overall UI
-- layout, which outlives any single screen.
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

local function ensure_root()
    if alive(root) and alive(root_owner) and alive(root_tree) then return root end

    root, root_owner, root_tree = nil, nil, nil
    blocks, drawn = {}, {}

    local layout
    pcall(function() layout = FindFirstOf("WBP_PalOverallUILayout_C") end)
    if not alive(layout) then
        warn_once("nolayout", "overall UI layout not found, so no rules panel")
        return nil
    end

    local tree
    pcall(function() tree = layout.WidgetTree end)
    if not alive(tree) then return nil end

    local base
    pcall(function() base = tree.RootWidget end)
    if not alive(base) then return nil end

    local canvas = first_canvas(base)
    if not alive(canvas) then
        warn_once("nocanvas", "no canvas on the UI layout, so no rules panel")
        return nil
    end

    root, root_owner, root_tree = canvas, layout, tree
    return root
end

-- One TextBlock per line, kept and reused. Rebuilding them every refresh
-- would leave orphans on the canvas, which is how the status strip ended up
-- drawing itself twice.
local function line(key, row, col, text, colour_key)
    local canvas = ensure_root()
    if not canvas then return end

    local tb = blocks[key]
    if not alive(tb) then
        local cls = api.cdo("/Script/UMG.TextBlock")
        if not cls or not alive(root_tree) then return end

        -- Constructed against the WidgetTree, not the canvas.
        --
        -- A UMG widget belongs to a WidgetTree; the panel it renders in is
        -- parenting, not ownership. Giving it a CanvasPanel as its outer
        -- leaves it owned by something that does not keep widgets alive, and
        -- the game crashed inside UE4SS on the first frame after this panel
        -- was drawn. The cell numbers on the stand have always used the tree,
        -- which is why they never did this.
        pcall(function() tb = StaticConstructObject(cls, root_tree) end)
        if not alive(tb) then return end

        local slot
        local ok = pcall(function() slot = canvas:AddChildToCanvas(tb) end)
        if not ok or not alive(slot) then return end

        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetPosition({ X = X + col, Y = Y + row * LINE }) end)
        pcall(function() slot:SetSize({ X = W - col, Y = LINE }) end)
        pcall(function() slot:SetZOrder(9000) end)
        pcall(function() tb:SetVisibility(0) end)
        pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)

        blocks[key] = tb
        drawn[key] = nil
    end

    local token = text .. "|" .. colour_key
    if drawn[key] ~= token then
        local ft = make_ftext(text)
        if ft then
            pcall(function() tb:SetText(ft) end)
            pcall(function()
                tb:SetColorAndOpacity({
                    SpecifiedColor = COLOUR[colour_key],
                    ColorUseRule = 0,
                })
            end)
            drawn[key] = token
        end
    end
    return tb
end

-- Lines left over from a previous, longer screen. Emptied rather than
-- destroyed: a destroyed widget leaves a dead wrapper behind, and an empty
-- one costs nothing.
local function clear_from(row)
    for key, tb in pairs(blocks) do
        local n = tonumber(key:match("^r(%d+)$") or "")
        if n and n >= row and alive(tb) and drawn[key] ~= "|dim" then
            local ft = make_ftext("")
            if ft then
                pcall(function() tb:SetText(ft) end)
                drawn[key] = "|dim"
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Stock
-- ---------------------------------------------------------------------------

-- What the bases are holding, measured the same way the scheduler measures
-- it, so a rule shown as met is one the scheduler also treats as met.
-- Cached, because the panel redraws every second and reading every container
-- on every loaded base is the most expensive thing this mod does. The
-- scheduler does it once per pass for a reason.
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

-- Every rule in force, so one written into config.lua shows here alongside
-- the ones clicked in. Clicking a config rule writes an override to caps.txt,
-- which is the same precedence the priority grid uses.
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
    line("title", 0, 0, "WORK RULES", "title")
    line("hint", 0, 300, "left click raise, right click lower", "dim")

    local rules = rule_list(cfg)
    local row = 2

    if #rules == 0 then
        line("r" .. row, row, 16, "no rules, every job runs unlimited", "dim")
        row = row + 2
    else
        for _, rule in ipairs(rules) do
            local have = totals[rule.item] or 0
            local met = have >= rule.amount

            line("r" .. row, row, 16, string.format("%-22s %-24s",
                workdefs.label(rule.work), rule.item), "item")
            line("n" .. row, row, 380, string.format("%d / %d%s",
                have, rule.amount, met and "   done" or ""),
                met and "met" or "unmet")

            hits["r" .. row] = { kind = "rule", rule = rule }
            hits["n" .. row] = { kind = "rule", rule = rule }
            row = row + 1
        end
        row = row + 1
    end

    line("r" .. row, row, 16, "+ new rule", "action")
    hits["r" .. row] = { kind = "new" }
    clear_from(row + 1)
end

local function draw_item_picker(cfg, totals)
    line("title", 0, 0, "NEW RULE - pick an item", "title")
    line("hint", 0, 300,
        search == "" and "showing everything" or ("filter: " .. search), "dim")

    local found = items.search(search, ROWS)
    local row = 2

    if #found == 0 then
        line("r" .. row, row, 16, "nothing matches " .. search, "dim")
        row = row + 1
    else
        for _, id in ipairs(found) do
            local have = totals[id] or 0
            line("r" .. row, row, 16, id, "item")
            line("n" .. row, row, 380,
                have > 0 and string.format("%d in storage", have) or "",
                "dim")
            hits["r" .. row] = { kind = "item", item = id }
            hits["n" .. row] = { kind = "item", item = id }
            row = row + 1
        end
    end

    row = row + 1
    line("r" .. row, row, 16, "< back", "action")
    hits["r" .. row] = { kind = "back" }
    clear_from(row + 1)
end

local function draw_work_picker(cfg)
    line("title", 0, 0, "NEW RULE - which job produces it", "title")
    line("hint", 0, 300, draft and draft.item or "", "dim")

    local row = 2
    for _, name in ipairs(workdefs.ORDER) do
        if name ~= workdefs.ANYONE then
            line("r" .. row, row, 16, workdefs.label(name), "item")
            hits["r" .. row] = { kind = "work", work = name }
            row = row + 1
        end
    end

    row = row + 1
    line("r" .. row, row, 16, "< back", "action")
    hits["r" .. row] = { kind = "back" }
    clear_from(row + 1)
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

function M.refresh(cfg)
    if not M.open then return end
    if not ensure_root() then return end

    hits = {}
    local totals = stock_totals(cfg)

    if mode == "item" then
        draw_item_picker(cfg, totals)
    elseif mode == "work" then
        draw_work_picker(cfg)
    else
        draw_list(cfg, totals)
    end
end

local function blank_everything()
    for key, tb in pairs(blocks) do
        if alive(tb) then
            local ft = make_ftext("")
            if ft then
                pcall(function() tb:SetText(ft) end)
                drawn[key] = nil
            end
        end
    end
    hits = {}
end

-- Opened on a hotkey, which means it can come up during ordinary play where
-- there is no mouse cursor at all. Without one nothing can be hovered, and
-- IsHovered is the whole of the panel's hit testing, so the cursor is turned
-- on with it and put back as it was on close.
local cursor_was = nil

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
end

function M.toggle()
    M.open = not M.open

    if not M.open then
        blank_everything()
        set_cursor(false)
        mode, draft, search = "list", nil, ""
        return
    end

    set_cursor(true)
    log.say("work rules open, Alt+F9 again to close")
end

function M.reset()
    M.open = false
    cursor_was = nil
    totals_cache, totals_at = nil, 0
    root, root_owner, root_tree = nil, nil, nil
    blocks, drawn, hits = {}, {}, {}
    mode, draft, search = "list", nil, ""
    ftext_mode = nil
    warned = {}
end

-- ---------------------------------------------------------------------------
-- Clicking
-- ---------------------------------------------------------------------------

-- Amounts run into the thousands, so a click walks a ladder that coarsens as
-- the numbers grow rather than stepping by one.
local LADDER = {
    100, 250, 500, 1000, 2000, 3000, 5000,
    7500, 10000, 15000, 20000, 30000, 50000,
}

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
        local hit = false
        pcall(function()
            if alive(tb) then hit = tb:IsHovered() end
        end)
        if hit == true then return what end
    end
    return nil
end

-- Returns true when the click was ours, so the caller leaves the priority
-- grid alone.
function M.handle_click(cfg, dir)
    if not M.open then return false end

    local what = hovered()
    if what == nil then return false end

    if what.kind == "new" then
        mode, search = "item", ""
        return true
    end

    if what.kind == "back" then
        if mode == "work" then
            mode, draft = "item", nil
        else
            mode, search = "list", ""
        end
        return true
    end

    if what.kind == "item" then
        draft = { item = what.item }
        mode = "work"
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
