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
--   CRASH RULE 1: resolve objects through the current callback's tree or
--   native arguments. IsValid on a stored, freed wrapper is itself unsafe;
--   pcall cannot catch the native access violation. Only strings and plain
--   identity data are retained between callbacks.
--
--   CRASH RULE 2: never READ a row's bindedSlot property. The read itself
--   crashes natively inside UE4SS before Lua sees anything. Pal identity is
--   captured by hooking the row's BindFromSlot function instead, where the
--   slot arrives as a safe hook argument.

local log = require("log")
local measurement = require("measurement")
local session = require("session")
local tree_lookup = require("ui_tree")
local render = require("ui_render")
local stand_input = require("stand_input")
local stand_pointer = require("stand_pointer")
local stand_lifecycle = require("stand_lifecycle")
local input_blocked
local pad = require("pad")
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
local said_none = false
-- Registration failing is normal until the blueprint class loads, so the
-- warning waits for a run of failures rather than the first one.
local said_painted_none = false
local last_cell_error = nil
local last_bind_error = nil
local hook_fails = 0
local HOOK_FAIL_WARN = 5
local painted_gen = nil        -- which net.pals generation the cells show
-- Bumped every time the injected cells are dropped.
--
-- The menu's own name cannot answer this. Closing and reopening the stand
-- builds a NEW instance whose cells carry the SAME generated full names - the
-- comment on live_menu below says so - so comparing names reported "same
-- menu" for a tree whose widgets had all just been thrown away, and the
-- repaint was skipped. Measured: reopening logged
-- "cells=0 same_menu=true", and the grid stayed vanilla until an unrelated
-- server push happened to move the generation.
--
-- A counter cannot be fooled that way: whatever drops the cells bumps it, and
-- a paint records the value it painted at.
local inject_epoch = 0
local painted_epoch = -1
local last_ask = -math.huge    -- when this client last asked for stand data
local ask_gap = 10             -- seconds until the next ask, doubling
local asked_gen = nil          -- net.pals_gen at the moment of the last ask
local missing_gen = nil        -- generation we last asked about a missing pal
local missing_key = nil        -- which pal that was, so it is asked about once
local missing_at = nil         -- when; re-armed if no pal data follows in missing_wait
local MISSING_WAIT = 10
local missing_wait = MISSING_WAIT -- doubles while asks go unanswered, to ASK_GAP_MAX
local ASK_GAP_MAX = 120
local last_hook_try = -math.huge
local menu_likely_open = false
local menu_lookup_uncertain = false

-- Cells.
local cell_row = {}             -- cell full name -> row full name
local cell_text = {}            -- cell full name -> injected TextBlock NAME only
local cell_paths = {}           -- bounded scalar tree-edge hints, never widgets
local cell_text_count = 0       -- bounded ownership registry; never evict live ownership
-- Which menu instance those TextBlocks were injected into. See live_menu.
local menu_name = nil
local cell_last = {}            -- cell full name -> last style token written
local cell_cb = {}              -- cell full name -> the checkbox's own visibility
local edit_states = { epoch=session.epoch, transport=net.local_nonce, entries={}, count=0, sequence=0, incomplete=false }
local legend_names, legend_count = {}, 0 -- bounded string-only ownership, like cell_text
-- menu full name -> the name of the legend Border whose style is written.
-- The backing, padding and visibility are set once per Border, not each beat.
local legend_styled = {}
-- One line under the stand (review 2026-10-21): what each mouse button does,
-- the rule a newcomer trips over and where the limits panel is. Two lines were
-- tried and the upper one ran into the game's own "unused Stat Points" bar,
-- which sits just above the bottom-anchored text (in game, 2026-10-22).
--
-- A left click keeps wrapping from 1 to X (decision 2026-10-29: a clamp would
-- change 0.4.1 behaviour), so the legend says it: the first left click on a
-- fresh install sets X. Equal numbers leave the Pal to the game. The number
-- scale and the marks "* ! ?" moved to every cell's tooltip (M.MARKS_HELP)
-- to make room for both.
--
-- Round 3 (2026-10-29): the line starts with the state a fresh install is
-- in, so the first left click setting X is no surprise (newcomer P2-2), and
-- names Enter and the arrows, which keyboard players otherwise only found in
-- the mouse-hover tooltip (accessibility P2-3). Enter is the receiver's code
-- 10, the same step toward 1 as a left click; the arrows move the selection.
-- The parts are kept apart with " | " and joined by M.edit_legend, which
-- drops the least needed part when a long rebound key would not fit.
M.LEGEND_START = "All start at 1"
M.LEGEND_CONTROLS = "Left click/Enter: toward 1 (1 wraps to X) | Right click: toward X | Arrows, keys 1-5, X"
M.LEGEND_EQUAL = "All equal: game picks"
M.LEGEND_PANEL = "ALT+F1: Production Limits"
M.EDIT_LEGEND = table.concat({M.LEGEND_START, M.LEGEND_CONTROLS, M.LEGEND_EQUAL, M.LEGEND_PANEL}, " | ")
-- On a controller (StandInput contract 3, 2026-10-22). Y is the stand's own
-- view switch, so the panel opens with View. Buttons are named as buttons:
-- "X: off" read as "X means off", not "press X" (audit 2026-10-28). A and X
-- also say where they sit, because on a PlayStation pad the button players
-- call X (Cross) is the bottom one, not the left one (accessibility P3-1).
-- A arrives as code 10 and LB as 11, both toward 1; RB is 12, toward X.
M.PAD_CONTROLS = "LB/A (bottom button): toward 1 (1 wraps to X) | RB: toward X | X (left button): set X"
M.PAD_PANEL = "View button: Production Limits"
M.PAD_LEGEND = table.concat({M.LEGEND_START, M.PAD_CONTROLS, M.LEGEND_EQUAL, M.PAD_PANEL}, " | ")
-- What the legend line no longer has room for, in each cell's tooltip.
M.MARKS_HELP = "1 highest, 5 lowest, X off.  * sending  ! not saved  ? unknown"
-- Every legend line must fit one 1280x720 screen at 14 pt. Measured at 12 pt
-- on 2026-10-28: 152 characters drew 730 px wide, so 14 pt is about 5.6 px a
-- character and 160 characters about 900 px with the backing's padding.
M.LEGEND_MAX_CHARS = 160
-- The config reset notice (configuration.upgrade_message) used to appear
-- only in the Production Limits panel, which a player who was updated by
-- the Workshop may never open (onboarding P2-4). The stand shows it once
-- too, for this long or until the stand is opened again. Only the panel
-- acknowledges it, after drawing it, so the marker file stays for the panel.
M.RESET_NOTICE_SECONDS = 12
-- Bumped with main.lua's VERSION, like net.OLD_CLIENT_NOTICE
-- (tests/test_ui_integration.lua compares the two).
M.MOD_VERSION = "0.5.0"
-- A client whose server never completes the mod's handshake gets the game's
-- own stand back (audit A5, 2026-10-28): no "?" cells, the vanilla checkboxes,
-- and one line saying why.
M.VANILLA_ABSENT = "This server does not run Pal Work Priority " .. M.MOD_VERSION
    .. ". The stand works as in the base game."
-- A server with another version of the mod still schedules: a 0.4.1 server
-- rewrites the work flags every pass, so base-game checkboxes would show a
-- choice it overwrites (review round 2, 2026-10-29). The stand stays
-- read-only and says who controls work.
-- The advice matches the panel's (onboarding round 3, P2-1): a Workshop
-- player cannot go back to an older version, so the host updates the server.
M.LOCKED_INCOMPATIBLE = "This server runs another Pal Work Priority version, which controls work here. "
    .. "Ask the host to update the server."
-- The receivers that take clicks, number keys and controller buttons live in
-- the pak. Without it the stand can show numbers but nothing on it edits them.
M.PAK_MISSING = "Stand editing unavailable: PalWorkPriority.pak is missing. Reinstall the mod."
-- Shown in a cell's tooltip for a Pal the scheduler leaves to the game
-- (scheduler_plan.unordered: every job it may do has the same number).
M.SAME_NUMBER_HINT = "Same number on every job: the game picks. Give jobs different numbers to steer this Pal."
-- Whether the mod is doing anything, on the machine that runs the passes
-- (onboarding round 3, P2-3). All jobs start equal, so a fresh install
-- changes nothing in game and "N left to the game" was only in the log.
-- scheduler.steering_count answers from its last pass, or nil while it has
-- none that is current. A client runs no passes and is told no count, so it
-- shows none rather than a number that is not true. Plain numbers only.
-- Returns the full and the short wording.
local function steering_status()
    if api.has_authority() ~= true then return nil end
    local scheduler = package.loaded.scheduler
    if type(scheduler) ~= "table" or type(scheduler.steering_count) ~= "function" then return nil end
    local ok, steered, pals, left = pcall(scheduler.steering_count)
    if not ok then return nil end
    steered, pals, left = math.tointeger(steered), math.tointeger(pals), math.tointeger(left)
    if not steered or not pals or pals <= 0 or steered < 0 or steered > pals then return nil end
    local short = string.format("Steering %d of %d %s", steered, pals, pals == 1 and "Pal" or "Pals")
    -- Only when every Pal was left to the game for equal numbers; Pals the
    -- pass could not read are neither steered nor equal.
    if steered == 0 and left == pals then return short .. ": all jobs equal", short end
    return short, short
end

-- The first choice whose joined text fits one line.
local function fit_legend(choices)
    for _, parts in ipairs(choices) do
        local text = table.concat(parts, " | ")
        if #text <= M.LEGEND_MAX_CHARS then return text end
    end
    return table.concat(choices[#choices], " | ")
end

-- The panel key as the player bound it in DarnMenu. main.lua records it in
-- darnmenu.labels; without it (older main, no DarnMenu) the shipped text stands.
-- With a steering count, the count takes the place of "All start at 1" and
-- "All equal: game picks": "Steering 0 of 14 Pals: all jobs equal" says both
-- for the case they were written for, and the line has no room for all three.
function M.edit_legend()
    local controls, panel = M.LEGEND_CONTROLS, M.LEGEND_PANEL
    if api.last_input_type == 1 then
        controls, panel = M.PAD_CONTROLS, M.PAD_PANEL
    else
        local label
        pcall(function()
            local dm = package.loaded.darnmenu
            label = type(dm) == "table" and type(dm.labels) == "table" and dm.labels.key_panel or nil
        end)
        if type(label) == "string" and label ~= "" and #label <= 24 then
            label = label:upper()
            panel = (panel:gsub("ALT%+F1", function() return label end))
        end
    end
    local status, short = steering_status()
    if status then
        return fit_legend({{status, controls, panel}, {short, controls, panel}, {controls, panel}})
    end
    return fit_legend({{M.LEGEND_START, controls, M.LEGEND_EQUAL, panel},
        {controls, M.LEGEND_EQUAL, panel}, {controls, panel}})
end

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

local function invalidate_cells(rebound)
    if rebound then
        session.invalidate_ui()
        M.selection = nil
        pad.forget()
    end
    -- Only the name-to-name lookup. There is no widget array to drop any
    -- more; cells are resolved inside the call that uses them.
    cell_row = {}
    cell_last = {}
    inject_epoch = inject_epoch + 1
end

stand_lifecycle.configure(function(event)
    if event=='open' then menu_likely_open=true end
    M.selection=nil
    M.selection_revision=(M.selection_revision or 0)+1
    invalidate_cells() -- stand-only token revocation; keep other UI queues
end)

-- Invalidate the paint, retaining only ownership names. A data edit is not
-- a widget-generation change and must not cancel other queued rapid clicks.
function M.detach()
    invalidate_cells()
end

local function current_edits()
    if edit_states.epoch ~= session.epoch or edit_states.transport ~= net.local_nonce then
        edit_states = { epoch=session.epoch, transport=net.local_nonce, entries={}, count=0, sequence=0, incomplete=false }
    end
    return edit_states
end

-- Called by net.on_edit. No native reads, logging, or engine objects enter
-- this bounded record. Only an explicit durable acceptance clears an issue;
-- another attempt or a snapshot alone cannot prove a failed save recovered.
function M.edit_status(key, work, status, reason)
    if type(key) ~= "string" or #key == 0 or #key > 128 or key:find("[^%w_%-]") then return false end
    if type(work) ~= "number" and type(work) ~= "string" then return false end
    work = math.tointeger(work)
    if not work or not workdefs.name(work) then return false end
    local allowed = {pending=true, acknowledged=true, accepted=true, applied=true,
        applied_unsaved=true, rejected=true, timed_out=true, connecting=true, incompatible=true}
    if not allowed[status] then return false end
    local state = current_edits()
    local token = key .. "|" .. work
    local entry = state.entries[token]
    if not entry then
        if state.count == 128 then
            local oldest, sequence
            for id, item in pairs(state.entries) do
                if not sequence or item.sequence < sequence then oldest, sequence = id, item.sequence end
            end
            if state.entries[oldest].status ~= "accepted" then state.incomplete = true end
            state.entries[oldest] = nil
            state.count = state.count - 1
        end
        entry = {}; state.entries[token] = entry; state.count = state.count + 1
    end
    state.sequence = state.sequence + 1
    entry.status, entry.sequence = status, state.sequence
    entry.reason = type(reason) == "string" and reason:sub(1,192) or nil
    if status == "accepted" then entry.issue, entry.issue_reason = nil, nil
    elseif status == "applied_unsaved" or status == "rejected" or status == "timed_out" then
        entry.issue, entry.issue_reason = status, entry.reason
    end
    invalidate_cells()
    return true, state.count
end

-- World switch: every engine wrapper is dead. The bind hook itself survives
-- (UE4SS hooks are global), so bind_hooked stays.
function M.reset()
    stand_lifecycle.reset()
    M.selection = nil
    M.pad_handlers = nil
    invalidate_cells(true)
    -- A world switch really does destroy everything, so this is where the
    -- injected references are dropped rather than in detach.
    cell_text = {}
    cell_paths = {}
    cell_text_count = 0
    cell_last = {}
    cell_cb = {}
    edit_states = { epoch=session.epoch, transport=net.local_nonce, entries={}, count=0, sequence=0, incomplete=false }
    legend_names, legend_count = {}, 0
    legend_styled = {}
    menu_name = nil
    row_pal = {}
    menu_likely_open = false
    menu_lookup_uncertain = false
    ftext_mode = nil
    warned = {}

    -- The ask state belongs to the world too.
    --
    -- None of this was cleared. painted_gen surviving meant net.reset's
    -- generation bump left wants_repaint() true until a stand was opened, and
    -- said_client re-used a notice from the previous server. The new backoff
    -- would have been worse than either: said_none latches "this server has
    -- nothing for my guild", so carrying it into a DIFFERENT server would stop
    -- that client ever asking again.
    painted_gen = nil
    painted_epoch = -1
    last_ask = -math.huge
    ask_gap = 10
    asked_gen = nil
    said_client = false
    said_none = false
    missing_gen = nil
    missing_key = nil
    missing_at = nil
    missing_wait = MISSING_WAIT
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
    if not api.has_viewport() then return end
    if bind_hooked then return end
    local now = os.clock()
    if now - last_hook_try < 5 then return end
    last_hook_try = now

    -- Timed unconditionally, unlike the per-event hooks elsewhere: this runs
    -- at most once every five seconds, so two os.clock() calls are free, and
    -- it is the only repeating call in the mod with no price on it at all.
    -- It keeps retrying for the whole session on a player who never opens the
    -- stand, and on a headless server where the class never loads at all.
    local _t0 = os.clock()
    pcall(function() LoadAsset(ROW_BP_PATH) end)
    local _load = log.count("ui: try_hook_bind LoadAsset")
    _load.ms = _load.ms + (os.clock() - _t0) * 1000

    local _t1 = os.clock()
    local ok, err = pcall(function()
        RegisterHook(ROW_BIND_FN, measurement.callback("hook: stand row binding", function(Context, SlotParam)
            -- The message is kept, once per distinct error.
            --
            -- This body is where row_pal is filled, and row_pal is what every
            -- cell needs to draw a number. A throw anywhere in it - a renamed
            -- api function, a rank call that faults, a shape the wire format
            -- did not expect - leaves the table empty, every cell falls back
            -- to the vanilla checkbox, and the grid looks exactly like the
            -- feature being switched off. That is the api.camps() shape, at
            -- the single most load-bearing point in the grid, and it was a
            -- bare pcall.
            --
            -- Keyed on the message because this fires once per row bound, so
            -- an unkeyed warn would be one line per row per open.
            local ok_bind, err_bind = pcall(function()
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
                            -- with no data reads no ranks here: its cells show
                            -- "?" while the handshake runs and the vanilla
                            -- checkbox when it never completes (vanilla_message).
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
                    -- A bind is a native input boundary even when the same
                    -- Pal and generated row name are reused. A close/reopen
                    -- can fit between polls; equality cannot keep old edits
                    -- authorized. Pure data repaints still use detach().
                    menu_likely_open = true
                    invalidate_cells(true)
                end
            end)

            if not ok_bind then
                err_bind = tostring(err_bind)
                if err_bind ~= last_bind_error then
                    last_bind_error = err_bind
                    log.warn("a Monitoring Stand row could not be read, so " ..
                        "the grid will not draw numbers for it: " .. err_bind)
                end
            elseif last_bind_error ~= nil then
                last_bind_error = nil
                log.say("the Monitoring Stand rows are readable again")
            end
        end))
    end)

    local _reg = log.count("ui: try_hook_bind RegisterHook")
    _reg.ms = _reg.ms + (os.clock() - _t1) * 1000

    if ok then
        bind_hooked = true
        if hook_fails >= HOOK_FAIL_WARN then
            -- Retracted at the same level it was warned at, or the warn sits
            -- in the log describing a state that has since fixed itself.
            log.warn("the Monitoring Stand's row bind is hooked after all, " ..
                "the grid will draw")
        end
        log.debug("BindFromSlot hook registered")
    else
        -- Only after it has failed for a while, and only once.
        --
        -- There was no else at all, and a failure that nobody is told about
        -- kills the whole grid: no row binds, row_pal stays empty, every cell
        -- falls back to the vanilla checkbox, and this retries every few
        -- seconds for the session with nothing written at any level.
        --
        -- But the FIRST failures are expected and normal - the comment at the
        -- top of this function says so. The blueprint class loads on demand,
        -- so registration fails until a stand has been opened once, and on a
        -- headless server it never loads at all. Warning on the first attempt
        -- put a line saying "the priority grid cannot draw" at the top of
        -- every log, including sessions where it drew perfectly.
        --
        -- Five attempts is roughly half a minute of retrying, which is well
        -- past "the class has not loaded yet" and into "something is wrong".
        hook_fails = hook_fails + 1
        if hook_fails == HOOK_FAIL_WARN then
            log.warn("could not hook the Monitoring Stand's row bind after " ..
                HOOK_FAIL_WARN .. " tries, so the priority grid cannot " ..
                "draw: " .. tostring(err))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Menu discovery
-- ---------------------------------------------------------------------------

local function is_showing(m)
    local ok, vis = pcall(function() return m:IsVisible() end)
    return ok and vis == true
end

-- Ownership is a bounded registry of strings, retained while a menu is hidden.
-- A hidden tree may survive reopening. Its names are only resolved through
-- the current cell tree; retaining the names never retains an engine wrapper.
local function live_menu()
    -- Both routes return current-call objects. The typed native query reloads
    -- the generated class from its learned asset path each time; no widget or
    -- generated-class wrapper survives a callback. Empty/unavailable queries
    -- retain the global discovery route, including the first menu opening.
    local menu, tree, root
    local complete = pcall(function()
        local lookup = require('widget_lookup')
        local candidates = lookup.stands()
        if not candidates or #candidates==0 then
            candidates = FindAllOf(M.MENU_CLASS) or {}
            log.count('ui: menu via global lookup')
        else log.count('ui: menu via typed query') end
        for _, m in ipairs(candidates) do
            if alive(m) then
                local name = full_name(m)
                if not name or name=='' then error('unreadable stand identity') end
                local showing = false
                if not name:find("Default__", 1, true) then
                    showing=m:IsVisible()
                    if type(showing)~='boolean' then error('unknown stand visibility') end
                end
                if showing then
                    if menu ~= nil then error('ambiguous visible Monitoring Stands') end
                    local t, r
                    pcall(function() t = m.WidgetTree end)
                    if alive(t) then pcall(function() r = t.RootWidget end) end
                    if not alive(t) or not alive(r) then error('visible stand tree unavailable') end
                    menu, tree, root = m, t, r
                end
            end
        end
    end)
    menu_lookup_uncertain = not complete

    -- A partial/ambiguous enumeration never authorizes whichever menu was
    -- visited first. Keep native objects confined to this invocation.
    if not complete then menu, tree, root = nil, nil, nil end
    if menu then require('widget_lookup').remember_stand(menu) end

    -- A different instance than the one holding our widgets means the old
    -- ones are gone with it.
    local now_name = menu and full_name(menu) or nil
    if now_name ~= menu_name then
        menu_name = now_name
        invalidate_cells(true)
    end
    stand_lifecycle.observe(menu)

    return menu, tree, root
end
live_menu = measurement.callback("stand: menu lookup", live_menu)

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

    local placed = pcall(function()
        local function wrote(result) if result == false then error("cell placement failed") end end
        if class_name(cb_slot) == "CanvasPanelSlot" then
            wrote(new_slot:SetAnchors(cb_slot:GetAnchors()))
            wrote(new_slot:SetPosition(cb_slot:GetPosition()))
            wrote(new_slot:SetSize(cb_slot:GetSize()))
            wrote(new_slot:SetAlignment(cb_slot:GetAlignment()))
            wrote(new_slot:SetZOrder(cb_slot:GetZOrder() + 1))
        else
            wrote(new_slot:SetHorizontalAlignment(cb_slot.HorizontalAlignment))
            wrote(new_slot:SetVerticalAlignment(cb_slot.VerticalAlignment))
            wrote(new_slot:SetPadding(cb_slot.Padding))
        end
    end)
    if not placed then pcall(function() tb:RemoveFromParent() end) end
    return placed
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

    local ok, slot = pcall(function() return root:AddChild(tb) end)
    return ok and alive(slot)
end

local function ensure_cell_text(cell, cell_name)
    local cached_name = cell_text[cell_name]
    local current, complete, hint = tree_lookup.find(cell, cached_name, alive, cell_paths[cell_name])
    cell_paths[cell_name] = hint
    cell_last[cell_name] = nil -- same instance names cannot prove a previous write survived.
    if current then return current end
    if not complete then return nil end -- unknown is not permission to inject again
    if not cached_name and cell_text_count >= 2048 then
        warn_once("cellbudget", "stand control limit reached; new cells remain unavailable")
        return nil
    end
    -- A complete walk proved this tree does not contain our old label. Its
    -- checkbox is a new instance too; do not reuse the old visibility value.
    cell_cb[cell_name] = nil

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

    if not cached_name then cell_text_count = cell_text_count + 1 end
    cell_text[cell_name] = full_name(tb)
    return tb
end

ensure_cell_text = measurement.callback("stand: label lookup or construction", ensure_cell_text)

-- Priority colours, overridden while synchronization needs attention. The
-- suffix carries the same information without relying on colour perception.
local COLOUR = {
    p1       = { R = 0.25, G = 1.00, B = 0.25, A = 1.0 },
    p2       = { R = 1.00, G = 1.00, B = 0.15, A = 1.0 },
    p3       = { R = 1.00, G = 0.55, B = 0.05, A = 1.0 },
    p4       = { R = 1.00, G = 0.25, B = 0.18, A = 1.0 },
    p5       = { R = 0.62, G = 0.62, B = 0.62, A = 1.0 },
    off      = { R = 0.42, G = 0.42, B = 0.45, A = 0.9 },
    blank    = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 },
    pending  = { R = 0.35, G = 0.85, B = 1.00, A = 1.0 },
    issue    = { R = 1.00, G = 0.65, B = 0.25, A = 1.0 },
    unknown  = { R = 0.75, G = 0.75, B = 0.80, A = 1.0 },
    -- Ceilings are blue on purpose. Nothing in the priority run is blue, so
    -- a number in the header can never be mistaken for a priority.
    -- cap_set and cap_none used to sit here, blue and grey, for a ceiling
    -- drawn in the work type's column HEADER - a number there can never be
    -- mistaken for a priority. That marker was never built, and neither colour
    -- was referenced anywhere, so the grid shows a priority for a job the
    -- panel is reporting as Stopped and nothing connects the two.
    --
    -- Removed rather than left looking implemented. Marking a capped column is
    -- a design job with real risk - it means injecting into vanilla header
    -- widgets - and it is recorded as an open item in the Deferred list of
    -- docs/RELEASE-0.5.0.md rather than half-present here.
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
    local ok, hidden = pcall(function()
        local cb = cell.PalCheckBox
        if not alive(cb) then return false end
        local previous = cell_cb[cell_name]
        if previous == nil then
            previous = api.as_int(cb:GetVisibility())
            if previous == nil then return false end
        end
        if cb:SetVisibility(2) == false then return false end
        cell_cb[cell_name] = previous
        return true
    end)
    return ok and hidden == true
end

hide_checkbox = measurement.callback("stand: hide vanilla checkbox", hide_checkbox)

local function restore_checkbox(cell, cell_name)
    if cell_cb[cell_name] == nil then return true end
    local want = cell_cb[cell_name]
    local ok, restored = pcall(function()
        local cb = cell.PalCheckBox
        return alive(cb) and cb:SetVisibility(want) ~= false
    end)
    if ok and restored then cell_cb[cell_name] = nil; return true end
    return false
end

-- The grid does not mark which job a pal is on right now. Three
-- attempts all made it worse, and the game already answers that in its own
-- info panel. This is an editor: it shows what you set.
local function set_cell(tb, cell_name, glyph, colour_key)
    local ft = make_ftext(glyph)
    local result = render.write(tb, ft, COLOUR[colour_key])
    if result == "rendered" then cell_last[cell_name] = glyph .. "|" .. colour_key end
    return result
end

set_cell = measurement.callback("stand: text and colour writes", set_cell)

local EDIT_MESSAGES = {
    pending="Sending change; the value is not confirmed yet.",
    acknowledged="Server acknowledged the change; waiting for confirmed data.",
    applied="Saving...",
    accepted="Confirmed by server.",
    applied_unsaved="The server applied this change but could not save it; it may be lost after a restart.",
    rejected="The server rejected this change; showing the last confirmed value.",
    timed_out="The change was not confirmed in time.",
    connecting="Connecting to server; priority data unavailable.",
    incompatible="Server version incompatible; priority data unavailable.",
}
local EDIT_REASONS = {
    save_failed=EDIT_MESSAGES.applied_unsaved,
    ack_timeout="Server did not acknowledge the change.",
    snapshot_timeout="Confirmed server data did not arrive.",
    queue_timeout="The queued change expired before it could be confirmed.",
    not_authorized="The server did not authorize this edit.",
    transport_unavailable="The server connection is unavailable.",
}

-- Read the current gate on every presentation/action, never retain its token.
function M.settings_message()
    local state=require('settings_gate').status()
    if state=='restart_required' then
        return 'Settings locked after a session change or save failure. Restart the game to edit priorities and limits.'
    elseif state=='recovering' then
        return 'Loading saved settings. Priority and limit editing is temporarily locked.'
    end
    if api.has_authority()==false and net.status=='unavailable' then
        if net.status_reason=='settings_restart_required' then
            return 'Server settings are locked. The host must restart the game or server before editing can resume.'
        elseif net.status_reason=='settings_recovering' then
            return 'The server is loading saved settings. Priority and limit editing is temporarily locked.'
        end
        return 'Server settings are unavailable. Priority and limit editing is locked.'
    end
end

-- Does this client's server run no Pal Work Priority at all?
--
-- Then the stand belongs to the game again: the vanilla checkbox, no "?"
-- cells, no receivers. Drawing "?" over every cell and hiding the checkbox
-- for a whole session (audit A5) took the base game's own control away on a
-- server that never had the mod.
--
--   connecting / handshake_timeout   four Hellos without an answer, about a
--                  minute: a server without the mod. Latched for this
--                  transport nonce, because the next failed Hello reports
--                  transport_unavailable in between and the stand must not
--                  flicker back to "?". A Welcome sets server_nonce and a new
--                  session a new nonce; either one ends it.
--
-- Only this case. A server that answers with another version or a settings
-- fence runs the mod, and base-game checkboxes would mislead there
-- (M.lock_message, review round 2, 2026-10-29).
--
-- "connecting" before the timeout stays "?" with its tooltip: the brief wait
-- of a normal join. Plain reads of net fields only.
local absent_latched, absent_nonce = false, nil
function M.vanilla_message()
    if api.has_authority() ~= false then return nil end
    local status = net.status
    if status ~= "connecting" or net.server_nonce ~= nil then
        absent_latched = false
        return nil
    end
    if net.status_reason == "handshake_timeout" then
        absent_latched, absent_nonce = true, net.local_nonce
    end
    if absent_latched and absent_nonce == net.local_nonce then return M.VANILLA_ABSENT end
    return nil
end

-- Does this client's server run the mod but refuse our edits for now?
--
--   incompatible   a 0.4.1 server, or another schema. Its scheduler keeps
--                  writing the work flags (0.4.1 does it every pass), so a
--                  base-game checkbox would show a choice the server
--                  overwrites. It will not change until one side is updated.
--   unavailable    the server's settings fence holds; settings_message has
--                  the server's own reason.
--
-- The stand stays ours and read-only: "?" cells, the checkbox hidden, no
-- receiver armed, every edit refused, and the legend says why.
function M.lock_message()
    if api.has_authority() ~= false then return nil end
    if net.status == "incompatible" then return M.LOCKED_INCOMPATIBLE end
    if net.status == "unavailable" then return M.settings_message() end
end

-- Edits are refused while the settings fence holds, the server locks the
-- stand, or the stand is the game's again.
local function editing_blocked()
    return M.settings_message() ~= nil or M.lock_message() ~= nil or M.vanilla_message() ~= nil
end

local function pak_message()
    if stand_pointer.asset_missing == true then return M.PAK_MISSING end
end

-- The config reset notice, once per process (M.RESET_NOTICE_SECONDS). The
-- clock starts the first time the legend would show it, so a stand that is
-- locked or missing its pak shows that first and this after. The text is
-- copied then: the panel acknowledging it meanwhile does not cut it short.
-- stand_lifecycle.generation moves on every stand open.
local reset_note = {}
local function reset_notice()
    local now = os.clock()
    if reset_note.until_at then
        if now <= reset_note.until_at and reset_note.generation == stand_lifecycle.generation then
            return reset_note.text
        end
        return nil
    end
    local configuration = package.loaded.configuration
    if type(configuration) ~= "table" or configuration.upgrade_reset ~= true then return nil end
    local text = configuration.upgrade_message or configuration.UPGRADE_MESSAGE
    if type(text) ~= "string" or text == "" then return nil end
    local named = "Pal Work Priority: " .. text
    if #named <= M.LEGEND_MAX_CHARS then text = named end
    if #text > M.LEGEND_MAX_CHARS then return nil end
    reset_note.text, reset_note.until_at = text, now + M.RESET_NOTICE_SECONDS
    reset_note.generation = stand_lifecycle.generation
    return text
end

function M.legend_text()
    return M.vanilla_message() or M.lock_message() or M.settings_message() or pak_message()
        or reset_notice() or M.edit_legend()
end

local function edit_presentation(key, work)
    local blocked=M.settings_message()
    if blocked then return "?","unknown",blocked end
    local state=current_edits()
    local entry=state.entries[key.."|"..work]
    local status=entry and entry.status
    -- The pending value may become visible before main delivers on_edit.
    if net.pending_priority then
        local _,present,pending_status=net.pending_priority(key,work)
        if present then status=pending_status or "pending" end
    end
    if entry and entry.issue then
        local detail=EDIT_REASONS[entry.issue_reason] or EDIT_MESSAGES[entry.issue]
        if status=="pending" or status=="acknowledged" then
            detail=detail.." It will be retried; this warning clears once it is saved."
        end
        return "!","issue",detail
    end
    if status=="applied_unsaved" or status=="rejected" or status=="timed_out" then
        return "!","issue",EDIT_MESSAGES[status]
    end
    if status=="pending" or status=="acknowledged" or status=="applied" then
        return "*","pending",EDIT_MESSAGES[status]
    end
    if status=="connecting" or status=="incompatible" then
        return "?","unknown",EDIT_MESSAGES[status]
    end
    if state.incomplete and not entry then
        return "?","unknown","Not saved yet; it will be retried."
    end
    return "",nil,status and EDIT_MESSAGES[status] or "This is the priority you set, not what the Pal is doing now."
end

-- One small legend in a known multi-child root. Ownership is names only; each
-- refresh discovers it in the CURRENT tree. Single-child/unknown roots are
-- left intact and receive the same legend in cell tooltips instead.
--
-- The text sits in a dark Border. Bare 12 pt grey over the world measured
-- 1.4-2.4:1 on grass (audit E, 2026-10-28); the backing is the panel's own
-- near-black at 0.85 and the text 14 pt near-white, which is well above 7:1
-- whatever is behind it. The Border is the root child we own; the TextBlock
-- is its only content and is found through it on every refresh.
local LEGEND_BACKING = { R = 0.014, G = 0.021, B = 0.035, A = 0.85 }
local LEGEND_TEXT = { R = 0.93, G = 0.94, B = 0.96, A = 1.0 }
M.LEGEND_FONT_SIZE = 14
local function refresh_legend(menu)
    local ok,shown=pcall(function()
        local name=full_name(menu)
        local tree=menu.WidgetTree
        if not alive(tree) then return false end
        local root=tree.RootWidget
        if not name or not alive(root) then return false end
        local kind=root:GetClass():GetFName():ToString()
        if kind~="CanvasPanel" and kind~="Overlay" and kind~="VerticalBox" then return false end
        local n=api.as_int(root:GetChildrenCount())
        if not n or n<0 or n>1024 then return false end
        local box
        for i=0,n-1 do
            local child=root:GetChildAt(i)
            if not alive(child) then return false end -- incomplete is not absent
            if full_name(child)==legend_names[name] then box=child end
        end
        if not box then
            if not legend_names[name] and legend_count>=64 then return false end
            local class=api.cdo("/Script/UMG.Border")
            if not class then return false end
            box=StaticConstructObject(class,tree)
            if not alive(box) then return false end
            local box_name=full_name(box)
            if not box_name then return false end
            local slot=root:AddChild(box)
            -- Record attachment before style writes, so a retry cannot double it.
            if not legend_names[name] then legend_count=legend_count+1 end
            legend_names[name]=box_name
            if not alive(slot) then return false end
        end
        local function write(value) if value==false then error("legend write refused") end end
        -- The content, found in the current tree. A Border holds one child; a
        -- failed earlier attach leaves it empty and this one fills it.
        local inner=api.as_int(box:GetChildrenCount())
        if inner==nil or inner<0 or inner>1 then return false end
        local tb
        if inner==1 then
            tb=box:GetChildAt(0)
            if not alive(tb) then return false end
        else
            local class=api.cdo("/Script/UMG.TextBlock")
            if not class then return false end
            tb=StaticConstructObject(class,tree)
            if not alive(tb) then return false end
            legend_styled[name]=nil -- a new text block takes the style below
            if not alive(box:AddChild(tb)) then return false end
        end
        -- The style is the same on every beat, so it is written once per
        -- Border and its text (review round 2: up to eleven engine calls on
        -- every refresh with the stand open). It is recorded only after every write went
        -- through, so a refused write is tried again on the next refresh.
        -- Only the text changes with the state.
        if legend_styled[name]~=legend_names[name] then
            local slot=box.Slot
            if not alive(slot) then return false end
            if kind=="CanvasPanel" then
                write(slot:SetAnchors({Minimum={X=0.5,Y=1},Maximum={X=0.5,Y=1}}))
                write(slot:SetAlignment({X=0.5,Y=1})); write(slot:SetPosition({X=0,Y=-8}))
                write(slot:SetAutoSize(true)); write(slot:SetZOrder(20))
            else
                write(slot:SetHorizontalAlignment(2))
                if kind=="Overlay" then write(slot:SetVerticalAlignment(3)) end
                write(slot:SetPadding({Left=4,Top=4,Right=4,Bottom=4}))
            end
            write(box:SetBrushColor(LEGEND_BACKING))
            write(box:SetPadding({Left=10,Top=3,Right=10,Bottom=3}))
            write(box:SetVisibility(3))
            local font=tb.Font; font.Size=M.LEGEND_FONT_SIZE; write(tb:SetFont(font))
            write(tb:SetColorAndOpacity({SpecifiedColor=LEGEND_TEXT,ColorUseRule=0}))
            write(tb:SetVisibility(3))
            legend_styled[name]=legend_names[name]
        end
        write(tb:SetText(make_ftext(M.legend_text())))
        return true
    end)
    M.legend_mode=ok and shown and "footer" or "tooltip"
end
refresh_legend = measurement.callback("stand: legend refresh", refresh_legend)

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
    if painted_gen == net.pals_gen and painted_epoch == inject_epoch then return false end
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
        if net.pending_priority then
            local pending, present = net.pending_priority(pal.key,t)
            if present then return pending end
        end
        local entry = pal.key and net.pals and net.pals[pal.key]
        if entry and entry.prios then return entry.prios[t] end
        return nil
    end
    return store.effective(cfg, pal, work_name, t)
end

-- The same test as scheduler_plan.unordered, on what the stand shows: two or
-- more jobs with a number and all of them the same. Such a Pal is left to
-- the game, which a grid of equal numbers does not say by itself (UX P2-14).
-- Answered once per Pal per paint (same_memo is emptied by every whole-grid
-- refresh and every input paint), not once per cell.
local same_memo = {}
local function same_number(cfg, pal, ranks)
    if type(cfg) == "table" and cfg.leave_unordered_pals_to_game == false then return false end
    local memo = pal.key and same_memo[pal.key]
    if memo ~= nil then return memo end
    local seen, count, same = nil, 0, true
    for t in pairs(ranks) do
        local work_name = workdefs.name(t)
        local p = work_name and shown_prio(cfg, pal, work_name, t)
        if type(p) == "number" then
            if seen ~= nil and seen ~= p then same = false; break end
            seen, count = p, count + 1
        end
    end
    same = same and count >= 2
    if pal.key then same_memo[pal.key] = same end
    return same
end

-- The cell back to the game: its checkbox, no receiver, no number, and no
-- tooltip of ours unless the tooltip is where the legend lives.
local function give_back(cell, cell_name)
    stand_pointer.disable(cell, cell_name)
    local existing, _, hint = tree_lookup.find(cell, cell_text[cell_name], alive, cell_paths[cell_name])
    cell_paths[cell_name] = hint
    if existing and alive(existing) then set_cell(existing, cell_name, "", "blank") end
    local tip = M.legend_mode == "tooltip" and M.legend_text() or ""
    pcall(function() cell:SetToolTipText(make_ftext(tip)) end)
    if not restore_checkbox(cell, cell_name) then return "failed" end
    return "vanilla"
end

local function handle_cell(cfg, cell, known_name)
    if not alive(cell) then return end
    -- The caller has already paid GetFullName for its seen-set; computing it
    -- again here was ~60 redundant engine calls a second with the stand
    -- open. Recomputed only when a caller has nothing to hand over.
    local cell_name = known_name or full_name(cell)
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

    -- Before the row lookup: an unbound row's cell may still carry an earlier
    -- session's hidden checkbox, and it goes back too.
    if M.vanilla_message() then return give_back(cell, cell_name) end

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
    if ranks and not capable then
        stand_pointer.disable(cell,cell_name)
        local existing, _, hint = tree_lookup.find(cell, cell_text[cell_name], alive, cell_paths[cell_name])
        cell_paths[cell_name] = hint
        local usable = false
        if existing then
            usable = alive(existing)
        end

        if usable then
            set_cell(existing, cell_name, "", "blank")
        end
        -- Recycled rows must not carry another Pal's edit error on a vanilla dash.
        pcall(function() cell:SetToolTipText(make_ftext("")) end)
        if not restore_checkbox(cell, cell_name) then return "failed" end
        return
    end

    local tb = ensure_cell_text(cell, cell_name)
    if not tb then return "failed" end

    -- A locked stand (settings fence, another server version) arms nothing.
    if prio~=nil and ranks and capable and store.decided and not editing_blocked() then
        if not stand_pointer.ensure(cell,cell_name,pal.key,t,inject_at_checkbox) then
            if stand_pointer.asset_missing then
                warn_once("pointer", "stand editing unavailable: LogicMods/PalWorkPriority.pak is missing (WBP_StandInput not found); reinstall the mod")
            else
                warn_once("pointer", "stand mouse input unavailable; matching input asset required, navigation remains available")
            end
        end
    else stand_pointer.disable(cell,cell_name) end

    local marker, edit_colour, detail = edit_presentation(pal.key,t)
    local unavailable = not api.has_authority() and net.status~="ready" and net.status~="rejected"
        and net.status~="applied_unsaved"
    local glyph, colour
    local known = not (prio == nil or not ranks or unavailable or M.settings_message())
    if not known then
        glyph,colour="?","unknown"
        if unavailable then
            detail=M.lock_message() or M.settings_message() or EDIT_MESSAGES[net.status] or "Priority data unavailable."
        end
        if prio==nil and not unavailable then detail="Priority data unavailable; waiting for a confirmed value." end
        if marker=="?" then marker="" end
    elseif prio == false then
        glyph, colour = "X", "off"
    else
        glyph, colour = tostring(math.floor(prio)), colour_for(prio)
    end

    glyph=glyph..marker
    colour=edit_colour or colour
    local locked=M.lock_message() or M.settings_message()
    if locked then detail=locked end
    -- The legend line names the controls; the number scale and the marks
    -- live here (M.MARKS_HELP).
    local help=(pak_message() or M.edit_legend()).."\n"..M.MARKS_HELP
        .."\nClick or use arrows to focus the stand; then hover a priority and press 1-5/X."
        .."\nWithout hover, number keys edit the focused cell.\n"..(detail or "Priority data unavailable.")
    if known and same_number(cfg,pal,ranks) then help=help.."\n"..M.SAME_NUMBER_HINT end
    if locked then help=locked end
    pcall(function() cell:SetToolTipText(make_ftext(help)) end)
    if M.selection and M.selection.key == pal.key and M.selection.work == t then glyph = "[" .. glyph .. "]" end
    local result = set_cell(tb, cell_name, glyph, colour)
    local shown, visible = pcall(function() return tb:SetVisibility(3) end)
    if result == "rendered" and shown and visible ~= false and hide_checkbox(cell, cell_name) then
        return "rendered"
    end
    -- A failed number must not erase the still-usable vanilla control.
    stand_pointer.disable(cell,cell_name)
    pcall(function() tb:SetVisibility(2) end)
    restore_checkbox(cell, cell_name)
    return "failed"
end

-- Only the current visible menu may supply draw or input targets. An
-- incomplete tree is unavailable; a global class sweep includes hidden menus
-- and must never become a fallback source of editable targets.
handle_cell = measurement.callback("stand: cell refresh", handle_cell)

local function live_cells(menu)
    if not menu then return nil end
    local found, meta, names = tree_lookup.stand_cells(menu, M.CELL_CLASS, alive,
        log.perf and log or nil)
    log.count(found and "ui: cells via tree" or "ui: cells unavailable")
    return found, meta, names
end
live_cells = measurement.callback("stand: roster lookup", live_cells)

-- All fields are bounded plain data from the resolver's existing reads. This
-- summary must never retain, resolve, or inspect an engine wrapper.
local function tree_summary(meta)
    if not meta then return "tree metadata unavailable" end
    local summary = string.format("visits=%d/%d budget_exhausted=%s",
        meta.visits, meta.budget, tostring(meta.budget_exhausted))
    if meta.scope then summary = "scope=" .. meta.scope .. " " .. summary end
    if meta.owner_visits then
        summary = summary .. string.format(" owner_visits=%d/%d",meta.owner_visits,meta.owner_budget)
    end
    if meta.row_scopes then
        summary = summary .. string.format(" row_scopes=%d row_fallbacks=%d",
            meta.row_scopes,meta.row_fallbacks or 0)
    end
    if meta.stage then
        summary = string.format("stage=%s class=%s name=%s refusal_visit=%d %s",
            meta.stage, meta.class, meta.name, meta.refusal_visit, summary)
    end
    return summary
end

-- Returns how many cells it actually painted, so the caller can tell a draw
-- that happened from one that did not.
local function refresh_cells(cfg, menu)
    same_memo = {}
    local cells, meta, names = live_cells(menu)
    if not cells or #cells == 0 then return 0, false, meta end

    local painted, complete = 0, true

    for index, cell in ipairs(cells) do
        -- The completed traversal just read this name. handle_cell still
        -- validates the fresh target before touching its properties/widgets.
        local name = names and names[index] or full_name(cell)

        -- Counted, and the error kept.
        --
        -- This was a bare pcall per cell, so every one of them could throw and
        -- the caller still recorded the frame as painted. handle_cell reaches
        -- shown_prio, shown_ranks and the injected TextBlocks, so one bad
        -- assumption in any of them blanks the whole grid silently. Said once
        -- per distinct message, because it fires per cell.
        local ok, err = pcall(function() return handle_cell(cfg, cell, name) end)
        -- A cell handed back to the game is drawn too: it is what the stand
        -- should show, and an uncommitted generation would repaint every beat.
        if ok and (err == "rendered" or err == "vanilla") then
            painted = painted + 1
        elseif not ok or err == "failed" then
            complete = false
            err = tostring(err)
            if err ~= last_cell_error then
                last_cell_error = err
                log.warn("a stand cell could not be drawn: " .. err)
            end
        end
    end

    if complete and painted > 0 then last_cell_error = nil end
    -- Missing cells may belong to another still-live hidden tree. Pruning by
    -- this menu would lose their ownership and duplicate controls on reopen.
    return painted, complete, meta
end
refresh_cells = measurement.callback("stand: grid refresh (includes roster)", refresh_cells)

-- ---------------------------------------------------------------------------
-- Entry point, once per UI tick
-- ---------------------------------------------------------------------------

function M.refresh(cfg,flush_receipt)
    if not api.has_viewport() then return false end
    -- The stand grid used to be authority-only, and the reason was a crash
    -- rather than a preference. It draws on a client now - from what the
    -- server sends, never from a local read - and the paragraph below records
    -- why the original restriction existed, because the hazard it names is
    -- still real for anything that reads a pal directly.
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
        -- A client draws the grid from what the server sent, or gives the
        -- stand back to the game.
        --
        -- The three reasons this was off are answered separately. The fatal
        -- rank call is gone from the client path entirely - the ranks arrive
        -- over the wire. The numbers are the server's priorities rather than a
        -- local file it never reads. Clicks are sent to the server now; the
        -- protocol carries PWP_Prio upward and the server's answer back down,
        -- so the number that changes on screen is the server's.
        --
        -- No data is not a grid of dashes, which would read as "this pal can
        -- do nothing". While the handshake is under way each cell shows "?"
        -- ("not known yet", with a Connecting tooltip). On a server without
        -- the mod every cell goes back to the vanilla checkbox
        -- (M.vanilla_message); with another version or a settings fence the
        -- cells stay "?" and refuse edits (M.lock_message). Either way the
        -- legend says why. The hook is registered either way.
        --
        -- Returning here also skipped try_hook_bind, so the hook only existed
        -- once data had arrived - and rows bound before that were never bound
        -- again. Registering is safe with no data: the rank loop inside is
        -- gated on authority, and a pal with no entry shows "?" until data
        -- arrives.
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
            -- exactly like the feature being switched off. (Since round 3
            -- net.poll sends the handshake on every session, and this ask is
            -- left for a connected client whose table came back empty.)
            --
            -- Only while there is nothing to draw, and at most once every ten
            -- seconds, so a server that genuinely has no pals for this guild
            -- is not asked repeatedly.
            -- An answer of "nothing" is still an answer.
            --
            -- The generation moves when a batch commits, empty or not. So if
            -- it has moved since the last ask and there is still nothing to
            -- draw, the server has told us it has no pals for this guild -
            -- and asking again will get the same reply for the rest of the
            -- session.
            --
            -- Without this the retry was permanent. A guild with no camps
            -- streamed in leaves net.pals empty forever, so a re-ask every ten
            -- seconds ran for the whole session, on every such client, and
            -- each one costs the server a base walk plus fourteen native rank
            -- calls per pal. The comment here used to claim the opposite - "a
            -- server that genuinely has no pals for this guild is not asked
            -- repeatedly" - and that is the one case where it was asked
            -- forever.
            -- An empty answer slows the asking down; it does not end it.
            --
            -- This used to latch and return for good. The server declines an
            -- unresolvable guild now, but a guild that resolves fine and simply
            -- has no camps streamed in yet still answers empty - a player who
            -- joins away from their base, which is the common case. Latching
            -- there meant a vanilla grid for the rest of the session, and the
            -- return also sat above try_hook_bind, so the row hook was never
            -- registered either and no later data could have drawn anyway.
            --
            -- The backoff is the brake: it doubles to two minutes and the
            -- server answers three hellos a minute per join, so a client that
            -- genuinely has nothing costs almost nothing while still
            -- recovering on its own when its camps load.
            if asked_gen ~= nil and net.pals_gen ~= asked_gen and not said_none then
                said_none = true
                log.debug("stand: the server had nothing for this guild, " ..
                    "asking less often")
            end

            -- Backing off, because the reasons this is empty are mostly not
            -- ones another ask will fix.
            -- Committed only once the message has actually gone.
            --
            -- These three were set before the send was attempted and never
            -- rolled back, so while the network component was still resolving
            -- - up to the first eighteen seconds of a join - the client
            -- burned 10, 20, 40, 80 seconds of backoff without a single
            -- message leaving, and armed asked_gen
            -- for an answer that could never come.
            --
            -- net.ask_pals asks only a client that is already connected; the
            -- handshake is net.poll's (round 3: this asked from the first
            -- second of a join, before the role was decided, and spent the
            -- server's announcement budget). "pending" means a Hello went up
            -- moments ago and its full table is on the way: that counts as
            -- this ask, so the backoff starts from the join's own answer.
            local now = os.clock()
            if now - last_ask > ask_gap then
                local sent = false
                pcall(function()
                    sent = net.ask_pals()
                end)

                if sent then
                    last_ask = now
                    ask_gap = math.min(ask_gap * 2, ASK_GAP_MAX)
                    asked_gen = net.pals_gen
                    log.debug(sent == "pending" and "stand: pal data already on its way"
                        or "stand: asked the server for pal data")
                end
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
    -- An attached writer polls even while saved. Main may supply a single-use
    -- receipt for this callback; intervening edits/ownership changes invalidate
    -- it. Standalone calls and failed/pending maintenance retain this flush.
    if type(flush_receipt)~='function' or flush_receipt()~=true then store.flush()end

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
        -- A pal the server has never told us about.
        --
        -- The full table is sent once, on Hello, and a single-row push can add
        -- or overwrite a key but never announce one the client has not heard
        -- of in some other way. So a pal CAUGHT after joining is bound to a row
        -- here, has no entry in net.pals, and its cells fall back to vanilla -
        -- a stand where old pals show numbers and new ones show plain
        -- checkboxes, which reads as the mod being half broken.
        --
        -- Asking is cheaper than a periodic full push from the server, and the
        -- client is the side that can actually see the discrepancy. Once per
        -- generation: if the answer arrives and the key is still missing,
        -- net.pals_gen has moved and this will not fire again for it.
        -- An ask the server refused (its announcement budget) or that never
        -- arrived gets no answer, and nothing else pushes a full table, so
        -- the pal kept plain checkboxes for good in a quiet session (round
        -- 3). No pal data within missing_wait seconds re-arms the ask; the
        -- wait doubles while the asks stay unanswered.
        if missing_at then
            if missing_gen ~= net.pals_gen then
                missing_at, missing_wait = nil, MISSING_WAIT
            elseif os.clock() - missing_at >= missing_wait then
                missing_gen, missing_key, missing_at = nil, nil, nil
                missing_wait = math.min(missing_wait * 2, ASK_GAP_MAX)
            end
        end
        if next(net.pals) ~= nil and missing_gen ~= net.pals_gen then
            local absent = nil
            for _, pal in pairs(row_pal) do
                if type(pal) == "table" and type(pal.key) == "string"
                    and net.pals[pal.key] == nil then
                    absent = pal.key
                    break
                end
            end

            -- Once per unknown pal, not once per generation.
            --
            -- The server's answer is a push, which moves the generation, which
            -- made this condition true again - so a key that stays absent (a
            -- pal of another guild on the same stand, or one stand_rows skipped
            -- because its parameter was momentarily invalid) re-asked on every
            -- tick until the hello budget ran out, and restarted every time
            -- anyone edited anything.
            if absent and (absent ~= missing_key or os.clock() - last_ask >= ASK_GAP_MAX) then
                -- Committed only once the message has gone, as the backoff
                -- above already is. Setting the memos first meant a send
                -- attempted before the network component resolves - the first
                -- eighteen seconds - latched "already asked about this pal"
                -- for a message that never left, and the log line said
                -- "asking once" on a path where nothing was sent.
                local sent = false
                pcall(function()
                    sent = net.ask_pals()
                end)

                if sent then
                    missing_gen = net.pals_gen
                    missing_key = absent
                    last_ask = os.clock()
                    missing_at = last_ask
                    log.debug("stand: no data for " .. absent .. ", asked once")
                end
            end
        end

        -- The generation is NOT consumed here.
        --
        -- This used to return before live_menu() ran, which is the only thing
        -- that notices a new menu instance. So opening the stand after the
        -- data had already arrived left painted_gen equal to pals_gen, the
        -- refresh returned immediately, refresh_cells never ran, and the grid
        -- drew nothing at all - the numbers appeared only when a row happened
        -- to rebind, which is what clicking a vanilla checkbox does.
        --
        -- The saving this guard was written for is kept by the
        -- menu_likely_open test near the top of this function: while the stand
        -- is shut nothing below runs. What it must not do is skip the draw for
        -- a menu it has never drawn, which is why the generation check now
        -- happens after live_menu rather than here.
    end

    local menu = live_menu()
    if not menu then
        M.detach()
        -- A proven close stands down until a row binds again. Without this the mod runs a
        -- FindAllOf every second for the rest of the session after the stand
        -- is opened once. Unknown/ambiguous queries must remain retryable;
        -- they do not prove a close and may recover without any row bind.
        menu_likely_open = menu_lookup_uncertain
        return false
    end

    -- Committed only if something was drawn.
    --
    -- The comment on the gate above already states this invariant - "consumed
    -- only once a draw has actually happened. A generation marked as painted
    -- by a refresh that painted nothing is what made the grid blank" - and the
    -- code did not implement it. refresh_cells returned nothing, and every
    -- per-cell paint inside it is a discarded pcall, so all 62 could fail and
    -- the epoch still committed. The gate then returned early for ever after.
    refresh_legend(menu)
    local painted, complete, tree_meta = refresh_cells(cfg, menu)

    if painted == 0 or not complete then
        if not said_painted_none then
            said_painted_none = true
            if tree_meta and not tree_meta.complete then
                log.warn("the stand grid is unavailable: incomplete tree; no cells painted (" ..
                    tree_summary(tree_meta) .. ")")
            elseif painted == 0 then
                log.warn("the stand grid painted no cells (" ..
                    tostring(tree_meta and tree_meta.matched_cells or 0) .. " cells found)")
            else
                log.warn("the stand grid paint incomplete: " .. painted ..
                    " cells rendered; some cells failed")
            end
        end
        return false
    end

    said_painted_none = false
    painted_gen = net.pals_gen
    painted_epoch = inject_epoch
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
local function hovered_cell(cells)
    -- The caller resolves this complete roster inside the current action.
    -- It must never be kept for the next keybind or refresh callback.
    local hovered
    for _, cell in ipairs(cells or {}) do
        local ok,hit=pcall(function() return cell:IsHovered() end)
        if not ok or type(hit)~='boolean' then return nil,false end
        if hit then
            if hovered then return nil,false end
            hovered=cell
        end
    end
    return hovered,true
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

-- Only the edited cell and the former navigation focus need immediate paint.
-- All wrappers belong to this action's freshly proved roster. Data/snapshot
-- invalidations still get a complete refresh at the normal maintenance beat.
local function paint_input(cfg, cells, edited, previous)
    same_memo = {}
    for _, cell in ipairs(cells or {}) do
        local paint = cell == edited
        if not paint and previous then
            local pal, work = cell_target(cell)
            paint = pal and pal.key == previous.key and work == previous.work
        end
        if paint then
            local name = full_name(cell)
            if name then cell_last[name] = nil end
            local ok, result = pcall(handle_cell, cfg, cell, name)
            if not ok or (result ~= "rendered" and result ~= "vanilla") then
                -- Do not consume the full-grid generation on a partial draw.
                invalidate_cells()
                if not ok then warn_once("input paint", "stand edit could not be drawn: " .. tostring(result)) end
            end
        end
    end
end

-- dir -1 for left click (towards priority 1), +1 for right click.
local function bump(cfg, dir, cell_name, key, work, token, revision)
    if editing_blocked() then return false end
    if not menu_likely_open or not store.decided then return end

    -- Fresh discovery also invalidates queued actions when the visible menu
    -- changes without a preceding row-bind event. Do not finish this action
    -- against the replacement menu merely because discovery succeeded.
    local epoch = session.ui_epoch
    local menu = live_menu()
    if epoch ~= session.ui_epoch then return end
    if not menu then
        menu_likely_open = menu_lookup_uncertain
        return
    end

    local cells = live_cells(menu)
    local cell
    for _, candidate in ipairs(cells or {}) do
        if full_name(candidate)==cell_name
            and stand_pointer.matches(candidate,cell_name,key,work,token) then cell=candidate; break end
    end
    if not cell then return end

    local pal, t, work_name = cell_target(cell)
    if not pal or pal.key~=key or t~=work then return end

    local current = shown_prio(cfg, pal, work_name, t)
    if current==nil then return end
    local next_prio = store.cycle(current, dir)
    local previous = M.selection
    -- An accepted press must not erase navigation performed after that press.
    if revision==(M.selection_revision or 0) then M.selection = nil end
    if next_prio == current then paint_input(cfg, cells, cell, previous); return end

    local saved = store.set(pal.key, t, next_prio)
    paint_input(cfg, cells, cell, previous)
    if not saved then return end

    -- Deliberately NOT writing the game's permission flag here: the fence
    -- owns those. A click changes policy, the pass applies it. Writing here
    -- too gave one click three authorities and made the checkbox flicker.
    M.wants_pass = true

    log.debug(string.format("%s %s -> %s",
        tostring(pal.name), work_name,
        next_prio == false and "X" or tostring(next_prio)))
end

function M.is_open() return menu_likely_open end

local function input_targets(cells)
    local targets, row_order, next_row = {}, {}, 0
    for _, cell in ipairs(cells or {}) do
        local pal, work, name, cname = cell_target(cell)
        if pal then
            if not row_order[pal.key] then next_row=next_row+1; row_order[pal.key]=next_row end
            targets[#targets+1] = {key=pal.key,work=work,name=name,cname=cname,pal=pal,cell=cell}
        end
    end
    table.sort(targets,function(a,b)
        if a.key ~= b.key then return row_order[a.key]<row_order[b.key] end
        return a.work<b.work
    end)
    return targets
end

function M.nav(cfg,direction,origin)
    if editing_blocked() then return false end
    if not menu_likely_open or not store.decided or (input_blocked and input_blocked()) then return false end
    local epoch=session.ui_epoch
    local menu=live_menu()
    if epoch~=session.ui_epoch then return false end
    if not menu then menu_likely_open=menu_lookup_uncertain; M.selection=nil; return false end
    local owns, focused=pcall(function()
        return menu:HasAnyUserFocus()==true or menu:HasFocusedDescendants()==true
    end)
    if not owns or not focused then return false end
    local cells=live_cells(menu)
    local targets=input_targets(cells)
    local previous=M.selection
    if origin then
        local found=false
        for _,target in ipairs(targets) do
            if target.key==origin.key and target.work==origin.work then found=true; break end
        end
        if not found then return false end
    end
    local wanted=stand_input.select(targets,origin or M.selection,direction)
    if not wanted then return false end
    local selected
    for _,target in ipairs(targets) do
        if target.key==wanted.key and target.work==wanted.work then selected=target; break end
    end
    if not selected or not stand_pointer.focus(selected.cell,selected.cname,selected.key,selected.work) then return false end
    M.selection=wanted
    M.selection_revision=(M.selection_revision or 0)+1
    if direction=="enter" or direction=="raise" or direction=="lower" or direction=="disable" then
        local token=stand_pointer.token(selected.cell,selected.cname,selected.key,selected.work)
        if not token then return false end
        local intent={cell=selected.cname,key=selected.key,work=selected.work,token=token,
            world=session.epoch,ui=session.ui_epoch,pointer=false}
        if direction~='disable' then intent.cycle=direction=='lower' and 1 or -1 end
        -- Controller mutations share the same FIFO as native mouse/numbers.
        -- Cycle from the pending value at execution, never the old snapshot.
        if not session.enqueue(M.direct,true,cfg,false,intent) then return false end
    end
    paint_input(cfg,cells,selected and selected.cell,previous)
    return true
end

-- Native keyboard callback only. Resolve the target NOW, while Slate has
-- delivered the event to our focused receiver, and keep scalar identity only.
function M.capture_direct(source_name,source_key,source_work,source_token,source_only)
    if editing_blocked() then return false end
    if not menu_likely_open or not store.decided then return false end
    local epoch=session.ui_epoch
    local menu=live_menu()
    if epoch~=session.ui_epoch then return false end
    if not menu then menu_likely_open=menu_lookup_uncertain; return false end
    local cells=live_cells(menu)
    local source
    for _,candidate in ipairs(cells or {}) do
        if full_name(candidate)==source_name
            and stand_pointer.matches(candidate,source_name,source_key,source_work,source_token) then
            source=candidate; break
        end
    end
    if not source then return false end
    local hovered,complete
    if source_only then complete=true else hovered,complete=hovered_cell(cells) end
    if not complete then return false end
    local cell=hovered or source
    local pal,work,_,name=cell_target(cell)
    if not pal then return false end
    local token=stand_pointer.token(cell,name,pal.key,work)
    if not token then return false end
    return {cell=name,key=pal.key,work=work,token=token,world=session.epoch,ui=epoch,
        pointer=hovered~=nil,selection_revision=M.selection_revision or 0}
end

function M.direct(cfg,priority,intent)
    if editing_blocked() then return false end
    if not menu_likely_open or not store.decided or (input_blocked and input_blocked()) or type(intent)~='table'
        or intent.world~=session.epoch or intent.ui~=session.ui_epoch then return false end
    if priority~=false and (type(priority)~='number' or priority%1~=0 or priority<1 or priority>5) then return false end
    local menu=live_menu()
    if not menu or intent.ui~=session.ui_epoch then return false end
    local cells=live_cells(menu)
    local cell,pal,work
    for _,candidate in ipairs(cells or {}) do
        if full_name(candidate)==intent.cell
            and stand_pointer.matches(candidate,intent.cell,intent.key,intent.work,intent.token) then
            pal,work=cell_target(candidate)
            if pal and pal.key==intent.key and work==intent.work then cell=candidate end
            break
        end
    end
    if not cell then return false end
    if intent.cycle then
        if intent.cycle~=-1 and intent.cycle~=1 then return false end
        local current=shown_prio(cfg,pal,workdefs.name(work),work)
        if current==nil then return false end
        priority=store.cycle(current,intent.cycle)
    end
    local previous=M.selection
    -- A number key over a capable cell is the same pointer-directed edit as
    -- a click. Without hover, retain the navigation marker on the selected cell.
    if intent.pointer and intent.selection_revision==(M.selection_revision or 0) then M.selection=nil end
    local saved=store.set(pal.key,work,priority)
    paint_input(cfg,cells,cell,previous)
    if not saved then return false end
    M.wants_pass=true
    return true
end

M.open_panel = false -- set by main.lua: opens the limits panel (View on the stand)

function M.pad_tick(cfg)
    if not menu_likely_open or not api.has_viewport() then return end
    -- A controller press can only reach our receiver while it has the focus,
    -- and the game's stand gives the focus to its own cell. On a controller
    -- (asked at most four times a second) put it on the current selection,
    -- the same as the first arrow key does on a keyboard. Not while the stand
    -- is the game's again or the server locks it: then its own cursor keeps
    -- the focus, and nothing of ours could be edited anyway.
    local now=os.clock()
    if (M.pad_focus_at or 0)<=now and not M.vanilla_message() and not M.lock_message() then
        M.pad_focus_at=now+0.25
        local gamepad=api.input_is_gamepad and api.input_is_gamepad()==true
        if gamepad and not stand_pointer.keyboard_active() then
            local handed=M.nav(cfg,"here")
            -- One line per stand session and outcome, for the controller tests.
            local note=tostring(session.ui_epoch)..(handed and ":yes" or ":no")
            if M.pad_handover_note~=note then
                M.pad_handover_note=note
                log.say("controller: focus handover "..(handed and "done" or "refused").." (stand session "..tostring(session.ui_epoch)..")")
            end
        end
    end
    if not M.pad_handlers then
        M.pad_handlers={
            nav=function(verb) M.nav(M.pad_cfg,verb) end,
            up=function() M.nav(M.pad_cfg,"up") end,
            down=function() M.nav(M.pad_cfg,"down") end,
            left=function() M.nav(M.pad_cfg,"left") end,
            right=function() M.nav(M.pad_cfg,"right") end,
            enter=function() M.nav(M.pad_cfg,"raise") end,
            tab_prev=function() M.nav(M.pad_cfg,"raise") end,
            tab_next=function() M.nav(M.pad_cfg,"lower") end,
            remove=function() M.nav(M.pad_cfg,"disable") end,
        }
    end
    M.pad_cfg=cfg
    pad.tick_ms=16 -- main drives this from its 16ms game-thread loop
    pad.drive(M.pad_handlers)
end

-- Bound once, not per menu. The handlers bail on a plain Lua flag when the
-- stand is shut, so ordinary gameplay clicks cost nothing measurable.
-- `before` gets first refusal on every click and returning true consumes it.
-- The rules panel uses that: it can be open over the stand, and a click meant
-- for a rule must not also land on whatever priority cell sits underneath.
function M.bind_mouse(cfg_ref, before, blocked)
    input_blocked=blocked
    local bound = 0
    stand_pointer.configure(function(cell,key,work,token,dir,revision)
        if blocked and blocked() then return end
        bump(cfg_ref(),dir,cell,key,work,token,revision)
    end,function()
        return menu_likely_open and store.decided and not (blocked and blocked())
    end,function(priority,cell,key,work,token)
        if type(priority)=='number' and priority>=6 and priority<=9 then
            local direction=({[6]='up',[7]='down',[8]='left',[9]='right'})[priority]
            if direction then M.nav(cfg_ref(),direction,{key=key,work=work}) end
            return
        end
        -- Controller (StandInput contract 3): 11 = LB toward 1, 12 = RB toward
        -- X, 13 = View opens the Production Limits panel (Y is the stand's own view
        -- switch and never reaches us). A arrives as 10, X as 0
        -- and the D-pad as 6-9, the same codes as Enter, X and the arrows.
        if priority==13 then
            if M.open_panel then session.enqueue(function() M.open_panel() end,true) end
            return
        end
        local step=priority==10 or priority==11 or priority==12
        local intent=M.capture_direct(cell,key,work,token,step)
        if not intent then return end
        if step then intent.cycle=priority==12 and 1 or -1; priority=false end
        session.enqueue(function()
            if blocked and blocked() then return end
            M.direct(cfg_ref(),priority,intent)
        end,true)
    end,function() return M.selection_revision or 0 end)

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
                session.enqueue(function()
                    -- Raw callbacks have no native target. They may service the
                    -- separate panel, but must never acquire a stand cell later.
                    if before then before(dir) end
                end, true)
            end)
        end)
        if ok then bound = bound + 1 end
    end

    try("LEFT_MOUSE_BUTTON", -1)
    try("RIGHT_MOUSE_BUTTON", 1)
    return bound
end

-- Raw arrows may establish initial focus while the vanilla stand owns it.
-- Once a native receiver has taken over this generation, only its own key
-- events navigate; the global observer must not duplicate Slate delivery.
function M.raw_nav(cfg,direction)
    if direction=='enter' or stand_pointer.keyboard_active() then return false end
    return M.nav(cfg,direction)
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
    f:write(stand_pointer.report().."\n")
    f:write(stand_lifecycle.report().."\n")
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

            -- Use the same resolver as drawing/input. A refusal is not proof
            -- that rows are virtualized: report its first failed traversal
            -- stage and budget separately from the diagnostic global count.
            local found, meta = tree_lookup.stand_cells(m, M.CELL_CLASS, alive)
            local global_cells = 0
            pcall(function()
                for _, c in ipairs(FindAllOf(M.CELL_CLASS) or {}) do
                    if alive(c) then global_cells = global_cells + 1 end
                end
            end)
            f:write(string.format(
                "   tree cells: %s | global cell walk: %d\n",
                found and tostring(#found)
                    or "unavailable (incomplete tree)",
                global_cells))
            f:write("   tree walk: " .. tree_summary(meta) .. "\n")
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
            if shown == 1 then
                f:write(require('stand_event_probe').read(c, alive, StaticFindObject))
            end
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
