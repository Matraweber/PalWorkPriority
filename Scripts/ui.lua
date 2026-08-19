-- The Monitoring Stand display.
--
-- One number per grid cell: the priority in force for that pal and work type,
-- replacing the vanilla checkbox and coloured on RimWorld's work-tab scale.
-- Work the pal cannot do keeps its vanilla dash. Left click raises a cell,
-- right click lowers it.
--
-- Game-facing facts (class names, the BindFromSlot hook, BindedSuitability,
-- the checkbox-sibling placement) follow what PalPriority's UI mod proves
-- works on this build. The code is written fresh; two of its crash findings
-- are load-bearing here and worth restating:
--
--   CRASH RULE 1: pcall cannot catch the native access violation that calling
--   a method on a null/stale wrapper causes. Every member call on anything
--   received from the engine must be behind an affirmative IsValid() == true.
--
--   CRASH RULE 2: never READ a row's bindedSlot property. The read itself
--   crashes natively inside UE4SS before Lua sees anything. Pal identity is
--   captured by hooking the row's BindFromSlot function instead, where the
--   slot arrives as a safe hook argument.

local log = require("log")
local api = require("palapi")
local workdefs = require("workdefs")
local store = require("store")
local caps = require("caps")

local M = {}

-- Blueprint-generated classes need the _C suffix or FindAllOf finds nothing.
M.MENU_CLASS = "WBP_WorkSuitabilityPreferenceMenu_C"
M.CELL_CLASS = "WBP_WorkSuitabilityPreference_CheckBox_0_C"
-- The game's own typo ("Worl"): this is the real class name, keep it exactly.
M.ROW_CLASS = "WBP_WorlSuitabilityPreference_PalList_C"

local ROW_BP_PATH = "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/" ..
    "WorkSuitabilityPreference/WBP_WorlSuitabilityPreference_PalList." ..
    "WBP_WorlSuitabilityPreference_PalList_C"
local ROW_BIND_FN = ROW_BP_PATH .. ":BindFromSlot"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local warned = {}
local ftext_mode = nil          -- "direct" | "kismet"

-- Live menu cache. Multiple instances coexist (seen live: a hidden stale one
-- alongside the open one), so only a VISIBLE instance may be cached.
local menu_ref = nil

-- Row -> pal identity, captured at bind time. Rows recycle on scroll, so a
-- rebind overwrites.
local row_pal = {}              -- row full name -> { key, name, species }
local bind_hooked = false       -- never reset: the hook survives world switches
local last_hook_try = -math.huge
local menu_likely_open = false

-- Cells.
local cell_cache = nil          -- array of cell widgets, revalidated per use
local cell_row = {}             -- cell full name -> row full name
local cell_text = {}            -- cell full name -> injected TextBlock
local cell_last = {}            -- cell full name -> last style token written
local cell_cb = {}              -- cell full name -> the checkbox's own visibility

local function warn_once(key, message)
    if warned[key] then return end
    warned[key] = true
    log.warn(message)
end

-- CRASH RULE 1 gate.
local function alive(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function full_name(o)
    if not alive(o) then return nil end
    local n
    pcall(function() n = o:GetFullName() end)
    if type(n) == "string" then return n end
    return nil
end

local function class_name(o)
    local n
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

-- Lookup caches only. cell_text MUST survive: this runs on every scroll, rows
-- recycle rather than die, and dropping the reference to a live TextBlock
-- makes the next tick inject a second one on top of it.
-- Ceiling row state. Declared here rather than beside the rest of the
-- ceiling code so M.reset, which runs above it, can clear it.
local ceiling_text = {}     -- suitability value -> TextBlock
local ceiling_last = {}     -- suitability value -> last glyph drawn
local ceiling_cols = nil    -- suitability value -> the icon's canvas

-- Forward declared because M.refresh sits above the ceiling code and
-- would otherwise resolve this as a nil global. The call there is inside
-- a pcall, so that failure would not be reported: the row would simply
-- never appear, with nothing anywhere saying why.
local refresh_ceilings

local function invalidate_cells()
    cell_cache = nil
    cell_row = {}
end

-- Lost sight of the menu. Injected references are kept and alive() decides
-- what is still usable: detach fires on a merely-invisible frame too, so
-- dropping them here would duplicate widgets on the next tick.
function M.detach()
    menu_ref = nil
    invalidate_cells()
end

-- World switch: every engine wrapper is dead. The bind hook itself survives
-- (UE4SS hooks are global), so bind_hooked stays.
function M.reset()
    M.detach()
    -- A world switch really does destroy everything, so this is where the
    -- injected references are dropped rather than in detach.
    cell_text = {}
    cell_last = {}
    cell_cb = {}
    row_pal = {}
    ceiling_text = {}
    ceiling_last = {}
    ceiling_cols = nil
    menu_likely_open = false
    ftext_mode = nil
    warned = {}
end

-- ---------------------------------------------------------------------------
-- FText
-- ---------------------------------------------------------------------------

local function make_ftext(str)
    if ftext_mode == "direct" or ftext_mode == nil then
        local ft
        local ok = pcall(function() ft = FText(str) end)
        if ok and ft then
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

    warn_once("ftext", "no working FText path on this build, so the stand UI cannot render")
    return nil
end

-- ---------------------------------------------------------------------------
-- Pal identity: the BindFromSlot hook
-- ---------------------------------------------------------------------------

-- BP classes load on demand; registration fails until the class exists, and
-- rows bound before registration are never captured. LoadAsset forces the
-- class in, and the retry keeps trying every few seconds until it lands.
local function try_hook_bind()
    if bind_hooked then return end
    local now = os.clock()
    if now - last_hook_try < 5 then return end
    last_hook_try = now

    pcall(function() LoadAsset(ROW_BP_PATH) end)

    local ok = pcall(function()
        RegisterHook(ROW_BIND_FN, function(Context, SlotParam)
            pcall(function()
                local row = Context:get()
                if not alive(row) then return end
                local rname = full_name(row)
                if not rname then return end

                local slot = SlotParam:get()
                if not alive(slot) then return end
                local handle = slot.Handle
                if not alive(handle) then return end

                local id
                pcall(function() id = handle:GetIndividualID() end)
                if id == nil then return end

                local key = api.instance_key(id)
                if key then
                    -- Nickname and species are captured here, not looked up
                    -- from the last pass: overrides have to render for every
                    -- pal on the list, including ones no pass ever placed.
                    -- Ranks are captured here too. A pal with no aptitude
                    -- for a work type must keep its vanilla dash: writing a
                    -- priority into that cell claims the pal will do work it
                    -- is not capable of.
                    local name, species
                    local ranks = {}
                    pcall(function()
                        local param = handle:TryGetIndividualParameter()
                        if alive(param) then
                            name = api.pal_name(param)
                            species = api.pal_species(param)
                            for t = 1, #workdefs.ORDER do
                                local r = api.suitability_rank(param, t)
                                if type(r) == "number" and r > 0 then ranks[t] = r end
                            end
                        end
                    end)

                    -- The unmasked ints as well as the hex key: turning a
                    -- work type off goes through an RPC that wants the guid
                    -- structs verbatim, and the key cannot be turned back.
                    local raw
                    pcall(function()
                        raw = {
                            PlayerUId  = { A = id.PlayerUId.A,  B = id.PlayerUId.B,
                                           C = id.PlayerUId.C,  D = id.PlayerUId.D },
                            InstanceId = { A = id.InstanceId.A, B = id.InstanceId.B,
                                           C = id.InstanceId.C, D = id.InstanceId.D },
                        }
                    end)

                    row_pal[rname] = {
                        key = key, name = name, species = species,
                        ranks = ranks, raw = raw,
                    }
                    -- rows binding means the screen is opening or scrolling;
                    -- either way the cell list has moved
                    menu_likely_open = true
                    invalidate_cells()
                end
            end)
        end)
    end)

    if ok then
        bind_hooked = true
        log.debug("BindFromSlot hook registered")
    end
end

-- ---------------------------------------------------------------------------
-- Menu discovery
-- ---------------------------------------------------------------------------

local function is_showing(m)
    local ok, vis = pcall(function() return m:IsVisible() end)
    -- a failed visibility call counts as visible: don't go dark on a quirk
    if not ok then return true end
    return vis == true
end

-- Only a VISIBLE non-CDO instance counts. Returns menu, tree, root.
local function live_menu()
    if alive(menu_ref) and is_showing(menu_ref) then
        local t, r
        pcall(function() t = menu_ref.WidgetTree end)
        if alive(t) then pcall(function() r = t.RootWidget end) end
        if alive(t) and alive(r) then return menu_ref, t, r end
    end

    menu_ref = nil
    invalidate_cells()

    local menu, tree, root
    pcall(function()
        for _, m in ipairs(FindAllOf(M.MENU_CLASS) or {}) do
            if menu == nil and alive(m) then
                local name = full_name(m) or ""
                if not name:find("Default__", 1, true) and is_showing(m) then
                    local t, r
                    pcall(function() t = m.WidgetTree end)
                    if alive(t) then pcall(function() r = t.RootWidget end) end
                    if alive(t) and alive(r) then
                        menu, tree, root = m, t, r
                    end
                end
            end
        end
    end)

    if menu then menu_ref = menu end
    return menu, tree, root
end

-- ---------------------------------------------------------------------------
-- Cell -> row
-- ---------------------------------------------------------------------------

-- The cell's Outer chain leads to the GameInstance, not the row. The SLATE
-- parent does reach it: the panel the cell renders in lives in the row's tree.
local function row_of_cell(cell)
    local node
    pcall(function() node = cell:GetParent() end)
    if not alive(node) then return nil end
    for _ = 1, 5 do
        if class_name(node) == M.ROW_CLASS then return node end
        local outer
        pcall(function() outer = node:GetOuter() end)
        if not alive(outer) then return nil end
        node = outer
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Per-cell TextBlock
-- ---------------------------------------------------------------------------

-- Sibling of the checkbox with its slot geometry copied. The cell uses
-- absolute layout, so geometry must be copied rather than inferred.
local function inject_at_checkbox(cell, tb)
    local cb
    pcall(function() cb = cell.PalCheckBox end)
    if not alive(cb) then return false end

    local parent
    pcall(function() parent = cb:GetParent() end)
    if not alive(parent) then return false end

    local cb_slot
    pcall(function() cb_slot = cb.Slot end)
    if not alive(cb_slot) then return false end

    local new_slot
    local ok = pcall(function() new_slot = parent:AddChild(tb) end)
    if not ok or not alive(new_slot) then return false end

    if class_name(cb_slot) == "CanvasPanelSlot" then
        pcall(function() new_slot:SetAnchors(cb_slot:GetAnchors()) end)
        pcall(function() new_slot:SetPosition(cb_slot:GetPosition()) end)
        pcall(function() new_slot:SetSize(cb_slot:GetSize()) end)
        pcall(function() new_slot:SetAlignment(cb_slot:GetAlignment()) end)
        pcall(function() new_slot:SetZOrder(cb_slot:GetZOrder() + 1) end)
    else
        pcall(function() new_slot:SetHorizontalAlignment(cb_slot.HorizontalAlignment) end)
        pcall(function() new_slot:SetVerticalAlignment(cb_slot.VerticalAlignment) end)
        pcall(function() new_slot:SetPadding(cb_slot.Padding) end)
    end
    return true
end

-- Fallback when the checkbox route fails: first Overlay in the cell's tree,
-- else the root with plain AddChild.
local function inject_fallback(cell, tb)
    local tree
    pcall(function() tree = cell.WidgetTree end)
    if not alive(tree) then return false end

    local root
    pcall(function() root = tree.RootWidget end)
    if not alive(root) then return false end

    local queue, visited = { root }, 0
    while #queue > 0 and visited < 20 do
        local node = table.remove(queue, 1)
        visited = visited + 1
        if class_name(node) == "Overlay" then
            local oslot
            local ok = pcall(function() oslot = node:AddChildToOverlay(tb) end)
            if ok and oslot then
                pcall(function() oslot:SetHorizontalAlignment(2) end)
                pcall(function() oslot:SetVerticalAlignment(2) end)
                return true
            end
        end
        local n = 0
        pcall(function() n = node:GetChildrenCount() end)
        if type(n) == "number" then
            for i = 0, n - 1 do
                local child
                pcall(function() child = node:GetChildAt(i) end)
                if alive(child) then queue[#queue + 1] = child end
            end
        end
    end

    return pcall(function() root:AddChild(tb) end)
end

local function ensure_cell_text(cell, cell_name)
    local cached = cell_text[cell_name]
    if cached then
        if alive(cached) then return cached end
        cell_text[cell_name] = nil
        cell_last[cell_name] = nil
    end

    local tree
    pcall(function() tree = cell.WidgetTree end)
    if not alive(tree) then return nil end

    local cls = api.cdo("/Script/UMG.TextBlock")
    if not cls then return nil end

    local tb
    pcall(function() tb = StaticConstructObject(cls, tree) end)
    if not alive(tb) then return nil end

    if not inject_at_checkbox(cell, tb) then
        if not inject_fallback(cell, tb) then
            warn_once("cellinject", "cell injection failed, grid numbers unavailable")
            return nil
        end
    end

    -- The number must never eat a click meant for the checkbox underneath.
    pcall(function() tb:SetVisibility(3) end)
    pcall(function() tb:SetJustification(1) end)
    pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)

    cell_text[cell_name] = tb
    return tb
end

-- RimWorld's work-tab palette (WidgetsWork.ColorOfPriority), lifted slightly
-- off pure primaries for this darker UI. Colour means priority and nothing
-- else, so the same number is always the same colour.
local COLOUR = {
    p1       = { R = 0.25, G = 1.00, B = 0.25, A = 1.0 },
    p2       = { R = 1.00, G = 1.00, B = 0.15, A = 1.0 },
    p3       = { R = 1.00, G = 0.55, B = 0.05, A = 1.0 },
    p4       = { R = 1.00, G = 0.25, B = 0.18, A = 1.0 },
    p5       = { R = 0.62, G = 0.62, B = 0.62, A = 1.0 },
    off      = { R = 0.42, G = 0.42, B = 0.45, A = 0.9 },
    blank    = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 },
    -- Ceilings are blue on purpose. Nothing in the priority run is blue, so
    -- a number in the header can never be mistaken for a priority.
    cap_set  = { R = 0.40, G = 0.78, B = 1.00, A = 1.0 },
    cap_none = { R = 0.45, G = 0.45, B = 0.48, A = 0.75 },
}

local function colour_for(prio)
    local n = math.floor(tonumber(prio) or 0)
    if n < 1 then return "p5" end
    return "p" .. math.min(n, 5)
end

-- Hidden (2), not Collapsed, so the cell keeps its layout space and the grid
-- does not shift. Re-hidden every tick because the vanilla row refresh can
-- put it back.
local function hide_checkbox(cell, cell_name)
    pcall(function()
        local cb = cell.PalCheckBox
        if not alive(cb) then return end
        if cell_cb[cell_name] == nil then
            local ok, v = pcall(function() return cb:GetVisibility() end)
            cell_cb[cell_name] = (ok and type(v) == "number") and v or 0
        end
        cb:SetVisibility(2)
    end)
end

local function restore_checkbox(cell, cell_name)
    if cell_cb[cell_name] == nil then return end
    local want = cell_cb[cell_name]
    pcall(function()
        local cb = cell.PalCheckBox
        if alive(cb) then cb:SetVisibility(want) end
    end)
    cell_cb[cell_name] = nil
end

-- The grid does not mark which job a pal is on right now. Three
-- attempts all made it worse, and the game already answers that in its own
-- info panel. This is an editor: it shows what you set.
local function set_cell(tb, cell_name, glyph, colour_key)
    local token = glyph .. "|" .. colour_key
    if cell_last[cell_name] == token then return end

    local ft = make_ftext(glyph)
    if not ft then return end

    local ok = pcall(function() tb:SetText(ft) end)
    if not ok then return end

    pcall(function()
        tb:SetColorAndOpacity({
            SpecifiedColor = COLOUR[colour_key],
            ColorUseRule = 0,
        })
    end)

    cell_last[cell_name] = token
end

-- ---------------------------------------------------------------------------
-- What a cell should show
-- ---------------------------------------------------------------------------

local function handle_cell(cfg, cell)
    if not alive(cell) then return end
    local cell_name = full_name(cell)
    if not cell_name or cell_name:find("Default__", 1, true) then return end

    -- The battle-mode variant of the same cell class is not a work cell.
    local battle = false
    pcall(function() battle = cell.IsBattleSettingMode end)
    if battle == true then return end

    local t
    pcall(function() t = cell.BindedSuitability end)
    t = api.as_int(t)
    if t == nil or t <= 0 then return end

    local work_name = workdefs.name(t)
    if work_name == nil then return end

    local rname = cell_row[cell_name]
    if not rname then
        local row = row_of_cell(cell)
        if not row then return end
        rname = full_name(row)
        if not rname then return end
        cell_row[cell_name] = rname
    end

    local pal = row_pal[rname]
    if not pal then return end

    local prio = store.effective(cfg, pal, work_name, t)

    -- Hand the cell back to the game when we have nothing to say about it:
    -- the pal cannot do this work at all, or the work type is not configured.
    -- Vanilla draws a dash for the first case, and a number there would claim
    -- the pal will do something it is incapable of.
    local capable = pal.ranks and pal.ranks[t] ~= nil
    if not capable or prio == nil then
        local existing = cell_text[cell_name]
        if existing and alive(existing) then
            set_cell(existing, cell_name, "", "blank")
        end
        restore_checkbox(cell, cell_name)
        return
    end

    local tb = ensure_cell_text(cell, cell_name)
    if not tb then return end

    -- Ours now, so the tick underneath has to go or it shows through.
    hide_checkbox(cell, cell_name)

    local glyph, colour
    if prio == false then
        glyph, colour = "X", "off"
    else
        glyph, colour = tostring(math.floor(prio)), colour_for(prio)
    end

    set_cell(tb, cell_name, glyph, colour)
end

local function refresh_cells(cfg)
    -- Index the last pass once per refresh, not once per cell.
    if cell_cache == nil then
        cell_cache = {}
        pcall(function()
            for _, c in ipairs(FindAllOf(M.CELL_CLASS) or {}) do
                cell_cache[#cell_cache + 1] = c
            end
        end)
    end

    for _, cell in ipairs(cell_cache) do
        pcall(function() handle_cell(cfg, cell) end)
    end
end

-- ---------------------------------------------------------------------------
-- Entry point, once per UI tick
-- ---------------------------------------------------------------------------

function M.refresh(cfg)
    try_hook_bind()

    -- Plain Lua read while the stand has never been opened: zero engine calls
    -- is the whole idle cost of the mod.
    if not menu_likely_open then return false end

    local menu = live_menu()
    if not menu then
        if menu_ref ~= nil then M.detach() end
        -- Stand down until a row binds again. Without this the mod runs a
        -- FindAllOf every second for the rest of the session after the stand
        -- is opened once.
        menu_likely_open = false
        return false
    end

    refresh_cells(cfg)
    pcall(function() refresh_ceilings(cfg, menu) end)

    store.flush()
    return true
end

-- Set by a click; main clears it after running a pass, so an edit takes
-- effect within a second rather than waiting out the 30s cycle.
M.wants_pass = false

-- ---------------------------------------------------------------------------
-- Ceiling row
-- ---------------------------------------------------------------------------
--
-- The stand's icon header is a HorizontalBox of thirteen 32x32 SizeBoxes, one
-- per work suitability in enum order, each holding a
-- WBP_MainMenu_Pal_WorkIcon_C whose root canvas is somewhere a number can
-- sit. Hanging the row off that box means the columns line themselves up:
-- there are no coordinates to compute, and none to keep in step when the
-- game's own layout shifts under us.

local HEADER_BOX = "HorizontalBox_WorkIcon"
local ICON_SIZE = 32

-- What a click walks through. Ceilings run into the thousands, so a step of
-- one would be useless, and the steps coarsen as the numbers grow.
local LADDER = {
    100, 250, 500, 1000, 2000, 3000, 5000,
    7500, 10000, 15000, 20000, 30000, 50000,
}

-- Bounded breadth-first search for a widget by name. A nested UserWidget
-- keeps its children in its own WidgetTree rather than behind GetChildAt, so
-- both routes have to be followed.
local function find_named(root, want)
    local queue, seen = { root }, 0

    while #queue > 0 and seen < 800 do
        local node = table.remove(queue, 1)
        seen = seen + 1

        if alive(node) then
            local name
            pcall(function() name = node:GetFName():ToString() end)
            if name == want then return node end

            local tree
            pcall(function() tree = node.WidgetTree end)
            if alive(tree) then
                local sub
                pcall(function() sub = tree.RootWidget end)
                if alive(sub) then queue[#queue + 1] = sub end
            end

            local count = 0
            pcall(function() count = node:GetChildrenCount() end)
            if type(count) == "number" then
                for i = 0, count - 1 do
                    local child
                    pcall(function() child = node:GetChildAt(i) end)
                    if alive(child) then queue[#queue + 1] = child end
                end
            end
        end
    end
    return nil
end

-- The canvas inside each icon column, keyed by suitability value.
--
-- The icons are laid out in enum order and the enum reserves 0 for None, so
-- the first icon is suitability 1. If a game update ever reorders them the
-- numbers would sit under the wrong icons, which is visible at a glance
-- rather than silent.
local function header_columns(menu)
    if ceiling_cols then return ceiling_cols end

    local tree
    pcall(function() tree = menu.WidgetTree end)
    if not alive(tree) then return nil end

    local root
    pcall(function() root = tree.RootWidget end)
    if not alive(root) then return nil end

    local box = find_named(root, HEADER_BOX)
    if not alive(box) then
        warn_once("nohdr", "work icon header not found, so no ceiling row")
        return nil
    end

    local count = 0
    pcall(function() count = box:GetChildrenCount() end)
    if type(count) ~= "number" or count == 0 then return nil end

    local cols = {}
    for i = 0, count - 1 do
        local sizebox
        pcall(function() sizebox = box:GetChildAt(i) end)

        local icon
        if alive(sizebox) then pcall(function() icon = sizebox:GetChildAt(0) end) end

        local itree, iroot
        if alive(icon) then pcall(function() itree = icon.WidgetTree end) end
        if alive(itree) then pcall(function() iroot = itree.RootWidget end) end

        if alive(iroot) then cols[i + 1] = iroot end
    end

    ceiling_cols = cols
    return cols
end

local function ensure_ceiling_text(value, canvas)
    local cached = ceiling_text[value]
    if cached then
        if alive(cached) then return cached end
        ceiling_text[value] = nil
        ceiling_last[value] = nil
    end

    local cls = api.cdo("/Script/UMG.TextBlock")
    if not cls then return nil end

    local tb
    pcall(function() tb = StaticConstructObject(cls, canvas) end)
    if not alive(tb) then return nil end

    local slot
    local ok = pcall(function() slot = canvas:AddChildToCanvas(tb) end)
    if not ok or not alive(slot) then return nil end

    -- Wider than the icon and nudged left, so a five digit ceiling stays
    -- centred under a 32 pixel column instead of drifting right.
    pcall(function() slot:SetAutoSize(false) end)
    pcall(function() slot:SetPosition({ X = -8, Y = ICON_SIZE + 1 }) end)
    pcall(function() slot:SetSize({ X = ICON_SIZE + 16, Y = 16 }) end)
    pcall(function() slot:SetZOrder(50) end)

    -- Visible rather than HitTestInvisible, unlike the grid numbers: this row
    -- is the control, and a widget that cannot be hit cannot report IsHovered
    -- either, so making it click-through would make it unclickable.
    pcall(function() tb:SetVisibility(0) end)
    pcall(function() tb:SetJustification(1) end)
    pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)

    ceiling_text[value] = tb
    return tb
end

-- Which item a ceiling set from the stand applies to. Work types that produce
-- nothing in particular have no answer, and their columns stay blank.
local function ceiling_material(cfg, work_name)
    return (cfg.ceiling_material or {})[work_name]
end

local function ceiling_now(cfg, work_name, item)
    if item == nil then return nil end
    local ceilings = caps.for_work(cfg, work_name)
    if ceilings == nil then return nil end
    return ceilings[item]
end

function refresh_ceilings(cfg, menu)
    local cols = header_columns(menu)
    if cols == nil then return end

    for value, canvas in pairs(cols) do
        local work_name = workdefs.name(value)
        if work_name and alive(canvas) then
            local item = ceiling_material(cfg, work_name)
            local ceiling = ceiling_now(cfg, work_name, item)

            local glyph, colour
            if ceiling then
                glyph, colour = tostring(math.floor(ceiling)), "cap_set"
            elseif item then
                glyph, colour = "-", "cap_none"
            else
                -- No material to hang a ceiling on, so nothing to show and
                -- nothing a click here could mean.
                glyph, colour = "", "cap_none"
            end

            local token = glyph .. "|" .. colour
            if ceiling_last[value] ~= token then
                local tb = ensure_ceiling_text(value, canvas)
                if tb then
                    local ft = make_ftext(glyph)
                    if ft then
                        pcall(function() tb:SetText(ft) end)
                        pcall(function()
                            tb:SetColorAndOpacity({
                                SpecifiedColor = COLOUR[colour],
                                ColorUseRule = 0,
                            })
                        end)
                        ceiling_last[value] = token
                    end
                end
            end
        end
    end
end

local function hovered_ceiling()
    for value, tb in pairs(ceiling_text) do
        local hit = false
        pcall(function()
            if alive(tb) then hit = tb:IsHovered() end
        end)
        if hit == true then return value end
    end
    return nil
end

-- dir -1 raises the ceiling, +1 lowers it and eventually takes it off.
-- Both ends clamp rather than wrap, as the priority cells do.
local function step_ceiling(current, dir)
    if dir < 0 then
        if current == nil then return LADDER[1] end
        for _, step in ipairs(LADDER) do
            if step > current then return step end
        end
        return LADDER[#LADDER]
    end

    if current == nil then return nil end
    local below = nil
    for _, step in ipairs(LADDER) do
        if step < current then below = step end
    end
    return below
end

local function bump_ceiling(cfg, value, dir)
    local work_name = workdefs.name(value)
    if work_name == nil then return end

    local item = ceiling_material(cfg, work_name)
    if item == nil then
        log.say(workdefs.label(work_name) ..
            " has no material to cap. Add one to ceiling_material in config.lua")
        return
    end

    local current = ceiling_now(cfg, work_name, item)
    local next_ceiling = step_ceiling(current, dir)
    if next_ceiling == current then return end

    if next_ceiling == nil then
        caps.clear(work_name, item)
    else
        caps.set(work_name, item, next_ceiling)
    end

    ceiling_last[value] = nil
    M.wants_pass = true

    log.say(string.format("%s pauses at %s %s",
        workdefs.label(work_name),
        next_ceiling and tostring(next_ceiling) or "no limit,",
        item))
end

-- ---------------------------------------------------------------------------
-- Clicking a cell
-- ---------------------------------------------------------------------------

-- Exactly one cell can be hovered. IsHovered still answers with the checkbox
-- hidden, since Hidden removes the checkbox from hit testing, not the cell.
local function hovered_cell()
    if cell_cache == nil then return nil end
    for _, cell in ipairs(cell_cache) do
        local hit = false
        pcall(function()
            if alive(cell) then hit = cell:IsHovered() end
        end)
        if hit == true then return cell end
    end
    return nil
end

-- Resolves a cell to the pal and work type it represents, or nil when it is
-- not one of ours to touch.
local function cell_target(cell)
    if not alive(cell) then return nil end

    local battle = false
    pcall(function() battle = cell.IsBattleSettingMode end)
    if battle == true then return nil end

    local t = api.as_int((function()
        local v
        pcall(function() v = cell.BindedSuitability end)
        return v
    end)())
    if t == nil or t <= 0 then return nil end

    local work_name = workdefs.name(t)
    if work_name == nil then return nil end

    local cname = full_name(cell)
    if not cname then return nil end

    local rname = cell_row[cname]
    if not rname then
        local row = row_of_cell(cell)
        if not row then return nil end
        rname = full_name(row)
        if not rname then return nil end
        cell_row[cname] = rname
    end

    local pal = row_pal[rname]
    if not pal then return nil end

    -- Never write a priority into a cell for work the pal cannot do: the
    -- grid leaves those to vanilla, and an invisible edit sitting under a
    -- dash would surface later as a mystery.
    if not (pal.ranks and pal.ranks[t]) then return nil end

    return pal, t, work_name, cname
end

-- dir -1 for left click (towards priority 1), +1 for right click.
local function bump(cfg, dir)
    if not menu_likely_open then return end

    -- The header row is checked first. Its numbers sit outside every cell, so
    -- the two can never both be hovered, and asking about them first keeps
    -- the cheap plain-Lua loop ahead of the FindAllOf-backed one.
    local ceiling = hovered_ceiling()
    if ceiling then
        bump_ceiling(cfg, ceiling, dir)
        return
    end

    local cell = hovered_cell()
    if not cell then return end

    local pal, t, work_name, cname = cell_target(cell)
    if not pal then return end

    local current = store.effective(cfg, pal, work_name, t)
    local next_prio = store.cycle(current, dir)
    if next_prio == current then return end

    store.set(pal.key, t, next_prio)

    -- Deliberately NOT writing the game's permission flag here: the fence
    -- owns those. A click changes policy, the pass applies it. Writing here
    -- too gave one click three authorities and made the checkbox flicker.
    M.wants_pass = true

    -- Repaint this one cell immediately rather than waiting up to a second
    -- for the poll: a priority control that answers late feels broken even
    -- when it is working, and repainting also re-hides the checkbox the
    -- vanilla click just made visible again.
    cell_last[cname] = nil
    pcall(function() handle_cell(cfg, cell) end)

    log.debug(string.format("%s %s -> %s",
        tostring(pal.name), work_name,
        next_prio == false and "X" or tostring(next_prio)))
end

-- Bound once, not per menu. The handlers bail on a plain Lua flag when the
-- stand is shut, so ordinary gameplay clicks cost nothing measurable.
function M.bind_mouse(cfg_ref)
    local bound = 0

    local function try(key_name, dir)
        local key
        pcall(function() key = Key[key_name] end)
        if key == nil then
            warn_once("mouse" .. key_name,
                key_name .. " not available in this UE4SS build, " ..
                "click editing disabled for that button")
            return
        end
        local ok = pcall(function()
            RegisterKeyBind(key, function()
                pcall(function() bump(cfg_ref(), dir) end)
            end)
        end)
        if ok then bound = bound + 1 end
    end

    try("LEFT_MOUSE_BUTTON", -1)
    try("RIGHT_MOUSE_BUTTON", 1)
    return bound
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

-- Walks an open menu's widget tree, with canvas geometry where there is any.
--
-- The ceiling row has to line up under the work type icons, and neither the
-- widget that holds those icons nor the x of each column is something to
-- guess at. Reading any property name off a UE4SS object returns a live
-- looking wrapper whether or not it exists, so the only safe move is to
-- print what is actually there and build against that.
--
-- Only useful with the stand open. With it shut the menu has no tree.
local function dump_tree(f, node, depth, budget)
    if budget.n >= 1200 then return end
    if not alive(node) then return end
    budget.n = budget.n + 1

    local name = "?"
    pcall(function() name = node:GetFName():ToString() end)

    local geom = ""
    local slot
    pcall(function() slot = node.Slot end)
    if alive(slot) then
        local sclass = class_name(slot) or "?"
        if sclass == "CanvasPanelSlot" then
            pcall(function()
                local pos = slot:GetPosition()
                local size = slot:GetSize()
                geom = string.format("  pos=(%.0f,%.0f) size=(%.0f,%.0f)",
                    pos.X, pos.Y, size.X, size.Y)
            end)
        else
            -- The icon row is a HorizontalBox, so its children carry a
            -- HorizontalBoxSlot with no coordinates at all. Naming the slot
            -- class is what says which way a ceiling row has to be built.
            geom = "  slot=" .. sclass
        end
    end

    -- A SizeBox is what fixes each icon column's width, so its override is
    -- the column pitch a ceiling row would have to match.
    pcall(function()
        if class_name(node) == "SizeBox" then
            local w = node.WidthOverride
            local h = node.HeightOverride
            if w then geom = geom .. string.format("  w=%.0f h=%.0f", w, h or 0) end
        end
    end)

    -- The suitability a cell is bound to, so a column can be matched to a
    -- work type by something better than its position in the list.
    local suit
    pcall(function() suit = api.as_int(node.BindedSuitability) end)
    if suit and suit > 0 then
        geom = geom .. "  suit=" .. suit .. " (" ..
            tostring(workdefs.name(suit)) .. ")"
    end

    f:write(string.rep("  ", depth) .. (class_name(node) or "?") ..
        " " .. name .. geom .. "\n")

    if depth >= 15 then
        f:write(string.rep("  ", depth + 1) .. "...\n")
        return
    end

    -- A nested UserWidget keeps its children in its own WidgetTree rather
    -- than behind GetChildAt, so both routes have to be walked.
    local tree
    pcall(function() tree = node.WidgetTree end)
    if alive(tree) then
        local root
        pcall(function() root = tree.RootWidget end)
        if alive(root) then dump_tree(f, root, depth + 1, budget) end
    end

    local count = 0
    pcall(function() count = node:GetChildrenCount() end)
    if type(count) ~= "number" then return end
    for i = 0, count - 1 do
        local child
        pcall(function() child = node:GetChildAt(i) end)
        if alive(child) then dump_tree(f, child, depth + 1, budget) end
    end
end

function M.dump(f)
    f:write("=== monitoring stand (" .. M.MENU_CLASS .. ")\n")
    f:write("  bind hook: " .. tostring(bind_hooked) ..
        "  rows captured: " .. tostring((function()
            local n = 0
            for _ in pairs(row_pal) do n = n + 1 end
            return n
        end)()) .. "\n")

    local instances = {}
    pcall(function()
        for _, m in ipairs(FindAllOf(M.MENU_CLASS) or {}) do
            instances[#instances + 1] = m
        end
    end)

    f:write("  menu instances: " .. #instances .. "\n")
    for i, m in ipairs(instances) do
        local name = full_name(m) or "?"
        local t, r
        pcall(function() t = m.WidgetTree end)
        if alive(t) then pcall(function() r = t.RootWidget end) end
        f:write(string.format("   [%d] tree=%s root=%s showing=%s  %s\n",
            i, tostring(alive(t)), tostring(alive(r)),
            tostring(alive(m) and is_showing(m)), name))

        if alive(r) and alive(m) and is_showing(m) then
            f:write("   widget tree:\n")
            dump_tree(f, r, 4, { n = 0 })
        end
    end

    if #instances > 0 then
        local any = false
        for _, m in ipairs(instances) do
            if alive(m) and is_showing(m) then any = true end
        end
        if not any then
            f:write("  no menu on screen, so no tree to walk. " ..
                "Open the Monitoring Stand and run this again.\n")
        end
    end

    local cells = {}
    pcall(function()
        for _, c in ipairs(FindAllOf(M.CELL_CLASS) or {}) do
            cells[#cells + 1] = c
        end
    end)
    f:write("  cell instances: " .. #cells .. "\n")

    local shown = 0
    for _, c in ipairs(cells) do
        if shown >= 5 then break end
        if alive(c) then
            shown = shown + 1
            local t, battle
            pcall(function() t = c.BindedSuitability end)
            pcall(function() battle = c.IsBattleSettingMode end)
            local row = row_of_cell(c)
            local rname = row and full_name(row) or "?"
            f:write(string.format("   cell suit=%s battle=%s row=%s key=%s\n",
                tostring(api.as_int(t)), tostring(battle),
                rname, tostring((row_pal[rname or ""] or {}).key)))
        end
    end
end

return M
