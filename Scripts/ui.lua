-- The Monitoring Stand display.
--
-- Two layers, both read-only:
--   * one number per grid cell — the priority in force for that pal and work
--     type, replacing the vanilla checkbox, coloured strictly on RimWorld's
--     work-tab scale. A cyan glow behind the number marks the cell the last
--     pass actually assigned. Work the pal cannot do keeps its vanilla dash.
--   * a one-line status strip on the menu itself: mode, cap, dry/live, and
--     the last pass summary
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
--   CRASH RULE 2: never READ a row's bindedSlot property — the read itself
--   crashes natively inside UE4SS before Lua sees anything. Pal identity is
--   captured by hooking the row's BindFromSlot function instead, where the
--   slot arrives as a safe hook argument.

local log = require("log")
local api = require("palapi")
local workdefs = require("workdefs")
local store = require("store")

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

-- Status strip.
local strip = nil               -- TextBlock on the menu root
local strip_menu = nil          -- menu instance it belongs to
local strip_last = nil

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

-- Drops only the lookup caches. cell_text and cell_last deliberately survive.
--
-- This runs on every BindFromSlot, which means every scroll step — and rows
-- RECYCLE rather than being destroyed, so the cell widget and the TextBlock
-- already injected into it are both still alive. Clearing cell_text here
-- would make ensure_cell_text construct a second TextBlock at the same copied
-- geometry on the next tick, leaving the first one orphaned and still
-- rendering the previous pal's number. One scroll would double every glyph in
-- the grid, and it would keep stacking from there.
--
-- ensure_cell_text already drops entries whose widget genuinely died, which
-- is the only case that needs handling.
local function invalidate_cells()
    cell_cache = nil
    cell_row = {}
end

-- The menu is gone or going: unlike a scroll rebind, this really does
-- destroy the cell widgets, so the injected map is cleared here rather than
-- in invalidate_cells.
function M.detach()
    strip = nil
    strip_menu = nil
    strip_last = nil
    menu_ref = nil
    cell_text = {}
    cell_last = {}
    cell_cb = {}
    invalidate_cells()
end

-- World switch: every engine wrapper is dead. The bind hook itself survives
-- (UE4SS hooks are global), so bind_hooked stays.
function M.reset()
    M.detach()
    row_pal = {}
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

    warn_once("ftext", "no working FText path on this build — the stand UI cannot render")
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
                    -- is simply incapable of.
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

-- The cell's Outer chain goes to the GameInstance (dynamic CreateWidget), so
-- identity must come through the SLATE parent: the panel the cell actually
-- renders in lives inside the row's tree, and its Outer chain reaches the row.
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

-- Sibling-of-checkbox with copied slot geometry: identical placement by
-- construction. The cell's internals are canvas-style absolute layout, so
-- geometry is copied, never inferred.
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
            warn_once("cellinject", "cell injection failed — grid numbers unavailable")
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

-- RimWorld's work-tab palette (WidgetsWork.ColorOfPriority): 1 green,
-- 2 yellow, 3 orange, 4 red, anything beyond grey. Lifted very slightly off
-- pure primaries, which read harshly against this darker UI.
--
-- These are the ONLY thing that decides a number's colour. Whether the pal
-- is currently assigned there is shown by the shadow, not by the fill.
local COLOUR = {
    p1       = { R = 0.25, G = 1.00, B = 0.25, A = 1.0 },
    p2       = { R = 1.00, G = 1.00, B = 0.15, A = 1.0 },
    p3       = { R = 1.00, G = 0.55, B = 0.05, A = 1.0 },
    p4       = { R = 1.00, G = 0.25, B = 0.18, A = 1.0 },
    p5       = { R = 0.62, G = 0.62, B = 0.62, A = 1.0 },
    off      = { R = 0.42, G = 0.42, B = 0.45, A = 0.9 },
    blank    = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 },
}

local function colour_for(prio)
    local n = math.floor(tonumber(prio) or 0)
    if n < 1 then return "p5" end
    return "p" .. math.min(n, 5)
end

-- The vanilla checkbox has to go where a number is drawn, or the tick shows
-- through the glyph. Hidden (2) rather than Collapsed keeps the cell's layout
-- space, so the grid does not shift. The vanilla row refresh can re-show it,
-- hence hiding every tick rather than once.
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

-- Colour says priority and NOTHING else, so the same number is always the
-- same colour. Assignment is shown by drawing that number larger.
--
-- Colour carrying both facts made two pals at priority 3 render differently
-- and read as a fault. A coloured drop shadow was worse: it is literally a
-- second copy of the glyph, and looked like one.
local function set_cell(tb, cell_name, glyph, colour_key, assigned)
    local token = glyph .. "|" .. colour_key .. "|" .. tostring(assigned and 1 or 0)
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

    -- Size, not colour and not shadow. A drop shadow is a second copy of the
    -- glyph drawn behind and offset, so a bright one reads as a duplicate
    -- number rather than a glow — which is exactly how the cyan attempt
    -- looked in game. Scaling keeps one glyph, one colour, and still makes
    -- the assigned cell obvious.
    pcall(function()
        tb:SetRenderScale(assigned and { X = 1.35, Y = 1.35 } or { X = 1.0, Y = 1.0 })
    end)

    cell_last[cell_name] = token
end

-- ---------------------------------------------------------------------------
-- What a cell should show
-- ---------------------------------------------------------------------------

local function handle_cell(cfg, lookup, cell)
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
            set_cell(existing, cell_name, "", "blank", false)
        end
        restore_checkbox(cell, cell_name)
        return
    end

    local tb = ensure_cell_text(cell, cell_name)
    if not tb then return end

    -- Ours now, so the tick underneath has to go or it shows through.
    hide_checkbox(cell, cell_name)

    -- Colour carries the priority; white says the last pass actually put this
    -- pal on this work. The glyph is the effective priority either way —
    -- showing the bucket's global number in the assigned cell would
    -- contradict the pal's own override sitting in the rest of that column.
    local assigned = lookup.assign[pal.key .. "|" .. t] ~= nil
    local glyph, colour

    if prio == false then
        glyph, colour = "X", "off"
    else
        glyph, colour = tostring(math.floor(prio)), colour_for(prio)
    end

    set_cell(tb, cell_name, glyph, colour, assigned)
end

local function refresh_cells(cfg, report)
    -- Index the last pass once per refresh, not once per cell.
    local lookup = { assign = {} }
    if report and report.lines then
        for _, e in ipairs(report.lines) do
            if e.key and e.value then
                lookup.assign[e.key .. "|" .. e.value] = e
            end
        end
    end

    if cell_cache == nil then
        cell_cache = {}
        pcall(function()
            for _, c in ipairs(FindAllOf(M.CELL_CLASS) or {}) do
                cell_cache[#cell_cache + 1] = c
            end
        end)
    end

    for _, cell in ipairs(cell_cache) do
        pcall(function() handle_cell(cfg, lookup, cell) end)
    end
end

-- ---------------------------------------------------------------------------
-- Status strip
-- ---------------------------------------------------------------------------

-- Deliberately terse. The log summary is around 120 characters and ran off
-- the side of the screen; the strip has roughly 50 to work with.
function M.compose(cfg, report)
    local head = string.format("PWP  %s  %s  cap %s",
        cfg.enabled and (cfg.dry_run and "DRY RUN" or "LIVE") or "OFF",
        cfg.assignment_mode,
        cfg.max_pals_per_work_type and tostring(cfg.max_pals_per_work_type) or "-")

    if not report then return head .. "   no pass yet" end
    if (report.camps or 0) == 0 then return head .. "   no base camp" end

    return string.format("%s   %d/%d pals   %d queued",
        head, report.placed or 0, report.pals or 0, report.queued or 0)
end

local function attach_strip(menu, tree, root)
    local cls = api.cdo("/Script/UMG.TextBlock")
    if not cls then
        warn_once("tbclass", "UMG.TextBlock not found — status strip unavailable")
        return false
    end

    local tb
    pcall(function() tb = StaticConstructObject(cls, tree) end)
    if not alive(tb) then
        warn_once("construct", "could not construct the status strip")
        return false
    end

    local placed = false
    local slot
    if pcall(function() slot = root:AddChildToCanvas(tb) end) and slot then
        pcall(function()
            slot:SetAutoSize(true)
            -- The menu's own title bar, to the right of "Monitoring Stand".
            -- It is the one wide empty run on this screen: the bottom of the
            -- canvas put the strip over the hotbar, and lifting it only moved
            -- it onto the panel border and the pal info card.
            slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 },
                              Maximum = { X = 0.0, Y = 0.0 } })
            slot:SetAlignment({ X = 0.0, Y = 0.5 })
            slot:SetPosition({ X = 410.0, Y = 176.0 })
        end)
        placed = true
    elseif pcall(function() slot = root:AddChildToOverlay(tb) end) and slot then
        pcall(function()
            slot:SetHorizontalAlignment(0)
            slot:SetVerticalAlignment(2)
        end)
        placed = true
    elseif pcall(function() root:AddChild(tb) end) then
        placed = true
    end

    if not placed then
        warn_once("stripadd", "stand menu root accepted no child — status strip unavailable")
        return false
    end

    pcall(function() tb:SetVisibility(3) end)
    pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)
    pcall(function()
        tb:SetColorAndOpacity({
            SpecifiedColor = { R = 0.9, G = 0.9, B = 0.9, A = 1.0 },
            ColorUseRule = 0,
        })
    end)

    strip = tb
    strip_menu = menu
    strip_last = nil
    return true
end

local function refresh_strip(cfg, report, menu, tree, root)
    if strip_menu ~= menu or not alive(strip) then
        strip = nil
        strip_menu = nil
        if not attach_strip(menu, tree, root) then return end
    end

    local text = M.compose(cfg, report)
    if text == strip_last then return end

    local ft = make_ftext(text)
    if not ft then return end
    if pcall(function() strip:SetText(ft) end) then
        strip_last = text
    end
end

-- ---------------------------------------------------------------------------
-- Entry point, once per UI tick
-- ---------------------------------------------------------------------------

function M.refresh(cfg, report)
    try_hook_bind()

    -- Plain Lua read while the stand has never been opened: zero engine calls
    -- is the whole idle cost of the mod.
    if not menu_likely_open then return false end

    local menu, tree, root = live_menu()
    if not menu then
        if strip_menu ~= nil then M.detach() end
        -- Stand down until a row binds again. Without this the mod runs a
        -- FindAllOf every second for the rest of the session after the stand
        -- is opened once.
        menu_likely_open = false
        return false
    end

    refresh_strip(cfg, report, menu, tree, root)
    refresh_cells(cfg, report)

    M.dirty = false
    store.flush()
    return true
end

M.dirty = false

-- ---------------------------------------------------------------------------
-- Clicking a cell
-- ---------------------------------------------------------------------------

-- Exactly one cell can be under the pointer. IsHovered still answers with the
-- vanilla checkbox hidden, because Hidden only takes the checkbox out of hit
-- testing, not the cell widget that contains it.
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

    local cell = hovered_cell()
    if not cell then return end

    local pal, t, work_name, cname = cell_target(cell)
    if not pal then return end

    local current = store.effective(cfg, pal, work_name, t)
    local next_prio = store.cycle(current, dir)
    if next_prio == current then return end

    store.set(pal.key, t, next_prio)

    -- X has to actually stop the pal. Our scheduler declining to assign them
    -- means nothing to Palworld's own AI, which will pick the job up anyway —
    -- and in dry run we assign nothing at all, so without this an X changed
    -- only the number on screen. The game's own permission flag is the thing
    -- that stops work, so it is set to match: a number means allowed, X means
    -- not.
    --
    -- This also settles the fight with the vanilla left-click, which toggles
    -- that same flag underneath us: whatever it did, this puts the flag back
    -- in agreement with the number now showing.
    if pal.raw then
        local ok, err = api.set_work_enabled(pal.raw, t, next_prio ~= false)
        if not ok and err then
            warn_once("toggle", "could not change the game's own work permission: " ..
                tostring(err))
        end
    end

    -- Repaint this one cell immediately rather than waiting up to a second
    -- for the poll: a priority control that answers late feels broken even
    -- when it is working.
    cell_last[cname] = nil
    M.dirty = true

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
                key_name .. " not available in this UE4SS build — " ..
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
