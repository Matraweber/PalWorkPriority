-- Pal Work Priority
--
-- Numeric work priorities for base pals, driven from config.lua. Priority 1
-- work is staffed before priority 5 work, and within a priority the best
-- suited pal takes the job.
--
-- The mod does not hand pals jobs. It decides which work types each pal may
-- do right now and switches the rest off through
-- RequestChangeWorkSuitability_ToServer — the same flag the vanilla
-- checkboxes write — leaving Palworld's own AI to choose within that fence.

local log = require("log")
local api = require("palapi")
local workdefs = require("workdefs")
local scheduler = require("scheduler")
local discover = require("discover")
local ui = require("ui")
local store = require("store")
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

-- Output goes to the mod root rather than Scripts/, because redeploying
-- replaces Scripts/ wholesale and would take the log with it.
local SCRIPT_DIR = script_dir()
local DIR = SCRIPT_DIR:match("^(.*[\\/])[Ss]cripts[\\/]$") or SCRIPT_DIR

log.file_path = DIR .. "priority.log"
store.load(DIR .. "priorities.txt")

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local cfg = nil
local timer_running = false

local function validate(c)
    if type(c.work_priority) ~= "table" then
        log.error("config.work_priority is not a table — using an empty one")
        c.work_priority = {}
    end

    for name, prio in pairs(c.work_priority) do
        if not workdefs.is_known(name) then
            log.warn("config.work_priority has unknown work type '" .. tostring(name) ..
                "' — check the spelling against workdefs.lua")
        elseif prio ~= false and (type(prio) ~= "number" or prio < 1) then
            log.warn("config.work_priority['" .. name .. "'] should be a number >= 1 or false")
        end
    end

    -- A ceiling on a work type that does not exist, or one whose value is
    -- not a number, would simply never fire. Say so rather than let someone
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
                tostring(c.assignment_mode) .. "' — using spread")
        end
        c.assignment_mode = "spread"
    end

    -- false and nil both mean no limit; anything else has to be a count.
    if c.max_pals_per_work_type ~= nil and c.max_pals_per_work_type ~= false then
        local n = tonumber(c.max_pals_per_work_type)
        if not n or n < 1 then
            log.warn("config.max_pals_per_work_type should be a number >= 1 or false" ..
                " — treating as no limit")
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
    package.loaded["config"] = nil
    local ok, loaded = pcall(require, "config")
    if not ok or type(loaded) ~= "table" then
        log.error("config.lua failed to load: " .. tostring(loaded))
        return false
    end

    cfg = validate(loaded)
    log.set_level(cfg.log_level)
    return true
end

-- ---------------------------------------------------------------------------
-- Passes
-- ---------------------------------------------------------------------------

-- explicit marks a pass the user asked for by hand. Those always report
-- something, even when there was nothing to do: a keypress that produces no
-- output at all is indistinguishable from a mod that is not loaded, and
-- sends you debugging the wrong thing.
local function run_pass(reason, explicit)
    if not cfg then return end

    if not cfg.enabled then
        if explicit then
            log.say(reason .. ": disabled — '" .. cfg.chat_prefix .. " on' to enable")
        end
        return
    end

    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local stats = scheduler.run_pass(cfg)
            if stats.camps > 0 then
                log.info(reason .. ": " .. scheduler.format_stats(cfg, stats))
            elseif explicit then
                log.say(reason .. ": no base camp loaded. Camps only exist while " ..
                    "streamed in, so stand inside your base and try again.")
            end
        end)
        if not ok then
            log.error("pass failed: " .. tostring(err))
        end
    end)
end

local function tick()
    if not timer_running then return end
    run_pass("tick")
    ExecuteWithDelay(cfg.interval_seconds * 1000, tick)
end

local function start_timer()
    if timer_running then return end
    timer_running = true
    ExecuteWithDelay(cfg.interval_seconds * 1000, tick)
end

-- The stand panel needs its own cadence. A pass runs every 30s, but the menu
-- can be opened at any moment and a panel that appears half a minute late is
-- worse than none. This only looks for the menu; when the stand is shut it
-- finds nothing and stops there.
local ui_running = false

local function ui_tick()
    if not ui_running then return end
    -- Runs even when the mod is disabled: compose() renders an OFF state, and
    -- gating here instead would freeze the panel showing DRY RUN or LIVE for
    -- the rest of the session after '!pwp off'. refresh() costs nothing while
    -- the stand is shut.
    if cfg then
        ExecuteInGameThread(function()
            pcall(function() ui.refresh(cfg, scheduler.last_report) end)
        end)

        -- A priority just changed on the stand. Re-fence now rather than
        -- leaving the edit inert until the next 30s tick, which reads as the
        -- click having done nothing.
        if ui.wants_pass then
            ui.wants_pass = false
            run_pass("edit")
        end
    end
    ExecuteWithDelay(1000, ui_tick)
end

local function start_ui()
    if ui_running then return end
    ui_running = true
    ExecuteWithDelay(1000, ui_tick)
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
    log.say("  " .. p .. " discover  write Discovery.txt")
    log.say("keys: F10 pass, F11 Discovery.txt, F12 stock,")
    log.say("      Alt+F10 mode, Alt+F11 cap")
end

COMMANDS.status = function()
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
    log.say("  work pulses seen: " .. demandidx.pulses ..
        (demandidx.pulses == 0 and "  (demand is being ESTIMATED)" or ""))
    log.say("  mode: " .. tostring(cfg.assignment_mode) .. ", max per work type: " ..
        (cfg.max_pals_per_work_type and tostring(cfg.max_pals_per_work_type) or "no limit"))
end

COMMANDS.run = function()
    run_pass("manual", true)
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

COMMANDS.dry = function()
    cfg.dry_run = true
    log.say("dry run on — assignments will be logged, not sent")
end

COMMANDS.live = function()
    cfg.dry_run = false
    scheduler.forget()
    log.say("live — assignments will be sent to the server")
end

COMMANDS.on = function()
    cfg.enabled = true
    start_timer()
    start_ui()
    log.say("enabled")
end

COMMANDS.off = function()
    cfg.enabled = false
    log.say("disabled")
end

COMMANDS.reload = function()
    if load_config() then
        scheduler.forget()
        log.say("config reloaded")
        COMMANDS.status()
    end
end

COMMANDS.discover = function()
    ExecuteInGameThread(function()
        discover.run(DIR .. "Discovery.txt")
    end)
end

-- Prints what the base is actually holding, by internal item id. Those ids
-- are what work_caps keys on, and guessing their spelling is the easiest way
-- to write a ceiling that silently never triggers.
COMMANDS.stock = function()
    ExecuteInGameThread(function()
        local camps = api.base_camps()
        if #camps == 0 then
            log.say("no camps loaded — stand in your base and try again")
            return
        end

        local path = DIR .. "Stock.txt"
        local f = io.open(path, "wb")
        if f then f:write("base storage " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n") end

        for ci, camp in ipairs(camps) do
            local totals, chests = api.camp_item_totals(api.guid_key(api.camp_id(camp)))

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
                log.say("  no chests answered — ceilings would read as unmet")
            end
        end

        if f then
            f:close()
            log.say("written to " .. path)
        end
    end)
end

local function handle_command(text)
    local prefix = cfg.chat_prefix
    if text:sub(1, #prefix):lower() ~= prefix:lower() then return false end

    local rest = text:sub(#prefix + 1):match("^%s*(.-)%s*$") or ""
    local verb = rest:match("^(%S+)") or "help"

    local fn = COMMANDS[verb:lower()]
    if fn then
        local ok, err = pcall(fn)
        if not ok then log.error("command '" .. verb .. "' failed: " .. tostring(err)) end
    else
        log.say("unknown command '" .. verb .. "' — try " .. prefix .. " help")
    end
    return true
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

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    -- Engine wrappers do not survive a world switch, and neither should any
    -- memo built from them.
    api.reset()
    scheduler.forget()
    demandidx.reset()
    ui.reset()
    -- Registration is idempotent and cheap; this covers a world load that
    -- happened before the class existed.
    demandidx.install()

    if cfg.run_on_world_load then
        -- Base camps and their worker slots are not populated the instant
        -- the controller restarts, so the first look is deliberately late.
        ExecuteWithDelay(15000, function() run_pass("world load") end)
    end
    start_timer()
    start_ui()
end)

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

bind(Key.F10, "F10 (run pass)", function()
    run_pass("keybind", true)
end)

log.say(string.format("%s %s loaded — %s, %s. Type '%s help' in chat.",
    MOD_NAME, VERSION,
    cfg.enabled and "enabled" or "disabled",
    cfg.dry_run and "dry run" or "live",
    cfg.chat_prefix))

-- Chat input is not reliably available in every singleplayer session, so the
-- discovery dump gets its own key instead of living only behind a chat
-- command. F10/F11 were picked because every other Fn key in the low range
-- is already claimed by another installed mod.
bind(Key.F11, "F11 (discovery)", function()
    COMMANDS.discover()
end)

-- Base storage on a key too. Ceilings are keyed by internal item id, and
-- without a way to print those ids outside chat the whole feature is
-- unreachable in a session where chat input is not available.
bind(Key.F12, "F12 (stock)", function()
    COMMANDS.stock()
end)

-- Left click raises a cell towards priority 1, right click lowers it towards
-- never. cfg is passed as a getter because '!pwp reload' replaces the table.
do
    local n = ui.bind_mouse(function() return cfg end)
    if n < 2 then
        log.warn("only " .. n .. " of 2 mouse buttons bound — " ..
            "priority clicking will be partly unavailable")
    end
end

-- Toggles on modifiers rather than fresh F-keys: the plain ones are getting
-- crowded, and Alt+F10/F11 are clear of every keybind the other installed
-- mods claim. Ctrl is deliberately avoided near UE4SS's own Ctrl+H.
bind(Key.F10, "Alt+F10 (mode)", function()
    COMMANDS.mode()
end, { ModifierKey.ALT })

bind(Key.F11, "Alt+F11 (cap)", function()
    COMMANDS.cap()
end, { ModifierKey.ALT })
