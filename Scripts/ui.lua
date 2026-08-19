-- The Monitoring Stand display.
--
-- Two layers, both read-only:
--   * one number per grid cell — the priority in force for that pal and work
--     type, drawn over the vanilla checkbox; the cell the last pass actually
--     assigned is drawn green
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
                    local name, species
                    pcall(function()
                        local param = handle:TryGetIndividualParameter()
                        if alive(param) then
                            name = api.pal_name(param)
                            species = api.pal_species(param)
                        end
                    end)

                    row_pal[rname] = { key = key, name = name, species = species }
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

local COLOR = {
    normal   = { R = 1.0, G = 0.85, B = 0.1, A = 1.0 },  -- gold: priority in force
    assigned = { R = 0.3, G = 1.0, B = 0.4, A = 1.0 },   -- green: last pass put the pal here
    off      = { R = 0.7, G = 0.3, B = 0.3, A = 0.9 },   -- dim red: X, never assign
}

local function set_cell(tb, cell_name, glyph, color_key)
    local token = glyph .. "|" .. color_key
    if cell_last[cell_name] == token then return end

    local ft = make_ftext(glyph)
    if not ft then return end

    local ok = pcall(function() tb:SetText(ft) end)
    if not ok then return end

    pcall(function()
        tb:SetColorAndOpacity({
            SpecifiedColor = COLOR[color_key],
            ColorUseRule = 0,
        })
    end)
    cell_last[cell_name] = token
end

-- ---------------------------------------------------------------------------
-- What a cell should show
-- ---------------------------------------------------------------------------

-- Effective priority for one pal and work type. This must resolve exactly as
-- scheduler.priority_for does — nickname first, species second — or the grid
-- shows a policy the scheduler is not following.
local function effective_priority(cfg, pal, work_name)
    local overrides = cfg.pal_overrides or {}
    local entry = pal.name and overrides[pal.name] or nil
    if entry == nil and pal.species then entry = overrides[pal.species] end

    if type(entry) == "table" and entry[work_name] ~= nil then
        return entry[work_name]
    end
    return cfg.work_priority[work_name]
end

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

    local assigned = lookup.assign[pal.key .. "|" .. t]
    local prio = effective_priority(cfg, pal, work_name)

    local tb = ensure_cell_text(cell, cell_name)
    if not tb then return end

    -- The glyph is always the effective priority; green only says the last
    -- pass put this pal on this work. Showing the bucket's global priority in
    -- the assigned cell would contradict the pal's own override sitting in
    -- every other cell of the same column.
    local glyph, colour
    if assigned then
        glyph = tostring(type(prio) == "number" and prio or assigned.prio)
        colour = "assigned"
    elseif prio == false then
        glyph, colour = "X", "off"
    elseif type(prio) == "number" then
        glyph, colour = tostring(prio), "normal"
    else
        -- unconfigured work type: show nothing, leave the vanilla checkbox be
        glyph, colour = "", "normal"
    end

    set_cell(tb, cell_name, glyph, colour)
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

function M.compose(cfg, report)
    local head = string.format("PWP  %s  %s  cap %s",
        cfg.enabled and (cfg.dry_run and "DRY RUN" or "LIVE") or "OFF",
        cfg.assignment_mode,
        cfg.max_pals_per_work_type and tostring(cfg.max_pals_per_work_type) or "-")

    if report and report.summary and report.summary ~= "" then
        return head .. "  |  " .. report.summary
    end
    return head .. "  |  no pass has run yet"
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
            -- bottom-left of a 1080p-authored canvas: out of the way of both
            -- the grid and the pal info card
            slot:SetAnchors({ Minimum = { X = 0.0, Y = 1.0 },
                              Maximum = { X = 0.0, Y = 1.0 } })
            slot:SetAlignment({ X = 0.0, Y = 1.0 })
            slot:SetPosition({ X = 40.0, Y = -24.0 })
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
    return true
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
