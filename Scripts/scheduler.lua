-- The priority pass, as a fence rather than an assignment.
--
-- The mod does not hand pals jobs. It decides which work types each pal is
-- ALLOWED to do right now and switches the rest off, leaving the game's own
-- AI to choose within that. Assigning a pal to one specific work instead
-- leaves the AI free between jobs, which is how a pal ends up watering while
-- hauling waits.
--
-- Per camp, per pass:
--   1. count DEMAND per work type from the game's own pulses
--   2. walk priority levels 1..MAX, fencing each pal to the first level with
--      demand to spare
--   3. retain verified assignments, count every permission against staffing
--   4. reconcile idle camps as well as active camps
--   5. withdraw obsolete permissions before enabling replacements
--
-- Restoring is stateless: permissions are always "capable AND not X AND
-- (fenced-in OR unfenced)", so switching off restores "capable AND not X".
-- A fresh install captures the vanilla choices before its first write.

local log = require("log")
local caps = require("caps")
local api = require("palapi")
local workdefs = require("workdefs")
local store = require("store")
local demandidx = require("demand")
local trace = require("trace")
local allocator = require("scheduler_plan")
local permissions = require("scheduler_permissions")
local storage_scope = require("scheduler_storage")
local stock_prefetch = require("storage_prefetch")

local M = {}

-- Aggregate scopes only. around finishes its token even when a native adapter
-- throws; ordinary unprofiled passes avoid the extra protected call.
local function measured(label, fn, ...)
    if log.perf and log.around then return log.around(label, fn, ...) end
    return fn(...)
end

-- One pass never issues an unbounded number of RPCs. Steady state sends
-- almost nothing because only differences go out; this bounds the first pass
-- over a large base, and whatever is skipped is picked up next tick.
local MAX_TOGGLES_PER_PASS = 40

-- Only assignment identities and timestamps survive a pass; no wrappers.
local hold_since = {}
local permission_history = {}

-- Integration points for the authority/session layer. prepare_pal must return
-- true only after the pal's fresh-install baseline is safely established.
-- assignment_reader(pal, camp) must return plain evidence:
-- { id=stable job id, value=suitability, state="occupied"|"ready"|
--   "completed"|"unknown", manual=true|false|nil }.
-- Do not infer occupied/manual state from a suitability or a station name.
M.prepare_pal = nil
-- Native reader validated against the independent assignment census on RAM.
-- It resolves fresh actors within this pass and returns only plain evidence.
M.assignment_reader = require("assignments").read

-- Whether the "nothing owns a component" warn has already been said.
local said_no_component = false

-- What the bases were holding at the last pass, merged across camps.
--
-- Published because the panel needs the same numbers and was scanning every
-- container itself to get them, which is the most expensive thing this mod
-- does and it was doing it every three seconds on the game thread. The pass
-- already has the answer; it was throwing it away.
M.last_totals = {}
M.last_totals_by_guild = {}
M.last_storage = {}
M.last_totals_by_camp = {}
M.last_storage_by_camp = {}

-- work name -> { pass = n, camps = n, capped = n }, as the pass decided it.
--
-- Keyed by pass so a camp that stops being loaded drops out rather than
-- leaving a stale verdict behind: entries from an older pass are ignored and
-- overwritten the next time that work is considered.
M.last_capped = {}
M.pass_id = 0
local pass_totals = nil
local totals_guild, totals_ambiguous = nil, false

-- The fence itself is recomputed from demand every pass and remembers
-- nothing. The hold timers are the one exception, and a config reload or
-- world change should drop them.
-- How long a chest count stays good for.
--
-- The sweep is FindAllOf over everything derived from the container base
-- class, which on a built base is mostly walls, floors and fences, and it
-- calls GetBaseCampIdBelongTo on every one of them. Then for each real
-- container it walks ItemSlotArray reading ItemId.StaticId off each slot,
-- while pals are depositing into those same arrays.
--
-- BreedingHelper reads chests by exactly this route and is stable. It does it
-- when its window is open. This did it every ten seconds for the whole
-- session, which is both why the panel felt heavy and where the pass was
-- standing when it died on 21 August at 21:07 and again at 22:11.
--
-- Thirty seconds is three passes rather than one. A ceiling is a limit on
-- production, not a trigger that has to fire on the instant: the cost of the
-- delay is at most twenty extra seconds of a work type that was already at
-- its limit, against a sweep running a third as often.
-- Settable from outside with "pwp sweep <seconds>", because a fault that
-- takes twenty seven minutes to appear cannot be tested against. Zero makes
-- every pass sweep, and "pwp run" forces a pass on demand, so the two together
-- turn a half hour wait into as many sweeps as can be asked for.
M.stock_ttl = 30
local stock = {}
local guild_stock, guild_stock_key, guild_stock_at = {}, nil, nil
local guild_stock_failures = 0
local stock_interest = {}
local remote_stock_interest = {}

function M.forget(keep_permissions)
    stock_prefetch.reset()
    stock_interest = {}
    remote_stock_interest = {}
    api.last_storage_scan = nil
    hold_since = {}
    if not keep_permissions then permission_history = {} end
    stock = {}
    guild_stock, guild_stock_key, guild_stock_at = {}, nil, nil
    guild_stock_failures = 0

    -- The published figures go too. This is the world-switch reset, and the
    -- panel prefers last_totals over a fresh scan whenever it is non-empty -
    -- so leaving them behind showed the PREVIOUS world's storage, and the
    -- previous world's cap verdicts beside it, until the first pass of the
    -- new one happened to overwrite each entry. A flag that describes a world
    -- has to share that world's lifetime.
    M.last_totals = {}
    M.last_totals_by_guild = {}
    M.last_storage = {}
    M.last_totals_by_camp = {}
    M.last_storage_by_camp = {}
    M.last_capped = {}
    if not keep_permissions then M.pass_id = 0 end
end

-- Settings changes do not cancel an RPC already in transit. Main uses this
-- for mode/cap/live/reload/limit; only a session boundary uses forget().
function M.forget_policy()
    M.forget(true)
end

-- Called when the rules window opens, so what it shows is measured now
-- rather than up to half a minute old.
function M.forget_stock(panel_open)
    if panel_open==true and M.prefetch_enabled then
        -- Invalidate quantities as before, but let the established scalar
        -- scope request its fresh scan on a separate clock beat. A pass that
        -- arrives first retains the existing synchronous fallback.
        stock_prefetch.request_refresh()
    else
        stock_prefetch.reset()
        stock_interest = {}
    end
    api.last_storage_scan = nil
    stock = {}
    guild_stock, guild_stock_key, guild_stock_at = {}, nil, nil
    guild_stock_failures = 0
end

-- ---------------------------------------------------------------------------
-- Demand
-- ---------------------------------------------------------------------------

-- Whether a work type is suspended by its limits right now, and if it is not,
-- which of its items is still short.
--
-- A work type stops only when EVERY item listed for it has reached its
-- ceiling: one item still under means the job has something left to do. That
-- rule lives here, and the panel used to re-derive it per row as
-- `have >= rule.amount`, which is a different rule. With Mining limited on
-- both Stone and Ore, a full stone chest made the Stone row report itself
-- stopped while Mining carried on digging for Ore - the panel stating the
-- opposite of what the mod was doing. Exported so there is one answer to the
-- question instead of two.
--
-- The guild decides whose ceilings apply. A camp is only ever suspended by a
-- rule its own guild set, plus anything written in config or left over from
-- before guild scoping - never by another guild's ceiling, which used to
-- happen because there was one rule set for the whole machine.
function M.cap_state(cfg, work_name, totals, guild)
    local ceilings = caps.for_work(cfg, work_name, guild)
    if ceilings == nil then return false, nil end

    local listed, short = false, nil
    for item, ceiling in pairs(ceilings) do
        -- Only a number is a ceiling. A malformed one used to count towards
        -- `listed` while being impossible to satisfy, so the work type was
        -- capped for the rest of the session; config validation only warns
        -- about these, so a single typo in work_caps silently stopped a job
        -- and nothing said why.
        if type(ceiling) == "number" then
            listed = true
            if (totals[item] or 0) < ceiling then
                short = short or item
            end
        end
    end

    if not listed then return false, nil end
    return short == nil, short
end

local function cap_reached(cfg, work_name, totals, guild)
    return (M.cap_state(cfg, work_name, totals, guild))
end

-- Pending jobs per work type. A type whose resource ceiling is met
-- contributes nothing, which is what lets a ceiling release pals rather than
-- merely stop them.
--
-- Only reached by the estimated fallback, where `works` is every work object
-- the camp owns. That overstates demand badly: a cold campfire has one.
local function build_demand(cfg, works, totals, stats, guild)
    local demand = {}

    for _, w in ipairs(works) do
        local value, reason = api.work_suitability(w)
        local name = value and workdefs.name(value) or nil

        if name == nil then
            if reason == "ignored" then
                stats.ignored = stats.ignored + 1
            else
                stats.unknown_work = stats.unknown_work + 1
            end
        elseif cfg.work_priority[name] == nil then
            stats.unconfigured = stats.unconfigured + 1
        elseif cap_reached(cfg, name, totals, guild) then
            stats.capped = stats.capped + 1
        else
            -- A readable vacant slot is fallback demand evidence. Neither a
            -- failed read nor a full slot proves ready/occupied/completed.
            local free_slot
            local ok = pcall(function() free_slot = w:IsExistAssignableSlot() end)

            if ok and free_slot == true then
                demand[value] = (demand[value] or 0) + 1
                stats.needed = stats.needed + 1
            elseif ok and free_slot == false then
                stats.covered = stats.covered + 1
            else
                stats.unknown_work = stats.unknown_work + 1
            end
        end
    end

    return demand
end

-- ---------------------------------------------------------------------------
-- Planning the fence
-- ---------------------------------------------------------------------------

-- Every work type this pal is physically capable of and not barred from.
-- This is its permission set when nothing fences it, and what it is restored
-- to when the mod stops managing it.
-- Two sets, and conflating them was a real bug.
--
--   capable  every work type the pal has the skill for. This is the domain
--            apply_pal walks, so a type missing from it can never be switched
--            off, only left however the game last had it.
--   allowed  what the pal may actually do: capable, minus X, minus anything
--            whose rule is already satisfied.
--
-- An unfenced pal gets `allowed` as its plan. When those were one set, a
-- satisfied rule stopped the mod fencing anyone onto that work but never
-- withdrew the permission, so any pal that ended up unfenced had it switched
-- straight back on. That is a rule reading "done" while pals keep mining.
-- Public/manual passes enforce main's save and role boundary independently.
-- A failed capture leaves an in-memory row; a later edit can change `error`
-- back to `saving` without making that row durable.
local function settings_ready(stats, flush)
    if require('settings_gate').blocked() then
        stats.blocked=true;stats.blocked_reason=require('settings_gate').status()=='restart_required'
            and 'settings locked; restart the game' or 'settings recovery is in progress'
        return false
    end
    for _, source in ipairs({store, caps}) do
        local label = source == store and "priorities" or "limits"
        local ok = source.decided == true and source.is_client ~= true
            and (source.state == "saved" or source.state == "saving" or source.state == "missing")
        if ok and flush and source.state == "saving" then
            ok = type(source.flush) == "function" and source.flush(nil, true) == true
                and source.state == "saved"
        end
        if not ok then
            stats.blocked = true
            stats.blocked_reason = label .. " are not durable or authority-owned; permission updates blocked"
            return false
        end
    end
    -- A durability callback may have changed role while saving.
    if require('settings_gate').blocked() or store.decided ~= true or caps.decided ~= true or store.is_client == true
        or caps.is_client == true or store.state == "error" or caps.state == "error" then
        stats.blocked = true
        stats.blocked_reason = "settings changed during save; permission updates blocked"
        return false
    end
    return true
end

local function base_allowed(cfg, pal, capped)
    if store.decided ~= true or store.is_client == true
        or store.state == "error" or store.state == "unavailable"
        or not store.durable_key(pal.key) then return nil, nil end
    local capable, allowed = {}, {}
    pal.ranks, pal.priorities = {}, {}
    pal.permission_read_reuse_blocked = false

    for i = 1, #workdefs.ORDER do
        local name = workdefs.ORDER[i]
        local value = workdefs.value(name)

        -- Anyone is deliberately NOT in here, and the previous attempt to
        -- put it in made things worse.
        --
        -- `capable` is the domain apply_pal iterates to send toggles, so
        -- adding Anyone meant every fenced pal was sent "turn Anyone off" on
        -- every pass, for ever. Letting it through the rank gate as well
        -- would not have helped: nothing ever resolves a work object to
        -- suitability 14 - it appears in no entry of WORKTYPE_TO_SUIT or
        -- KEYWORDS - so demand[14] is always zero, the type is never wanted,
        -- and the fence never covers it. A permission that can never be
        -- granted and is withdrawn every pass is pure RPC churn, and it ate
        -- the toggle budget before X or a real fence change could use it.
        --
        -- Making Anyone work needs demand resolution for value 14, not a
        -- change here. Until something produces that demand,
        -- config.work_priority.Anyone is inert and this is the honest
        -- behaviour rather than a busy imitation of it.
        local rank = 0
        if name ~= workdefs.ANYONE then
            rank = api.suitability_rank(pal.param, value)
            if type(rank) ~= "number" or rank ~= rank or rank < 0 or rank == math.huge then
                return nil, nil
            end
        end
        if rank >= 1 then
            capable[value] = true
            pal.ranks[value] = rank
        end
    end

    -- Capture the actual vanilla choices before any fence has changed them.
    -- Only main's fresh-install decision enables this path. Upgrades must not
    -- reinterpret previously mod-written off flags as original player intent.
    local off = api.work_off_set(pal.param)
    if type(off) ~= "table" then return nil, nil end
    pal.observed_on = {}
    for value in pairs(capable) do
        if not off[value] then pal.observed_on[value] = true end
    end
    if store.baseline and store.data[pal.key] == nil then
        if type(off) ~= "table" or not store.capture_baseline(pal.key, capable, off) then
            return nil, nil
        end
    end
    if pal.hold_key then
        local history = permission_history[pal.hold_key]
        if not history then
            history = permissions.new()
            permission_history[pal.hold_key] = history
        end
        pal.permission_history = history
        -- Even pending writes acknowledged by this pass require fresh final
        -- readback. This flag belongs only to the current roster record.
        if next(history.pending) ~= nil then pal.permission_read_reuse_blocked = true end
        for value, on in pairs(permissions.observe(history, off, capable)) do
            -- A bit difference proves a permission changed, not who requested
            -- it. Vanilla cell events can race our own priority clicks; adopting
            -- that difference rewrote 3/4/5 as X or 1 between rapid clicks.
            -- Preserve durable policy until an authenticated priority edit or
            -- verified native-input adapter supplies the user's actual intent.
            -- Acknowledging this observation only updates plain history; it
            -- neither saves a priority nor fabricates a mod-write receipt.
            permissions.accept(history, value, on)
            pal.external_edits = (pal.external_edits or 0) + 1
        end
    end
    for value in pairs(capable) do
        local p = store.effective(cfg, pal, workdefs.name(value), value)
        if store.baseline and p == nil then return nil, nil end
        pal.priorities[value] = p
        if p ~= false and not capped[value] then allowed[value] = true end
    end
    if pal.current then
        pal.current_permitted = type(off) == "table" and not off[pal.current]
    end

    return capable, allowed
end

-- Returns pal key -> set of work values allowed this pass. The helper is
-- pure Lua so rankings, seat accounting and idle reconciliation are tested
-- independently of reflection and network delivery.
local function plan_fences(cfg, pals, demand, stats, capped)
    local ready = {}
    for _, pal in ipairs(pals) do
        pal.capable, pal.base = base_allowed(cfg, pal, capped or {})
        if pal.capable then
            ready[#ready + 1] = pal
            stats.vanilla_edits = stats.vanilla_edits + (pal.external_edits or 0)
        else
            stats.baseline_unavailable = stats.baseline_unavailable + 1
        end
    end
    local plan, report = allocator.plan(cfg, ready, demand, hold_since)
    for _, pal in ipairs(ready) do
        if pal.reconcile_only then
            -- Unverified storage must neither enable capped production nor
            -- revoke other jobs. Keep the observed choices, with explicit X
            -- still reconciled. No automatic admission uses missing totals.
            local off = api.work_off_set(pal.param)
            if type(off) == "table" then
                local safe = {}
                for value in pairs(pal.base) do
                    if not off[value] then safe[value] = true end
                end
                plan[pal.key] = safe
            else
                pal.capable, pal.base = nil, nil
                plan[pal.key] = nil
                stats.baseline_unavailable = stats.baseline_unavailable + 1
            end
        end
    end
    if #ready > 0 and ready[1].reconcile_only then
        report.fenced, report.held, report.staff_limited = 0, 0, 0
        report.free = 0 -- no automatic allocation decision was made
    end
    for key, value in pairs(report) do stats[key] = (stats[key] or 0) + value end
    return plan
end

-- ---------------------------------------------------------------------------
-- Applying it
-- ---------------------------------------------------------------------------

-- The network component for the pass in flight. Set by run_pass and restore,
-- cleared when they finish, so nothing here holds it between passes.
-- The guild every loaded camp agreed on, last pass, or nil. Read by
-- "!pwp adopt", which is the only thing allowed to act on it.
M.adoptable = nil

local pass_comp = nil
local pass_comp_tried = false

-- Every exit that set pass_comp leaves through here.
--
-- pass_comp is an engine object, and this file's own rule is that one is safe
-- for the call that found it and a use-after-free afterwards. run_pass ended
-- with "pass_comp = nil" under a comment saying nothing holds an engine
-- object between passes - true of the bottom of the function and false of the
-- early return above it, where a machine with no camps loaded yet kept the
-- component until the next pass happened to overwrite it.
--
-- Latent rather than live: every reader assigns it first, so nothing has ever
-- read a stale one. It is fixed because "a dangerous primitive that every
-- caller has to remember to guard is exactly the shape of the bug this gate
-- closes" is already written four hundred lines up this file, about this same
-- pair of functions, and it applies to exits as much as to entries.
local function released(stats)
    pass_comp, pass_comp_tried = nil, false
    return stats
end

-- One lookup at most per synchronous pass, including misses. A missing route
-- is not an attempted RPC and must never create a pending-write receipt.
local function ensure_pass_component(stats)
    if pass_comp ~= nil then return true end
    if not pass_comp_tried then
        pass_comp_tried = true
        local ok, comp = pcall(api.owned_network_component)
        if ok then pass_comp = comp end
    end
    if pass_comp ~= nil then
        if said_no_component then
            said_no_component = false
            log.info("a base camp component is available again, writes resume")
        end
        return true
    end
    stats.blocked = true
    stats.blocked_reason = "no base camp component this machine owns; permission writes deferred"
    if not said_no_component then
        said_no_component = true
        log.warn(stats.blocked_reason)
    end
    return false
end

-- The work types this pal is being iterated over, by name, for the diagnostic
-- below. Built only when something is about to be logged.
local function capable_names(pal)
    local out = {}
    for v in pairs(pal.capable or pal.base or {}) do
        out[#out + 1] = tostring(workdefs.name(v) or v)
    end
    table.sort(out)
    return out
end

local function apply_pal(cfg, pal, want, stats, phase)
    if not pal.capable then return end
    if not settings_ready(stats, true) then return end
    local off = api.work_off_set(pal.param)
    if type(off) ~= "table" then
        stats.unreadable = stats.unreadable + 1
        return
    end
    local order, said_off = {}, false
    for value in pairs(pal.capable) do order[#order + 1] = value end
    table.sort(order)
    for _, value in ipairs(order) do
        local should_be_on, is_on = want[value] == true, not off[value]
        if should_be_on ~= is_on and (phase == nil or should_be_on == phase)
            and not (pal.permission_history and pal.permission_history.pending[value] ~= nil) then
            -- Failed attempts consume the per-camp budget too. Check after
            -- diffing, so unchanged permissions do not count as deferred work.
            if (stats.camp_toggles or 0) >= MAX_TOGGLES_PER_PASS then
                stats.deferred = stats.deferred + 1
                return
            end
            stats.camp_toggles = (stats.camp_toggles or 0) + 1
            if cfg.dry_run then
                stats.would_toggle = stats.would_toggle + 1
                log.info(string.format("[dry run] %s %s -> %s", pal.name,
                    workdefs.label(workdefs.name(value)), should_be_on and "on" or "off"))
            else
                if not ensure_pass_component(stats) then
                    stats.deferred = stats.deferred + 1
                    return
                end
                if not settings_ready(stats, false) then return end
                -- Mark the request as pending, never as confirmed state.
                -- Even an unsuccessful call leaves its outcome uncertain
                -- until readback, so it cannot masquerade as a vanilla edit.
                pal.permission_read_reuse_blocked = true
                if pal.permission_history then
                    permissions.sent(pal.permission_history, value, should_be_on)
                end
                if api.set_work_enabled(pal.id, value, should_be_on, pass_comp) then
                    stats.toggles = stats.toggles + 1
                    log.debug(string.format("toggle %s %s -> %s", pal.name,
                        workdefs.label(workdefs.name(value)), should_be_on and "on" or "off"))
                    if not said_off then
                        said_off = true
                        local names = {}
                        for v in pairs(off) do names[#names + 1] = tostring(workdefs.name(v) or v) end
                        table.sort(names)
                        log.debug(string.format("   %s off=[%s] capable=[%s]", pal.name,
                            table.concat(names, " "), table.concat(capable_names(pal), " ")))
                    end
                else
                    stats.failed = stats.failed + 1
                end
            end
        end
    end
    -- Only the immediately following final confirmation may reuse this scalar
    -- observation. Any attempted write in either phase, or pending history,
    -- forces the caller's existing fresh native read instead.
    if phase == true and not cfg.dry_run and not pal.permission_read_reuse_blocked
        and not (pal.permission_history and next(pal.permission_history.pending) ~= nil) then
        return off
    end
end

-- One pass's tally. Shared by run_pass and restore so a restore reports the
-- same numbers in the same words.
function M.blank_stats()
    return {
        camps = 0, pals = 0, works = 0, chests = 0,
        fenced = 0, free = 0,
        toggles = 0, would_toggle = 0, failed = 0, deferred = 0, unreadable = 0,
        demand_types = 0,
        unknown_work = 0, unconfigured = 0, capped = 0, ignored = 0,
        demand_estimated = false,
        -- Set only by restore, when it could not act at all. Distinct from
        -- toggles == 0, which means there was nothing that needed changing.
        blocked = false,
        needed = 0, covered = 0, idle_skipped = 0, idle_reconciled = 0, held = 0,
        staff_limited = 0, manual_conflicts = 0, manual_limit_conflicts = 0,
        assignment_unknown = 0, manual_unavailable = 0, unverified_limit_conflicts = 0,
        unknown_scope = 0, demand_unavailable = 0,
        awaiting_withdrawal = 0, baseline_unavailable = 0, vanilla_edits = 0, storage_unverified = 0,
        pending_writes = 0, expired_writes = 0,
        demand_by_name = {},
        lines = {},
    }
end

-- Give every pal back everything it can do, and stop.
--
-- The mod withdraws permissions and, until now, had no way to hand them back.
-- Turning it off only set a flag: run_pass returned early and every pal stayed
-- fenced exactly as the last pass left it. Deleting the mod was worse - the
-- fences outlive it, because they are the game's own saved data. The only
-- recovery was re-ticking twelve checkboxes per pal by hand on the stand, and
-- a config.lua typo produced the same state.
--
-- "Restore" here means the same thing the header means by stateless: capable
-- AND not X. It deliberately still honours X, because X is the player's own
-- instruction rather than something this mod invented - a pal they barred
-- from Mining should stay barred after they switch the mod off.
--
-- Returns how many toggles it still owes, because MAX_TOGGLES_PER_PASS bounds
-- one sweep and a real base needs several. The caller loops.
function M.restore(cfg)
    -- Gated here as well as at the caller, and deliberately not only there.
    -- base_allowed below asks every pal for its suitability rank, which is
    -- fatal on a client rather than merely wrong, and this function is public.
    -- A dangerous primitive that every caller has to remember to guard is
    -- exactly the shape of the bug this gate closes.
    local stats = M.blank_stats()
    if not settings_ready(stats, false) then return stats end
    local authority = api.latch_authority()
    if authority ~= true then
        stats.blocked = true
        stats.blocked_reason = authority == false and "this machine is not the authority"
            or "authority data is unavailable; permissions were not changed"
        return released(stats)
    end

    -- Owned only, with no fallback, exactly as run_pass does.
    --
    -- This line used to read "owned_network_component() or
    -- network_component()". The fallback was taken out of run_pass in 673b856
    -- - "An empty dedicated server spent every pass sending calls it could not
    -- deliver" - which recorded that it had never once been observed to work,
    -- in any mode. restore kept it, and restore is the one command whose whole
    -- job is to leave the save clean before the mod is removed.
    --
    -- What that cost: on a dedicated server with nobody connected, the camps
    -- still stream in, so every set_work_enabled went through the game state's
    -- component, every pcall succeeded, the toggle count climbed, and not one
    -- change landed. restore_all then printed "gave every pal its work back".
    -- An admin who uninstalled next kept a save with every pal fenced, which
    -- is the precise outcome this command exists to prevent.
    --
    -- Saying so out loud rather than returning a quiet zero: a count of no
    -- changes reads as "there was nothing to undo", and the two are opposite.
    pass_comp = api.owned_network_component()
    if pass_comp == nil then
        stats.blocked = true
        log.warn("nothing on this machine owns a base camp component, so no " ..
            "pal work can be changed from here and nothing was restored")
        return released(stats)
    end

    local camps = api.base_camps()
    if api.camps_available ~= true then
        stats.blocked = true
        stats.blocked_reason = "base camp enumeration is unavailable"
        return released(stats)
    end

    -- One pal at a time, because this is the undo path.
    --
    -- The loop was bare, and a throw anywhere in it - base_allowed asks every
    -- pal for a suitability rank, apply_pal sends a request per work type -
    -- abandoned every pal after it still fenced, with no way to tell which,
    -- and skipped the pass_comp release on the way out. "!pwp off" leaving a
    -- base half switched off is worse than leaving it wholly on: the mod is
    -- meant to be removable, and a partial restore is a state neither the mod
    -- nor the player asked for.
    --
    -- Per pal rather than per camp, so one unhappy pal costs one pal.
    local failed = 0

    for _, camp in ipairs(camps) do
        local camp_id = api.camp_id(camp)
        local camp_key = camp_id ~= nil and api.guid_key(camp_id) or nil
        if camp_key ~= nil then
            stats.camp_toggles = 0
            local pals, pal_err = api.camp_pals(camp)
            if pal_err or type(pals) ~= "table" then
                stats.blocked, stats.unreadable = true, stats.unreadable + 1
                stats.blocked_reason = "camp roster unavailable during restoration: " .. tostring(pal_err or "missing roster")
                return released(stats)
            end
            -- These describe the complete roster inspected, not confirmed
            -- restorations. Completion also requires all failure/pending
            -- counters to be clear and actual permission readback.
            stats.camps = stats.camps + 1
            stats.pals = stats.pals + #pals
            for _, pal in ipairs(pals) do
                -- No plan and no ceilings: base_allowed then returns capable
                -- minus X, which is precisely the vanilla state this mod
                -- started from.
                local ok = pcall(function()
                    pal.hold_key = camp_key .. "|" .. tostring(pal.key)
                    local capable, base = base_allowed(cfg, pal, {})
                    pal.capable, pal.base = capable, base
                    if capable then
                        apply_pal(cfg, pal, base, stats)
                        if not cfg.dry_run and pal.permission_history then
                            local off = api.work_off_set(pal.param)
                            if type(off) ~= "table" then
                                stats.unreadable = stats.unreadable + 1
                            else
                                permissions.confirm(pal.permission_history, off, base, capable)
                            end
                            local pending, expired = permissions.status(pal.permission_history)
                            stats.pending_writes = stats.pending_writes + pending
                            stats.expired_writes = stats.expired_writes + expired
                            stats.deferred = stats.deferred + pending
                        end
                    else
                        stats.baseline_unavailable = stats.baseline_unavailable + 1
                        stats.unreadable = stats.unreadable + 1
                        stats.failed = stats.failed + 1
                    end
                end)
                -- Cleared whatever happened: these are scratch fields hung on
                -- a pal record that outlives this call.
                pal.capable, pal.base, pal.param = nil, nil, nil
                pal.hold_key, pal.permission_history, pal.observed_on = nil, nil, nil
                if not ok then failed = failed + 1 end
            end
        else
            stats.blocked, stats.unknown_scope = true, stats.unknown_scope + 1
            stats.blocked_reason = "restoration needs a readable camp identity"
        end
    end

    if cfg.dry_run and stats.would_toggle > 0 then
        stats.blocked = true
        stats.blocked_reason = "dry run did not apply the required restoration requests"
    end

    if failed > 0 then
        stats.failed = stats.failed + failed
        log.warn(failed .. " pal(s) could not be restored and are still " ..
            "fenced; run it again, or switch their work back on by hand")
    end

    return released(stats)
end

-- ---------------------------------------------------------------------------
-- One camp, one pass-- ---------------------------------------------------------------------------
-- One camp, one pass
-- ---------------------------------------------------------------------------

-- Set by the panel while it is open.
M.want_totals = false
M.prefetch_enabled = true

-- Authenticated UI interest expires without a close packet. It requests work
-- from the normal pass, never a synchronous container scan in an RPC callback.
function M.request_stock(guild)
    if type(guild)~='string' or #guild==0 or #guild>128 then return false end
    local now, count=os.clock(),0
    for key, until_at in pairs(remote_stock_interest) do
        if until_at<=now then remote_stock_interest[key]=nil else count=count+1 end
    end
    if not remote_stock_interest[guild] and count>=128 then return false end
    remote_stock_interest[guild]=now+60
    return true
end

local function wants_stock(guild)
    return M.want_totals or (remote_stock_interest[guild] or 0)>os.clock()
end

-- Developer A/B switch; session memory only, never changes saved rules.
function M.set_prefetch(enabled)
    M.prefetch_enabled=enabled==true
    stock_prefetch.reset()
end

-- Only this camp's effective numeric ceilings need stock for scheduling.
-- Use the existing merge so guild OFF masks and inherited rules agree with
-- cap_state. Unknown ownership cannot rule out another guild's ceilings.
local function limits_apply(cfg, guild)
    if not caps.any(cfg) then return false end
    if guild == nil then return true end
    local rules = caps.all(cfg, guild)
    for _, name in ipairs(workdefs.ORDER) do
        if name ~= workdefs.ANYONE then
            for _, ceiling in pairs(rules[name] or {}) do
                if type(ceiling) == "number" then return true end
            end
        end
    end
    return false
end

local function verified_storage(evidence)
    return type(evidence) == "table" and evidence.complete == true
        and evidence.deduplicated == true and (evidence.unknown_scope or 0) == 0
end

local function fresh_stock(entry)
    if not entry then return false end
    local ttl = storage_scope.retry_ttl(M.stock_ttl, entry.failures)
    local age = os.clock() - entry.at
    return ttl > 0 and age >= 0 and age < ttl
end

local function stock_entry(totals, chests, evidence, previous, at)
    return { totals = totals, chests = chests, evidence = evidence, at = at,
        failures = storage_scope.failures(previous and previous.failures, verified_storage(evidence)) }
end

local function prepare_guild_stock(cfg, camps)
    local metadata, key_parts = {}, {}
    stock_interest = {}
    for _, camp in ipairs(camps) do
        local id, guild = api.guid_key(api.camp_id(camp)), api.camp_guild(camp)
        metadata[#metadata + 1] = { id = id, guild = guild }
        if guild then stock_interest[guild]=true end
        key_parts[#key_parts + 1] = tostring(id) .. ":" .. tostring(guild)
    end
    table.sort(key_parts)
    local key = table.concat(key_parts, "|") .. "|" .. stock_prefetch.filters(cfg)
    local now = os.clock()
    local ttl = storage_scope.retry_ttl(M.stock_ttl, guild_stock_failures)
    local ready=stock_prefetch.take(cfg,key,M.stock_ttl)
    if not ready and key == guild_stock_key and guild_stock_at and ttl > 0
        and now - guild_stock_at >= 0 and now - guild_stock_at < ttl then
        stock_prefetch.observe(cfg,key,guild_stock_at,guild_stock_failures==0,M.stock_ttl)
        return
    end
    trace.at("pass: guild storage sweep")
    local by_camp, counts, evidence
    if ready then
        by_camp,counts,evidence,now=ready.by,ready.counts,ready.evidence,ready.at
        if log.count then log.count("storage: prefetched snapshot used") end
    else
        by_camp, counts, evidence = api.chest_totals_by_camp({
            include = cfg.counted_containers, exclude = cfg.uncounted_containers,
        })
    end
    trace.done()
    local unknown
    guild_stock, unknown = storage_scope.group(metadata, by_camp, counts, evidence)
    -- No guild entries is not positive evidence of a complete read. Unknown
    -- ownership must retain retry progression even when there is no bucket.
    local verified = verified_storage(evidence) and unknown == 0 and next(guild_stock) ~= nil
    for _, entry in pairs(guild_stock) do
        if not entry.verified then verified = false end
    end
    guild_stock_failures = storage_scope.failures(
        key == guild_stock_key and guild_stock_failures or 0, verified)
    guild_stock_key, guild_stock_at = key, now
    stock_prefetch.observe(cfg,key,now,verified,M.stock_ttl)
end

-- Cheap eligibility check; the actual scan runs in its own budgeted callback.
-- Scope is validated again by prepare_guild_stock before a candidate is used.
function M.stock_refresh_due(cfg)
    if not M.prefetch_enabled or cfg.enabled==false then return false end
    if not M.want_totals then
        local needed=false
        for guild in pairs(stock_interest) do
            if wants_stock(guild) or limits_apply(cfg,guild) then needed=true; break end
        end
        if not needed then return false end
    end
    if not settings_ready({},false) then return false end
    return stock_prefetch.due(cfg,M.stock_ttl)
end

function M.refresh_stock(cfg)
    if not M.stock_refresh_due(cfg) then return false end
    return stock_prefetch.refresh(cfg,M.stock_ttl)
end

local function publish_storage(cfg, camp_key, camp_guild, stats, prepare_stock)
    local has_limits = limits_apply(cfg, camp_guild)
    local totals, limits_available = {}, true
    if has_limits or wants_stock(camp_guild) then
        prepare_stock()
        local chests, evidence
        local opts = {
            include = cfg.counted_containers,
            exclude = cfg.uncounted_containers,
        }

        -- collected for the panel, which must not scan this itself
        local scope_key = camp_key
        local held = stock[scope_key]

        if cfg.storage_scope == "global" then
            local grouped = camp_guild and guild_stock[camp_guild]
            limits_available = grouped ~= nil and grouped.verified == true
            totals, chests = grouped and grouped.totals or {}, grouped and grouped.chests or 0
            if camp_guild then
                M.last_storage[camp_guild] = { verified = limits_available,
                    unknown_scope = grouped and grouped.unknown_scope or 1, scope = "guild",
                    pass = M.pass_id, sampled_at = guild_stock_at, ttl = M.stock_ttl }
                M.last_totals_by_guild[camp_guild] = totals
            end
        elseif fresh_stock(held) then
            totals, chests, evidence = held.totals, held.chests, held.evidence
            limits_available = verified_storage(evidence)
        else
            trace.at("camp: chest sweep, scope " .. tostring(cfg.storage_scope))
            totals, chests, evidence = api.camp_item_totals(camp_key, opts)
            trace.done()
            limits_available = verified_storage(evidence)
            stock[scope_key] = stock_entry(totals, chests, evidence, held, os.clock())
        end
        -- Even complete counts cannot identify which guild's rules apply
        -- when camp ownership is unreadable. Never treat that as no rules.
        if camp_guild == nil and caps.any(cfg) then limits_available = false end
        if not limits_available then stats.storage_unverified = stats.storage_unverified + 1 end
        M.last_storage_by_camp[camp_key] = { verified = limits_available, guild = camp_guild,
            scope = cfg.storage_scope == "global" and "guild" or "camp", pass = M.pass_id,
            sampled_at = cfg.storage_scope == "global" and guild_stock_at
                or (stock[scope_key] and stock[scope_key].at), ttl = M.stock_ttl }
        if cfg.storage_scope ~= "global" then M.last_totals_by_camp[camp_key] = totals end

        stats.chests = stats.chests + (chests or 0)

        -- Summed across camps, but only when each camp holds its own count.
        --
        -- In global scope every camp reads the SAME cached figure - scope_key
        -- is the literal "global" for all of them - so adding it once per camp
        -- multiplied the published totals by the number of loaded camps. Three
        -- camps made the panel and "pwp limit" report triple the real stock,
        -- while ceilings kept firing off the honest per-camp `totals`. The two
        -- numbers disagreed, and since cap_state now reads the published one,
        -- the status column would call a job stopped that was still running.
        if pass_totals then
            if not limits_available or not camp_guild or (totals_guild and totals_guild ~= camp_guild) then
                totals_ambiguous = true
            else
                totals_guild = camp_guild
            end
            if cfg.storage_scope == "global" then
                for id, n in pairs(totals) do
                    pass_totals[id] = n
                end
            else
                -- Max, not sum, for the reason given at panel.stock_totals:
                -- under camp scope each base is judged on its own, so the
                -- total across bases is a figure nothing is compared against.
                -- This is what the panel displays and what cap_state reads,
                -- so summing here made both disagree with the fencing.
                for id, n in pairs(totals) do
                    if n > (pass_totals[id] or 0) then pass_totals[id] = n end
                end
            end
        end
    end

    return totals, limits_available, has_limits
end

local function run_camp(cfg, camp, stats, prepare_stock)
    if not settings_ready(stats, false) then return end
    -- Each camp gets the full allowance. See the note in apply_pal.
    stats.camp_toggles = 0

    trace.at("camp: GetId")
    local camp_id = api.camp_id(camp)
    trace.done()
    if camp_id == nil then
        log.debug("skipping a camp with no readable id")
        return
    end
    local camp_key = api.guid_key(camp_id)
    if camp_key == nil then
        stats.unknown_scope = stats.unknown_scope + 1
        return
    end

    -- Resolved once for the camp, because every ceiling check below needs it
    -- and it costs an engine call. nil when the camp will not say which guild
    -- owns it, and that is left as nil rather than widened: a camp with no
    -- readable guild gets config and pre-scoping rules only, never another
    -- guild's ceilings.
    local camp_guild = api.camp_guild(camp)

    trace.at("camp: camp_pals")
    local pals, pal_err = measured("scheduler: camp roster", api.camp_pals, camp)
    trace.done()
    if pal_err or type(pals) ~= "table" then
        stats.blocked, stats.unreadable = true, stats.unreadable + 1
        stats.blocked_reason = "camp roster unavailable; its permissions were not changed: " .. tostring(pal_err or "missing roster")
        log.debug(stats.blocked_reason)
        return
    end
    if #pals == 0 then
        -- Storage belongs to the base, not its roster. A requested read of an
        -- empty base still uses verified scope, normal TTL and shared scanning.
        if wants_stock(camp_guild) then publish_storage(cfg, camp_key, camp_guild, stats, prepare_stock) end
        log.debug("camp has no working pals")
        return
    end
    local unprepared = false
    if M.prepare_pal then
        local ready = {}
        for _, pal in ipairs(pals) do
            local ok, prepared = pcall(M.prepare_pal, cfg, pal, camp)
            -- Preparation can save a baseline and invoke a role-changing
            -- callback. Check before the next Pal or the deferred storage read.
            if not settings_ready(stats, false) then return end
            if ok and prepared == true then
                ready[#ready + 1] = pal
            else
                unprepared = true
                stats.baseline_unavailable = stats.baseline_unavailable + 1
            end
        end
        pals = ready
        if #pals == 0 then return end
    end

    local totals, limits_available, has_limits = publish_storage(cfg, camp_key, camp_guild, stats, prepare_stock)

    -- A panel-only read can remain unknown without blocking this camp's
    -- policy. The storage publications above retain the actual read proof.
    if not has_limits then limits_available = true end

    -- What the camp actually wants doing, from the game's own pulses.
    --
    -- The fallback must not key off the pulse count: a base whose pals are
    -- asleep produces no pulses, and falling back there would fence the whole
    -- roster onto night work that does not exist. No pulses on the authority
    -- means nothing wants doing, which is a real answer.
    --
    -- It is NOT a real answer on a client connected to a dedicated server.
    -- The pulse hook sits on a _ServerInternal function, so a client registers
    -- it cleanly and never receives anything, and reading that as "no work"
    -- left the mod doing precisely nothing while looking healthy. So the
    -- fallback runs when the hook did not register OR when we are not the
    -- authority that would fire it.
    trace.at("camp: demand index")
    local demand, live, pulse_evidence = demandidx.for_camp(camp_key)
    if pulse_evidence then
        stats.unknown_scope = math.max(stats.unknown_scope, pulse_evidence.unknown_scope or 0)
        stats.unknown_work = stats.unknown_work + (pulse_evidence.unknown_type or 0)
    end
    trace.done()
    local counted = live

    if not demandidx.live() then
        trace.at("camp: camp_works fallback")
        local all, work_err = api.camp_works(camp)
        trace.done()
        if work_err then
            log.debug("camp works unavailable: " .. work_err)
            -- This diagnostic RPC needs the same owned route as writes. Do
            -- not let the legacy API fallback perform a second/global lookup.
            if ensure_pass_component(stats) then
                api.request_work_replication(camp_id, true, pass_comp)
            end
            demand, counted = {}, 0
            stats.demand_unavailable = stats.demand_unavailable + 1
        else
            demand = build_demand(cfg, all, totals, stats, camp_guild)
            counted = #all
            stats.demand_estimated = true
        end
    else
        -- Ceilings and unconfigured types still have to be honoured, and the
        -- pulse index knows nothing about either.
        for value in pairs(demand) do
            local name = workdefs.name(value)
            if name == nil then
                demand[value] = nil
            elseif cfg.work_priority[name] == nil then
                stats.unconfigured = stats.unconfigured + 1
                demand[value] = nil
            elseif cap_reached(cfg, name, totals, camp_guild) then
                stats.capped = stats.capped + 1
                demand[value] = nil
            end
        end
    end

    -- Which work types have a satisfied rule right now. Worked out once for
    -- the camp and used both to drop them from demand and to withdraw the
    -- permission, so a rule reading "done" actually stops the work.
    local capped = {}
    for i = 1, #workdefs.ORDER do
        local name = workdefs.ORDER[i]
        if limits_available and name ~= workdefs.ANYONE
            and cap_reached(cfg, name, totals, camp_guild) then
            capped[workdefs.value(name)] = true
        end

        -- Published as decided, per camp, rather than left to be re-derived.
        --
        -- The panel used to ask cap_state itself, against last_totals - which
        -- under the default camp scope is the SUM across every camp, while
        -- the decision above is made per camp against that camp's own
        -- storage. Two bases holding 3000 wood each under a 5000 limit: the
        -- panel said Stopped and the lumberjacks kept working, because both
        -- were right about different numbers. cap_state was exported so the
        -- two could not disagree about the rule; this stops them disagreeing
        -- about the input.
        if name ~= workdefs.ANYONE then
            local seen = M.last_capped[name]
            if seen == nil or seen.pass ~= M.pass_id then
                seen = { pass = M.pass_id, camps = 0, capped = 0, unknown = 0 }
                M.last_capped[name] = seen
            end
            seen.camps = seen.camps + 1
            if not limits_available then seen.unknown = (seen.unknown or 0) + 1 end
            if capped[workdefs.value(name)] then
                seen.capped = seen.capped + 1
            end
        end
    end

    stats.camps = stats.camps + 1
    stats.pals = stats.pals + #pals
    stats.works = stats.works + counted

    for value, n in pairs(demand) do
        stats.demand_types = stats.demand_types + 1
        local name = workdefs.name(value)
        if name then
            stats.demand_by_name[name] = (stats.demand_by_name[name] or 0) + n
        end
    end

    -- Idle is still a reconciliation pass: X edits and withdrawn ceilings
    -- must change permissions even while every pal sleeps. Missing work data
    -- is reported separately and never used as occupancy/assignment proof.
    if next(demand) == nil then stats.idle_reconciled = stats.idle_reconciled + 1 end

    for _, pal in ipairs(pals) do
        pal.reconcile_only = not limits_available and has_limits
        pal.current = api.current_work_suitability(pal.param)
        pal.hold_key = camp_key and not tostring(pal.key):match("^slot%d+$")
            and (camp_key .. "|" .. tostring(pal.key)) or nil
        pal.assignment = nil
        if M.assignment_reader then
            local ok, a = pcall(measured, "scheduler: assignment read", M.assignment_reader, pal, camp)
            if ok and type(a) == "table" then
                -- Copy just the declared Lua fields; never retain an object
                -- that a reader might include in its callback-local result.
                local state = a.state
                if state ~= "ready" and state ~= "occupied" and state ~= "completed" then
                    state = "unknown"
                end
                local manual
                if type(a.manual) == "boolean" then manual = a.manual end
                pal.assignment = {
                    id = type(a.id) == "string" and a.id or nil,
                    value = type(a.value) == "number" and math.tointeger(a.value) or nil,
                    state = state,
                    manual = manual,
                }
            end
        end
    end

    trace.at("camp: plan_fences")
    local plan = measured("scheduler: plan fences", plan_fences, cfg, pals, demand, stats, capped)
    trace.done()
    -- Capture/observation can stage settings while planning. No native write
    -- may use those choices until the staged generation is durable.
    if not settings_ready(stats, true) then return end

    -- Withdraw obsolete permissions before admitting replacements. A sent
    -- RPC is not proof that its withdrawal landed: re-read current permissions
    -- and defer new enables if any withdrawal remains outstanding.
    local unreadable_at = stats.unreadable
    measured("scheduler: withdraw permissions", function()
        for _, pal in ipairs(pals) do
            apply_pal(cfg, pal, plan[pal.key] or {}, stats, false)
        end
    end)
    local can_enable = not unprepared and stats.unreadable == unreadable_at
    for _, pal in ipairs(pals) do
        if pal.capable == nil then can_enable = false end
    end
    measured("scheduler: verify withdrawals", function()
        if not cfg.dry_run then
            for _, pal in ipairs(pals) do
                if pal.capable then
                    local off = api.work_off_set(pal.param)
                    if type(off) ~= "table" then
                        can_enable = false
                    else
                        if pal.permission_history then
                            permissions.confirm(pal.permission_history, off, plan[pal.key] or {}, pal.capable)
                            local pending = permissions.status(pal.permission_history)
                            -- A delayed ENABLE still owns a potential seat. Do
                            -- not replace it before its delivery is resolved.
                            if pending > 0 then can_enable = false end
                        end
                        for value in pairs(pal.capable) do
                            if not (plan[pal.key] or {})[value] and not off[value] then
                                can_enable = false
                                break
                            end
                        end
                    end
                end
            end
        end
    end)
    if not can_enable then stats.awaiting_withdrawal = stats.awaiting_withdrawal + 1 end

    measured("scheduler: enable and confirm permissions", function()
        for _, pal in ipairs(pals) do
            local want = plan[pal.key] or pal.base or {}
            trace.at("camp: apply " .. tostring(pal.name or pal.key))
            local observed_off
            if can_enable then observed_off = apply_pal(cfg, pal, want, stats, true) end
            if not cfg.dry_run and pal.capable and pal.permission_history then
                if observed_off == nil then observed_off = api.work_off_set(pal.param) end
                permissions.confirm(pal.permission_history, observed_off, want, pal.capable)
                local pending, expired = permissions.status(pal.permission_history)
                stats.pending_writes = stats.pending_writes + pending
                stats.expired_writes = stats.expired_writes + expired
            end
            trace.done()

            local restricted = false
            for value in pairs(pal.base or {}) do
                if not want[value] then restricted = true; break end
            end
            if restricted then
                local names = {}
                for value in pairs(want) do
                    names[#names + 1] = workdefs.label(workdefs.name(value))
                end
                table.sort(names)
                stats.lines[#stats.lines + 1] = {
                    pal = pal.name,
                    key = pal.key,
                    fence = table.concat(names, ", "),
                }
            end

            -- Scratch fields, dropped so nothing survives into the next pass.
            -- The pal tables come fresh from camp_pals each time, but clearing is
            -- cheap and keeps that an implementation detail rather than a
            -- dependency.
            pal.base = nil
            pal.capable = nil
            pal.order = nil
            pal.current = nil
            pal.current_permitted = nil
            pal.observed_on = nil
            pal.permission_history, pal.external_edits = nil, nil
            pal.permission_read_reuse_blocked = nil
            pal.reconcile_only = nil
            pal.ranks, pal.priorities, pal.assignment, pal.hold_key = nil, nil, nil, nil
        end
    end)
end

local function run_pass_body(cfg)
    local stats = M.blank_stats()
    if not settings_ready(stats, false) then return stats end
    M.pass_id = M.pass_id + 1

    -- Camps first, component second, and the order is the fix.
    --
    -- Every lookup here is a full object-array walk, and the component needs
    -- TWO of them. They used to run in the other order, which meant a player
    -- in the open field with no camp streamed in paid every walk this pass
    -- owns and then aborted on the empty camp list - the most expensive
    -- possible way to do nothing, six times a minute. Camps are one walk, so
    -- they go first, and an empty list ends the pass before the component is
    -- ever asked for.
    trace.at("pass: base_camps sweep")
    local camps = api.base_camps()
    trace.done()
    if api.camps_available ~= true then
        stats.blocked = true
        stats.blocked_reason = "base camp enumeration is unavailable: " .. tostring(api.camps_error or "unknown")
        return released(stats)
    end
    if #camps == 0 then
        log.debug("no base camps loaded")
        return released(stats)
    end
    -- Asked fresh, not read from the memo, and asked HERE rather than trusted
    -- from the caller.
    --
    -- Everything below reaches suitability_rank and current_work_suitability,
    -- which are UFunction calls on pal parameters. On a dedicated server
    -- client those are replicated proxies and the call is an access violation
    -- rather than an error, so no pcall on the way down catches it. M.restore
    -- already gates itself for exactly this reason and its comment argues the
    -- general case: a dangerous primitive that every caller has to remember to
    -- guard is the shape of the bug the gate closes. run_pass is strictly more
    -- dangerous and had only an owned-component test, which a client passes.
    --
    -- latch_authority rather than has_authority, deliberately. The memo is
    -- cleared by api.reset, which runs only when world_key says the world
    -- changed - and world_key is derived from the map package path, which may
    -- not differ between hosting and joining a server. If it does not, a
    -- session that hosted first carries a stale "yes" into a client session
    -- with the pass timer still armed. Probing here re-latches every pass, so
    -- a stale answer survives at most one interval and cannot reach the calls
    -- below. On a host the lookup exits early; on a client it is one walk to
    -- return false, once per pass.
    local authority = api.latch_authority()
    if authority ~= true then
        -- Named, like the component abort below.
        --
        -- Without it a client running '!pwp run' fell through to main.lua's
        -- camp-streaming advice, which is exactly wrong: the pass stopped
        -- because this machine is not the authority, not because a camp is
        -- not loaded. This is also the path the fresh re-probe exists for, so
        -- it is the one worth naming.
        local blank = M.blank_stats()
        blank.blocked = true
        blank.blocked_reason = authority == false and "this machine is not the authority, so the server decides assignments"
            or "authority data is unavailable; permissions were not changed"
        return blank
    end

    -- The latch sits BELOW the camps abort now: with no camp streamed in
    -- there is nothing any answer could protect, so a pass in the open field
    -- ends after one walk instead of probing authority first. Nothing
    -- between the top of this function and here reaches a pal - base_camps
    -- is FindAllOf plus valid(), which a client survives - so the crash
    -- guard the latch provides has lost no ground, it just runs one step
    -- later. And with the pulse hint wired, the probe itself is free on any
    -- authority that has scheduled work since it spawned.

    -- Resolve an owned send route only after a permission difference is found.
    -- Reconciliation, authority checks and readback still run on every pass.

    -- The upgrade from unowned rules to guild owned ones is OFFERED here and
    -- carried out by "!pwp adopt". It used to happen on its own.
    --
    -- The test below is careful about what it can see and blind to what it
    -- cannot. It refuses if any loaded camp has an unreadable guild, and
    -- refuses if two of them disagree - but base_camps is a FindAllOf, so it
    -- only ever sees camps that are STREAMED IN. On a dedicated server that is
    -- whichever bases happen to have somebody near them.
    --
    -- So on a server carrying an upgraded caps.txt with two guilds, if only
    -- guild A is online, only A's camps load, "every camp agrees" is true, and
    -- every shared ceiling silently became A's - written to disk, with the
    -- wildcard deleted, and nothing to undo it. Guild B lost limits they were
    -- relying on and gained no message saying so. The README promised this
    -- happens only where every camp ON THE SERVER is one guild, which is a
    -- thing this code cannot determine: there is no way to enumerate guilds,
    -- only to read one off a camp that happens to be loaded.
    --
    -- Not fixed by looking harder, because the missing information is not
    -- there to find. An irreversible cross-guild migration should be somebody
    -- deciding, not a side effect of walking near your own base, so the pass
    -- now says what it sees once per session and stops.
    if api.has_authority() then
        local sole = nil
        for _, camp in ipairs(camps) do
            local g = api.camp_guild(camp)
            if g == nil then
                sole = nil
                break
            end
            if sole == nil then
                sole = g
            elseif sole ~= g then
                sole = nil
                break
            end
        end
        M.adoptable = sole
        if sole then caps.offer_adopt(sole) end
    end

    -- Delay the shared scan until a readable, prepared, nonempty roster can
    -- use it. No demand is still an idle reconciliation, so it does not skip
    -- this step. Guild totals still include every loaded camp, even empty ones.
    -- This closure and its camp wrappers live only for this synchronous pass.
    local stock_prepared, stock_error = false, nil
    local function prepare_stock()
        if not stock_prepared then
            stock_prepared = true
            local ok, err = pcall(function()
                if cfg.storage_scope == "global" then
                    prepare_guild_stock(cfg, camps)
                elseif M.stock_ttl > 0 and #camps > 1 then
                    local stale = false
                    for _, c in ipairs(camps) do
                        local k = api.guid_key(api.camp_id(c))
                        if k and not fresh_stock(stock[k]) then
                            stale = true
                            break
                        end
                    end
                    if stale then
                        trace.at("pass: bucketed chest sweep")
                        local by_camp, chest_counts, evidence = api.chest_totals_by_camp({
                            include = cfg.counted_containers,
                            exclude = cfg.uncounted_containers,
                        })
                        trace.done()
                        local now = os.clock()
                        for _, c in ipairs(camps) do
                            local k = api.guid_key(api.camp_id(c))
                            if k then
                                stock[k] = stock_entry(by_camp[k] or {},
                                    (chest_counts and chest_counts[k]) or 0, evidence, stock[k], now)
                            end
                        end
                    end
                end
            end)
            if not ok then stock_error = tostring(err) end
        end
        -- A failed shared scan must neither repeat per camp nor let a later
        -- camp consume old data after the failed preparation.
        if stock_error then error(stock_error, 0) end
    end
    pass_totals, totals_guild, totals_ambiguous = {}, nil, false

    for camp_n, camp in ipairs(camps) do
        trace.at("pass: camp " .. camp_n .. " of " .. #camps)
        local ok, err = pcall(function() run_camp(cfg, camp, stats, prepare_stock) end)
        trace.done()
        if not ok then
            stats.failed = stats.failed + 1
            log.warn("pass threw on a camp: " .. tostring(err))
        end
    end

    -- Only published when the pass actually read storage. A pass with no
    -- ceilings does not scan containers at all, and overwriting good totals
    -- with an empty table would make the panel show every rule at zero.
    if totals_ambiguous then
        -- Legacy consumers lack a selected guild. Do not publish whichever
        -- guild happened to run last as if it described the local player.
        M.last_totals = {}
    elseif next(pass_totals) ~= nil then
        M.last_totals = pass_totals
    end
    pass_totals = nil

    if #stats.lines > 0 then
        local who = {}
        for _, e in ipairs(stats.lines) do
            who[#who + 1] = e.pal .. " -> " .. e.fence
        end
        log.info("fenced: " .. table.concat(who, "; "))
    end

    -- Dropped with the pass that resolved it. Nothing holds an engine object
    -- between passes - which is now true of the early returns above as well.
    return released(stats)
end

function M.run_pass(cfg)
    if require('settings_gate').blocked() then
        local stats=M.blank_stats()
        stats.blocked=true;stats.blocked_reason=require('settings_gate').status()=='restart_required'
            and 'settings locked; restart the game' or 'settings recovery is in progress'
        return stats
    end
    pass_comp, pass_comp_tried = nil, false
    local ok, result = pcall(run_pass_body, cfg)
    pass_comp, pass_comp_tried, pass_totals = nil, false, nil
    if ok then return result end
    local stats = M.blank_stats()
    stats.blocked, stats.failed = true, 1
    stats.blocked_reason = "pass did not complete: " .. tostring(result)
    log.warn(stats.blocked_reason)
    return stats
end

-- Which types want a worker. "3 type(s)" says nothing when a pal is on the
-- wrong job.
local function demand_summary(stats)
    local names = {}
    for name in pairs(stats.demand_by_name) do names[#names + 1] = name end
    if #names == 0 then return nil end

    table.sort(names, function(a, b)
        local ca, cb = stats.demand_by_name[a], stats.demand_by_name[b]
        if ca ~= cb then return ca > cb end
        return a < b
    end)

    local out = {}
    for _, name in ipairs(names) do
        out[#out + 1] = workdefs.label(name) .. " " .. stats.demand_by_name[name]
    end
    return table.concat(out, ", ")
end

function M.format_stats(cfg, stats)
    local parts = {
        string.format("%d camp(s), %d pal(s), %d work(s) in %d type(s)",
            stats.camps, stats.pals, stats.works, stats.demand_types),
        stats.fenced .. " fenced" .. (stats.held > 0 and (" (" .. stats.held .. " holding)") or ""),
        stats.free .. " free",
    }

    local moved = cfg.dry_run and stats.would_toggle or stats.toggles
    parts[#parts + 1] = moved .. (cfg.dry_run and " would request" or " permission request(s) sent")

    if stats.failed > 0 then parts[#parts + 1] = stats.failed .. " failed" end
    if stats.deferred > 0 then parts[#parts + 1] = stats.deferred .. " deferred" end
    if stats.unreadable > 0 then parts[#parts + 1] = stats.unreadable .. " unreadable" end
    if stats.capped > 0 then parts[#parts + 1] = stats.capped .. " capped" end
    if stats.unknown_work > 0 then parts[#parts + 1] = stats.unknown_work .. " untyped" end
    if stats.covered > 0 then parts[#parts + 1] = stats.covered .. " covered" end
    if stats.idle_reconciled > 0 then
        parts[#parts + 1] = stats.idle_reconciled .. " idle camp(s) reconciled"
    end
    if stats.staff_limited > 0 then parts[#parts + 1] = stats.staff_limited .. " staffing restrictions" end
    if stats.manual_conflicts > 0 then parts[#parts + 1] = stats.manual_conflicts .. " manual assignment conflicts" end
    if stats.manual_limit_conflicts > 0 then
        parts[#parts + 1] = stats.manual_limit_conflicts .. " fixed workers above staffing limit"
    end
    if stats.assignment_unknown > 0 then
        parts[#parts + 1] = stats.assignment_unknown .. " assignment(s) unverified"
    end
    if stats.manual_unavailable > 0 then
        parts[#parts + 1] = stats.manual_unavailable .. " current worker(s) awaiting assignment evidence"
    end
    if stats.unverified_limit_conflicts > 0 then
        parts[#parts + 1] = stats.unverified_limit_conflicts .. " unverified workers above staffing limit"
    end
    if stats.unknown_scope > 0 then parts[#parts + 1] = stats.unknown_scope .. " work(s) quarantined" end
    if stats.demand_unavailable > 0 then parts[#parts + 1] = "demand UNAVAILABLE" end
    if stats.awaiting_withdrawal > 0 then parts[#parts + 1] = "waiting for permission withdrawals" end
    if stats.pending_writes > 0 then parts[#parts + 1] = stats.pending_writes .. " permission request(s) unconfirmed" end
    if stats.expired_writes > 0 then
        parts[#parts + 1] = stats.expired_writes .. " permission request(s) timed out; delivery unresolved"
    end
    if stats.baseline_unavailable > 0 then parts[#parts + 1] = "baseline UNAVAILABLE" end
    if stats.storage_unverified > 0 then parts[#parts + 1] = "storage UNVERIFIED" end
    if stats.vanilla_edits > 0 then
        parts[#parts + 1] = stats.vanilla_edits .. " unattributed permission change(s); priorities preserved"
    end
    if stats.demand_estimated then parts[#parts + 1] = "demand ESTIMATED" end
    if stats.blocked_reason then parts[#parts + 1] = "BLOCKED: " .. stats.blocked_reason end

    local wants = demand_summary(stats)
    if wants then return table.concat(parts, ", ") .. "  |  wanted: " .. wants end
    return table.concat(parts, ", ")
end

return M
