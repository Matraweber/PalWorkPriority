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
-- panel and overlay are fetched at call time rather than captured here.
--
-- reload.lua replaces them in package.loaded while the game runs, and a local
-- taken at load would go on pointing at the old copy for the rest of the
-- session. require on an already loaded module is a table lookup, so calling
-- these costs nothing worth measuring.
local function panel() return require("panel") end
local function overlay() return require("overlay") end

local reload = require("reload")
local icons = require("icons")
local net = require("net")
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
reload.path = DIR .. "reload.trigger"
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

-- explicit marks a pass asked for by hand. Those always report something,
-- even when there was nothing to do: a keypress with no output at all is
-- indistinguishable from a mod that failed to load.
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

-- The grid needs its own cadence: the stand can be opened at any moment and
-- numbers that appear a pass later read as broken. This only looks for the
-- menu, and finds nothing while the stand is shut.
local ui_running = false

-- Milliseconds of grid time owed, so the stand grid keeps its slow cadence
-- while the panel runs fast.
local grid_owed = 0

local tick_error = nil

local function ui_tick()
    if not ui_running then return end

    -- A menu that answers once a second is not a menu. The panel redrew on
    -- this one second tick, so a hover highlight took up to a second to
    -- follow the pointer, which is what "laggy and unresponsive" was: not
    -- the cost of a frame, the wait between frames. It also let the mouse
    -- and the keyboard disagree about the current row long enough for two of
    -- them to be marked at once.
    -- Everything below is guarded, and the reschedule at the end is not.
    --
    -- That order matters more than it looks. panel() is a require, and a
    -- require throws when the module it fetches has an error in it. Before
    -- this, one bad edit reloaded into a dead mod: the accessor threw here,
    -- the tick never reached its own reschedule, and nothing ran again until
    -- the game was restarted. A reload loop where a mistake costs a restart
    -- is not a reload loop.
    local delay = 1000

    local function body()
        delay = panel().fast() and 100 or 1000
        grid_owed = grid_owed + delay

        -- Runs even when disabled, so the grid still reflects edits. It costs
        -- nothing while the stand is shut.
        if cfg then
            ExecuteInGameThread(function()
                -- The grid stays on its second, because refreshing it means a
                -- FindAllOf over every cell and it has nothing to gain from ten
                -- times the rate.
                if grid_owed >= 1000 then
                    grid_owed = 0
                    pcall(function() ui.refresh(cfg) end)
                end

                -- Drawn independently: the panel opens on a hotkey and has to
                -- keep working with the stand shut.
                pcall(function() panel().refresh(cfg) end)

                -- Checked here rather than on a timer of its own, so a reload
                -- can never land between two halves of a draw.
                pcall(function() reload.poll() end)
            end)

            if panel().wants_pass then
                panel().wants_pass = false
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

    local ok, err = pcall(body)
    if not ok then
        -- Said once per distinct complaint rather than ten times a second,
        -- which is what an error in a redraw would otherwise produce.
        if tick_error ~= tostring(err) then
            tick_error = tostring(err)
            log.warn("tick: " .. tick_error)
        end
    elseif tick_error then
        tick_error = nil
        log.say("tick: recovered")
    end

    ExecuteWithDelay(delay, ui_tick)
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
    log.say("  " .. p .. " limit     set a stock ceiling for a work type")
    log.say("  " .. p .. " scope     ceilings per base, or across loaded bases")
    log.say("  " .. p .. " net       transport state, and echo test")
    log.say("  " .. p .. " discover  write Discovery.txt")
    log.say("keys, Ctrl does a thing:")
    log.say("  Ctrl+F8 transport test   Ctrl+F9  work rules")
    log.say("  Ctrl+F10 run a pass      Ctrl+F11 Discovery.txt")
    log.say("  Ctrl+F12 base storage")
    log.say("keys, Alt changes a setting:")
    log.say("  Alt+F10 mode   Alt+F11 pals per work   Alt+F12 storage scope")
    log.say("in the rules panel: up and down move, right raises, left lowers")
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
                totals[id] = (totals[id] or 0) + n
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
    local all = caps.all(cfg)

    local works = {}
    for work in pairs(all) do works[#works + 1] = work end
    table.sort(works)

    if #works == 0 then
        log.say("no stock limits set")
        log.say("  " .. cfg.chat_prefix .. " limit Lumbering Wood 5000")
        log.say("run " .. cfg.chat_prefix .. " stock for the item ids this base holds")
        return
    end

    ExecuteInGameThread(function()
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

    ExecuteInGameThread(function()
        local totals = stock_across_camps()

        if clearing then
            local id = match_stock_id(totals, item_text) or item_text
            if caps.clear(work, id) then
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

            caps.set(work, id, math.floor(ceiling))
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

    if verb == net.PREFIX .. "Set" and #parts >= 4 then
        caps.apply_set(parts[2], parts[3], tonumber(parts[4]) or 0)
        log.say(string.format("%s set %s to %s by a player",
            parts[2], parts[3], parts[4]))
        net.push_rules(caps, cfg, nil)
        run_pass("rule change")
        return
    end

    if verb == net.PREFIX .. "Clear" and #parts >= 3 then
        caps.apply_clear(parts[2], parts[3])
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
        incoming[#incoming + 1] = {
            work = parts[2], item = parts[3], amount = tonumber(parts[4]) or 0,
        }
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
if not api.has_authority() then
    caps.submit = function(kind, work, item, amount)
        if not net.request(kind, work, item, amount) then
            log.say("could not reach the server, that change was not made")
            return false
        end
        return true
    end
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    -- Engine wrappers do not survive a world switch, and neither should any
    -- memo built from them.
    api.reset()
    scheduler.forget()
    demandidx.reset()
    ui.reset()
    items.reset()
    panel().reset()
    net.reset()
    overlay().reset()
    -- Registration is idempotent and cheap; this covers a world load that
    -- happened before the class existed.
    demandidx.install()

    -- Fetch the blueprint widget's class ahead of anyone wanting it. The
    -- lookup has to happen on the game thread and answers through a callback,
    -- so a panel opened while it was still in flight would open on the wrong
    -- host. Asking at world load means the answer is there long before
    -- anybody presses anything.
    ExecuteWithDelay(25000, function()
        pcall(function() overlay().prepare() end)
    end)

    -- A client announces itself so the server knows to push rules to it, and
    -- gets the current set back in reply. Delayed with everything else,
    -- because the network component does not exist the instant a world loads.
    ExecuteWithDelay(18000, function()
        if not api.has_authority() then
            if net.to_server(net.PREFIX .. "Hello", 1) then
                log.debug("announced to the server, waiting for the rules")
            end
        end
    end)

    -- Checked here rather than at load. There is no world when a mod starts,
    -- so PalGameMode does not exist yet and every single player session
    -- reported itself as a client on a dedicated server.
    ExecuteWithDelay(20000, function()
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

-- Every key here is Ctrl or Alt with a function key, and every one was
-- checked against the other installed mods with tools/keybind_audit.py rather
-- than by eye. Two collisions were found that way and both had been missed by
-- grepping: FreeCam sets its key and its modifier lines apart so Alt+F8 reads
-- as plain F8, and UltraGraphics registers through a wrapper so its plain F10
-- never appeared in a search for RegisterKeyBind at all.
--
-- Ctrl does a thing, Alt changes a setting.
bind(Key.F10, "Ctrl+F10 (run pass)", function()
    run_pass("keybind", true)
end, { ModifierKey.CONTROL })

log.say(string.format("%s %s loaded (%s, %s). Type '%s help' in chat.",
    MOD_NAME, VERSION,
    cfg.enabled and "enabled" or "disabled",
    cfg.dry_run and "dry run" or "live",
    cfg.chat_prefix))

-- Chat input is not reliably available in every singleplayer session, so the
-- discovery dump gets its own key instead of living only behind a chat
-- command. F10/F11 were picked because every other Fn key in the low range
-- is already claimed by another installed mod.
bind(Key.F11, "Ctrl+F11 (discovery)", function()
    COMMANDS.discover()
end, { ModifierKey.CONTROL })

-- Base storage on a key too. Ceilings are keyed by internal item id, and
-- without a way to print those ids outside chat the whole feature is
-- unreachable in a session where chat input is not available.
bind(Key.F12, "Ctrl+F12 (stock)", function()
    COMMANDS.stock()
end, { ModifierKey.CONTROL })

-- Left click raises a cell towards priority 1, right click lowers it towards
-- never. cfg is passed as a getter because '!pwp reload' replaces the table.
do
    local n = ui.bind_mouse(function() return cfg end, function(dir)
        return panel().handle_click(cfg, dir)
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

-- The rules panel. F9 is taken by another installed mod and F8 by two, so
-- this sits on the modifier alongside the other toggles.
bind(Key.F9, "Ctrl+F9 (work rules)", function()
    panel().toggle()
end, { ModifierKey.CONTROL })

-- The transport test needs a key of its own, because the machine most worth
-- running it on is a client in single player, where there is no chat box to
-- type a command into. Ctrl rather than Alt: Alt+F8 is FreeCam's toggle.
bind(Key.F8, "Ctrl+F8 (transport test)", function()
    COMMANDS.net()
end, { ModifierKey.CONTROL })

-- The panel draws its boxes but no text, and every input mode call failed.
-- Both are the API not being shaped as assumed, so this asks it directly
-- rather than guessing a second time.
bind(Key.F7, "Ctrl+F7 (icon probe)", function()
    ExecuteInGameThread(function()
        pcall(function() overlay().icon_probe() end)
        pcall(function() icons.report() end)
    end)
end, { ModifierKey.CONTROL })

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
        { "UP_ARROW",    function() return panel().nav(cfg, "up") end },
        { "DOWN_ARROW",  function() return panel().nav(cfg, "down") end },
        { "RIGHT_ARROW", function() return panel().nav(cfg, "right") end },
        { "LEFT_ARROW",  function() return panel().nav(cfg, "left") end },
        { "RETURN",      function() return panel().nav(cfg, "enter") end },
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
