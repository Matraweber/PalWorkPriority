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

local MOD_NAME = "Pal Work Priority"
local VERSION = "0.1.0"

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
remote.path = DIR .. "remote.txt"
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
        elseif prio ~= false and (type(prio) ~= "number" or prio < 1) then
            log.warn("config.work_priority['" .. name .. "'] should be a number >= 1 or false")
        end
    end

    -- A ceiling on a work type that does not exist, or one whose value is
    -- not a number, would never fire. Say so rather than let someone
    -- believe a cap is in force.
    c.work_caps = c.work_caps or {}
    for name, caps in pairs(c.work_caps) do
        if not workdefs.is_known(name) then
            log.warn("config.work_caps has unknown work type '" .. tostring(name) .. "'")
        elseif type(caps) ~= "table" then
            log.warn("config.work_caps['" .. name .. "'] should be a table of item = amount")
        else
            for item, ceiling in pairs(caps) do
                if type(ceiling) ~= "number" then
                    log.warn("config.work_caps['" .. name .. "']['" .. tostring(item) ..
                        "'] should be a number")
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
    local chunk, load_err = loadfile(SCRIPT_DIR .. "config.lua")

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

    cfg = validate(loaded)
    log.set_level(cfg.log_level)
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
        return
    end

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
    if grid_owed >= 1000 then
        grid_owed = 0
        pcall(function() ui.refresh(cfg) end)
    end

    -- Icons resolved ahead of being drawn, a few per beat.
    --
    -- Looking one up costs an engine call, and doing it while a tile is being
    -- drawn puts that cost on the frame that can least afford it. This gets
    -- the answers known before anybody opens the picker, and it stands aside
    -- whenever the loader has real work queued.
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
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local COMMANDS = {}

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
    log.say("  " .. p .. " cap       cycle max pals per work type")
    log.say("  " .. p .. " stock     print base storage by item id")
    log.say("  " .. p .. " limit     set a stock ceiling for a work type")
    log.say("  " .. p .. " scope     ceilings per base, or across loaded bases")
    log.say("  " .. p .. " net       transport state, and echo test")
    log.say("  " .. p .. " discover  write Discovery.txt")
    log.say("  " .. p .. " guilds    write Guilds.txt")
    log.say("  " .. p .. " icons     probe the overlay icons")
    log.say("  " .. p .. " restore   give every pal its work back, unfence")
    log.say("keys, all on Alt, because Ctrl is crouch:")
    log.say("  Alt+F1 work rules        Alt+F2 run a pass")
    log.say("  Alt+F3 base storage      Alt+F5 Discovery.txt")
    log.say("  Alt+F9 transport test")
    log.say("keys that change a setting:")
    log.say("  Alt+F10 mode   Alt+F11 pals per work   Alt+F12 storage scope")
    log.say("in the rules panel: up and down move, right raises, left lowers")
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
        or "NO, this is a client. Work is estimated from the camp's own work " ..
           "objects, because the server's pulses never reach a client"))
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
COMMANDS.cap = function()
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
local function restore_all(why)
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

    local sent, rounds = 0, 0

    repeat
        rounds = rounds + 1
        local stats = scheduler.restore(cfg)
        sent = sent + stats.toggles
        local owed = stats.deferred
    until owed == 0 or rounds >= 12

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

            caps.set(work, id, math.floor(ceiling), api.my_guild())
            log.say(string.format("limit set: %s pauses at %d %s, base holds %d",
                workdefs.label(work), math.floor(ceiling), id, totals[id] or 0))
        end

        scheduler.forget()
        run_pass("limit change", true)
    end)
end

local function handle_command(text)
    local prefix = cfg.chat_prefix
    if text:sub(1, #prefix):lower() ~= prefix:lower() then return false end

    local rest = text:sub(#prefix + 1):match("^%s*(.-)%s*$") or ""
    local verb = rest:match("^(%S+)") or "help"
    local args = rest:match("^%S+%s+(.*)$") or ""

    local fn = COMMANDS[verb:lower()]
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

net.on_command = function(command, _, comp)
    local parts = net.split(command)
    local verb = parts[1]

    if verb == net.PREFIX .. "Hello" then
        -- A modded client announced itself, so send it the world as it
        -- stands. Its own component, not a broadcast: an unmodded client
        -- must receive nothing at all.
        net.push_rules(caps, cfg, comp)
        log.debug("a modded client said hello, sent it the rules")
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
    if api.has_authority() then
        caps.submit = nil
        return
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

    -- A client announces itself so the server knows to push rules to it, and
    -- gets the current set back in reply. Delayed with everything else,
    -- because the network component does not exist the instant a world loads.
    clock.once(18000, function()
        if not api.has_authority() then
            if net.to_server(net.PREFIX .. "Hello", 1) then
                log.debug("announced to the server, waiting for the rules")
            end
        end
    end)

    -- Checked here rather than at load. There is no world when a mod starts,
    -- so PalGameMode does not exist yet and every single player session
    -- reported itself as a client on a dedicated server.
    clock.once(20000, function()
        decide_write_or_send()

        if not api.has_authority() then
            log.warn("no authority here, so this looks like a client on a " ..
                "dedicated server. Work demand will be estimated from the " ..
                "camp's own work objects rather than read from the server's " ..
                "pulses, which is coarser.")
        end
    end)

    if cfg.run_on_world_load then
        -- Base camps and their worker slots are not populated the instant
        -- the controller restarts, so the first look is late on purpose.
        clock.once(15000, function() run_pass("world load") end)


        -- One question, asked once: does the game hand out item icons itself?
        -- If it does, most of icons.lua stops being necessary.
        clock.once(25000, function()
            pcall(function() icons.data_probe() end)
        end)
    end
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

RegisterHook("/Script/Pal.PalUIChat:OnReceivedChat", function(context, message)
    local ok, err = pcall(function()
        local received = message:get()
        if not (received and received.Message) then return end
        handle_command(received.Message:ToString())
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
bind(Key.F2, "Alt+F2 (run pass)", function()
    run_pass("keybind", true)
end, { ModifierKey.ALT })

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
bind(Key.F3, "Alt+F3 (stock)", function()
    COMMANDS.stock()
end, { ModifierKey.ALT })

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
bind(Key.F10, "Alt+F10 (mode)", function()
    COMMANDS.mode()
end, { ModifierKey.ALT })

bind(Key.F11, "Alt+F11 (cap)", function()
    COMMANDS.cap()
end, { ModifierKey.ALT })

-- Single player has no chat box, so every command behind the chat prefix is
-- unreachable there. Anything that changes what the mod does needs a key as
-- well, or it may as well not exist for a single player game.
bind(Key.F12, "Alt+F12 (storage scope)", function()
    COMMANDS.scope()
end, { ModifierKey.ALT })

-- The rules panel, on the lowest free key, because it is the one a player
-- reaches for most and F1 is where a hand goes looking for a panel.
bind(Key.F1, "Alt+F1 (work rules)", function()
    panel.toggle()
end, { ModifierKey.ALT })

-- The transport test needs a key of its own, because the machine most worth
-- running it on is a client in single player, where there is no chat box to
-- type a command into. F9 rather than F8: Alt+F8 is FreeCam's toggle, and the
-- plain F9 that BaseTrimmer and UltraGraphics claim is a different binding.
bind(Key.F9, "Alt+F9 (transport test)", function()
    COMMANDS.net()
end, { ModifierKey.ALT })

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
