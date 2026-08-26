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
local net = require("net")
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

-- Live menu cache. Multiple instances coexist (seen live: a hidden stale one
-- alongside the open one), so only a VISIBLE instance may be cached.

-- Row -> pal identity, captured at bind time. Rows recycle on scroll, so a
-- rebind overwrites.
local row_pal = {}              -- row full name -> { key, name, species }
local bind_hooked = false
-- One line per session when the grid stands down on a client.
local said_client = false
local painted_gen = nil        -- which net.pals generation the cells show
local last_ask = -math.huge    -- when this client last asked for stand data
local last_hook_try = -math.huge
local menu_likely_open = false

-- Cells.
local cell_row = {}             -- cell full name -> row full name
local cell_text = {}            -- cell full name -> injected TextBlock
-- Which menu instance those TextBlocks were injected into. See live_menu.
local menu_name = nil
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

local function invalidate_cells()
    -- Only the name-to-name lookup. There is no widget array to drop any
    -- more; cells are resolved inside the call that uses them.
    cell_row = {}
end

-- Lost sight of the menu. Injected references are kept and alive() decides
-- what is still usable: detach fires on a merely-invisible frame too, so
-- dropping them here would duplicate widgets on the next tick.
function M.detach()
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
    menu_name = nil
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
                    local from_server = nil

                    -- On a client the ranks come down the wire, because
                    -- asking for them here is what kills the process.
                    --
                    -- GetWorkSuitabilityRank on a replicated pal is an access
                    -- violation rather than a Lua error, so the pcall below
                    -- would catch nothing. The name and species reads are
                    -- property reads and stay safe either way, which is why
                    -- only the rank loop moves.
                    if not api.has_authority() then
                        from_server = net.pals and net.pals[key] or nil
                        if from_server then ranks = from_server.ranks or {} end
                    end

                    pcall(function()
                        local param = handle:TryGetIndividualParameter()
                        if alive(param) then
                            name = api.pal_name(param)
                            species = api.pal_species(param)
                            -- AUTHORITY, not "the server sent nothing".
                            --
                            -- This crashed the game. The condition was
                            -- from_server == nil, which is true on a client
                            -- that has not received a push yet - so the fatal
                            -- call ran in exactly the state it was written to
                            -- avoid. A hook cannot be unregistered either, so
                            -- a session that registered this while hosting
                            -- keeps firing it after joining a server.
                            --
                            -- The only safe test is who owns the pal. A client
                            -- with no data draws nothing, which is the correct
                            -- answer to "I do not know yet".
                            if api.has_authority() then
                                for t = 1, #workdefs.ORDER do
                                    local r = api.suitability_rank(param, t)
                                    if type(r) == "number" and r > 0 then ranks[t] = r end
                                end
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
-- The full name of the menu instance the injected TextBlocks were put into.
--
-- They are deliberately kept across frames - rows recycle rather than die, so
-- dropping the reference makes the next tick inject a second widget on top of
-- the one already there - and that is safe only for as long as the menu they
-- were injected INTO still exists. When the stand is closed and reopened the
-- game builds a new instance, whose cells carry the SAME generated names
-- (Row_3.Cell_2 and so on), so a map keyed by cell name silently keeps
-- pointing at widgets belonging to the destroyed one. Then ensure_cell_text
-- asks one of them whether it is still valid, which is the crash rather than
-- a check against it, and this file already records two crashes from exactly
-- that.
--
-- Keying the whole map on the menu instance closes it: same instance, the
-- widgets are real and worth keeping; different instance, everything from the
-- old one goes at once, before anything asks it a question. menu_name is
-- declared with the maps it guards, because M.reset clears it.
local function forget_injected(why)
    if next(cell_text) == nil and next(cell_last) == nil then return end
    log.debug("stand: dropping injected cell text (" .. why .. ")")
    cell_text, cell_last, cell_cb, cell_row = {}, {}, {}, {}
end

local function live_menu()
    -- Resolved fresh, never from a kept reference.
    --
    -- This used to hold menu_ref between calls and ask alive() on it, which
    -- is the same stored-wrapper dereference the cells were fixed for one
    -- function down. It costs one FindAllOf a second, which is what the cell
    -- sweep beside it already pays.
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

    -- A different instance than the one holding our widgets means the old
    -- ones are gone with it.
    local now_name = menu and full_name(menu) or nil
    if now_name ~= menu_name then
        forget_injected("menu instance changed")
        menu_name = now_name
        invalidate_cells()
    end

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
        -- A widget we put into the game's own stand menu, kept since an
        -- earlier frame. The menu rebuilds itself, and this mod has two
        -- crashes in its history from exactly that.
        local still = alive(cached)

        if still then return cached end
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

-- What a cell currently says, from whichever side owns the answer.
--
-- Both the draw and the click go through this. They used to disagree: the
-- draw read the server's value while bump read the client's own store, so a
-- click cycled from a number nobody could see - the cell showed 5, the local
-- default was 3, and a left click sent "2". The repaint then re-read the
-- stale snapshot and the cell did not move at all, so the grid looked dead
-- while the server was applying edits correctly.
-- What this pal can do, from whichever side owns the answer.
--
-- Live, not the bind-time copy, for the same reason shown_prio is. The hook
-- only registers once the client HAS data, so on the first open after joining
-- the rows bind while ranks are still empty - and a row is not rebound until
-- the list scrolls or the menu is reopened. The grid came up vanilla and
-- stayed vanilla, which is indistinguishable from the feature being off.
-- Has the server sent a batch this module has not drawn yet?
--
-- Called from the fast beat so a push repaints on the next tick rather than at
-- the next grid second.
--
-- The integer test goes FIRST, and the comment here used to claim the whole
-- function was "two integers" while its first line was a full object array
-- walk - ten milliseconds, ten times a second, for the entire session whether
-- or not the stand was ever opened. The generation is unchanged on almost
-- every call, so testing it first skips the expensive question outright.
--
-- The order is safe: on the authority painted_gen is never assigned and stays
-- nil while net.pals_gen is 0, so the first test falls through and the second
-- answers false exactly as it did before.
function M.wants_repaint()
    if painted_gen == net.pals_gen then return false end
    return not api.has_authority()
end

local function shown_ranks(pal)
    if not api.has_authority() then
        local entry = pal.key and net.pals and net.pals[pal.key]
        if entry and entry.ranks then return entry.ranks end
        return nil
    end
    return pal.ranks
end

local function shown_prio(cfg, pal, work_name, t)
    if not api.has_authority() then
        local entry = pal.key and net.pals and net.pals[pal.key]
        if entry and entry.prios then return entry.prios[t] end
        return nil
    end
    return store.effective(cfg, pal, work_name, t)
end

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

    -- Read LIVE from net.pals, not from a snapshot taken when the row bound.
    --
    -- row_pal.server_prios used to hold a reference captured at bind time, and
    -- a push replaces M.pals wholesale with fresh sub-tables - so the
    -- reference was orphaned the moment new data arrived. row_pal is only
    -- rewritten when BindFromSlot fires, i.e. when the list scrolls or the
    -- menu is reopened. Two players with the stand open: one sets a priority,
    -- the other's client receives it and keeps drawing the old number.
    --
    -- The server's answer on a client, the local store on the authority.
    --
    -- store.effective reads priorities.txt, which on a client is a file the
    -- server never looks at - so drawing from it showed numbers that meant
    -- nothing. That is half of why this grid was switched off entirely rather
    -- than merely made read-only.
    local prio = shown_prio(cfg, pal, work_name, t)

    -- Hand the cell back to the game when we have nothing to say about it:
    -- the pal cannot do this work at all, or the work type is not configured.
    -- Vanilla draws a dash for the first case, and a number there would claim
    -- the pal will do something it is incapable of.
    local ranks = shown_ranks(pal)
    local capable = ranks and ranks[t] ~= nil
    if not capable or prio == nil then
        local existing = cell_text[cell_name]
        local usable = false
        if existing then
            usable = alive(existing)
        end

        if usable then
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

-- The cells that exist right now, resolved inside this call.
--
-- They used to be found once and kept until something invalidated the cache,
-- which is the stored-wrapper dereference this codebase is built to avoid.
-- FindAllOf returns cells from EVERY instance of the menu, and the file
-- already records that a hidden stale instance coexists with the open one -
-- so when the stale one is torn down while the live one stays visible, the
-- kept array is holding freed objects, and alive() on one of those IS the
-- crash rather than a guard against it.
--
-- The sweep is once a second, not once a frame, which is the rate the caller
-- was built around: main.lua's comment on the grid says it stays on its
-- second precisely because refreshing means a FindAllOf over every cell.
local function live_cells()
    local out = {}
    pcall(function()
        for _, c in ipairs(FindAllOf(M.CELL_CLASS) or {}) do
            -- Asked in the same call that produced it, which is the only age
            -- at which the question is safe.
            if alive(c) then out[#out + 1] = c end
        end
    end)
    return out
end

local function refresh_cells(cfg)
    local cells = live_cells()
    if #cells == 0 then return end

    local seen = {}
    for _, cell in ipairs(cells) do
        local name = full_name(cell)
        if name then seen[name] = true end
        pcall(function() handle_cell(cfg, cell) end)
    end

    -- Entries whose cell no longer exists are dropped.
    --
    -- These are keyed by cell full name and were cleared only on a world
    -- switch, so every open and close of the stand added a fresh set that
    -- nothing ever reclaimed. Safe to prune here and only here: the sweep
    -- above just enumerated every cell that exists, so a key missing from it
    -- names something gone. Guarded on a non-empty sweep, because an empty
    -- one means the menu is shut, not that every cell died - and cell_text
    -- must survive a shut menu, or the next tick injects a second widget on
    -- top of the one already there.
    for name in pairs(cell_text) do
        if not seen[name] then
            cell_text[name] = nil
            cell_last[name] = nil
            cell_cb[name] = nil
            cell_row[name] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Entry point, once per UI tick
-- ---------------------------------------------------------------------------

function M.refresh(cfg)
    -- The stand grid is authority-only, and the reason is a crash rather than
    -- a preference.
    --
    -- Binding a row reaches api.suitability_rank, which is
    -- GetWorkSuitabilityRank on the pal's individual parameter. On a client
    -- those pals are replicated proxies and that call faults outright - not a
    -- Lua error, an access violation, so the pcall around it catches nothing
    -- and the process goes. discover.lua and main.lua both carry that warning
    -- and both gated themselves on 23 August in d3d024a. That commit touched
    -- seven files and missed this one, which had held the same call since the
    -- 19th.
    --
    -- Gating it costs nothing, which is what makes this easy. The grid never
    -- worked on a client: store.lua has no submit indirection the way caps.lua
    -- does, so a click writes the client's own priorities.txt and asks for a
    -- pass that returns immediately for want of authority; and the protocol
    -- carries no priority messages in either direction, so the numbers on
    -- screen were the client's local file, which the server never reads. It
    -- looked like a control and was a decoration.
    --
    -- Checked every refresh rather than once at load, so a session that
    -- changes role picks it up, and placed above try_hook_bind so the hook is
    -- never registered on a machine that must not run it. Vanilla's own grid
    -- is untouched underneath.
    if not api.has_authority() then
        -- A client draws the grid from what the server sent, or not at all.
        --
        -- The three reasons this was off are answered separately. The fatal
        -- rank call is gone from the client path entirely - the ranks arrive
        -- over the wire. The numbers are the server's priorities rather than a
        -- local file it never reads. And clicks are refused below, because the
        -- protocol carries no priority edits upward yet.
        --
        -- No data means no grid, rather than an empty one: before the server's
        -- first push there is nothing honest to draw, and a grid of dashes
        -- reads as "this pal can do nothing" instead of "not known yet".
        -- The hook is registered either way, and the DRAW is what waits.
        --
        -- Returning here also skipped try_hook_bind, so the hook only existed
        -- once data had arrived - and rows bound before that were never bound
        -- again. Registering is safe with no data: the rank loop inside is
        -- gated on authority, and a pal with no entry draws nothing.
        if not (net.pals and next(net.pals) ~= nil) then
            if not said_client then
                said_client = true
                log.debug("stand grid waiting: no pal data from the server yet")
            end

            -- Ask, rather than wait for a hello that already happened.
            --
            -- The server pushes on Hello, and Hello is sent once, from the
            -- world-load handler. Rejoin a world the client considers the same
            -- one - "respawn in the same world, caches kept" - and that branch
            -- does not run, so a freshly launched process that reconnects
            -- never announces itself and never receives anything. The grid
            -- then draws nothing, for the rest of the session, and looks
            -- exactly like the feature being switched off.
            --
            -- Only while there is nothing to draw, and at most once every ten
            -- seconds, so a server that genuinely has no pals for this guild
            -- is not asked repeatedly.
            local now = os.clock()
            if now - last_ask > 10 then
                last_ask = now
                pcall(function()
                    if net.to_server(net.PREFIX .. "Hello", 1) then
                        log.debug("stand: asked the server for pal data")
                    end
                end)
            end
        end
    end

    try_hook_bind()

    -- Before every early return below, not after them.
    --
    -- A click marks the store dirty and this flush is debounced two seconds so
    -- a run of clicks is one write. It used to sit at the bottom of this
    -- function, under two early returns - so closing the stand within that
    -- window took the only path that reaches it away, and the edit never
    -- reached priorities.txt. Silently: the checkbox had visibly moved.
    -- Flushing here costs nothing when nothing is dirty.
    store.flush()

    -- Plain Lua read while the stand has never been opened: zero engine calls
    -- is the whole idle cost of the mod.
    if not menu_likely_open then return false end

    -- On a client, nothing changes between pushes.
    --
    -- Below here is a FindAllOf over the menu class and another over every
    -- cell, once a second. On the authority that is the price of noticing an
    -- edit made anywhere. On a client the numbers can only change when the
    -- server sends a batch, and the object array a client walks is far larger
    -- because it holds every replicated actor - so the same two walks that
    -- cost 20-40ms while hosting are what made the stand hitch every second.
    --
    -- A rebind still repaints through the hook, so only the polling half is
    -- skipped.
    if not api.has_authority() then
        if painted_gen == net.pals_gen then return false end
        painted_gen = net.pals_gen
    end

    local menu = live_menu()
    if not menu then
        M.detach()
        -- Stand down until a row binds again. Without this the mod runs a
        -- FindAllOf every second for the rest of the session after the stand
        -- is opened once.
        menu_likely_open = false
        return false
    end

    refresh_cells(cfg)
    return true
end

-- Set by a click; main clears it after running a pass, so an edit takes
-- effect within a second rather than waiting out the 30s cycle.
M.wants_pass = false


-- ---------------------------------------------------------------------------
-- Clicking a cell
-- ---------------------------------------------------------------------------

-- Exactly one cell can be hovered. IsHovered still answers with the checkbox
-- hidden, since Hidden removes the checkbox from hit testing, not the cell.
local function hovered_cell()
    -- Resolved here rather than read from a kept array. This runs from the
    -- mouse keybind, which can fire arbitrarily long after the last refresh,
    -- so a kept array is at its most stale exactly when this reads it.
    for _, cell in ipairs(live_cells()) do
        local hit = false
        pcall(function() hit = cell:IsHovered() end)
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
    local ranks = shown_ranks(pal)
    if not (ranks and ranks[t]) then return nil end

    -- A client's click is allowed now, because it goes somewhere.
    --
    -- store.set routes through store.submit on a client, which sends the edit
    -- to the server; the server validates it, writes it, and pushes the new
    -- picture to every client. So the number a player sees change is the
    -- server's answer arriving, not a local write pretending to be one.
    --
    -- This used to be refused, and the refusal was right at the time: there
    -- was no submit path, so a click wrote a file the server never reads.

    return pal, t, work_name, cname
end

-- dir -1 for left click (towards priority 1), +1 for right click.
local function bump(cfg, dir)
    if not menu_likely_open then return end

    local cell = hovered_cell()
    if not cell then return end

    local pal, t, work_name, cname = cell_target(cell)
    if not pal then return end

    local current = shown_prio(cfg, pal, work_name, t)
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
-- `before` gets first refusal on every click and returning true consumes it.
-- The rules panel uses that: it can be open over the stand, and a click meant
-- for a rule must not also land on whatever priority cell sits underneath.
function M.bind_mouse(cfg_ref, before)
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
                local consumed = false
                if before then
                    pcall(function() consumed = before(dir) == true end)
                end
                if not consumed then
                    pcall(function() bump(cfg_ref(), dir) end)
                end
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
-- Reading any property name off a UE4SS object returns a live looking wrapper
-- whether or not it exists, so the only safe move is to print what is actually
-- there and build against that.
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
            -- class is what says which way anything here has to be built.
            geom = "  slot=" .. sclass
        end
    end

    -- A SizeBox is what fixes each icon column's width, so its override is
    -- the column pitch of the work icon header.
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
