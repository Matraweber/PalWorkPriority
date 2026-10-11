-- Pal Work Priority
--
-- Numeric work priorities for base pals, driven from config.lua. Priority 1
-- is highest; balanced and strict modes differ in how they distribute seats.
--
-- The mod does not hand pals jobs. It decides which work types each pal may
-- do right now and switches the rest off through
-- RequestChangeWorkSuitability_ToServer, the same flag the vanilla
-- checkboxes write, leaving the game's own AI to choose within that fence.

local log = require("log")
local api = require("palapi")
local workdefs = require("workdefs")
local scheduler = require("scheduler")
local discover = require("discover")
local ui = require("ui")
local store = require("store")
local caps = require("caps")
local items = require("items")
local panel = require("panel")
local remote = require("remote")
local reload = require("reload")
local clock = require("clock")
local trace = require("trace")
local icons = require("icons")
local net = require("net")
local overlay = require("overlay")
local demandidx = require("demand")
local pad = require("pad")
local darnmenu = require("darnmenu")
local session = require("session")
local configuration = require("configuration")
local measurement = require("measurement")

-- Each row covers a complete function; nested rows are explicitly inclusive.
for _, entry in ipairs({
    {scheduler,"run_pass","scheduler: complete"},
    {api,"base_camps","api: camp enumeration"},
    {api,"latch_authority","api: authority resolution"},
    {api,"owned_network_component","api: owned component resolution"},
    {api,"camp_item_totals","storage: camp totals"},
    {api,"chest_totals_by_camp","storage: bucketed totals"},
    {api,"all_chest_totals","storage: all totals"},
    {ui,"refresh","stand: complete refresh"},
    {panel,"refresh","panel: complete refresh"},
    {panel,"hover_tick","panel: hover and input"},
    {panel,"fill_tick","panel: incremental fill"},
    {overlay,"host","overlay: host resolution"},
    {icons,"get","icons: get"},
    {pad,"drive","pad: complete drive"},
    {net,"storage_tick","network storage: complete"},
}) do measurement.bind(entry[1],entry[2],entry[3]) end

local MOD_NAME = "Pal Work Priority"
local VERSION = "0.5.0-rc1"

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local function script_dir()
    local src = debug.getinfo(1, "S").source
    local path = src:sub(2)
    return path:match("^(.*[\\/])") or ""
end

-- Output goes to the mod root: redeploying replaces Scripts/ wholesale and
-- would take the log with it.
local SCRIPT_DIR = script_dir()
local DIR = SCRIPT_DIR:match("^(.*[\\/])[Ss]cripts[\\/]$") or SCRIPT_DIR

log.file_path = DIR .. "priority.log"
-- Only when the file is actually there.
--
-- This was wired unconditionally, so every subscriber's game did a synchronous
-- open/read/close of remote.txt once a second for the whole session - a
-- developer-only control channel, in a release build, on the game thread. It
-- is small per call and it is pure waste, and it is the best structural match
-- for the "micro-stutters every second in the open field" report on the
-- Workshop page.
--
-- Checked once here rather than every poll: someone who wants the channel
-- creates the file and restarts, which is what the testing doc already tells
-- them to do.
local remote_file = DIR .. "remote.txt"
local remote_probe = io.open(remote_file, "r")
if remote_probe then
    remote_probe:close()
    remote.path = remote_file
    log.say("remote.txt found, the remote control channel is on")
end
trace.path = DIR .. "trace.txt"

-- What was in flight when the last session ended.
--
-- The fault being hunted kills the process outright, so nothing reaches the
-- ordinary log after it. The breadcrumb file survives, and reading it here
-- means the answer is waiting at the top of the next session rather than
-- needing to be gone looking for.
do
    local was = trace.last()
    if was then
        log.warn("last session was in the middle of: " .. was)
    end
end
-- The wire format's width has to match the work list it describes.
--
-- net.lua carries its own constant because it deliberately requires only log
-- and palapi. Checked here, where workdefs is in scope, so adding a work type
-- fails loudly at load rather than silently truncating the new column.
if net.WORKS ~= #workdefs.ORDER then
    log.error("the network format carries " .. tostring(net.WORKS) ..
        " work types but workdefs lists " .. #workdefs.ORDER ..
        ". Update net.WORKS or the grid will be missing a column.")
end

-- Checked local async trial only. Release packages never contain this launcher.
-- Run inside this Lua state so Caps/Store and the recovery gate are shared.
local async_trial
do
    -- Presence alone fences an interrupted offline cutover. Never read, execute
    -- or remove this marker, and do not inspect either settings recovery set or
    -- the trial launcher until absence has been positively established.
    local cutover_checked, cutover_marker, _, cutover_code = pcall(io.open, DIR .. ".settings-cutover", "rb")
    if cutover_checked and cutover_marker then pcall(function() cutover_marker:close() end) end
    if not cutover_checked or cutover_marker or cutover_code ~= 2 then
        local gate = require('settings_gate')
        local token = gate.acquire()
        if token then gate.require_restart(token) end
        log.error("settings cutover marker exists or is unreadable; settings fenced until recovery and restart. " ..
            "Preserve .settings-cutover; do not remove it to bypass recovery.")
    else
    store.load(DIR .. "priorities.txt")
    caps.load(DIR .. "caps.txt")
    local marker, marker_error, marker_code = io.open(DIR .. "async-trial/launch.lua", "rb")
    if marker then
        local closed = marker:close()
        local ok, result = pcall(function()
            assert(closed == true, "trial launcher close failed")
            return assert(loadfile(DIR .. "async-trial/launch.lua"))()
        end)
        if ok and type(result) == "table" and type(result.transition) == "function" then
            async_trial = result
        else
            -- A launch failure must never silently resume obsolete legacy writes.
            if not require('settings_gate').blocked() then require('settings_gate').acquire() end
            log.error("async trial unavailable; settings fenced: " .. tostring(result))
        end
    elseif marker_code ~= 2 then
        if not require('settings_gate').blocked() then require('settings_gate').acquire() end
        log.error("async trial presence is unknown; settings fenced: " .. tostring(marker_error))
    else
        -- A missing launcher is not evidence that legacy files are current.
        -- Checked trial installers retain this receipt before journal admission.
        -- Never execute it or interpret its contents as rollback authorization.
        local checked, receipt, _, receipt_code = pcall(io.open, DIR .. "async-trial/receipt.lua", "rb")
        if receipt and checked then pcall(function() receipt:close() end) end
        if not checked or receipt or receipt_code ~= 2 then
            local gate = require('settings_gate')
            local token = gate.acquire()
            if token then gate.require_restart(token) end
            log.error("async trial launcher missing but recovery receipt exists or is unreadable; " ..
                "settings fenced. Preserve journals and restore the checked trial before restarting; " ..
                "do not delete its receipt to bypass recovery.")
        end
    end
    end
end

-- Timestamp-only evidence cannot bind a delayed native callback to a connection.
-- Fresh world/function probes remain until native event identity is verified.
api.set_authority_hint(nil)

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local cfg = nil
local timer_running = false

local function validate(c)
    if type(c.work_priority) ~= "table" then
        log.error("config.work_priority is not a table, using an empty one")
        c.work_priority = {}
    end

    for name, prio in pairs(c.work_priority) do
        if not workdefs.is_known(name) then
            log.warn("config.work_priority has unknown work type '" .. tostring(name) ..
                "', check the spelling against workdefs.lua")
        elseif prio ~= false then
            -- Dropped, not merely warned about.
            --
            -- A fractional priority passed this and then did nothing at all:
            -- plan_fences matches "== level" against whole levels, so 2.5 is
            -- never equal to any of them and the pal simply falls through
            -- unfenced. Worse, a click on that cell wrote 1.5, and the loader
            -- matches the priority with (%w+) - which a dot is not - so the
            -- line was silently dropped on the next launch. The network path
            -- already refuses fractions for exactly this reason and said so;
            -- the config path only shrugged.
            local n = math.tointeger(tonumber(prio))
            if n == nil or n < 1 or n > store.MAX then
                log.warn("config.work_priority['" .. name .. "'] should be a " ..
                    "whole number from 1 to " .. store.MAX .. ", or false. " ..
                    "Ignoring " .. tostring(prio) .. ".")
                c.work_priority[name] = nil
            else
                c.work_priority[name] = n
            end
        end
    end

    -- A ceiling on a work type that does not exist, or one whose value is
    -- not a number, would never fire. Say so rather than let someone
    -- believe a cap is in force.
    -- pal_overrides is the third way a priority reaches plan_fences, and it
    -- was the one left unchecked. store.effective reads it directly, so a
    -- fractional value here lands in exactly the same place a fractional
    -- work_priority did: never equal to any whole level, so the pal is
    -- silently never fenced for that work.
    c.pal_overrides = c.pal_overrides or {}
    for who, entry in pairs(c.pal_overrides) do
        if type(entry) ~= "table" then
            log.warn("config.pal_overrides['" .. tostring(who) ..
                "'] should be a table of work = priority. Ignoring it.")
            c.pal_overrides[who] = nil
        else
            for name, prio in pairs(entry) do
                if prio ~= false then
                    local n = math.tointeger(tonumber(prio))
                    if n == nil or n < 1 or n > store.MAX then
                        log.warn("config.pal_overrides['" .. tostring(who) ..
                            "']['" .. tostring(name) .. "'] should be a whole " ..
                            "number from 1 to " .. store.MAX .. ", or false. " ..
                            "Ignoring " .. tostring(prio) .. ".")
                        entry[name] = nil
                    else
                        entry[name] = n
                    end
                end
            end
        end
    end

    c.work_caps = c.work_caps or {}

    -- Read BEFORE the loop, because the loop variable below is also named
    -- `caps` and shadows the module for the whole body. Asking the module for
    -- its ceiling limit inside the loop gets the per-work-type table instead,
    -- which has no such field, and comparing a number against nil throws -
    -- during config validation, so the mod would come up with no config.
    local max_ceiling = caps.MAX_CEILING

    for name, caps in pairs(c.work_caps) do
        if not workdefs.is_known(name) then
            log.warn("config.work_caps has unknown work type '" .. tostring(name) .. "'")
        elseif type(caps) ~= "table" then
            log.warn("config.work_caps['" .. name .. "'] should be a table of item = amount")
        else
            for item, ceiling in pairs(caps) do
                -- Dropped, not merely warned about.
                --
                -- The warning left the bad value in cfg, merged_for copies
                -- cfg.work_caps verbatim - bypassing valid_rule, which is the
                -- only thing that floors - and push_rules formats it with %d.
                -- On Lua 5.4 that throws for anything with no integer form,
                -- inside the pcall every caller wraps it in, and the batch is
                -- never cached. So one "5000.5" in config.lua meant NO client
                -- ever received any ceiling, for the whole session, with
                -- nothing in the log.
                local n = math.tointeger(tonumber(ceiling))
                if n == nil or n < 1 or n > max_ceiling then
                    log.warn("config.work_caps['" .. name .. "']['" ..
                        tostring(item) .. "'] should be a whole number from " ..
                        "1 to " .. max_ceiling .. ". Ignoring " ..
                        tostring(ceiling) .. ".")
                    caps[item] = nil
                end
            end
        end
    end

    if c.assignment_mode ~= "spread" and c.assignment_mode ~= "fill" then
        if c.assignment_mode ~= nil then
            log.warn("config.assignment_mode should be \"spread\" or \"fill\", got '" ..
                tostring(c.assignment_mode) .. "', using spread")
        end
        c.assignment_mode = "spread"
    end

    -- false and nil both mean no limit; anything else has to be a count.
    if c.max_pals_per_work_type ~= nil and c.max_pals_per_work_type ~= false then
        local n = tonumber(c.max_pals_per_work_type)
        if not n or n < 1 then
            log.warn("config.max_pals_per_work_type should be a number >= 1 or false" ..
                ", treating as no limit")
            c.max_pals_per_work_type = false
        else
            c.max_pals_per_work_type = math.floor(n)
        end
    end

    c.pal_overrides = c.pal_overrides or {}
    c.min_suitability_rank = c.min_suitability_rank or 1
    c.interval_seconds = math.max(5, tonumber(c.interval_seconds) or 30)
    c.chat_prefix = c.chat_prefix or "!pwp"
    return c
end

local function load_config()
    -- loadfile, not require.
    --
    -- reload.lua proved this by experiment and wrote it down: clearing
    -- package.loaded and calling require again returns a table, reports no
    -- error, and does not read the file - UE4SS keeps the compiled chunk of
    -- its own accord, so require hands back the code it compiled at startup.
    -- reload.now() was fixed; this was not.
    --
    -- So "pwp reload" re-ran the ORIGINAL chunk: it threw away any runtime
    -- change made with pwp dry / mode / cap / scope, put the shipped values
    -- back, printed "config reloaded", and never once picked up an edit to
    -- config.lua - which the file's own header tells the user it does.
    local loaded, load_err, fresh = configuration.load(DIR, SCRIPT_DIR)
    if not loaded then
        log.error("user config unavailable: " .. tostring(load_err))
        return false
    end
    if fresh and store.state == "missing" then store.baseline = true end

    -- Whatever the player set in DarnMenu, on top of config.lua and before
    -- validate sees it, so a value from the menu is checked by exactly the
    -- same rules as a value typed into the file. Absent DarnMenu, or absent a
    -- saved file, this changes nothing.
    pcall(function() darnmenu.apply(loaded) end)
    local valid_cfg, cfg_error = configuration.validate(loaded)
    if not valid_cfg then
        log.error("configuration rejected; previous settings retained: " .. tostring(cfg_error))
        return false
    end
    cfg = validate(loaded)
    caps.configure(cfg)
    log.set_level(cfg.log_level)

    -- Written on every load, so an edit to the schema reaches the menu without
    -- anyone remembering to do it by hand. Idempotent: it only writes when the
    -- bytes differ.
    pcall(function() darnmenu.register() end)
    return true
end

-- ---------------------------------------------------------------------------
-- Passes
-- ---------------------------------------------------------------------------

-- explicit marks a pass asked for by hand. Those always report something,
-- even when there was nothing to do: a keypress with no output at all is
-- indistinguishable from a mod that failed to load.
-- Handed to ExecuteInGameThread by name, never as a fresh closure.
--
-- UE4SS keeps a Lua registry reference to anything scheduled, and a new
-- anonymous function every cycle means a new reference every cycle. On
-- 21 August at 21:12:58 it gave up on one of them: "Ref was not function,
-- removing hook", and the engine tick went with it. The same reference going
-- bad without being noticed is the likelier reading of the access violations,
-- which is why the crash site kept moving between unrelated loops.
--
-- One function that lives as long as the mod cannot be collected, so there is
-- nothing to go stale. The reason and the explicit flag ride on upvalues
-- because the callback takes no arguments; they are only used for the log
-- line, so a second pass overwriting a first is a wrong word, not a wrong
-- decision.
local pass_reason, pass_explicit
local pass_queued = false

local function pass_body()
    local ok, err = pcall(function()
        local stats = scheduler.run_pass(cfg)
        if stats.camps > 0 then
            log.info(pass_reason .. ": " .. scheduler.format_stats(cfg, stats))
        elseif pass_explicit and stats.blocked_reason then
            -- The cause the pass actually hit, rather than a guess at it.
            --
            -- Every silent-abort path returns before stats.camps is
            -- incremented, so a manual run fell through to the camp-streaming
            -- advice below whatever the real reason was. That is right for one
            -- of the seven ways a pass can stop and wrong for the rest.
            log.say(pass_reason .. ": " .. stats.blocked_reason)
        elseif pass_explicit then
            log.say(pass_reason .. ": no loaded camp was available")
        end
        return stats
    end)
    pass_queued = false

    if not ok then
        log.error("pass failed: " .. tostring(err))
        return nil
    end
    return err
end

-- Defined further down, needed here.
--
-- Switching the mod off has to give the pals back, and the only place that
-- reliably notices "off" is the pass gate below: a config edit, a DarnMenu
-- save and a fresh launch all arrive as cfg.enabled being false with nothing
-- calling COMMANDS.off.
local restore_all

-- One give-back per disabled session, so the sweep is not re-run every
-- interval once it has nothing left to do.
local restored_for_disabled = false

local function run_pass(reason, explicit)
    if require('settings_gate').blocked() then
        if explicit then
            log.say(require('settings_gate').status()=='restart_required'
                and 'pass refused: settings locked; restart the game'
                or 'pass refused: settings recovery is in progress')
        end
        return
    end
    if not cfg or not store.decided or store.is_client then return end
    if store.state == "error" or caps.state == "error" then
        if explicit then log.say("pass refused: settings are unavailable or awaiting a successful save") end
        return
    end

    -- Only the machine running the world decides anything. A client can see
    -- the base and could technically send work suitability changes, but two
    -- machines fencing the same pals would fight every pass, and the client
    -- cannot see the work pulses that make the decision good.
    if not api.has_authority() then
        if explicit then
            log.say(reason .. ": this is a client, the server decides " ..
                "assignments. Your rules are sent to it.")
        end
        return
    end

    if not cfg.enabled then
        if explicit then
            log.say(reason .. ": disabled. Use '" .. cfg.chat_prefix .. " on' to enable")
        end

        -- Off means give the pals back, not just stop touching them.
        --
        -- COMMANDS.off already does this and its comment explains why it must:
        -- the fences are the game's own saved data, so they outlive the mod,
        -- and a save left fenced has twelve of thirteen work suitabilities
        -- unchecked on every base pal with no way back but the stand, by hand.
        --
        -- That fix only ever covered the chat command. Every other way of
        -- switching the mod off - editing config.lua, unticking "Assign Pals
        -- to jobs" in DarnMenu, '!pwp reload' - lands here instead, and here
        -- only stopped. So the documented promise, "false leaves the game
        -- completely untouched", was the one route that did not keep it.
        --
        -- This also covers the case a transition check would miss: disabled
        -- BEFORE the game started, which is exactly what a player does after
        -- deciding to turn the mod off. There is no edge to detect in that
        -- session, only leftover fences. The sweep is idempotent, so when
        -- there is nothing fenced it sends nothing.
        if not restored_for_disabled then
            restored_for_disabled = true
            log.say("disabled, so giving every pal its work back")
            restore_all("disabled")
        end
        return
    end

    -- Armed again, so a later switch-off sweeps again.
    restored_for_disabled = false

    -- One pass at a time.
    --
    -- Nothing stopped a second pass being queued while the first was still
    -- running, and a pass sweeping chests takes longer than the interval the
    -- stress drives it at, so they stacked up. Overlapping passes are wrong on
    -- their own terms as well: two of them read the same camp and both decide
    -- what to fence, which is how a pal could be assigned twice in a tick.
    --
    -- Re-entrancy only, now that passes run synchronously on the clock: a
    -- pass cannot currently overlap itself, and this costs nothing to keep
    -- against the day one is deferred again. It was written while the crash
    -- was still unexplained and the comment claimed to be testing for it,
    -- which it never was.
    if pass_queued then
        if explicit then
            log.say(reason .. ": a pass is already running")
        end
        return
    end
    pass_queued = true

    pass_reason, pass_explicit = reason, explicit

    -- Called directly: every caller is already on the game thread.
    --
    -- The clock drives the tick there, remote commands run inside the
    -- clock's ui entry, and the chat hook is a game-thread callback. The
    -- ExecuteInGameThread that used to sit here was one more registry
    -- registration per pass, which is the currency the crash is paid in,
    -- bought to move to a thread we are already on.
    return pass_body()
end

-- Both loops are clock entries now. The comment that used to be here said
-- LoopAsync registers once and is therefore safe; UE4SS's own maintainers
-- deprecated it as never having been thread safe at all (PR #1128), and the
-- stress reproducer agreed, dropping the engine tick within 25 executed
-- passes whatever shape the callbacks took. The full story is in
-- docs/research-ue4ss-crash.md; the machinery is in clock.lua.
-- Registers or re-registers the pass entry. clock.every replaces by name, so
-- calling this again is how a changed interval takes effect.
local function arm_pass_timer()
    clock.every("pass", cfg.interval_seconds * 1000, function()
        run_pass("tick")
    end, true)
    clock.every("stock refresh check", 1000, function()
        if scheduler.stock_refresh_due(cfg) then
            clock.defer("storage refresh", session.guard(function() scheduler.refresh_stock(cfg) end))
        end
    end)
end

local function start_timer()
    if timer_running then return end
    timer_running = true
    arm_pass_timer()
    clock.start()
end

-- The grid needs its own cadence: the stand can be opened at any moment and
-- numbers that appear a pass later read as broken. This only looks for the
-- menu, and finds nothing while the stand is shut.
local ui_running = false

-- Milliseconds of grid time owed, so the stand grid keeps its slow cadence
-- while the panel runs fast.
local grid_owed = 0

-- The same rule as pass_body, and this one mattered more: it was scheduled
-- once a second for the whole session, so it minted a registry reference every
-- second the game was open.
-- The last panel error reported, so a throw that repeats ten times a second
-- is logged once rather than a hundred times.
local last_panel_error = nil
local last_grid_error = nil
local last_tick_error = nil


local function panel_body()
    if not cfg or not api.has_viewport() then return end
    -- Drawn independently: the panel opens on a hotkey and has to keep
    -- working with the stand shut.
    -- The message is kept, not thrown away.
    --
    -- A bare pcall here meant a panel that threw simply stopped drawing, with
    -- nothing anywhere to say why - which is exactly how a use-before-local in
    -- panel.lua hid for a whole session. Rate limited to one line per distinct
    -- error, because this runs ten times a second and a repeating throw would
    -- otherwise write a hundred lines a second into priority.log.
    local ok, err = pcall(function() panel.refresh(cfg) end)
    if not ok then
        err = tostring(err)
        if err ~= last_panel_error then
            last_panel_error = err
            log.warn("the panel stopped drawing: " .. err)
        end
    elseif last_panel_error ~= nil then
        last_panel_error = nil
        log.say("the panel is drawing again")
    end

end

local function ui_body_flushed(flush_receipt)
    -- Include attached persistence polling, not just disk writes. These calls
    -- precede panel.refresh's own timer and may perform fresh authority proofs.
    -- Inclusive, opt-in timings: do not add them to the enclosing maintenance.
    log.around("persistence: limits maintenance", caps.flush)
    pcall(remote.poll)
    pcall(remote.drain)
    if not api.has_viewport() then return end
    -- Input paints affected cells on the fast beat. Maintenance refreshes the
    -- complete current scoped roster once a second. With the rules panel open,
    -- a pending repaint may use its faster maintenance beat.
    local pushed = (ui.wants_repaint ~= nil) and ui.wants_repaint() or false

    if grid_owed >= 1000 or pushed then
        -- Retain elapsed remainder after a budget-delayed maintenance job.
        -- Resetting to zero here could skip the next whole maintenance second.
        grid_owed = grid_owed >= 1000 and grid_owed % 1000 or 0
        -- The message is kept, as panel.refresh's is a few lines below.
        --
        -- This was a bare pcall, so a grid that threw simply stopped updating
        -- with nothing anywhere to say why - which is exactly how a
        -- use-before-local in panel.lua hid for a session, and the panel got
        -- this treatment for it while the grid did not. Rate limited to one
        -- line per distinct error, because this runs on a beat.
        local ok_grid, err_grid = pcall(function() ui.refresh(cfg,flush_receipt) end)
        if not ok_grid then
            err_grid = tostring(err_grid)
            if err_grid ~= last_grid_error then
                last_grid_error = err_grid
                log.warn("the stand grid stopped drawing: " .. err_grid)
            end
        elseif last_grid_error ~= nil then
            last_grid_error = nil
            log.say("the stand grid is drawing again")
        end
    end

    -- Keep two complete native redraws out of one background callback.
    -- Reacquire the current panel in its own session-bound heartbeat.
    clock.defer("panel render", session.guard(panel_body))

    -- Instructions from outside, read and acted on here rather than on a
    -- timer of their own, so one can never land between two halves of a draw.
    -- Both are already on the game thread.

end

local function ui_body()
    -- Only prepare a snapshot when the ordinary stand refresh is due. A
    -- repaint requested later in this callback safely keeps its own flush.
    if grid_owed<1000 then
        log.around("persistence: priorities maintenance",store.flush)
        return ui_body_flushed()
    end
    local epoch=session.epoch
    return store.with_flush_receipt(function()
        return log.around("persistence: priorities maintenance",store.flush)
    end,function(receipt)
        return ui_body_flushed(function()return session.epoch==epoch and receipt()end)
    end)
end

-- LoopAsync takes one interval for the life of the loop, so the cadence that
-- used to live in the delay argument lives here instead. The loop beats at the
-- fast rate and the body is gated: ten times a second with the panel up, once
-- a second with it shut.
--
-- A menu that answers once a second is not a menu. The panel redrew on the one
-- second tick, so a hover highlight took up to a second to follow the pointer,
-- which is what "laggy and unresponsive" was: not the cost of a frame, the
-- wait between frames. It also let the mouse and the keyboard disagree about
-- the current row long enough for two of them to be marked at once.
-- Back to one number, because the split was measured and did not work.
--
-- UI_BEAT was cut to 33 with a redraw-on-hover-change gate, on the theory
-- that a faster tick would move the highlight sooner. Two things were wrong
-- with it. clock.lua beats at 100ms, so a 33ms entry still fired every
-- 100ms - the number was a wish. And the gate meant a hover change forced a
-- FULL redraw, so sweeping the pointer across five rows paid five 30-50ms
-- draws it never paid before. Hover now lives on its own persistent 16ms
-- game-thread loop (see start_ui), which moves the highlight with two brush
-- writes and never draws.
local UI_BEAT = 100
local body_owed = 0

local function ui_tick()
    grid_owed = grid_owed + UI_BEAT
    body_owed = body_owed + UI_BEAT
    if not cfg then return end

    -- Input belongs to the 100ms game-thread beat, even with the rules panel
    -- closed. Drain a FIFO snapshot; actions added while draining wait for the
    -- next beat, and session/UI guards still run before each action.
    if session.has_pending() then
        log.around("input: queued actions", session.drain, function(err)
            log.warn("queued input failed: " .. tostring(err))
        end, 8)
    end

    -- The client's 100ms edit-coalescing deadline must not wait for another
    -- maintenance second. This plain role gate adds no server/unknown-role
    -- network or viewport lookup. Transport keeps its own retry deadlines.
    if store.decided and store.is_client == true and net.poll then net.poll() end

    -- Keep ordinary stand redraw and maintenance at their existing cadence.
    -- A queued panel-open action can make panel maintenance due on this beat.
    local want = panel.open and UI_BEAT or 1000
    if body_owed >= want then
        body_owed = 0
        -- Queue plain-data work for another heartbeat. The clock admits only
        -- one expensive job, preventing a stand refresh and periodic pass
        -- from forming the measured 70ms batch. No widget survives this call.
        clock.defer("maintenance", session.guard(ui_body))
    end

    -- One reconciliation for all edits in this batch. Clear before running:
    -- a request raised during the pass must remain for the next beat. The
    -- independent periodic pass is intentionally not deduplicated here.
    if (panel.wants_pass or ui.wants_pass) and not session.has_pending() then
        clock.defer("reconcile", session.guard(function()
            if session.has_pending() then return end -- the burst still has accepted edits to apply
            local rule_change, priority_change = panel.wants_pass, ui.wants_pass
            if rule_change or priority_change then
                panel.wants_pass, ui.wants_pass = false, false
                run_pass(rule_change and "rule change" or "edit")
            end
        end))
    end
end

local function start_ui()
    if ui_running then return end
    ui_running = true
    clock.every("ui", UI_BEAT, ui_tick)
    clock.start()

    -- The pointer's own loop: one persistent registration, 16ms, game
    -- thread. This is the other half of the hover fix - the highlight moves
    -- at frame rate through panel.hover_tick, which retints two rows and
    -- draws nothing. The body above keeps redrawing on its 100ms deadline
    -- for data changes, exactly as before.
    --
    -- LoopInGameThreadWithDelay registers once and fires forever: no per-arm
    -- registry churn, which is the corruption vector ShinyPals' pump.lua
    -- dissects (upstream #1180) and the reason no per-beat primitive is used
    -- here. Verified present in this UE4SS.dll by binary scan. Absent the
    -- API, hover simply rides the 100ms body as it always did.
    --
    -- panel is an upvalue reload.rewire reassigns, so this closure follows
    -- hot reloads; hover_tick is guarded because panel hot-swaps and a
    -- session can briefly run an older panel without it.
    if type(LoopInGameThreadWithDelay) == "function" then
        local ok = pcall(function()
            LoopInGameThreadWithDelay(16, function()
                -- Both stand and panel use fresh local-controller reads within
                -- this callback. Always release the scope, including failures.
                api.pc_memo_begin()
                local ok_fast, err_fast=pcall(function()
                if not panel.open and ui.is_open() then
                    local ok_input, err_input=pcall(ui.pad_tick,cfg)
                    if not ok_input then log.warn("stand controller input: "..tostring(err_input)) end
                end
                if panel.open and api.has_viewport() and panel.hover_tick then
                    -- The message is kept. A throw here kills the gamepad and hover entirely,
    -- and this is three discards deep otherwise - panel wraps its own body,
    -- pad wraps its handlers, and this wrapped the lot.
    local ok_hover, err_hover = pcall(panel.hover_tick)
    if not ok_hover then
        err_hover = tostring(err_hover)
        if err_hover ~= last_tick_error then
            last_tick_error = err_hover
            log.warn("the panel's hover and pad tick stopped: " .. err_hover)
        end
    end
                end
                -- A page being shown for the first time draws eight
                -- milliseconds of tiles per frame and asks to be called back
                -- until it is done. Guarded like hover_tick and for the same
                -- reason: panel hot swaps, and a session can briefly run an
                -- older one without this.
                if panel.open and panel.fill_tick then
                    -- Same, and this is the one refresh path that reported nothing. A throw
    -- mid-fill leaves RB.pending true and repeats at 16ms for ever, so the
    -- picker sits half drawn with no error anywhere.
    local ok_fill, err_fill = pcall(panel.fill_tick)
    if not ok_fill then
        err_fill = tostring(err_fill)
        if err_fill ~= last_tick_error then
            last_tick_error = err_fill
            log.warn("the panel's fill tick stopped: " .. err_fill)
        end
    end
                end
                end)
                api.pc_memo_end()
                if not ok_fast then log.warn("fast UI callback failed: "..tostring(err_fast)) end
            end)
        end)
        log.say(ok and "hover: 16ms game-thread loop"
            or "hover: loop registration failed, riding the body beat")
    end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local COMMANDS = {}

-- Kept in step with the README's table deliberately: an audit found four
-- commands documented in neither, and two documented with the wrong meaning.
COMMANDS.help = function()
    local p = cfg.chat_prefix
    log.say("commands:")
    log.say("  " .. p .. " status    what the mod thinks is going on")
    log.say("  " .. p .. " run       run one pass now")
    log.say("  " .. p .. " dry       switch to log-only")
    log.say("  " .. p .. " live      actually assign pals")
    log.say("  " .. p .. " on / off  enable or disable")
    log.say("  " .. p .. " reload    re-read config.lua")
    log.say("  " .. p .. " mode      spread <-> fill")
    log.say("  " .. p .. " cap       how many pals may share one work type")
    log.say("  " .. p .. " stock     print base storage by item id")
    log.say("  " .. p .. " limit     how much of an item a base stockpiles")
    log.say("  " .. p .. " scope     ceilings per base, or across loaded bases")
    log.say("  " .. p .. " net       transport state, and echo test")
    log.say("  " .. p .. " discover  write Discovery.txt")
    log.say("  " .. p .. " guilds    write Guilds.txt")
    log.say("  " .. p .. " assignments  read-only authority assignment census")
    log.say("  " .. p .. " icons     probe the overlay icons")
    log.say("  " .. p .. " perf      hook counts and file writes " ..
            "(perf on for ms)")
    log.say("  " .. p .. " stand     write the Monitoring Stand's widget " ..
            "tree to StandTree.txt")
    log.say("  " .. p .. " funcs     write a class's callable functions to " ..
            "Functions.txt")
    log.say("  " .. p .. " probe     targeted reads for the elimination " ..
            "routes")
    log.say("  " .. p .. " adopt     make limits from before guild rules " ..
            "this guild's")
    log.say("  " .. p .. " restore   give every pal its work back, unfence")
    log.say("keys, all on Alt, because Ctrl is crouch:")
    log.say("  Alt+F1 Production Limits Alt+F2 run a pass")
    log.say("  Alt+F3 base storage      Alt+F5 Discovery.txt")
    log.say("  Alt+F9 transport test")
    log.say("keys that change a setting:")
    log.say("  Alt+F10 mode   Alt+F11 pals per work   Alt+F12 storage scope")
    log.say("in the panel: up and down move, right and left change the " ..
        "ceiling, Esc or Alt+F1 closes it")
end

COMMANDS.status = function()
    local beat_age = os.clock() - (clock.last_beat or 0)
    log.say(string.format("  heartbeat: %s (%.1fs since last beat)",
        beat_age < 1.0 and "alive" or "STALLED", beat_age))
    log.say(string.format("%s %s | local configuration: %s | %s | every %ds",
        MOD_NAME, VERSION,
        cfg.enabled and "enabled" or "disabled",
        cfg.dry_run and "dry run" or "live",
        cfg.interval_seconds))

    local camps = api.base_camps()
    log.say(string.format("  %d camp(s) loaded", #camps))

    local probe = api._suitability_source
    log.say("  work type read from: " ..
        (probe and (probe.kind .. " " .. probe.name) or "not resolved yet"))
    log.say("  enum offset: " .. workdefs.enum_offset)
    log.say("  demand hook: " .. (demandidx.hooked and "installed" or "NOT INSTALLED") ..
        ", " .. demandidx.pulses .. " pulse(s) seen" ..
        (demandidx.live() and demandidx.pulses == 0
            and "  (nothing wants doing, which is normal while pals sleep)" or ""))
    log.say("  transport: " .. (net.installed and "hooked" or "NOT HOOKED") ..
        ", echo " .. net.stats.echo_returned .. "/" .. net.stats.echo_sent ..
        " returned")
    local authority = api.has_authority()
    log.say("  authority: " .. (authority == nil and "unknown; writes paused"
        or (authority and "yes, this machine runs the world" or "client; server owns assignments")))
    log.say("  priorities: " .. tostring(store.state) .. (store.error and ("; " .. store.error) or ""))
    log.say("  limits: " .. tostring(caps.state) .. (caps.error and ("; " .. caps.error) or ""))
    -- net.status describes a client's upstream connection, not host readiness.
    local synchronization = "unknown; session role not established"
    if store.decided == true and caps.decided == true and caps.session == session.epoch then
        if authority == true and store.is_client == false and caps.is_client == false then
            synchronization = "not required; local authority"
        elseif authority == false and store.is_client == true and caps.is_client == true then
            synchronization = "client; " .. tostring(
                net.epoch == session.epoch and net.status or "unknown")
        end
    end
    log.say("  synchronization: " .. synchronization)

    if authority == true then
        log.say("  mode: " .. tostring(cfg.assignment_mode) .. ", max per work type: " ..
            (cfg.max_pals_per_work_type and tostring(cfg.max_pals_per_work_type) or "no limit"))
        log.say("  ceilings measured against: " ..
            (cfg.storage_scope == "global" and "every loaded base" or "each base on its own"))
    elseif authority == false then
        -- Client config is local, not a confirmed copy of server scheduling policy.
        log.say("  staffing mode and worker maximum: server controlled; not synchronized")
        log.say("  storage scope: see the confirmed scope in Production Limits")
    else
        log.say("  staffing policy and storage scope: unavailable until authority is established")
    end
    local scan = api.last_storage_scan
    if scan then
        log.say(string.format("  last storage scan (%s; cached diagnostic): complete=%s deduplicated=%s unknown_scope=%d failed_reads=%d",
            scan.reader, tostring(scan.complete), tostring(scan.deduplicated), scan.unknown_scope, scan.failed_reads))
        local reasons = {}
        for reason, count in pairs(scan.reasons) do reasons[#reasons + 1] = reason .. "=" .. count end
        table.sort(reasons)
        log.say("  storage read failures: " .. (#reasons > 0 and table.concat(reasons, ", ") or "none recorded"))
        log.say("  world loot outside bases (last scan): " .. tostring(scan.outside_camp_loot or 0))
        if scan.class_reads ~= nil then
            log.say("  storage class lookups (last scan): " .. tostring(scan.class_reads) ..
                " read, " .. tostring(scan.class_skips or 0) .. " unnecessary reads skipped")
        end
    else
        log.say("  last storage scan: unavailable (no scan since context reset)")
    end
end

COMMANDS.run = function(args)
    args = args or ""
    if args:match("^%s*$") then return run_pass("manual", true) end
    local run, request, mode = args:match("^([%w%-]+)%s+(%d+)%s+(%a+)%s*$")
    request = math.tointeger(tonumber(request))
    if not run or #run > 64 or not request or request < 1 or request > 1000000
        or (mode ~= "normal" and mode ~= "sweep" and mode ~= "dry") then
        log.say("run requires: <run-id> <request-id> <normal|sweep|dry>")
        return false
    end
    local old_dry, old_ttl = cfg.dry_run, scheduler.stock_ttl
    local before_pass, before_session = scheduler.pass_id, session.epoch
    if mode == "dry" then cfg.dry_run = true end
    if mode == "sweep" then scheduler.stock_ttl = 0 end
    local actual_dry = cfg.dry_run == true
    local ok, stats = pcall(run_pass, "manual", true)
    cfg.dry_run, scheduler.stock_ttl = old_dry, old_ttl
    local invocation_complete = ok and type(stats) == "table" and stats.camps > 0
        and scheduler.pass_id > before_pass and session.epoch == before_session
        and stats.pals > 0 and not stats.blocked_reason and (stats.failed or 0) == 0
        and (stats.unreadable or 0) == 0 and (stats.baseline_unavailable or 0) == 0
    local status = "aborted"
    if invocation_complete then
        -- A returned pass may preserve permissions because assignment/storage
        -- evidence is missing, or leave requests/withdrawals unresolved. Neither
        -- qualifies as completed stress work. Unknown evidence takes precedence
        -- over unfinished work; zero requests alone is not a failure. Even a
        -- completed receipt is not proof of native gameplay effects, and dry=true
        -- continues to identify planning only.
        if (stats.assignment_unknown or 0) > 0 or (stats.manual_unavailable or 0) > 0
            or (stats.unverified_limit_conflicts or 0) > 0 or (stats.storage_unverified or 0) > 0 then
            status = "unverified"
        elseif (stats.deferred or 0) > 0 or (stats.pending_writes or 0) > 0
            or (stats.expired_writes or 0) > 0 or (stats.awaiting_withdrawal or 0) > 0 then
            status = "incomplete"
        else
            status = "completed"
        end
    end
    log.say(string.format("PWP_PASS run=%s request=%d pass=%d session=%d status=%s mode=%s camps=%d dry=%s pending=%d invocation=%s",
        run,request,scheduler.pass_id,session.epoch,status,mode,
        (ok and type(stats)=="table") and stats.camps or 0,tostring(actual_dry),
        (ok and type(stats)=="table") and (stats.pending_writes or 0) or 0,
        invocation_complete and "completed" or "aborted"))
    return status == "completed"
end

-- How long a chest count is kept. Zero sweeps on every pass.
--
-- Here so the sweep can be driven hard while it is under suspicion. It crashed
-- once in twenty seven minutes at thirty seconds, which is not a rate anything
-- can be tested at, and the guard that is meant to have fixed it wants
-- thousands of sweeps against a chest pals are filling, not a dozen.
COMMANDS.sweep = function(args)
    local n = tonumber((args or ""):match("^%s*(%d+)"))
    if n == nil then
        log.say("stock sweep interval: " .. tostring(scheduler.stock_ttl) ..
            "s. Use '" .. cfg.chat_prefix .. " sweep <seconds>', 0 for every pass")
        return
    end
    scheduler.stock_ttl = n
    scheduler.forget_stock()
    log.say("stock sweep interval now " .. n .. "s" ..
        (n == 0 and " (every pass)" or ""))
end

-- Both toggles forget the assignment memo. Changing how pals are spread
-- makes every remembered placement stale, and without the reset the next
-- pass would skip re-issuing the ones that happen to match.
COMMANDS.mode = function()
    cfg.assignment_mode = (cfg.assignment_mode == "fill") and "spread" or "fill"
    scheduler.forget_policy()
    log.say("assignment mode: " .. cfg.assignment_mode ..
        (cfg.assignment_mode == "spread"
            and " (one pal each, then seconds)"
            or " (priority 1 takes everyone it can)"))
    run_pass("mode change", true)
end

-- off -> 1 -> 2 -> 3 -> 4 -> off
-- Takes nothing, and says so rather than ignoring what it was given.
--
-- This cycles how many pals may share one work type. The other feature - a
-- ceiling on how much of an item a base stockpiles - is "!pwp limit", but it
-- is called caps everywhere else in the mod: caps.lua, caps.txt, work_caps in
-- config.lua. So "!pwp cap Lumbering Wood 5000" is a reasonable thing for
-- somebody to type after reading any of those, and it used to discard all
-- three arguments, silently cycle a completely different setting, and re-fence
-- every base in the guild. The only sign was a log line nobody is watching.
--
-- Renaming the ceiling feature to match the command is the real fix and is a
-- bigger change than this - caps.txt has to be read under both names for a
-- release or two. Refusing to guess is the part worth having now.
COMMANDS.cap = function(args)
    if type(args) == "string" and args:match("%S") then
        log.say("'" .. cfg.chat_prefix .. " cap' takes no arguments: it " ..
            "cycles how many pals may share one work type, and it is " ..
            "currently " .. tostring(cfg.max_pals_per_work_type or "no limit"))
        log.say("to cap how much of an item a base stockpiles, that is '" ..
            cfg.chat_prefix .. " limit " .. args .. "'")
        return
    end

    local current = tonumber(cfg.max_pals_per_work_type)
    local next_cap
    if current == nil then
        next_cap = 1
    elseif current >= 4 then
        next_cap = false
    else
        next_cap = current + 1
    end

    cfg.max_pals_per_work_type = next_cap
    scheduler.forget_policy()
    log.say("max pals per work type: " ..
        (next_cap and tostring(next_cap) or "no limit"))
    run_pass("cap change", true)
end

-- Phase 0 of the multiplayer plan. Everything networked depends on these two
-- RPCs actually crossing, so there is a command that does nothing but find
-- out, and it reports rather than assuming.
COMMANDS.net = function()
    net.report()
    net.selftest()
end

COMMANDS.scope = function()
    cfg.storage_scope = (cfg.storage_scope == "global") and "camp" or "global"
    log.say("ceilings measured against: " ..
        (cfg.storage_scope == "global"
            and "every loaded base together"
            or "each base on its own"))
    log.say("a base you are away from is not loaded and cannot be counted either way")
    run_pass("scope change", true)
end

-- The breadcrumb costs a file write per mark inside the pass, which is the
-- mitigation issue #1372 landed on removing. Off by default; a hunt turns it
-- on for exactly as long as it is needed.
COMMANDS.trace = function(args)
    local want = (args or ""):match("^%s*(%S*)")
    if want == "on" then
        trace.on = true
        log.say("trace marks on, " .. tostring(trace.path))
    elseif want == "off" then
        trace.on = false
        log.say("trace marks off")
    else
        log.say("trace marks are " .. (trace.on and "on" or "off") ..
            ". Use '" .. cfg.chat_prefix .. " trace on|off'")
    end
end

-- Counters for the per-event hooks and the file writes.
--
-- Deliberately not in SAFE_FROM_CHAT: it is a diagnostic, and the same
-- reasoning that keeps trace off a channel a stranger can type into applies.
--
-- Counting is always on because an increment is nearly free and FREQUENCY is
-- the actual unknown - a hook on PalNetworkBaseCampComponent fires for every
-- base camp RPC in the game, and nothing has ever counted them. Timing costs
-- two os.clock() calls per fire and is therefore opt in: measuring the hot
-- path must not be the thing that makes the hot path slow.
COMMANDS.perf = function(args)
    local want = (args or ""):match("^%s*(%S*)")
    if want == "on" then
        log.set_perf(true)
        log.reset_marks()
        log.say("perf: timing on, counters reset")
    elseif want == "off" then
        log.set_perf(false)
        log.say("perf: timing off; a new counts-only window started")
    elseif want == "reset" then
        log.reset_marks()
        log.say("perf: counters reset")
    else log.say(log.report()) end
end

-- Was Ctrl+F7 until Ctrl turned out to roll the character on every press. It
-- is a diagnostic for a panel drawing bug that is long fixed, so it lost the
-- argument for one of the eight free Alt slots and became a command instead.
COMMANDS.icons = function()
    -- A chat line is rare, so riding the next clock beat (at most 100 ms away)
    -- costs nothing perceptible and no registration at all.
    clock.once(0, function()
        pcall(function() overlay.icon_probe() end)
        pcall(function() icons.report() end)
    end)
    log.say("icon probe queued, look for the report in UE4SS.log")
end

-- Drives the panel's own click handler by name, so an interaction can be
-- tested without a person and a mouse. The panel owns the input mode while it
-- is open, which is exactly when its clicking most needs testing.
-- The one door into the panel's own test actions. Everything behind it lives
-- in panel.lua, which hot reloads, so adding a new one never costs a restart
-- again. This is the last panel command that should ever need adding here.
COMMANDS.panel = function(args)
    log.say(panel.command(cfg, args))
end

-- What the controller can and cannot see, asked rather than assumed.
--
-- "pwp pad" watches for a few seconds so things can be pressed while it runs.
-- "pwp pad probe" answers the narrower question of whether the reading works
-- at all, without needing anything held down.
COMMANDS.pad = function(args)
    args = (args or ""):match("^%s*(.-)%s*$")
    if args == "probe" then
        log.say(pad.probe())
        return
    end
    if args == "watch" or args == "" then
        log.say(pad.watch(true))
        return
    end
    if args == "watch off" or args == "off" then
        log.say(pad.watch(false))
        return
    end
    log.say("use: pad probe | pad watch | pad watch off")
end

-- Does the game answer when asked what an item is called?
--
-- Measured before it is wired into anything that draws. The picker renders 27
-- tiles a page, so per-name cost matters only if it is wild; what actually
-- decides the design is whether resolving all 2466 at load is a hitch or a
-- shrug, and that is what the timing below is for.
COMMANDS.names = function(args)
    local n = tonumber(args) or 14
    items.load()

    if not items.real_name then
        log.say("this build has no name resolver, restart to pick it up")
        return
    end

    local ids = items.ids or {}
    local t0 = os.clock()
    local shown = 0

    for i = 1, #ids do
        local id = ids[i]
        local real = items.real_name(id)
        if shown < n then
            shown = shown + 1
            log.say(string.format("  %-30s %s", id,
                real or "(no name, would fall back)"))
        end
    end

    local ms = (os.clock() - t0) * 1000
    log.say(string.format(
        "resolved %d, unnamed %d, of %d ids in %.0fms (%.2fms each)",
        items.resolved, items.unresolved, #ids, ms,
        #ids > 0 and (ms / #ids) or 0))
end

COMMANDS.click = function(args)
    local kind, rest = (args or ""):match("^%s*(%S+)%s*(.*)$")
    if kind == nil then
        log.say("use: " .. cfg.chat_prefix ..
            " click item <ItemId> | rule 1 | job 1 | drop 1 | tab add")
        return
    end
    rest = (rest ~= "" and rest) or nil
    log.say(panel.click_named(cfg, kind, rest, -1))
end

COMMANDS.clicks = function()
    panel.debug_clicks = not panel.debug_clicks
    log.say("click reporting " .. (panel.debug_clicks and "on" or "off"))
end

COMMANDS.dry = function()
    cfg.dry_run = true
    log.say("dry run on, changes are logged and nothing is sent")
end

COMMANDS.live = function()
    cfg.dry_run = false
    scheduler.forget_policy()
    log.say("live, changes are sent to the server")
end

COMMANDS.on = function()
    cfg.enabled = true
    start_timer()
    start_ui()
    log.say("enabled")
end

-- Hands every pal back everything it can do, and says so.
--
-- Looped, because one sweep is bounded to MAX_TOGGLES_PER_PASS and a real base
-- needs several. Bounded itself so a pal whose permissions cannot be read
-- cannot spin here for ever.
function restore_all(why)
    if not cfg then log.say(why .. ": configuration is unavailable"); return false end
    if api.latch_authority() ~= true then
        log.say(why .. ": authority is unavailable; restoration was not confirmed")
        return false
    end
    local sent, rounds, stats = 0, 0, nil
    repeat
        rounds = rounds + 1
        stats = scheduler.restore(cfg)
        sent = sent + (stats.toggles or 0)
        -- More synchronous requests cannot make an asynchronous RPC arrive.
        -- Keep the pending history for a later observation or explicit retry.
        if stats.blocked or (stats.failed or 0)>0 or (stats.unreadable or 0)>0
            or (stats.baseline_unavailable or 0)>0 or (stats.pending_writes or 0)>0
            or (stats.expired_writes or 0)>0 or (stats.awaiting_withdrawal or 0)>0 then break end
    until (stats.deferred or 0)==0 or rounds>=12
    local incomplete = stats.blocked or (stats.failed or 0)>0 or (stats.unreadable or 0)>0
        or (stats.baseline_unavailable or 0)>0 or (stats.pending_writes or 0)>0
        or (stats.expired_writes or 0)>0 or (stats.awaiting_withdrawal or 0)>0
        or (stats.deferred or 0)>0 or (stats.camps or 0)==0 or (stats.pals or 0)==0
    if incomplete then
        log.warn(string.format("%s: restoration UNCONFIRMED (%d requests, %d sweeps): %s. Keep the mod installed until readback is confirmed.",
            why,sent,rounds,stats.blocked_reason or scheduler.format_stats(cfg,stats)))
        return false
    end
    log.say(string.format("%s: allowed work permissions verified after %d request(s) over %d sweep(s); X choices remain disabled",
        why,sent,rounds))
    return true
end

-- Switching off now actually switches off.
--
-- It used to set a flag and stop there: run_pass returned early and every pal
-- stayed fenced exactly as the last pass left it, for ever. The fences are the
-- game's own saved data, so they outlive the mod - deleting it left a save
-- with twelve of thirteen work suitabilities unchecked on every base pal and
-- no way back but the stand, by hand, one checkbox at a time.
COMMANDS.off = function()
    cfg.enabled = false
    log.say("disabled")
    restore_all("disabled")
end

-- The same thing on demand, for a save that has been left fenced by a crash,
-- a config error, or an uninstall that is about to happen.
-- The wildcard upgrade, on purpose rather than by accident.
--
-- This used to run itself inside the pass. It cannot be done safely there:
-- the test it depends on can only see camps that are streamed in, so on a
-- server where one guild happened to be online it moved every shared limit to
-- that guild, deleted the wildcard, and saved - with no way back and nothing
-- said to the guild that lost them. Doing it from a command does not make the
-- guess any better informed; it makes it somebody's decision, which is the
-- part that was actually missing.
COMMANDS.adopt = function()
    if not api.has_authority() then
        log.say("only the machine that owns the world can do this. Run it " ..
            "on the server.")
        return
    end

    local sole = scheduler.adoptable
    if sole == nil then
        log.say("not now: either no base camp is loaded yet, one of them " ..
            "will not say which guild it belongs to, or the loaded camps " ..
            "belong to more than one guild. Stand in your base and try again.")
        return
    end

    local moved = caps.adopt_wildcard(sole)
    if moved == 0 then
        log.say("there was nothing left from before guild rules to adopt")
    end
end

COMMANDS.restore = function()
    restore_all("restore")
end

COMMANDS.reload = function()
    if load_config() then
        scheduler.forget_policy()
        -- Re-armed, or a changed interval_seconds does nothing at all:
        -- start_timer returns immediately once the timer is running, so the
        -- entry kept whatever interval it was first registered with while the
        -- command cheerfully reported the config reloaded.
        if timer_running then arm_pass_timer() end
        log.say("config reloaded")
        COMMANDS.status()
    end
end

-- Calls fn immediately. Stands where ExecuteInGameThread used to, in code
-- that is only ever reached on the game thread already: command handlers run
-- from the chat hook or from the clock's ui entry, both game-thread contexts.
-- Every removed registration is one fewer registry write, and registry writes
-- are the currency this mod's crash was paid in.
--
-- Declared ABOVE its first caller. It used to sit ten lines below
-- COMMANDS.discover, which made that one reference compile to a global read
-- instead of an upvalue, so "pwp discover" and Ctrl+F11 both died on "attempt
-- to call a nil value" - and Discovery.txt is what the README tells you to
-- run when a work type comes back unmapped.
local function run_now(fn) fn() end

COMMANDS.discover = function()
    run_now(function()
        discover.run(DIR .. "Discovery.txt")
    end)
end

-- The guild half of the reconnaissance, on its own.
--
-- Worth a second command rather than a flag on the first: the full dump reads
-- pals, which is authority only, and the guild answers are wanted precisely
-- where that is unsafe - on a client, where a rule set by one guild must not
-- reach another guild's base.
COMMANDS.guilds = function()
    run_now(function()
        discover.guilds(DIR .. "Guilds.txt")
    end)
end

-- Why the same work suitability toggles repeat every pass.
-- The Monitoring Stand's widget tree, written to a file. Exists to answer
-- what the perf counters cannot: WHY cells_under found nothing when the
-- stand was open ("ui: cells via tree" never moved, only the global-walk
-- fallback did). The suspect is a virtualized ListView whose row entries
-- are not children of the menu's own tree; the dump shows the tree as it
-- actually is, plus cells_under's answer against the global walk's count.
-- Needs the stand open on screen, and says so itself when it is not.
COMMANDS.stand = function(args)
    run_now(function()
        if args == 'input' then log.say(require('stand_event_probe').watch()); return end
        if args == 'events' then log.say(require('stand_event_probe').report()); return end
        local path = DIR .. "StandTree.txt"
        local f = io.open(path, "w")
        if not f then
            log.say("could not open " .. path .. " for writing")
            return
        end

        local ok, err = pcall(function() ui.dump(f) end)
        f:close()

        if ok then
            log.say("stand tree written to " .. path)
        else
            log.say("stand dump failed: " .. tostring(err))
        end
    end)
end

-- Every callable on a class, with typed parameters, to Functions.txt.
-- '!pwp funcs PalUtility' resolves /Script/Pal.PalUtility; a name with a
-- slash is taken as a full path. Exists so a call into the game's own
-- functions can be written against this build's real signatures instead of
-- folklore - the parameter list is the contract, and a guessed NameProperty
-- taking a bare string is the one mistake that kills the process outright.
COMMANDS.funcs = function(args)
    local want = (args or ""):match("^%s*(%S+)")
    if not want then
        log.say("usage: " .. cfg.chat_prefix .. " funcs <ClassName>")
        return
    end

    run_now(function()
        local path = DIR .. "Functions.txt"
        local ok, err = discover.functions(want, path)
        if ok then
            log.say("functions written to " .. path)
        else
            log.say("funcs: " .. tostring(err))
        end
    end)
end

-- Targeted reads for the 0.4.1 elimination routes, one screenful.
--
-- The alternative was full class dumps, and a full dump of PalUtility's
-- function parameters killed the process once already. Everything here is a
-- single property read or a verified-signature call under pcall, printing
-- what answered and what did not; nothing is stored, nothing is walked.
COMMANDS.lookup = function()
    log.say(require('widget_lookup').probe())
end

COMMANDS.prefetch = function(args)
    local want=(args or ""):match("^%s*(%S*)")
    if want=="on" or want=="off" then scheduler.set_prefetch(want=="on") end
    log.say("storage prefetch: " .. (scheduler.prefetch_enabled and "on" or "off") ..
        "; global scope only; use prefetch on|off for developer A/B testing")
end

COMMANDS.frameevents = function(args)
    local want=(args or ''):match('^%s*(%S*)')
    if want=='start' then
        log.start_frame_events()
        log.say('frame events: started; bounded 180s / 4096 events; minimum 4ms; inclusive')
    elseif want=='stop' or want=='export' then
        if want=='stop' then log.stop_frame_events() end
        local ok,reason=log.export_frame_events(DIR..'frame-events.tsv')
        log.say(ok and 'frame events: exported frame-events.tsv' or ('frame events: '..tostring(reason)))
    else log.say('usage: frameevents start|stop|export (developer capture only)') end
end

COMMANDS.frameanchor = function(args)
    local id=(args or ''):match('^%s*([%w_-]+)%s*$')
    local ok,reason=log.frame_anchor(DIR..'perf-anchor.txt',id)
    log.say(ok and ('frame anchor: '..id) or ('frame anchor failed: '..tostring(reason)))
end

COMMANDS.storageprobe = function()
    run_now(function()
        local storage_census = require('storage_probe')
        log.say(storage_census.format(storage_census.read()))
    end)
end

COMMANDS.assignments = function()
    run_now(function()
        local census = require('assignment_probe')
        log.say(census.format(census.read()))
    end)
end

COMMANDS.probe = function()
    run_now(function()
        log.say("probe: elimination-route reads")

        local pc = api.player_controller()
        if not api.valid(pc) then
            log.say("  no player controller, nothing to probe")
            return
        end

        local role
        pcall(function() role = api.as_int(pc.Role) end)
        log.say("  pc.Role = " .. tostring(role) ..
            "  (authority expects 3, owning client 2)")

        local kids, n
        pcall(function() kids = pc.Children end)
        pcall(function() n = #kids end)
        local tx_hit = "none found"
        if type(n) == "number" and n > 0 then
            pcall(function()
                for i = 1, n do
                    local fn
                    pcall(function() fn = kids[i]:GetFullName() end)
                    if type(fn) == "string"
                        and fn:find("PalNetworkTransmitter", 1, true) then
                        tx_hit = fn
                        break
                    end
                end
            end)
        end
        log.say("  pc.Children = " .. tostring(n) ..
            " entries, transmitter: " .. tx_hit)

        local world
        pcall(function() world = pc:GetWorld() end)
        local util = api.cdo("/Script/Pal.Default__PalUtility")

        local gm, gmname
        pcall(function() gm = util:GetPalGameMode(world) end)
        pcall(function() gmname = gm:GetFullName() end)
        log.say("  GetPalGameMode -> " .. tostring(gmname))

        local mgr, mgrname
        pcall(function() mgr = util:GetBaseCampManager(world) end)
        pcall(function() mgrname = mgr:GetFullName() end)
        log.say("  GetBaseCampManager -> " .. tostring(mgrname))

        -- The manager's property walk is GONE, and the reason is carved
        -- here so nobody rebuilds it. It ran once, listed every property
        -- through every real superclass, and answered the question for
        -- good: the manager exposes CONFIG ONLY - per-tribe maps, data
        -- tables, tick budgets, delegates - and no reflected container of
        -- live camp models exists. FindAllOf(PalBaseCampModel) is the
        -- honest camps route, full stop. Then the walk stepped past
        -- Object into a super that would not even name itself - printed
        -- as [?] - enumerated its properties, and KILLED THE PROCESS:
        -- GetSuperStruct hands back a live-looking wrapper where a nil
        -- belongs, the same TrivialObject hazard the codebase already
        -- records for property reads. The last log line named the killer,
        -- which is the one thing the design got right.

        local nd
        pcall(function() nd = world.NetDriver end)
        log.say("  World.NetDriver = " .. tostring(nd))
    end)
end

COMMANDS.worksuit = function()
    run_now(function()
        discover.worksuit(DIR .. "WorkSuit.txt")
    end)
end

-- Prints what the base is actually holding, by internal item id. Those ids
-- are what work_caps keys on, and guessing their spelling is the easiest way
-- to write a ceiling that silently never triggers.
COMMANDS.stock = function()
    run_now(function()
        local camps = api.base_camps()
        if #camps == 0 then
            log.say("no camps loaded. Stand in your base and try again")
            return
        end

        local path = DIR .. "Stock.txt"
        local f = io.open(path, "wb")
        if f then f:write("base storage " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n") end

        for ci, camp in ipairs(camps) do
            local totals, chests, evidence = api.camp_item_totals(
                api.guid_key(api.camp_id(camp)),
                { include = cfg.counted_containers,
                  exclude = cfg.uncounted_containers })

            local rows = {}
            for id, n in pairs(totals) do rows[#rows + 1] = { id = id, n = n } end
            table.sort(rows, function(a, b)
                if a.n ~= b.n then return a.n > b.n end
                return a.id < b.id
            end)

            local complete = evidence and evidence.complete == true and evidence.deduplicated == true
            local header = string.format("camp %d: %d container(s), %d item type(s); %s",
                ci, chests, #rows, complete and "complete for base-scoped stock" or "PARTIAL / stock unavailable")
            log.say(header)
            if f then f:write("\n" .. header .. "\n") end

            for i, row in ipairs(rows) do
                local line = string.format("  %-30s %d", row.id, row.n)
                if i <= 15 then log.say(line) end
                if f then f:write(line .. "\n") end
            end

            if #rows > 15 then
                log.say(string.format("  ... and %d more, full list in Stock.txt", #rows - 15))
            end
            if chests == 0 then
                log.say(complete and "  no counted storage in this base" or "  no verified storage total; ceilings remain undecided")
            end

            -- Report containers excluded by the user's class filters.
            -- Stations and feed boxes are included by default.
            local include = nil
            if type(cfg.counted_containers) == "table"
                and #cfg.counted_containers > 0 then
                include = {}
                for _, cls in ipairs(cfg.counted_containers) do include[cls] = true end
            end

            local excluded = {}
            for _, cls in ipairs(cfg.uncounted_containers or api.DEFAULT_UNCOUNTED) do
                excluded[cls] = true
            end

            local function is_counted(cls)
                if include then return include[cls] == true end
                return not excluded[cls]
            end

            local uncounted = {}
            for _, holder in ipairs(api.camp_containers(api.guid_key(api.camp_id(camp)))) do
                if not is_counted(holder.class) then
                    local entry = uncounted[holder.class]
                    if entry == nil then
                        entry = { objects = 0, items = {} }
                        uncounted[holder.class] = entry
                    end
                    entry.objects = entry.objects + 1
                    for id, n in pairs(holder.items) do
                        entry.items[id] = (entry.items[id] or 0) + n
                    end
                end
            end

            local classes = {}
            for cls in pairs(uncounted) do classes[#classes + 1] = cls end
            table.sort(classes)

            if #classes > 0 then
                local title = "  holding stock but NOT counted by ceilings:"
                log.say(title)
                if f then f:write(title .. "\n") end

                for _, cls in ipairs(classes) do
                    local entry = uncounted[cls]
                    local ids = {}
                    for id in pairs(entry.items) do ids[#ids + 1] = id end
                    table.sort(ids)

                    local parts = {}
                    for _, id in ipairs(ids) do
                        parts[#parts + 1] = id .. " " .. entry.items[id]
                    end

                    local line = string.format("    %s x%d: %s",
                        cls, entry.objects, table.concat(parts, ", "))
                    log.say(line)
                    if f then f:write(line .. "\n") end
                end
            end
        end

        if f then
            f:close()
            log.say("written to " .. path)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Stock limits
-- ---------------------------------------------------------------------------

local function split_words(text)
    local out = {}
    for word in tostring(text or ""):gmatch("%S+") do out[#out + 1] = word end
    return out
end

-- Accepts the internal name (Deforest) or the in-game label (Lumbering), in
-- any case, because the stand and the icons only ever show the label.
local function resolve_work(text)
    if type(text) ~= "string" or text == "" then return nil end

    for _, name in ipairs(workdefs.ORDER) do
        if name:lower() == text:lower() then return name end
    end
    return workdefs.from_label(text)
end

local function stock_across_camps()
    -- Reuse the same positively scoped evidence as the panel. Commands must
    -- not scan another guild's chests or present failed reads as zero stock.
    -- With camp scope the first known base is named explicitly in the output.
    local status = require("panel_status")
    local view = status.stock(cfg, scheduler, api.my_guild(), nil,
        api.has_authority() ~= true)
    return view.verified and view.totals or {}, view.verified, view.label
end

-- The id as the base actually spells it. Ceilings are compared against ids
-- read out of chests, so a lower case "wood" would never match "Wood" and
-- the limit would sit there looking set while doing nothing at all.
local function match_stock_id(totals, wanted)
    if totals[wanted] then return wanted end

    local lowered = wanted:lower()
    for id in pairs(totals) do
        if id:lower() == lowered then return id end
    end
    return nil
end

local function show_limits()
    local all = caps.all(cfg, api.my_guild())

    local works = {}
    for work in pairs(all) do works[#works + 1] = work end
    table.sort(works)

    if #works == 0 then
        log.say("no legacy group limits in the available view")
        log.say("new item-specific limits are unavailable until producer controls are verified")
        return
    end

    run_now(function()
        local totals, verified, scope = stock_across_camps()

        log.say("legacy group limits; " .. scope .. (verified and "" or " (stock unavailable)"))
        for _, work in ipairs(works) do
            local items = {}
            for item in pairs(all[work]) do items[#items + 1] = item end
            table.sort(items)

            for _, item in ipairs(items) do
                local ceiling = all[work][item]
                local have = verified and (totals[item] or 0) or nil
                log.say(string.format("  %-22s %-24s %s / %d%s",
                    workdefs.label(work), item, have and tostring(have) or "unavailable", ceiling,
                    have and have >= ceiling and "   threshold met" or ""))
            end
        end
        log.say("legacy groups can restrict the entire work type, including unrelated products; thresholds do not prove actual activity")
    end)
end

-- Ceilings, set from chat so they can be tried without a restart.
--
-- The verb is "limit" rather than "cap" because "cap" already means how many
-- pals may pile onto one work type.
COMMANDS.limit = function(args)
    local w = split_words(args)

    if #w == 0 then
        show_limits()
        return
    end

    if #w < 3 then
        log.say("usage: " .. cfg.chat_prefix .. " limit <work> <item> <amount>")
        log.say("       " .. cfg.chat_prefix .. " limit <work> <item> off")
        log.say("run " .. cfg.chat_prefix .. " stock for the item ids this base holds")
        return
    end

    -- Read from the end: item ids never contain spaces and neither do
    -- amounts, so whatever is left in front is the work name. That keeps two
    -- word labels like Oil Extraction working without any quoting.
    local amount_text = w[#w]
    local item_text = w[#w - 1]
    local work_text = table.concat(w, " ", 1, #w - 2)

    local work = resolve_work(work_text)
    if work == nil then
        log.say("no work type called " .. work_text)
        log.say("use the names on the stand, for example Lumbering or Mining")
        return
    end

    local lowered = amount_text:lower()
    local ceiling = amount_text:match("^%d+$") and math.tointeger(tonumber(amount_text)) or nil

    -- 0 removes the ceiling rather than being read literally. Taken at face
    -- value it would mean "you already have at least none of these", which
    -- suspends the work type for good, and priority X on the stand already
    -- says that far more clearly.
    local clearing = (lowered == "off" or lowered == "none"
        or lowered == "clear" or ceiling == 0)

    if not clearing and (ceiling == nil or ceiling < 1 or ceiling > caps.MAX_CEILING) then
        log.say("use a whole amount from 1 to " .. caps.MAX_CEILING .. ", or off/0 to remove; previous limit retained")
        return
    end

    run_now(function()
        local totals, verified, scope = stock_across_camps()
        local id = match_stock_id(totals, item_text) or item_text
        local written, outcome

        if clearing then
            written, outcome = caps.clear(work, id, api.my_guild())
        else
            written, outcome = caps.set(work, id, ceiling, api.my_guild())
        end
        if not written then
            if outcome == "pending" then
                log.say("limit change accepted; saving asynchronously: " .. workdefs.label(work)
                    .. " " .. id .. (clearing and " off" or " " .. ceiling))
            elseif outcome == "applied_unsaved" then
                log.say("legacy limit changed in memory but not saved; retry pending: " .. tostring(caps.error))
            else
                log.say("limit change unconfirmed: " .. tostring(caps.error or "session or rule unavailable"))
            end
            return
        end
        if caps.is_client then
            log.say("limit change queued; awaiting server confirmation")
            return
        end
        log.say("legacy group limit " .. (clearing and "removed and saved: " or "saved: ")
            .. workdefs.label(work) .. " " .. id .. (clearing and "" or " " .. ceiling))
        log.say(scope .. ": stock " .. (verified and tostring(totals[id] or 0) or "unavailable")
            .. "; this does not confirm actual production")
        scheduler.forget_policy()
        run_pass("limit change", true)
    end)
end

-- Commands that only READ. Everything else changes something.
--
-- Chat is not an admin channel. OnReceivedChat fires when the chat box
-- RECEIVES a message, and Palworld replicates chat to everyone, so any line a
-- stranger types runs on every modded machine that can see it. On a listen
-- host that is full authority - '!pwp adopt' moves every wildcard ceiling into
-- the host's guild and caps.lua says plainly that adopting cannot be undone.
-- On a dedicated server it is a confused deputy: the line runs on other
-- players' clients, and each one then submits a request under ITS OWN guild,
-- which satisfies every check on the network path because it genuinely did
-- come from a member of that guild.
--
-- The list is short on purpose. discover, worksuit and stock each do a full
-- object walk and a file write, and worksuit is not authority gated, so none
-- of them belongs on a channel a stranger can type into.
local SAFE_FROM_CHAT = {
    help = true, status = true, net = true,
}

-- Whether a chat line can be trusted to have come from this machine's player.
--
-- The FALLBACK, not the main answer. The sender check below decides first:
-- a chat message carries SenderPlayerUId, which is compared against this
-- machine's own player. This is what happens when that comparison cannot be
-- made at all - no controller yet, or a build whose PlayerState names its id
-- something my_player_uid does not try. Provably solo means the authority,
-- with no modded client registered and no second player controller, which is a
-- session where the only person who can type is the one at the keyboard.
--
-- Refusing is the right default while that is unknown. A refused command is an
-- annoyance; an accepted one from a stranger is someone else's base stopped.
-- Anyone else in the world at all, modded or not.
--
-- net.clients only ever holds MODDED clients - it is filled from the mod's own
-- message hook - so on a listen host with vanilla co-op partners it is empty,
-- and reading that as "solo" left the exact hole this gate was added to close:
-- another player types '!pwp adopt' in chat and it runs with full authority on
-- the host, and caps.lua says plainly that adopting cannot be undone.
--
-- Controllers are the honest count. One walk, and only when somebody types a
-- changing command, which is rare.
local function others_connected()
    local n = 0
    local ok = pcall(function()
        for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
            if api.valid(pc) then n = n + 1 end
        end
    end)

    -- Could not tell, so assume company. Refusing costs a command; guessing
    -- wrong the other way costs somebody their base.
    if not ok or n == 0 then return true end
    return n > 1
end

local function chat_is_trusted()
    if not api.has_authority() then return false end
    if next(net.clients) ~= nil then return false end
    return not others_connected()
end

local warned_chat_refusal = false

local function handle_command(text, from_chat, from_me)
    local prefix = cfg.chat_prefix
    if text:sub(1, #prefix):lower() ~= prefix:lower() then return false end

    local rest = text:sub(#prefix + 1):match("^%s*(.-)%s*$") or ""
    local verb = rest:match("^(%S+)") or "help"
    local args = rest:match("^%S+%s+(.*)$") or ""

    local key = verb:lower()

    local fn = COMMANDS[key]

    -- Only a real command is refused. Checked before the gate so a typo does
    -- not write a warn line per keystroke - and so an unknown verb still gets
    -- the ordinary "try !pwp help" reply rather than a lecture about chat.
    -- Refused only when this is somebody ELSE's chat line.
    --
    -- The probe answered what a chat message carries: Sender, a name, and
    -- SenderPlayerUId, a struct that guid_key reads. So the sender can be
    -- compared against this machine's own player, which is the check the gate
    -- always wanted and could not make. When it answers, it decides on its
    -- own - the player at this keyboard keeps every command in every session,
    -- and another player's line is refused even in a two-person game.
    --
    -- chat_is_trusted stays as the fallback for when the comparison cannot be
    -- made at all: no controller yet, or a build whose PlayerState names the
    -- id something this does not try.
    if fn and from_chat and not SAFE_FROM_CHAT[key]
        and not from_me and not chat_is_trusted() then
        -- Worded for what was actually established.
        --
        -- from_me is tri-state: true, false, or nil for "could not tell" -
        -- no controller yet, or a build whose PlayerState names its id
        -- something my_player_uid does not try. The old wording asserted the
        -- line came from someone else on all three, which points a person
        -- diagnosing a broken sender check away from the real cause.
        log.warn("refused '" .. key .. "' from chat: " ..
            (from_me == false
                and "it came from another player, and chat reaches everyone"
                or "could not tell whose line it was, and chat reaches " ..
                   "everyone"))
        if not warned_chat_refusal then
            warned_chat_refusal = true
            log.say("your own commands work from chat. This one could not " ..
                "be attributed to you, and chat reaches every player, so " ..
                "anything that changes something is refused. The server " ..
                "console and remote.txt always work.")
        end
        return true
    end

    if fn then
        local ok, err = pcall(fn, args)
        if not ok then log.error("command '" .. verb .. "' failed: " .. tostring(err)) end
    else
        log.say("unknown command '" .. verb .. "', try " .. prefix .. " help")
    end
    return true
end

-- panel and overlay are held here as locals, so a swap has to hand them back
-- or this file keeps calling the code that was just discarded. remote holds
-- one too and is not itself swapped, so it is told at the same time.
reload.scripts_dir = SCRIPT_DIR

reload.rewire = function()
    icons = require("icons")
    panel = require("panel")
    overlay = require("overlay")
    pcall(function() remote.rewire() end)
end

-- Reachable from outside the game, since singleplayer has no chat box to type
-- into. Takes the words after the prefix, so remote.txt carries "pwp off" and
-- this receives "off".
remote.command = function(words)
    handle_command(cfg.chat_prefix .. " " .. words)
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

if not load_config() then
    log.error(MOD_NAME .. " " .. VERSION .. " did not start")
    return
end

-- Installed at load, not on world entry: the pulses start as soon as a camp
-- exists, and a hook registered late misses every job already running.
demandidx.install()

-- Registered at load like the demand hook, and for the same reason: a hook
-- registered late misses everything that happened before it.
net.install()

-- ---------------------------------------------------------------------------
-- Which machine decides
-- ---------------------------------------------------------------------------
--
-- One mod, two roles, worked out at runtime rather than shipped as two
-- packages. Authority means this machine runs the world and owns the rules.
-- A screen means there is somebody here to show them to. Single player and a
-- listen server host are both, a dedicated server is the first only, and a
-- client is the second only.
--
-- Everything below follows from that and nothing else needs configuring.

-- Server side. A client asked for a change; apply it and tell everyone.
-- How often one client may change the rules.
--
-- Every accepted change writes caps.txt, broadcasts to every other client and
-- forces a scheduler pass, so the cost of a request is not small and it is
-- paid by the host. Ten in ten seconds is far more than a person clicking a
-- panel will ever need and far less than a loop can do damage with. Per
-- sender, so one bad client cannot stop everybody else editing.
local RULE_CHANGES = 10
local RULE_WINDOW = 10.0
local rule_budget = {}

-- Hello gets its own, far tighter budget.
--
-- It was not budgeted at all, and it is the most expensive message the server
-- handles: two full transmitter walks, a base camp walk, and fourteen native
-- rank calls per pal. Roughly 40-60ms of game thread each on a populated
-- server, so a client sending them in a loop freezes the game for everyone.
--
-- A legitimate client sends exactly one, once per spawn. Two per minute is
-- generous for that and still refuses a loop outright.
local HELLO_MAX = 2
local HELLO_WINDOW = 60.0
local hello_budget = {}

local function may_announce(comp)
    local who = net.who and net.who(comp) or "unknown"
    local now = os.clock()
    local b = hello_budget[who]

    if b == nil or (now - b.at) > HELLO_WINDOW then
        hello_budget[who] = { at = now, n = 1 }
        return true
    end

    b.n = b.n + 1
    if b.n > HELLO_MAX then
        if b.n == HELLO_MAX + 1 then
            log.warn("ignoring repeated announcements from one player, " ..
                "too many at once")
        end
        return false
    end
    return true
end

local function may_change(comp)
    local who = net.who and net.who(comp) or "unknown"
    local now = os.clock()
    local b = rule_budget[who]

    if b == nil or (now - b.at) > RULE_WINDOW then
        rule_budget[who] = { at = now, n = 1 }
        return true
    end

    b.n = b.n + 1
    if b.n > RULE_CHANGES then
        if b.n == RULE_CHANGES + 1 then
            log.warn("ignoring rule changes from one player, too many at once")
        end
        return false
    end
    return true
end

-- Ranks and priorities for every base pal, for a client's stand grid.
--
-- Built here rather than in net.lua because only this side can ask a pal for
-- its rank at all: GetWorkSuitabilityRank on a replicated pal is an access
-- violation, so the call must happen where the pals are real and the answer
-- must travel. That asymmetry is the whole reason the grid was authority-only.
--
-- Walked on demand rather than cached off a pass. A pass runs every ten
-- seconds and a client's grid is open for a few of them, so caching would
-- keep a table of engine-derived values warm for minutes to save a walk
-- nobody is waiting on.
-- A verified guild is required: only that guild's camps may enter a client's
-- snapshot or edit validation. Missing scope is unavailable, never global.
local function stand_rows(want_guild, observation)
    if type(want_guild) ~= "string" or want_guild == "" then return nil, "guild unavailable" end
    -- Only a synchronous push may share this observation. Standalone edit
    -- validation creates its own, and nothing survives a callback or session.
    observation = observation or {epoch=session.epoch}
    if observation.epoch ~= session.epoch then return nil, "session changed" end
    if not observation.attempted then
        observation.attempted = true
        observation.error = "authority unavailable"
        if api.latch_authority() == true then
            observation.error = "camp enumeration unavailable"
            local camps = api.base_camps()
            if type(camps) == "table" and api.camps_available == true then
                observation.camps, observation.error = camps, nil
            end
        end
    end
    if observation.epoch ~= session.epoch then return nil, "session changed" end
    if observation.error then return nil, observation.error end
    local camps = observation.camps
    local rows, seen = {}, {}
    for _, camp in ipairs(camps) do
        local guild = api.camp_guild(camp)
        if type(guild) ~= "string" or guild == "" then return nil, "camp ownership unavailable" end
        if guild == want_guild then
            local pals, pal_error = api.camp_pals(camp)
            if type(pals) ~= "table" or pal_error then return nil, pal_error or "Pal roster unavailable" end
            for _, pal in ipairs(pals) do
                if not store.durable_key(pal.key) or not api.valid(pal.param) or seen[pal.key] then
                    return nil, "Pal identity unavailable or duplicated"
                end
                local ranks, prios = {}, {}
                for t = 1, #workdefs.ORDER do
                    local value = workdefs.value(workdefs.ORDER[t])
                    local r = api.suitability_rank(pal.param, value)
                    if type(r) ~= "number" or r ~= r or r < 0 or r >= math.huge or r ~= math.floor(r) then
                        return nil, "Pal capability unavailable"
                    end
                    if r > 0 then
                        ranks[t] = r
                        prios[t] = store.effective(cfg,pal,workdefs.ORDER[t],value)
                    end
                end
                seen[pal.key] = true
                rows[#rows+1] = {key=pal.key,ranks=ranks,prios=prios}
            end
        end
    end
    -- Complete roster of the currently loaded, positively scoped camps.
    -- An empty table is valid; failure above is a different result.
    return rows
end

-- Only when somebody is listening, and only from the authority.
-- only_key pushes just the one pal whose row moved.
--
-- A full table is right when a client is meeting the server for the first
-- time; it is sixteen RPCs to report a single changed number in every other
-- case, and on a client each RPC costs roughly seventeen milliseconds of game
-- thread. That was the per-click hitch.
local function push_stand(comp, only_key, current)
    if not api.has_authority() then return end

    -- Nobody to tell, so nothing to walk.
    --
    -- push_rules checks this BEFORE its object walks and this did not, so
    -- every grid click in a solo session paid a full base walk plus fourteen
    -- native rank calls per pal, built a batch, and discarded it.
    if comp == nil and next(net.clients) == nil then return end

    local seen, built_rows, failures = 0, {}, {}
    local observation = {epoch=session.epoch}
    local function rows_for(guild)
        if observation.epoch ~= session.epoch then return nil end
        local key = guild or "<unknown>"
        if failures[key] then return nil end
        if built_rows[key] then return built_rows[key] end
        local ok, rows, why = pcall(stand_rows,guild,observation)
        if not ok or type(rows) ~= "table" then
            failures[key] = true
            log.warn("stand data unavailable: " .. tostring(ok and why or rows))
            return nil
        end
        built_rows[key] = rows
        seen = seen + #rows
        return rows
    end

    local sent = false
    local ok, err = pcall(function()
        sent = log.around(only_key and "network: stand delta" or "network: stand full",
            net.push_pals, rows_for, comp, only_key, current)
    end)
    if not ok then
        log.warn("stand push failed: " .. tostring(err))
        return
    end

    log.debug("stand push: " .. (only_key and ("1 row of " .. seen) or
        (seen .. " pal(s)")) .. ", sent=" .. tostring(sent))
    return sent
end

-- All snapshot routes (Hello, recovery, edit and broadcasts) share the same
-- owner-bound publication policy; pending async memory is never confirmed state.
net.publication_guard = function(stream,publication_cfg)
    if stream=="P" then return store.publication_guard() end
    if stream=="R" then return caps.publication_guard(nil,nil,publication_cfg or cfg) end
end

-- These callbacks are inert until a reviewed trial explicitly enables net's
-- deferred transport before negotiation. No config/default enables it here.
net.pending_owner = function(stream,guild)
    if stream=="P" then return store.pending_owner(guild) end
    if stream=="R" then return caps.pending_owner(guild) end
end
net.pending_status = function(stream,receipt)
    local module=stream=="P" and store or stream=="R" and caps
    if not module then return nil end
    local receipt_state=module.receipt_status(receipt)
    if receipt_state.state~='saved' then return receipt_state end
    return receipt_state,module.publication_guard(receipt_state.body,receipt_state.revision,stream=="R" and cfg or nil)
end
net.publish_pending = function(stream,comp,current)
    if stream=="P" then return push_stand(comp,nil,current) end
    if stream=="R" then return net.push_rules(caps,cfg,comp,current) end
    return false
end

net.on_command = function(command, _, comp, command_token)
    if not store.decided or store.is_client then return false end
    if api.latch_authority() ~= true then
        store.set_role(nil, session.epoch)
        caps.set_role(nil, session.epoch)
        return false, "authority_unavailable"
    end
    local parts = net.split(command)
    local verb = parts[1]

    if verb == net.PREFIX .. "Hello" then

        -- "I cannot tell yet" is not "you have nothing".
        --
        -- A client announces itself as soon as it can, which can be before its
        -- guild has replicated to the server - so guild_of_sender answers nil,
        -- the per-guild batch is correctly empty, and the client is handed a
        -- table saying it owns no pals. That is a real answer as far as the
        -- client is concerned: the generation moves, and the backoff added for
        -- the runaway retry then latches "this server has nothing for my
        -- guild" and stops asking for the rest of the session.
        --
        -- Seen in the log as "stand data: 0 pal(s)" immediately before a
        -- correct one. It recovered only because a second, scheduled Hello
        -- happened to follow. Not answering leaves the generation where it is,
        -- so the client keeps asking on its own backoff until the guild is
        -- there - which is what an unanswerable question deserves.
        if net.guild_of_sender(comp) == nil then
            log.debug("a client said hello before its guild resolved, " ..
                "leaving it to ask again")
            return
        end

        -- Budget spent only on a hello that will actually be answered.
        -- Charged before the guild check, a normal join - which sends one
        -- from the world-load one-shot and one or two from the grid while it
        -- waits - could burn the allowance on requests that were refused
        -- anyway, and then be told off for it.
        if not may_announce(comp) then return end

        -- A modded client announced itself, so send it the world as it
        -- stands. Its own component, not a broadcast: an unmodded client
        -- must receive nothing at all.
        net.push_rules(caps, cfg, comp)
        push_stand(comp)
        log.debug("a modded client said hello, rules sent")
        return
    end

    -- Nothing below writes to disk, broadcasts, or runs a pass until the
    -- request has been checked. It used to do all three unconditionally on
    -- whatever arrived: caps.apply_set took the strings straight into the
    -- rules table and saved, so anything able to send the FName could fill
    -- the host's caps.txt with keys of its choosing - and an amount of zero
    -- reads as "capped at zero", which suspends that work type for good.
    -- The guild comes from the object the message arrived on, never from the
    -- message. A client naming its own guild could name one it is not in, and
    -- the ceiling would then stop work at bases it has nothing to do with.
    -- Unresolvable means the rule is refused, not filed somewhere convenient:
    -- caps refuses a write with no guild rather than widening it to everyone.
    -- A priority edit from a client's Monitoring Stand.
    --
    -- Rate limited by the same may_change gate the ceilings use, and validated
    -- rather than trusted: the key must look like one this machine actually
    -- knows, the work value must be in range, and the priority must be one of
    -- the six things a cell can hold. A client naming a pal it cannot see
    -- would otherwise write priorities for somebody else's base.
    if verb == net.PREFIX .. "Prio" and #parts >= 4 then
        if not may_change(comp) then return end

        local key = parts[2]
        local value = tonumber(parts[3])
        local raw = parts[4]

        -- WHOLE numbers. tonumber("3.5") is 3.5 and passed every check here.
        --
        -- It reached store.apply_set, which writes with %d - and on Lua 5.4
        -- that raises "number has no integer representation" INSIDE save,
        -- after the file was already opened "wb" and truncated. dirty_at is
        -- never cleared, so flush retries every second, re-truncating and
        -- re-failing, and every priority sorting after the poisoned entry is
        -- gone from disk for the rest of the session. On a listen host the
        -- throw also propagates out of store.flush at the top of ui.refresh
        -- and stops the host's own grid repainting.
        --
        -- One crafted packet, permanent damage. Rejected at the door.
        if type(key) ~= "string" or key == "" or value == nil
            or value ~= math.floor(value)
            or value < 1 or value > #workdefs.ORDER then
            log.warn("refused a priority from the network: bad key or work")
            return
        end

        -- The pal must be one this server can see right now. That is what
        -- stops a client writing priorities for a base it has nothing to do
        -- with, and it is the same principle as taking the guild from the
        -- component rather than from the message.
        -- The pal must belong to the SENDER'S guild, not merely exist.
        --
        -- This walked every loaded base and accepted any pal it found
        -- anywhere. Combined with a push that sent every guild's keys to every
        -- client, that let a player set X on a rival guild's pals - ten edits
        -- per ten seconds, so a fifteen pal base fully disabled in a few
        -- minutes, logged only as "a player". The guild comes from the
        -- component the message arrived on, which a client cannot forge, for
        -- exactly the reason the ceiling path takes it from there too.
        local sender_guild
        if command_token ~= nil then
            sender_guild = net.command_guild(command_token, comp, session.epoch)
        else
            sender_guild = net.guild_of_sender(comp)
        end

        -- Refused, not widened. stand_rows would now return nothing for a nil
        -- guild anyway, but an edit that cannot be attributed to a guild
        -- should say so rather than fail an ownership test it was never
        -- really given the chance to pass.
        if type(sender_guild) ~= "string" or sender_guild == "" then
            log.warn("refused a priority from the network: cannot say which " ..
                "guild the sender is in")
            return
        end

        local known = false
        local sender_rows, rows_error = log.around("network edit: roster validation", stand_rows, sender_guild)
        if not sender_rows then
            log.warn("priority edit refused: " .. tostring(rows_error))
            return false
        end
        for _, row in ipairs(sender_rows) do
            if row.key == key then known = true break end
        end
        if not known then
            log.warn("refused a priority from the network: that pal is not " ..
                "in the sender's guild")
            return
        end

        local prio
        if raw == "X" then prio = false
        elseif raw == "-" then prio = nil
        else
            prio = tonumber(raw)
            -- Whole numbers here too, and against store.MAX rather than a
            -- hardcoded 5. A fractional priority writes fine and then fails
            -- to parse on the next load, so the pal is silently never
            -- scheduled for that work - quieter than a crash and harder to
            -- find. net.request_prio floors, but a hand-rolled client does
            -- not, and this side is the one that has to be sure.
            if prio == nil or prio ~= math.floor(prio)
                or prio < 1 or prio > (store.MAX or 5) then
                log.warn("refused a priority from the network: bad value")
                return
            end
        end

        -- Roster reads can dispatch nested engine callbacks. Do not carry an
        -- authenticated guild across an invalidated invocation into a write.
        if command_token ~= nil
            and net.command_guild(command_token, comp, session.epoch) ~= sender_guild then
            return false, "session_changed"
        end
        local accepted, state, receipt
        if prio == nil then accepted, state, receipt = store.apply_clear(key, value)
        else accepted, state, receipt = store.apply_set(key, value, prio) end
        -- Memory acceptance is neither failure nor durability. Preserve the
        -- attachment receipt for deferred completion; do not flush again,
        -- broadcast uncommitted memory, or run a pass in this handler.
        if not accepted then return false, state, receipt end
        local saved, committed_scope = log.around("network edit: save and notify", store.flush, nil, true, true)
        if not saved then
            push_stand(nil,key)
            return "applied_unsaved", "save_failed"
        end

        log.say(string.format("priority %s set to %s by a player",
            workdefs.ORDER[value] or tostring(value), tostring(raw)))

        -- This handler owns notification for this successful save. Do not
        -- also let the save callback broadcast the entire stand. A no-op
        -- clear still needs a fresh snapshot for the client's edit to settle.
        -- A flush can commit earlier dirty changes too: include them instead
        -- of silently narrowing that batch to the last request's Pal.
        local only_key = key
        if committed_scope and (committed_scope.full or committed_scope.key ~= key) then only_key = nil end
        push_stand(nil, only_key)
        run_pass("priority change")
        return true
    end

    if verb == net.PREFIX .. "Set" and #parts >= 4 then
        if not may_change(comp) then return end
        local guild = net.guild_of_sender(comp)
        local saved, state, receipt = caps.apply_set(parts[2], parts[3], parts[4], guild)
        if not saved then
            if state == "pending" then return false, state, receipt end
            if state == "applied_unsaved" then
                net.push_rules(caps,cfg,nil)
                return "applied_unsaved", "save_failed"
            end
            return false, state
        end

        log.say(string.format("%s set %s to %s by a player",
            parts[2], parts[3], parts[4]))
        net.push_rules(caps, cfg, nil)
        run_pass("rule change")
        return true
    end

    if verb == net.PREFIX .. "Clear" and #parts >= 3 then
        if not may_change(comp) then return end
        local saved, state, receipt = caps.apply_clear(parts[2], parts[3], net.guild_of_sender(comp))
        if not saved then
            if state == "pending" then return false, state, receipt end
            -- Refused, so the asking client is still drawing a rule it
            -- believes it deleted. Pushing the unchanged set back corrects it
            -- on the next refresh instead of leaving the panel and the server
            -- quietly disagreeing until something else happens to sync them.
            net.push_rules(caps, cfg, comp)
            if state == "applied_unsaved" then return "applied_unsaved", "save_failed" end
            return false, state
        end

        log.say(string.format("%s %s cleared by a player", parts[2], parts[3]))
        net.push_rules(caps, cfg, nil)
        run_pass("rule change")
        return true
    end
end

-- Only complete, negotiated snapshots reach this callback.
net.on_snapshot = function(rows, metadata)
    if metadata.stream ~= nil and metadata.stream ~= 'R' then return false end
    if not store.decided or not store.is_client or metadata.epoch ~= session.epoch then return false end
    return caps.replace_all(rows, session.epoch, metadata.guild) ~= false
end
net.on_edit = function(key, work, status, reason)
    if ui.edit_status then ui.edit_status(key,work,status,reason) end
    ui.detach() -- invalidates the visible generation; no widgets are touched.
    if key == nil then caps.remote_state, caps.remote_error = status, reason end
end
net.on_status = function(status, reason)
    caps.remote_state, caps.remote_error = status, reason
    if status=='unavailable' then
        caps.remote,caps.remote_scope=nil,nil
    end
end
net.on_session = function(epoch)
    if store.is_client and epoch == session.epoch then
        -- Transport re-handshake does not change the proven local role.
        -- Requests remain blocked by net until the new snapshot is complete.
        caps.remote, caps.remote_scope = nil, nil
        caps.remote_state, caps.remote_error = "connecting", nil
    else
        store.set_role(nil, epoch)
        caps.set_role(nil, epoch)
    end
    session.invalidate_ui()
    ui.detach()
end

-- A client's edits are requests, not writes. Setting this is what makes
-- caps.set send rather than save, so there is one place that decides and
-- every caller is unaware of which machine it is on.
--
-- Decided after the world loads, never here. There is no world when a mod
-- starts, so PalGameMode does not exist and has_authority answers no to
-- everyone, host included. Asked at load, this wired every single player
-- session up as a client: caps.save opens with "if M.submit then return
-- false" because a client owns no rules file, so the host quietly refused to
-- write its own. Every ceiling set in game since has been forgotten at the
-- next restart, and caps.txt had not been touched in two days.
--
-- The same trap is called out twenty lines below for the demand estimate. It
-- was worth writing down once and then obeying in both places.
local function decide_write_or_send()
    local authority = api.latch_authority()
    if authority == nil then
        store.set_role(nil, session.epoch)
        caps.set_role(nil, session.epoch)
        return
    end
    local role = authority and "authority" or "client"
    store.set_role(role, session.epoch)
    caps.set_role(role, session.epoch)


    -- Probed once here and remembered, which is the whole point of doing this
    -- on a timer: every later caller reads a boolean instead of walking the
    -- object array. A client's grid repaint asked this twice per cell, so a
    -- fourteen column grid over fifteen pals paid four hundred full array
    -- walks - seconds of game thread - for one clicked cell.
    if authority then
        caps.submit = nil
        if store.baseline then store.save() end

        -- The authority tells everyone when its own rules move. Set here
        -- rather than at load for the same reason submit is: there is no world
        -- when a mod starts, so this question has no answer yet.
        caps.on_change = function()
            local ok_push, err_push = pcall(function()
                net.push_rules(caps, cfg, nil)
            end)
            if not ok_push then
                log.warn("pushing the ceilings to clients failed: " ..
                    tostring(err_push))
            end
        end

        -- Same for priorities. A change made at the server's own keyboard
        -- reaches every client the same way a client's request does, so the
        -- grid is the same picture wherever it is opened.
        store.submit = nil
        store.on_change = function(key)
            pcall(function() push_stand(nil, key) end)
        end
        -- Loading Lua alone is not world readiness. Report after baseline
        -- persistence and writer installation, never from a historical banner.
        local settings_ready = not require('settings_gate').blocked()
            and cfg ~= nil and store.state ~= "error" and store.state ~= "unavailable"
            and caps.state ~= "error" and caps.state ~= "unavailable"
        log.say(string.format("PWP_READY version=%s session=%d role=%s settings=%s",
            VERSION, session.epoch, role, settings_ready and "available" or "unavailable"))
        return
    end

    -- A client never pushes. Its own edits go up as requests and come back
    -- down as the server's answer, which is the only copy that counts.
    caps.on_change = nil
    store.on_change = nil

    -- A client's grid click becomes a request, not a write.
    --
    -- Without this, store.set wrote the client's own priorities.txt - a file
    -- the server never reads - so the number changed on screen and the pal
    -- carried on exactly as before. The old comment in ui.lua called that a
    -- decoration, which is precisely what it was.
    store.submit = function(kind, key, value, prio)
        local ok = net.request_prio(key, value,
            kind == "clear" and nil or prio)

        -- Said, as the ceiling path says it. A click made before the network
        -- component resolves is a no-op, and silence there reads as the grid
        -- being broken rather than as the click not having gone anywhere.
        if not ok then
            log.say("could not reach the server, that priority was not set")
        end
        return ok
    end

    caps.submit = function(kind, work, item, amount, _guild)
        -- The guild is deliberately not sent. The server files the rule under
        -- whichever guild the message arrived from, which a client cannot
        -- forge; a guild named in the payload could be any guild at all.
        if not net.request(kind, work, item, amount) then
            log.say("could not reach the server, that change was not made")
            return false
        end
        return true
    end
end

local function role_tick()
    if not store.decided then decide_write_or_send() end
end
-- Read-only stock requests extend normal scheduler interest; no RPC callback
-- scans containers, runs a pass, or applies rows to the durable rule store.
net.on_storage_interest = function(guild)
    if not store.decided or store.is_client or api.has_authority() ~= true then return false end
    return scheduler.request_stock(guild)
end
net.on_storage_request = function(guild, selected, now)
    if not store.decided or store.is_client or api.has_authority() ~= true then return nil end
    return require('storage_snapshot').build(cfg, scheduler, guild, selected, now)
end
clock.every('storage transport', 100, function()
    net.set_storage_open(store.decided and store.is_client == true and panel.open == true)
    net.storage_tick()
end)
clock.every("deferred settings replies",1000,function()net.complete_pending()end)
clock.every("role", 2000, role_tick)
clock.every("log summaries", 5000, log.flush_repeats)
clock.start()

-- The world the caches were built against. nil until the first spawn.
-- Said once. The decision it reports is re-made on every spawn now, and
-- a player does not need telling on each death that this is a client.
local said_client_warning = false

RegisterHook("/Script/Engine.PlayerController:ClientRestart", measurement.callback("hook: complete spawn", function(Context)
  -- Ignore another player's spawn on a listen/dedicated authority.
  local local_pc = api.local_player_controller()
  if local_pc then
      local same = nil
      pcall(function()
          local owner = Context:get()
          local owner_name = owner:GetFullName()
          local local_name = local_pc:GetFullName()
          same = type(owner_name) == "string" and owner_name ~= "" and
              type(local_name) == "string" and local_name ~= "" and
              owner_name == local_name
      end)
      -- An unreadable context is not proof of a local spawn. In particular,
      -- another player's restart must not discard this player's queued edits.
      if same ~= true then return end
  elseif api.latch_authority() == true then
      return -- dedicated startup uses role_tick; a remote spawn is not a new server session.
  end
  -- Stop writers and invalidate queued work before resolving the new session.
  if async_trial then async_trial.transition() end
  session.begin(nil)
  store.set_role(nil, session.epoch)
  caps.set_role(nil, session.epoch)
  api.reset()
  if net.begin_session then net.begin_session(session.epoch) end

  -- Every line below runs under one pcall.
  --
  -- Nine calls ran bare here. If any of them threw - and panel.reset reaches
  -- into icons, overlay and the whole widget tree - everything after it was
  -- skipped, so net.reset, overlay.reset, demandidx.install and all four
  -- delayed starts silently did not happen and the mod came up half reset
  -- with nothing in the log.
  local ok, err = pcall(function()

    -- ClientRestart also fires on a same-map reconnect and respawn. A matching
    -- map name cannot prove that the old connection or widget lifetime survives.
    local now_key = api.world_key()
    local switched = true -- names are not connection identities; reset every spawn

    if switched then
        -- Engine wrappers do not survive a world switch, and neither should
        -- any memo built from them.
        --
        -- One pcall each, and the key committed only afterwards. Under a
        -- single pcall a throw in any one of these - and panel.reset reaches
        -- into icons, overlay and the whole widget tree - aborted the rest
        -- while world_key had ALREADY been updated, so the next ClientRestart
        -- saw no change and never retried. That left api.reset done and
        -- overlay.reset not, which is the precise state that makes the
        -- overlay's freed-controller window fire every time rather than
        -- occasionally.
        for _, step in ipairs({
            { "api", api.reset }, { "clock", clock.reset },
            { "scheduler", scheduler.forget }, { "demand", demandidx.reset },
            { "ui", ui.reset }, { "items", items.reset },
            { "panel", panel.reset }, { "net", net.reset },
            { "overlay", overlay.reset },
        }) do
            local ok_step, err_step = pcall(step[2])
            if not ok_step then
                log.warn("world reset step '" .. step[1] .. "' threw: " ..
                    tostring(err_step))
            end
        end
    end

    -- Record the map as diagnostic context; the new epoch identifies the session.
    if switched then
        log.say("world key: " .. tostring(now_key))
    end

    session.world = now_key

    -- Registration is idempotent and cheap; this covers a world load that
    -- happened before the class existed.
    demandidx.install()

    -- Fetch the blueprint widget's class ahead of anyone wanting it: the
    -- lookup answers through a callback on the game thread, and a panel
    -- opened while it was in flight would open on the wrong host. Guarded
    -- because overlay hot-swaps and this file does not.
    if api.has_viewport() and overlay.prepare then
        pcall(function() overlay.prepare() end)
    end


    -- Only on an actual world change, which is what these were always for.
    --
    -- ClientRestart fires on every spawn, so all three ran again on every
    -- death: a redundant authority decision, a whole extra pass, and a dev
    -- probe, fifteen to twenty five seconds after each one. The comment on the
    -- guard above names "re-queued four one-shots" as part of what it was
    -- written to stop, but the guard was only ever put around the cache
    -- resets, so this half of the problem stayed.
    --
    -- The authority answer cannot change without a world change, and its
    -- warning is the one a client sees; unguarded it printed on every death.
    if switched then
        -- A client announces itself so the server knows to push rules to it,
        -- and gets the current set back in reply. Delayed with everything
        -- else, because the network component does not exist the instant a
        -- world loads.
        --
        -- Behind the guard now. It used to run on every spawn, which cost the
        -- host a full object-array walk plus one RPC per rule on every death,
        -- and it was left that way on purpose for one commit: the register
        -- dropped a client after two minutes of silence, so this accidental
        -- re-announce was the only thing putting a player back on the list.
        -- The register keeps anyone who still resolves now, so the crutch can
        -- go with the thing it was propping up.
        clock.once(18000, session.guard(function()
            if not api.has_authority() then
                if net.to_server(net.PREFIX .. "Hello", 1) then
                    log.debug("announced to the server, waiting for the rules")
                end
            end
        end))

        if cfg.run_on_world_load then
            -- Base camps and their worker slots are not populated the instant
            -- the controller restarts, so the first look is late on purpose.
            clock.once(15000, session.guard(function()
                clock.defer("world load", session.guard(function() run_pass("world load") end))
            end))
            -- Icon-route diagnostics are manual commands, never startup work.
        end
    end
    -- Not behind the switched guard, and not on a twenty second delay.
    --
    -- Both were wrong for the same reason. Behind the guard, a respawn the
    -- client considers the same world never re-ran this; at twenty seconds,
    -- there was a long opening window where the grid was already drawn and
    -- taking clicks that store.set had nowhere to send. Clicks made in it
    -- were written to the client's own file and then overwritten by the
    -- server's next push.
    --
    -- Two seconds is enough: has_authority is one FindFirstOf for PalGameMode,
    -- which exists as soon as the world is up and never appears on a client.
    -- It does not wait on base camps or worker slots like the first pass does.
    -- Asked again at twenty in case two was optimistic on a slow load; the
    -- function is idempotent, so a second answer only ever confirms the first.
    clock.once(2000, session.guard(function() decide_write_or_send() end))
    clock.once(20000, session.guard(function()
        decide_write_or_send()

        if not api.has_authority() and not said_client_warning then
            said_client_warning = true
            log.warn("no authority here, so this looks like a client on " ..
                "a dedicated server. No passes will run on this machine " ..
                "and the priorities are the server's - it sends them " ..
                "down for the Monitoring Stand grid to draw, and your " ..
                "edits go back up to it.")
        end
    end))

    start_timer()
    start_ui()
    clock.every("role", 2000, role_tick)
    clock.every("log summaries", 5000, log.flush_repeats)

  end)

  if not ok then
      log.warn("world load handler threw: " .. tostring(err))
  end
end))

-- Started at load as well, not only on world entry. ClientRestart fires when
-- a player spawns, and a dedicated server with nobody connected never fires
-- it, which left the mod loaded but inert on the headless rig: no ticks, no
-- command channel, nothing. Both loops idle harmlessly while there is no
-- world, so starting early costs nothing on the client either.
if cfg and cfg.enabled then
    start_timer()
    start_ui()
end

-- Tell the game an overlay is up while the panel is up.
--
-- The problem this solves: with the panel open on a Game-and-UI route, pad
-- buttons and keys still reach the game, so a face button pressed to confirm
-- something in the panel also threw a sphere behind it.
--
-- The obvious answer, DisableInput on the controller, was tried and is much
-- worse than the problem. A disabled controller ignores every menu the game
-- draws, so the player could not click anything in their own inventory. It
-- stopped the leak by breaking the game.
--
-- This is BreedingHelper's approach and the difference matters. Nothing is
-- taken away from anyone: the game is asked "is an overlay UI active" and,
-- while our panel is on screen, the honest answer is yes. The game then
-- suppresses its own gameplay actions the way it does for its own menus, and
-- its menus keep working because nothing was disabled.
--
-- Registered here rather than in overlay or panel because a hook cannot be
-- unregistered and this file is never swapped. It reads panel.open through the
-- upvalue that reload hands back, so a swap does not strand it on a dead table.
--
-- Both classes, because which one the build routes through is not worth
-- guessing at. Registering a hook for a function that is not there fails
-- harmlessly and is reported.
for _, path in ipairs({
    "/Script/Pal.PalHUDService:IsAnyOverlayUIActive",
    "/Script/Pal.PalHUDInGame:IsAnyOverlayUIActive",
}) do
    local ok = pcall(function()
        RegisterHook(path, function() end, measurement.callback("hook: overlay ui active", function(_, ReturnValue)
            -- The game's own answer, read BEFORE we override it, and kept on
            -- palapi because that module is never swapped. It is the only way
            -- anything else can ask "does the GAME have UI up" without reading
            -- back our own lie and believing it.
            api.game_ui_active = nil
            pcall(function()
                local observed = ReturnValue:get()
                if type(observed) == "boolean" then api.game_ui_active = observed end
            end)

            if not (panel and panel.open) then return end

            -- Both shapes. Some UE4SS builds take the returned value, others
            -- want the out parameter written, and which one this build wants
            -- is not worth a separate experiment when doing both is free.
            pcall(function() ReturnValue:set(true) end)
            return true
        end))
    end)
    if not ok then
        log.debug("overlay gate: could not hook " .. path)
    end
end

RegisterHook("/Script/Pal.PalUIChat:OnReceivedChat", measurement.callback("hook: complete chat", function(context, message)
    local ok, err = pcall(function()
        local received = message:get()
        if not (received and received.Message) then return end
        -- Whose line is this?
        --
        -- nil means "could not tell" and is deliberately NOT the same as
        -- "somebody else": the gate falls back to refusing while anyone is
        -- connected, rather than either trusting a stranger or locking the
        -- player out of their own commands.
        local from_me = nil
        pcall(function()
            local mine = api.my_player_uid()
            if mine == nil then return end
            local theirs = api.guid_key(received.SenderPlayerUId)
            if theirs == nil then return end
            from_me = (theirs == mine)
        end)

        handle_command(received.Message:ToString(), true, from_me)
    end)
    if not ok then log.debug("chat hook: " .. tostring(err)) end
end))

-- A keybind that fails to register does so silently, which then reads as
-- "the mod is broken" the first time a key does nothing. Report it.
local function bind(key, label, fn, modifiers)
    local action = fn
    fn = function() session.enqueue(action, true) end
    local ok, err = pcall(function()
        if modifiers then
            RegisterKeyBind(key, modifiers, fn)
        else
            RegisterKeyBind(key, fn)
        end
    end)
    if not ok then
        log.warn("could not bind " .. label .. ": " .. tostring(err))
    end
    return ok
end

-- A rebindable key, from DarnMenu when the player has set one.
--
-- The shipped Alt+Fn stays the default and is used whenever DarnMenu is absent,
-- the saved file is absent, or the saved key is one this UE4SS has no entry
-- for. A hotkey that silently does not exist is the worst outcome available
-- here, and this mod has already shipped one of those once.
--
-- The label follows the binding, so the warning printed when a bind fails
-- names the key the player actually chose rather than the one we shipped.
local function bind_action(name, default_key, what, fn)
    local key, mods, _, label

    pcall(function()
        key, mods, _, label = darnmenu.binding(name, default_key, { "ALT" })
    end)

    if key == nil then
        key = Key and Key[default_key] or nil
        mods = (ModifierKey ~= nil) and { ModifierKey.ALT } or nil
        label = "Alt+" .. default_key
    end

    if key == nil then
        log.warn("no " .. default_key .. " on this UE4SS build, so " ..
            what .. " has no hotkey")
        return
    end

    bind(key, label .. " (" .. what .. ")", fn, mods)
end

-- Every key here is Alt with a function key, and every one was checked against
-- the other installed mods with tools/keybind_audit.py rather than by eye. Two
-- collisions were found that way and both had been missed by grepping: FreeCam
-- sets its key and its modifier lines apart so Alt+F8 reads as plain F8, and
-- UltraGraphics registers through a wrapper so its plain F10 never appeared in
-- a search for RegisterKeyBind at all.
--
-- Alt, and nothing but Alt, because Ctrl is crouch. Every Ctrl+Fn press rolled
-- the character, which made half the mod unusable in practice: the modifier
-- does not stop the game seeing the modifier. Palworld binds Alt to nothing,
-- so it is the only one of the three that costs nothing to hold. Shift was
-- considered and rejected - it is sprint, and FreeCam decides its own F8
-- modifier at runtime with Shift among the candidates.
--
-- That leaves Alt+F1, F2, F3, F5 and F9 free, plus the three already here.
-- F4 is Windows, F6 and F7 are EffigyBeacons (and PalBaseInfoGrid on F7), F8
-- is FreeCam. Eight slots for eight keys, which is why the icon probe became
-- a chat command instead: it is a diagnostic for a bug that is long fixed and
-- it was the only one here nobody would miss.
bind_action("key_pass", "F2", "run pass", function()
    run_pass("keybind", true)
end)

log.say(string.format("%s %s loaded (%s, %s). Type '%s help' in chat.",
    MOD_NAME, VERSION,
    cfg.enabled and "enabled" or "disabled",
    cfg.dry_run and "dry run" or "live",
    cfg.chat_prefix))

-- Chat input is not reliably available in every singleplayer session, so the
-- discovery dump gets its own key instead of living only behind a chat
-- command. F10/F11 were picked because every other Fn key in the low range
-- is already claimed by another installed mod.
bind(Key.F5, "Alt+F5 (discovery)", function()
    COMMANDS.discover()
end, { ModifierKey.ALT })

-- Base storage on a key too. Ceilings are keyed by internal item id, and
-- without a way to print those ids outside chat the whole feature is
-- unreachable in a session where chat input is not available.
bind_action("key_stock", "F3", "stock", function()
    COMMANDS.stock()
end)

-- Left click raises a cell towards priority 1, right click lowers it towards
-- never. cfg is passed as a getter because '!pwp reload' replaces the table.
do
    local n = ui.bind_mouse(function() return cfg end, function(dir)
        return panel.handle_click(cfg, dir)
    end, function() return panel.open end)
    if n < 2 then
        log.warn("only " .. n .. " of 2 mouse buttons bound, " ..
            "priority clicking will be partly unavailable")
    end
end

-- Toggles on modifiers rather than fresh F-keys: the plain ones are getting
-- crowded, and Alt+F10/F11 are clear of every keybind the other installed
-- mods claim. Ctrl is avoided because UE4SS uses Ctrl+H itself.
bind_action("key_mode", "F10", "mode", function()
    COMMANDS.mode()
end)

bind_action("key_cap", "F11", "cap", function()
    COMMANDS.cap()
end)

-- Single player has no chat box, so every command behind the chat prefix is
-- unreachable there. Anything that changes what the mod does needs a key as
-- well, or it may as well not exist for a single player game.
bind_action("key_scope", "F12", "storage scope", function()
    COMMANDS.scope()
end)

-- The rules panel, on the lowest free key, because it is the one a player
-- reaches for most and F1 is where a hand goes looking for a panel.
bind_action("key_panel", "F1", "work rules", function()
    panel.toggle()
end)

-- The transport test needs a key of its own, because the machine most worth
-- running it on is a client in single player, where there is no chat box to
-- type a command into. F9 rather than F8: Alt+F8 is FreeCam's toggle, and the
-- plain F9 that BaseTrimmer and UltraGraphics claim is a different binding.
bind(Key.F9, "Alt+F9 (transport test)", function()
    COMMANDS.net()
end, { ModifierKey.ALT })

-- Cancel the current edit first; a later press closes the panel. This raw
-- key observer does not consume Palworld's Escape action. Native testing
-- still shows it closing a Monitoring Stand underneath the editor, so input
-- isolation remains a separate release gate. The overlay handoff must not
-- try to repair that collision by stealing another menu's focus.
bind(Key.ESCAPE, "Esc (cancel editing or close the rules panel)", function()
    if panel.open and overlay.native_cancel ~= true then panel.escape() end
end)

-- Arrow keys for the rules panel.
--
-- The mouse works, but the cursor sits over a live game world and the rows
-- are thin, so aiming is fiddly. ShinyPals solves the same problem the same
-- way and these are deliberately the same keys: every handler here returns
-- immediately when our panel is shut, so the two only overlap if both panels
-- are open at once.
local function arrows()
    -- The keys say which way, not what it does. What it does depends on the
    -- screen: on the rules list left and right change a ceiling, in the
    -- picker they move across a grid, and only the panel knows which is up.
    local moves = {
        { "UP_ARROW",    function() if panel.open then return panel.nav(cfg, "up") end; return ui.raw_nav(cfg,"up") end },
        { "DOWN_ARROW",  function() if panel.open then return panel.nav(cfg, "down") end; return ui.raw_nav(cfg,"down") end },
        { "RIGHT_ARROW", function() if panel.open then return panel.nav(cfg, "right") end; return ui.raw_nav(cfg,"right") end },
        { "LEFT_ARROW",  function() if panel.open then return panel.nav(cfg, "left") end; return ui.raw_nav(cfg,"left") end },
        { "RETURN",      function() if panel.open then return panel.nav(cfg, "enter") end; return ui.raw_nav(cfg,"enter") end },
    }

    for _, entry in ipairs(moves) do
        local key
        pcall(function() key = Key[entry[1]] end)
        if key == nil then
            log.warn("no " .. entry[1] .. " on this UE4SS build, " ..
                "so the rules panel is mouse only")
        else
            bind(key, entry[1] .. " (rules panel)", function()
                pcall(entry[2])
            end)
        end
    end
end
arrows()

-- Stand 1-5/X is delivered by the focused native input surface. A global
-- key observer has neither event-time hover identity nor Slate input ownership
-- and must not acquire either later when the game-thread queue drains.
