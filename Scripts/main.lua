-- Pal Work Priority
--
-- Numeric work priorities for base pals, driven from config.lua. Priority 1
-- work is staffed before priority 5 work, and within a priority the best
-- suited pal takes the job.
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

local MOD_NAME = "Pal Work Priority"
local VERSION = "0.4.0"

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

store.load(DIR .. "priorities.txt")
caps.load(DIR .. "caps.txt")

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
    local loaded
    -- Text only. config.lua is a literal table and has no business
    -- being bytecode, and mode "bt" would load it if it were.
    -- Text only AND no environment. config.lua is a literal table and
    -- needs nothing from _G; mode "bt" alone would still have loaded
    -- bytecode, and _ENV = _G still handed a chunk io and os.execute.
    local chunk, load_err = loadfile(SCRIPT_DIR .. "config.lua", "t", {})

    if chunk then
        local ok_chunk, result = pcall(chunk)
        if not ok_chunk or type(result) ~= "table" then
            log.error("config.lua failed to load: " .. tostring(result))
            return false
        end
        loaded = result
    else
        -- Only if the file cannot be read at all. Keeps first boot working if
        -- the path is ever wrong, at the cost of the staleness described above.
        log.warn("could not read config.lua (" .. tostring(load_err) ..
            "), falling back to the compiled copy")
        package.loaded["config"] = nil
        local ok_req, result = pcall(require, "config")
        if not ok_req or type(result) ~= "table" then
            log.error("config.lua failed to load: " .. tostring(result))
            return false
        end
        loaded = result
    end

    -- Whatever the player set in DarnMenu, on top of config.lua and before
    -- validate sees it, so a value from the menu is checked by exactly the
    -- same rules as a value typed into the file. Absent DarnMenu, or absent a
    -- saved file, this changes nothing.
    pcall(function() darnmenu.apply(loaded) end)

    cfg = validate(loaded)
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
        elseif pass_explicit then
            log.say(pass_reason .. ": no base camp loaded. Camps only exist while " ..
                "streamed in, so stand inside your base and try again.")
        end
    end)
    pass_queued = false

    if not ok then
        log.error("pass failed: " .. tostring(err))
    end
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
    if not cfg then return end

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
    pass_body()
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


local function ui_body()
    -- The grid stays on its second, because refreshing it means a FindAllOf
    -- over every cell and it has nothing to gain from ten times the rate.
    -- A second, or immediately when the server has sent something new.
    --
    -- The grid's own reason for a one second beat is that noticing an edit
    -- means a FindAllOf over every cell. That holds while hosting, where a
    -- change can come from anywhere. On a client a change can only arrive as a
    -- batch, and net.pals_gen says exactly when one has - so waiting out the
    -- rest of the second afterwards is latency for nothing. It is what made
    -- clicking feel slow: the edit reached the server and came back in well
    -- under a second, then sat unpainted until the beat came round.
    local pushed = (ui.wants_repaint ~= nil) and ui.wants_repaint() or false

    if grid_owed >= 1000 or pushed then
        grid_owed = 0
        pcall(function() ui.refresh(cfg) end)
    end

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

    -- Instructions from outside, read and acted on here rather than on a
    -- timer of their own, so one can never land between two halves of a draw.
    -- Both are already on the game thread.
    pcall(function() remote.poll() end)
    pcall(function() remote.drain() end)
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

    local want = panel.open and UI_BEAT or 1000
    if body_owed < want then return end
    body_owed = 0

    -- Runs even when disabled, so the grid still reflects edits. It costs
    -- nothing while the stand is shut. Already on the game thread, so the
    -- body is a call, not a registration.
    if cfg then
        ui_body()

        if panel.wants_pass then
            panel.wants_pass = false
            run_pass("rule change")
        end

        -- A priority just changed. Re-fence now rather than leaving the edit
        -- inert until the next tick, which reads as the click doing nothing.
        if ui.wants_pass then
            ui.wants_pass = false
            run_pass("edit")
        end
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
                if panel.open and panel.hover_tick then
                    pcall(panel.hover_tick)
                end
                -- A page being shown for the first time draws eight
                -- milliseconds of tiles per frame and asks to be called back
                -- until it is done. Guarded like hover_tick and for the same
                -- reason: panel hot swaps, and a session can briefly run an
                -- older one without this.
                if panel.open and panel.fill_tick then
                    pcall(panel.fill_tick)
                end
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
    log.say("  " .. p .. " icons     probe the overlay icons")
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
    log.say(string.format("%s %s | %s | %s | every %ds",
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
    log.say("  authority: " .. (api.has_authority()
        and "yes, this machine runs the world"
        -- Not "work is estimated here". Nothing is: run_pass returns
        -- immediately without authority, so a client never reaches the code
        -- that would estimate anything. The old wording described a fallback
        -- that cannot execute, which is the same class of error as
        -- documenting a keybind that never fires.
        or "NO, this is a client. No passes run here and the Monitoring " ..
           "Stand grid is drawn from what the server sends, and your edits " ..
           "go back up to it"))
    log.say("  mode: " .. tostring(cfg.assignment_mode) .. ", max per work type: " ..
        (cfg.max_pals_per_work_type and tostring(cfg.max_pals_per_work_type) or "no limit"))
    log.say("  ceilings measured against: " ..
        (cfg.storage_scope == "global" and "every loaded base" or "each base on its own"))
end

COMMANDS.run = function()
    run_pass("manual", true)
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
    scheduler.forget()
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
    scheduler.forget()
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
    scheduler.forget()
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
    -- The fences belong to whoever set them, and a client never set any: the
    -- passes run on the authority, for the reason given at run_pass. So there
    -- is nothing here to give back.
    --
    -- It is worse than merely pointless. base_allowed asks every pal for its
    -- suitability rank, and GetWorkSuitabilityRank on a replicated proxy is an
    -- access violation rather than an error, so no pcall on the way down
    -- catches it. That is what killed the game from the discovery probe on
    -- 23 August, which is why THAT probe has been gated ever since - but the
    -- same call sat one branch away behind '!pwp off', unguarded, where a
    -- 14 pal base would have reached it a couple of thousand times before the
    -- first sweep finished.
    if not api.has_authority() then
        log.say(why .. ": this is a client, so it has no fences to undo. " ..
            "Run '" .. cfg.chat_prefix .. " restore' on the server.")
        return
    end

    local sent, rounds, blocked = 0, 0, false

    repeat
        rounds = rounds + 1
        local stats = scheduler.restore(cfg)
        sent = sent + stats.toggles
        blocked = stats.blocked or false
        local owed = stats.deferred
    until owed == 0 or blocked or rounds >= 12

    -- Three different things, said three different ways. This used to print
    -- "gave every pal its work back" for all of them, including the one where
    -- it had changed nothing because it could not.
    if blocked then
        log.say(why .. ": nothing was restored, see the warning above")
        return
    end
    if sent == 0 then
        log.say(why .. ": nothing needed giving back, every pal already has " ..
            "all of its work")
        return
    end
    log.say(string.format(
        "%s: gave every pal its work back (%d change(s) over %d sweep(s))",
        why, sent, rounds))
    if rounds >= 12 then
        log.warn("stopped after 12 sweeps, run '" .. cfg.chat_prefix ..
            " restore' again if any pal still looks fenced")
    end
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
        scheduler.forget()
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
            local totals, chests = api.camp_item_totals(
                api.guid_key(api.camp_id(camp)),
                { include = cfg.counted_containers,
                  exclude = cfg.uncounted_containers })

            local rows = {}
            for id, n in pairs(totals) do rows[#rows + 1] = { id = id, n = n } end
            table.sort(rows, function(a, b)
                if a.n ~= b.n then return a.n > b.n end
                return a.id < b.id
            end)

            local header = string.format("camp %d: %d chest(s), %d item type(s)",
                ci, chests, #rows)
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
                log.say("  no container answered, so ceilings would read as unmet")
            end

            -- Ceilings count chests only. Anything else on the base holding
            -- stock is invisible to them, so name it rather than leaving a
            -- limit to look broken when the resource is really just sitting
            -- somewhere that is not counted.
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

-- Item totals across every loaded camp. Used to check a spelling and to show
-- what a ceiling is up against. The ceilings themselves are still judged one
-- camp at a time by the scheduler.
-- How the scheduler is currently told to read storage, so the listing and
-- the pass can never disagree about what counts.
local function container_opts()
    return {
        include = cfg.counted_containers,
        exclude = cfg.uncounted_containers,
    }
end

local function stock_across_camps()
    -- Global scope counts chests the camp filter would drop, so ask for them
    -- the same way the scheduler does rather than summing per camp.
    if cfg.storage_scope == "global" then
        return (api.all_chest_totals(container_opts()))
    end

    local totals = {}

    for _, camp in ipairs(api.base_camps()) do
        local camp_id = api.camp_id(camp)
        if camp_id then
            local part = api.camp_item_totals(api.guid_key(camp_id), container_opts())
            for id, n in pairs(part or {}) do
                -- The fullest base, not the sum. Same reason as
                -- panel.stock_totals: the ceiling is checked against one base
                -- at a time, so the total across bases is a figure nothing is
                -- ever compared against, and printing it beside a limit that
                -- has not fired reads as the limit being broken.
                if n > (totals[id] or 0) then totals[id] = n end
            end
        end
    end
    return totals
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
        log.say("no stock limits set")
        log.say("  " .. cfg.chat_prefix .. " limit Lumbering Wood 5000")
        log.say("run " .. cfg.chat_prefix .. " stock for the item ids this base holds")
        return
    end

    run_now(function()
        local totals = stock_across_camps()

        log.say("stock limits:")
        for _, work in ipairs(works) do
            local items = {}
            for item in pairs(all[work]) do items[#items + 1] = item end
            table.sort(items)

            for _, item in ipairs(items) do
                local ceiling = all[work][item]
                local have = totals[item] or 0
                log.say(string.format("  %-22s %-24s %d / %d%s",
                    workdefs.label(work), item, have, ceiling,
                    have >= ceiling and "   met" or ""))
            end
        end
        log.say("a work type pauses once every item listed for it is at its limit")
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
    local ceiling = tonumber(amount_text)

    -- 0 removes the ceiling rather than being read literally. Taken at face
    -- value it would mean "you already have at least none of these", which
    -- suspends the work type for good, and priority X on the stand already
    -- says that far more clearly.
    local clearing = (lowered == "off" or lowered == "none"
        or lowered == "clear" or ceiling == 0)

    if not clearing and (ceiling == nil or ceiling < 1) then
        log.say(amount_text .. " is not an amount, use a number or 0 to remove")
        return
    end

    run_now(function()
        local totals = stock_across_camps()

        if clearing then
            local id = match_stock_id(totals, item_text) or item_text
            if caps.clear(work, id, api.my_guild()) then
                log.say("limit removed: " .. workdefs.label(work) .. " " .. id)
            else
                log.say("no limit was set for " .. workdefs.label(work) .. " " .. id)
                return
            end
        else
            local id = match_stock_id(totals, item_text)
            if id == nil then
                -- Not fatal: capping something the base has none of yet is a
                -- perfectly good thing to want. A typo looks the same though,
                -- so say so rather than letting it fail quietly later.
                id = item_text
                log.warn("nothing called " .. item_text .. " is in this base right " ..
                    "now, so check the spelling with " .. cfg.chat_prefix .. " stock")
            end

            local written = caps.set(work, id, math.floor(ceiling),
                api.my_guild())
            if not written then
                -- The clearing branch above already read this answer; setting
                -- discarded it. caps.set refuses outright when there is no
                -- guild, and on a client it reports only whether the request
                -- was SENT, so this is the strongest claim available either
                -- way.
                log.say(string.format(
                    "asked for %s to pause at %d %s, "
                    .. "it has not been confirmed",
                    workdefs.label(work), math.floor(ceiling), id))
                return
            end
            log.say(string.format("limit set: %s pauses at %d %s, base holds %d",
                workdefs.label(work), math.floor(ceiling), id, totals[id] or 0))
        end

        scheduler.forget()
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
-- Provably solo is the only case that can be answered today: the authority,
-- with no modded client registered, is a session where the only person who can
-- type is the one at the keyboard. Anything else waits for the sender check,
-- which needs a field name this build has not been measured for - see the
-- probe in the chat hook.
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
        log.warn("refused '" .. key .. "' from chat: it did not come from " ..
            "this machine's player, and chat reaches everyone")
        if not warned_chat_refusal then
            warned_chat_refusal = true
            log.say("commands that change something are refused from chat " ..
                "while anyone else is connected, because chat reaches every " ..
                "player. To use them here, create an empty remote.txt next " ..
                "to priority.log and restart.")
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
-- want_guild nil means every camp, which is what a local pass wants. A guild
-- means only that guild's camps, which is what a client may see or write.
local function stand_rows(want_guild)
    local rows = {}

    -- No guild means NO rows, never every row.
    --
    -- This used to read "want_guild == nil or camp_guild == want_guild", so an
    -- unresolvable guild silently widened to every camp on the server. Both
    -- callers are network paths - the ownership check for an incoming edit and
    -- the batch built for one client - so that turned the ownership test back
    -- into "does this pal exist anywhere", which is the exact defect the
    -- comment in the Prio handler says was fixed, and made the push hand one
    -- client every guild's roster.
    --
    -- nil is an ordinary state, not an error: a player in no guild, or one
    -- whose guild has not replicated yet. palapi says what to do with it -
    -- "Callers must read that as 'no scope known', never as 'applies
    -- everywhere'." The ceilings path already refuses; this now does too.
    if type(want_guild) ~= "string" or want_guild == "" then
        return rows
    end

    for _, camp in ipairs(api.base_camps() or {}) do
        local camp_guild = api.camp_guild(camp)
        if camp_guild == want_guild then
        for _, pal in ipairs(api.camp_pals(camp) or {}) do
            if type(pal.key) == "string" and api.valid(pal.param) then
                local ranks, prios = {}, {}

                for t = 1, #workdefs.ORDER do
                    local value = workdefs.value(workdefs.ORDER[t])
                    local r = api.suitability_rank(pal.param, value)
                    if type(r) == "number" and r > 0 then
                        ranks[t] = r
                        -- Only where the pal is capable. A priority on work it
                        -- cannot do would draw a number over the vanilla dash,
                        -- which is the one thing the grid promises never to do.
                        prios[t] = store.effective(cfg, pal,
                            workdefs.ORDER[t], value)
                    end
                end

                rows[#rows + 1] = { key = pal.key, ranks = ranks, prios = prios }
            end
        end
        end
    end

    return rows
end

-- Only when somebody is listening, and only from the authority.
-- only_key pushes just the one pal whose row moved.
--
-- A full table is right when a client is meeting the server for the first
-- time; it is sixteen RPCs to report a single changed number in every other
-- case, and on a client each RPC costs roughly seventeen milliseconds of game
-- thread. That was the per-click hitch.
local function push_stand(comp, only_key)
    if not api.has_authority() then return end

    -- Nobody to tell, so nothing to walk.
    --
    -- push_rules checks this BEFORE its object walks and this did not, so
    -- every grid click in a solo session paid a full base walk plus fourteen
    -- native rank calls per pal, built a batch, and discarded it.
    if comp == nil and next(net.clients) == nil then return end

    -- Said out loud, because the failure this had was silent.
    --
    -- The first version called api.camps(), which does not exist - the name is
    -- base_camps - so stand_rows threw inside a pcall, returned nothing, and
    -- the client drew the vanilla grid exactly as if the feature were still
    -- switched off. luacheck does not see undefined calls, so nothing caught
    -- it but the game.
    -- Each recipient gets their own guild's pals, and nobody else's. Passed as
    -- a function because net.lua caches one batch per guild and calls this
    -- once for each distinct guild it is actually sending to.
    local seen = 0
    local built_rows = {}

    local function rows_for(guild)
        -- Cached per guild, because the zero-row check below has to ask the
        -- same question push_pals is about to ask and neither should pay for
        -- a second base walk.
        local ck = guild or "<none>"
        if built_rows[ck] then return built_rows[ck] end

        local rows = {}
        local ok, err = pcall(function() rows = stand_rows(guild) end)
        if not ok then
            log.warn("stand rows failed: " .. tostring(err))
            return {}
        end
        seen = seen + #rows
        built_rows[ck] = rows
        return rows
    end

    -- Nothing to say is not the same as "you have nothing".
    --
    -- A guild that resolves fine but whose camps are not streamed in yields
    -- zero rows, and a full push then sends PalReset+PalDone - an empty table
    -- that moves the client's generation and reads to it as a definite answer.
    -- Its backoff latched on that and stopped asking for the session, so a
    -- player who joined away from their base got a vanilla grid for ever.
    --
    -- Only the addressed-reply case: a broadcast with no rows for a guild is
    -- ordinary and must still clear that guild's clients.
    if comp ~= nil and not only_key then
        -- Asked, not assumed.
        --
        -- This read `seen == 0` directly, and seen is only incremented INSIDE
        -- rows_for - which push_pals calls lazily, after this line. So it was
        -- always zero here and the guard fired on every single hello: the
        -- server refused to answer any client at all, while logging a reason
        -- that sounded plausible. Exactly the shape this whole audit keeps
        -- finding, written while fixing it.
        if #rows_for(net.guild_of_sender(comp)) == 0 then
            log.debug("no camps loaded for that guild yet, so nothing was " ..
                "sent and the client will ask again")
            return
        end
    end

    local sent = false
    local ok, err = pcall(function()
        sent = net.push_pals(rows_for, comp, only_key)
    end)
    if not ok then
        log.warn("stand push failed: " .. tostring(err))
        return
    end

    log.debug("stand push: " .. (only_key and ("1 row of " .. seen) or
        (seen .. " pal(s)")) .. ", sent=" .. tostring(sent))
end

net.on_command = function(command, _, comp)
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
        local sender_guild = net.guild_of_sender(comp)

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
        for _, row in ipairs(stand_rows(sender_guild)) do
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

        if prio == nil then store.apply_clear(key, value)
        else store.apply_set(key, value, prio) end

        log.say(string.format("priority %s set to %s by a player",
            workdefs.ORDER[value] or tostring(value), tostring(raw)))

        -- Pushed explicitly, and this was removed once on the reasoning that
        -- store.apply_set fires store.on_change which does the same job. The
        -- reasoning was sound and the result was that NOTHING was pushed:
        -- every edit applied on the server and no client was ever told. The
        -- log said so plainly - a priority line with no stand push after it.
        --
        -- So the explicit call is back, because a duplicate push is a cost and
        -- a missing one is a broken feature. Whether on_change fires at all is
        -- now logged rather than assumed.
        push_stand(nil, key)
        run_pass("priority change")
        return
    end

    if verb == net.PREFIX .. "Set" and #parts >= 4 then
        if not may_change(comp) then return end
        local guild = net.guild_of_sender(comp)
        if not caps.apply_set(parts[2], parts[3], parts[4], guild) then
            return
        end

        log.say(string.format("%s set %s to %s by a player",
            parts[2], parts[3], parts[4]))
        net.push_rules(caps, cfg, nil)
        run_pass("rule change")
        return
    end

    if verb == net.PREFIX .. "Clear" and #parts >= 3 then
        if not may_change(comp) then return end
        if not caps.apply_clear(parts[2], parts[3],
            net.guild_of_sender(comp)) then
            -- Refused, so the asking client is still drawing a rule it
            -- believes it deleted. Pushing the unchanged set back corrects it
            -- on the next refresh instead of leaving the panel and the server
            -- quietly disagreeing until something else happens to sync them.
            net.push_rules(caps, cfg, comp)
            return
        end

        log.say(string.format("%s %s cleared by a player", parts[2], parts[3]))
        net.push_rules(caps, cfg, nil)
        run_pass("rule change")
        return
    end
end

-- Client side. The server sent state; take it as the truth.
local incoming = nil

net.on_state = function(message)
    local parts = net.split(message)
    local verb = parts[1]

    if verb == net.PREFIX .. "Reset" then
        incoming = {}
        return
    end

    if verb == net.PREFIX .. "Rule" and #parts >= 4 and incoming then
        -- Bounded while it accumulates, not only when it is applied.
        --
        -- replace_all caps what it keeps, but the batch is built here first -
        -- so a server that never sends Done can grow this table until the
        -- client runs out of memory, and nothing would have stopped it. The
        -- ceiling is caps.MAX_RULES with slack, since anything past it is
        -- dropped anyway.
        if #incoming < (caps.MAX_RULES or 500) * 2 then
            incoming[#incoming + 1] = {
                work = parts[2], item = parts[3], amount = parts[4],
            }
        end
        return
    end

    if verb == net.PREFIX .. "Done" then
        -- Swapped in whole, only once the batch has ended. Applying each rule
        -- as it lands would leave the panel showing a half built list every
        -- time the server pushed.
        if incoming then
            caps.replace_all(incoming)
            log.debug("rules updated from the server, " .. #incoming .. " of them")
            incoming = nil
        end
        return
    end
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
    store.decided = true
    caps.decided = true

    -- Probed once here and remembered, which is the whole point of doing this
    -- on a timer: every later caller reads a boolean instead of walking the
    -- object array. A client's grid repaint asked this twice per cell, so a
    -- fourteen column grid over fifteen pals paid four hundred full array
    -- walks - seconds of game thread - for one clicked cell.
    if api.latch_authority() then
        caps.submit = nil

        -- The authority tells everyone when its own rules move. Set here
        -- rather than at load for the same reason submit is: there is no world
        -- when a mod starts, so this question has no answer yet.
        caps.on_change = function()
            pcall(function() net.push_rules(caps, cfg, nil) end)
        end

        -- Same for priorities. A change made at the server's own keyboard
        -- reaches every client the same way a client's request does, so the
        -- grid is the same picture wherever it is opened.
        store.submit = nil
        store.on_change = function(key)
            pcall(function() push_stand(nil, key) end)
        end
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

-- The world the caches were built against. nil until the first spawn.
local world_key = nil

-- Said once. The decision it reports is re-made on every spawn now, and
-- a player does not need telling on each death that this is a client.
local said_client_warning = false

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
  -- Every line below runs under one pcall.
  --
  -- Nine calls ran bare here. If any of them threw - and panel.reset reaches
  -- into icons, overlay and the whole widget tree - everything after it was
  -- skipped, so net.reset, overlay.reset, demandidx.install and all four
  -- delayed starts silently did not happen and the mod came up half reset
  -- with nothing in the log.
  local ok, err = pcall(function()

    -- ClientRestart fires on every spawn, not only on a world load, so this
    -- also ran on every death. That wiped the demand index, the hold timers,
    -- the stock cache and every icon cache, and re-queued four one-shots -
    -- after which the scheduler saw no demand and idle-skipped every camp for
    -- up to forty five seconds. Dying is not a world change, so the caches
    -- only go when the world key actually moves.
    local now_key = api.world_key()
    local switched = (now_key == nil) or (now_key ~= world_key)

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
    else
        log.debug("respawn in the same world, caches kept")
    end

    -- Printed so the question can be answered from a log rather than argued.
    --
    -- world_key is the level's own object path, and Palworld runs one
    -- persistent map - so it is not obvious that single player and a dedicated
    -- server produce different strings. If they do not, "switched" is false for
    -- every reconnect and the whole reset list stops running. Play solo once,
    -- join the server once, compare these two lines.
    if switched then
        log.say("world key: " .. tostring(now_key))
    end

    world_key = now_key

    -- Registration is idempotent and cheap; this covers a world load that
    -- happened before the class existed.
    demandidx.install()

    -- Fetch the blueprint widget's class ahead of anyone wanting it: the
    -- lookup answers through a callback on the game thread, and a panel
    -- opened while it was in flight would open on the wrong host. Guarded
    -- because overlay hot-swaps and this file does not.
    if overlay.prepare then
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
        clock.once(18000, function()
            if not api.has_authority() then
                if net.to_server(net.PREFIX .. "Hello", 1) then
                    log.debug("announced to the server, waiting for the rules")
                end
            end
        end)

        if cfg.run_on_world_load then
            -- Base camps and their worker slots are not populated the instant
            -- the controller restarts, so the first look is late on purpose.
            clock.once(15000, function() run_pass("world load") end)

            -- One question, asked once: does the game hand out item icons
            -- itself? If it does, most of icons.lua stops being necessary.
            clock.once(25000, function()
                pcall(function() icons.data_probe() end)
            end)
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
    clock.once(2000, function() decide_write_or_send() end)
    clock.once(20000, function()
        decide_write_or_send()

        if not api.has_authority() and not said_client_warning then
            said_client_warning = true
            log.warn("no authority here, so this looks like a client on " ..
                "a dedicated server. No passes will run on this machine " ..
                "and the priorities are the server's - it sends them " ..
                "down for the Monitoring Stand grid to draw, and your " ..
                "edits go back up to it.")
        end
    end)

    start_timer()
    start_ui()

  end)

  if not ok then
      log.warn("world load handler threw: " .. tostring(err))
  end
end)

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
        RegisterHook(path, function() end, function(_, ReturnValue)
            -- The game's own answer, read BEFORE we override it, and kept on
            -- palapi because that module is never swapped. It is the only way
            -- anything else can ask "does the GAME have UI up" without reading
            -- back our own lie and believing it.
            pcall(function()
                api.game_ui_active = (ReturnValue:get() == true)
            end)

            if not (panel and panel.open) then return end

            -- Both shapes. Some UE4SS builds take the returned value, others
            -- want the out parameter written, and which one this build wants
            -- is not worth a separate experiment when doing both is free.
            pcall(function() ReturnValue:set(true) end)
            return true
        end)
    end)
    if not ok then
        log.debug("overlay gate: could not hook " .. path)
    end
end

RegisterHook("/Script/Pal.PalUIChat:OnReceivedChat", function(context, message)
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
end)

-- A keybind that fails to register does so silently, which then reads as
-- "the mod is broken" the first time a key does nothing. Report it.
local function bind(key, label, fn, modifiers)
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
    end)
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

-- Esc closes the panel, so it can never be open while the game's own menu is.
--
-- Both of the cursor faults came from those two overlapping. With the panel
-- open, Esc opens Palworld's menu and changes nothing here; then either the
-- second Esc closes that menu and takes the cursor with it while this panel is
-- still up, or closing this panel first calls SetInputMode_GameOnly and takes
-- the cursor away from the menu, which is still up. Same collision, either
-- order, and in both cases the pointer is gone until Esc is pressed again.
--
-- overlay.reassert_input covers the first. This covers the second, and is the
-- better half of the pair because it stops the overlap happening at all
-- rather than repairing it afterwards.
--
-- Close only, never toggle: with the panel shut this is a no-op and the game's
-- own Esc is untouched, which is the shape BreedingHelper settled on for the
-- same reason. Unmodified, because Esc is Esc.
bind(Key.ESCAPE, "Esc (close the rules panel)", function()
    if panel.open then
        pcall(function() panel.toggle() end)
    end
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
        { "UP_ARROW",    function() return panel.nav(cfg, "up") end },
        { "DOWN_ARROW",  function() return panel.nav(cfg, "down") end },
        { "RIGHT_ARROW", function() return panel.nav(cfg, "right") end },
        { "LEFT_ARROW",  function() return panel.nav(cfg, "left") end },
        { "RETURN",      function() return panel.nav(cfg, "enter") end },
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
