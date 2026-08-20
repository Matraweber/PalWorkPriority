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
--   3. a pal already working a type keeps it, bounded by HOLD_SECONDS
--   4. a pal fenced nowhere is left unfenced rather than idled
--   5. diff against the game's permissions and send only the differences
--
-- Restoring is stateless: permissions are always "capable AND not X AND
-- (fenced-in OR unfenced)", so switching off restores "capable AND not X".
-- The cost is that a work type unchecked by hand in vanilla comes back on.

local log = require("log")
local caps = require("caps")
local api = require("palapi")
local workdefs = require("workdefs")
local store = require("store")
local demandidx = require("demand")

local M = {}

M.last_report = nil

-- One pass never issues an unbounded number of RPCs. Steady state sends
-- almost nothing because only differences go out; this bounds the first pass
-- over a large base, and whatever is skipped is picked up next tick.
local MAX_TOGGLES_PER_PASS = 40

-- How long a pal may be held on work that no longer announces itself.
--
-- The hold stops a fence being released mid-job. It must not outlast the job:
-- a workbench keeps its work object forever and a finished crafter still
-- reports Handiwork, so an unbounded hold pins it at the bench with nothing
-- to do. Real demand resets the clock.
local HOLD_SECONDS = 90

-- pal key -> { value, since }. Which work each pal is being held on and when
-- that hold began.
local hold_since = {}

-- What the bases were holding at the last pass, merged across camps.
--
-- Published because the panel needs the same numbers and was scanning every
-- container itself to get them, which is the most expensive thing this mod
-- does and it was doing it every three seconds on the game thread. The pass
-- already has the answer; it was throwing it away.
M.last_totals = {}
M.totals_at = 0
local pass_totals = nil

-- The fence itself is recomputed from demand every pass and remembers
-- nothing. The hold timers are the one exception, and a config reload or
-- world change should drop them.
function M.forget()
    hold_since = {}
end

-- ---------------------------------------------------------------------------
-- Demand
-- ---------------------------------------------------------------------------

local function cap_reached(cfg, work_name, totals)
    local ceilings = caps.for_work(cfg, work_name)
    if ceilings == nil then return false end

    local listed = false
    for item, ceiling in pairs(ceilings) do
        listed = true
        if type(ceiling) == "number" and (totals[item] or 0) < ceiling then
            return false
        end
    end
    return listed
end

-- Pending jobs per work type. A type whose resource ceiling is met
-- contributes nothing, which is what lets a ceiling release pals rather than
-- merely stop them.
--
-- Only reached by the estimated fallback, where `works` is every work object
-- the camp owns. That overstates demand badly: a cold campfire has one.
local function build_demand(cfg, works, totals, stats)
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
        elseif cap_reached(cfg, name, totals) then
            stats.capped = stats.capped + 1
        else
            -- A work with no assignable slot left is already covered and
            -- needs nobody. Unreadable counts as needing someone, since
            -- overstating demand only wastes a pal while understating it
            -- leaves work undone.
            local free_slot = true
            pcall(function() free_slot = w:IsExistAssignableSlot() end)

            if free_slot ~= false then
                demand[value] = (demand[value] or 0) + 1
                stats.needed = stats.needed + 1
            else
                stats.covered = stats.covered + 1
            end
        end
    end

    return demand
end

-- Work objects of each type that exist, announcing or not. NOT demand: a cold
-- campfire has one. It answers only "is there any of this left?", which is
-- enough to keep a pal working but not to pull one in.
local function count_work_objects(camp)
    local out = {}
    for _, w in ipairs(api.camp_works(camp)) do
        local value = api.work_suitability(w)
        if value then out[value] = (out[value] or 0) + 1 end
    end
    return out
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
local function base_allowed(cfg, pal, capped)
    local capable, allowed = {}, {}

    for i = 1, #workdefs.ORDER do
        local name = workdefs.ORDER[i]
        local value = workdefs.value(name)

        if api.suitability_rank(pal.param, value) >= 1 then
            capable[value] = true

            -- X bars a pal outright, and a met ceiling bars the work for
            -- everyone. A work type with no opinion set stays permitted:
            -- having no opinion is not the same as forbidding it.
            if store.effective(cfg, pal, name, value) ~= false
                and not capped[value] then
                allowed[value] = true
            end
        end
    end

    return capable, allowed
end

-- Returns pal key -> set of work values that pal may do this pass.
local function plan_fences(cfg, pals, demand, objects, stats, capped)
    local plan, fenced = {}, {}
    local taken = {}            -- work value -> pals fenced onto it
    local cap = tonumber(cfg.max_pals_per_work_type)
    local spread = (cfg.assignment_mode ~= "fill")

    local function wanted(value)
        return (demand[value] or 0) > 0
    end

    -- What a type can still absorb: three pending haul jobs never need a
    -- fourth hauler. In spread mode lap tightens it so every type gets one pal
    -- before any gets a second.
    --
    -- This decides only whether a pal is PULLED here, never what goes in the
    -- fence. Doing both cost a pal one of its two priority-1 types.
    local function room(value, lap)
        local limit = demand[value] or 0
        if cap and cap < limit then limit = cap end
        if spread and lap < limit then limit = lap end
        return (taken[value] or 0) < limit
    end

    for _, pal in ipairs(pals) do
        pal.capable, pal.base = base_allowed(cfg, pal, capped or {})
        pal.current = api.current_work_suitability(pal.param)

        -- Sorted, because pairs() order is not stable in Lua and this list
        -- decides ties. A pal equally suited to two work types at the same
        -- priority was picking whichever the hash happened to yield first,
        -- so it flipped between them every pass and spent its toggles going
        -- back and forth instead of working.
        pal.order = {}
        for value in pairs(pal.base) do pal.order[#pal.order + 1] = value end
        table.sort(pal.order)
    end

    -- The asymmetry that holds this together. To PULL a pal to a work type
    -- takes a real pulse, so nobody is sent to a cold station. To KEEP a pal
    -- where it is takes only that work of that type still exists.
    --
    -- Without it the fence is released the instant a job is ASSIGNED: an
    -- assigned job stops asking for anyone, so it looks finished the moment
    -- it truly starts.
    local now = os.time()

    local function keeps(pal, value)
        if pal.current ~= value then return false end
        if (objects[value] or 0) == 0 then return false end

        local h = hold_since[pal.key]
        if h == nil or h.value ~= value then
            hold_since[pal.key] = { value = value, since = now }
            return true
        end

        -- Genuine demand means the hold is not what is keeping the pal here,
        -- so the clock restarts and a busy pal never ages out.
        if (demand[value] or 0) > 0 then
            h.since = now
            return true
        end

        return (now - h.since) < HOLD_SECONDS
    end

    local laps = spread and math.max(cap or #pals, 1) or 1
    for lap = 1, laps do
        for level = 1, store.MAX do
            for _, pal in ipairs(pals) do
                if not fenced[pal.key] then
                    local fence = {}
                    local best, best_rank = nil, -1

                    local consumes = false

                    for _, value in ipairs(pal.order) do
                        local name = workdefs.name(value)
                        local held = keeps(pal, value)

                        if store.effective(cfg, pal, name, value) == level
                            and (wanted(value) or held) then

                            local rank = api.suitability_rank(pal.param, value)
                            if rank >= cfg.min_suitability_rank then
                                -- Everything at this level that is wanted goes
                                -- in the fence, so the pal can move between
                                -- equally-wanted jobs without a re-plan.
                                fence[value] = true

                                -- A type with room pulls the pal here. So does
                                -- the job it is already doing, but that one
                                -- claims no allocation, since the pal is
                                -- staying put rather than being handed out.
                                -- Strictly greater, so the first of equal
                                -- ranks wins and the sorted order decides it.
                                -- A job already in progress beats a tie
                                -- outright, so a pal is never shuffled off
                                -- work it is doing for an equal alternative.
                                local better = rank > best_rank
                                    or (held and rank == best_rank)

                                if (room(value, lap) or held) and better then
                                    best, best_rank = value, rank
                                    consumes = not held
                                end
                            end
                        end
                    end

                    if best then
                        -- Fenced to the whole level, not only the one type it
                        -- is best at: a pal should be free to move between
                        -- equally-wanted jobs without waiting on a re-plan.
                        plan[pal.key] = fence
                        fenced[pal.key] = true
                        if consumes then taken[best] = (taken[best] or 0) + 1 end
                        stats.fenced = stats.fenced + 1
                        if not consumes then stats.held = stats.held + 1 end
                    end
                end
            end
        end
    end

    for _, pal in ipairs(pals) do
        if not fenced[pal.key] then
            plan[pal.key] = pal.base
            stats.free = stats.free + 1
        end
    end

    return plan
end

-- ---------------------------------------------------------------------------
-- Applying it
-- ---------------------------------------------------------------------------

local function apply_pal(cfg, pal, want, stats)
    -- The game's own record is the only ground truth. Diffing against what we
    -- believe we set last time would drift the moment anything else touched a
    -- toggle, including the player.
    local off = api.work_off_set(pal.param)
    if off == nil then
        -- Nothing to diff against. Sending the whole set blind would spam the
        -- channel every pass, so skip and retry next tick.
        stats.unreadable = stats.unreadable + 1
        return
    end

    for value in pairs(pal.capable or pal.base or {}) do
        if stats.toggles + stats.would_toggle >= MAX_TOGGLES_PER_PASS then
            stats.deferred = stats.deferred + 1
            return
        end

        local should_be_on = want[value] == true
        local is_on = not off[value]

        if should_be_on ~= is_on then
            if cfg.dry_run then
                stats.would_toggle = stats.would_toggle + 1
                log.info(string.format("[dry run] %s %s -> %s",
                    pal.name, workdefs.label(workdefs.name(value)),
                    should_be_on and "on" or "off"))
            elseif api.set_work_enabled(pal.id, value, should_be_on) then
                stats.toggles = stats.toggles + 1
            else
                stats.failed = stats.failed + 1
            end
        end
    end

    -- X is absolute: it applies whether or not the pal is fenced, and it is
    -- the whole reason X can stop a pal working at all.
    for i = 1, #workdefs.ORDER do
        local name = workdefs.ORDER[i]
        local value = workdefs.value(name)

        if store.effective(cfg, pal, name, value) == false and not off[value]
            and api.suitability_rank(pal.param, value) >= 1 then

            if cfg.dry_run then
                stats.would_toggle = stats.would_toggle + 1
            elseif api.set_work_enabled(pal.id, value, false) then
                stats.toggles = stats.toggles + 1
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- One camp, one pass
-- ---------------------------------------------------------------------------

-- Reading every chest in a camp is the most expensive thing a pass does, so
-- it only happens when some ceiling could actually use the answer.
local function needs_totals(cfg)
    return caps.any(cfg)
end

local function run_camp(cfg, camp, stats)
    local camp_id = api.camp_id(camp)
    if camp_id == nil then
        log.debug("skipping a camp with no readable id")
        return
    end

    local pals, pal_err = api.camp_pals(camp)
    if pal_err then
        log.debug("camp pals unavailable: " .. pal_err)
        return
    end
    if #pals == 0 then
        log.debug("camp has no working pals")
        return
    end

    local totals = {}
    if needs_totals(cfg) then
        local chests
        local opts = {
            include = cfg.counted_containers,
            exclude = cfg.uncounted_containers,
        }

        -- collected for the panel, which must not scan this itself
        if cfg.storage_scope == "global" then
            totals, chests = api.all_chest_totals(opts)
        else
            totals, chests = api.camp_item_totals(api.guid_key(camp_id), opts)
        end
        stats.chests = stats.chests + (chests or 0)

        if pass_totals then
            for id, n in pairs(totals) do
                pass_totals[id] = (pass_totals[id] or 0) + n
            end
        end
    end

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
    local camp_key = api.guid_key(camp_id)
    local demand, live = demandidx.for_camp(camp_key)
    local counted = live

    if not demandidx.live() then
        local all, work_err = api.camp_works(camp)
        if work_err then
            log.debug("camp works unavailable: " .. work_err)
            api.request_work_replication(camp_id, true)
            return
        end
        demand = build_demand(cfg, all, totals, stats)
        counted = #all
        stats.demand_estimated = true
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
            elseif cap_reached(cfg, name, totals) then
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
        if name ~= workdefs.ANYONE and cap_reached(cfg, name, totals) then
            capped[workdefs.value(name)] = true
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

    -- Nothing wanted. That is either a genuinely idle base or a read that
    -- came back empty for a moment, and the two are indistinguishable from
    -- here. A live pass was seen reporting 0 works between passes reporting
    -- 200. Unfencing the whole base on it costs a dozen toggles and another
    -- dozen to put back, so the existing fences are left exactly as they are.
    -- An idle base loses nothing by staying fenced; there is no work either
    -- way.
    if next(demand) == nil then
        stats.idle_skipped = stats.idle_skipped + 1
        return
    end

    local objects = count_work_objects(camp)
    local plan = plan_fences(cfg, pals, demand, objects, stats, capped)

    for _, pal in ipairs(pals) do
        local want = plan[pal.key] or pal.base or {}
        apply_pal(cfg, pal, want, stats)

        if want ~= pal.base then
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
    end
end

function M.run_pass(cfg)
    local stats = {
        camps = 0, pals = 0, works = 0, chests = 0,
        fenced = 0, free = 0,
        toggles = 0, would_toggle = 0, failed = 0, deferred = 0, unreadable = 0,
        demand_types = 0,
        unknown_work = 0, unconfigured = 0, capped = 0, ignored = 0,
        demand_estimated = false,
        needed = 0, covered = 0, idle_skipped = 0, held = 0,
        demand_by_name = {},
        lines = {},
    }

    local camps = api.base_camps()
    if #camps == 0 then
        log.debug("no base camps loaded")
        M.last_report = nil
        return stats
    end

    pass_totals = {}

    for _, camp in ipairs(camps) do
        local ok, err = pcall(function() run_camp(cfg, camp, stats) end)
        if not ok then
            log.warn("pass threw on a camp: " .. tostring(err))
        end
    end

    -- Only published when the pass actually read storage. A pass with no
    -- ceilings does not scan containers at all, and overwriting good totals
    -- with an empty table would make the panel show every rule at zero.
    if next(pass_totals) ~= nil then
        M.last_totals = pass_totals
        M.totals_at = os.clock()
    end
    pass_totals = nil

    if #stats.lines > 0 then
        local who = {}
        for _, e in ipairs(stats.lines) do
            who[#who + 1] = e.pal .. " -> " .. e.fence
        end
        log.info("fenced: " .. table.concat(who, "; "))
    end

    M.last_report = {
        lines = stats.lines,
        summary = (stats.camps > 0) and M.format_stats(cfg, stats) or "no base camp loaded",
        camps = stats.camps,
        pals = stats.pals,
        fenced = stats.fenced,
        toggles = cfg.dry_run and stats.would_toggle or stats.toggles,
    }

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
    parts[#parts + 1] = moved .. (cfg.dry_run and " would toggle" or " toggled")

    if stats.failed > 0 then parts[#parts + 1] = stats.failed .. " failed" end
    if stats.deferred > 0 then parts[#parts + 1] = stats.deferred .. " deferred" end
    if stats.unreadable > 0 then parts[#parts + 1] = stats.unreadable .. " unreadable" end
    if stats.capped > 0 then parts[#parts + 1] = stats.capped .. " capped" end
    if stats.unknown_work > 0 then parts[#parts + 1] = stats.unknown_work .. " untyped" end
    if stats.covered > 0 then parts[#parts + 1] = stats.covered .. " covered" end
    if stats.idle_skipped > 0 then parts[#parts + 1] = stats.idle_skipped .. " camp(s) idle" end
    if stats.demand_estimated then parts[#parts + 1] = "demand ESTIMATED" end

    local wants = demand_summary(stats)
    if wants then return table.concat(parts, ", ") .. "  |  wanted: " .. wants end
    return table.concat(parts, ", ")
end

return M
