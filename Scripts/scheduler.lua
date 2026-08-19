-- The priority pass, as a fence rather than an assignment.
--
-- The mod does not hand pals specific jobs. It decides which work types each
-- pal is ALLOWED to do right now and switches the rest off, then lets
-- Palworld's own AI choose within that. A pal whose top-priority work has
-- something waiting gets everything else switched off, so the AI has nowhere
-- else to send it.
--
-- The earlier design pinned one pal to one work object through
-- RequestFixedAssignWorkInBaseCamp_ToServer and left the AI otherwise free,
-- so a pal could still wander off to a lower-priority job the moment it
-- finished — items waiting to be carried while a pal went watering instead.
-- Fencing is how PalPriority does it, and it is the mechanism that actually
-- makes a priority order govern behaviour.
--
-- Per camp, per pass:
--   1. count DEMAND: how many pending jobs exist of each work type
--   2. walk priority levels 1..MAX, fencing each pal to the first level where
--      it is capable of something that still has demand to spare
--   3. a pal fenced nowhere is left unfenced — everything it may legally do
--      stays on, since barring an unneeded pal from everything just idles it
--   4. diff against the game's own permissions and send only the differences
--
-- Restoring is stateless. A pal's permissions are always
-- "capable AND not X AND (fenced-in OR unfenced)", so switching the mod off
-- puts back "capable AND not X" with no record of what was there before.
-- The cost is that a work type you unchecked by hand in vanilla will be
-- switched back on; X is how you say "never" to this mod.

local log = require("log")
local api = require("palapi")
local workdefs = require("workdefs")
local store = require("store")

local M = {}

M.last_report = nil

-- One pass never issues an unbounded number of RPCs. Steady state sends
-- almost nothing because only differences go out; this bounds the first pass
-- over a large base, and whatever is skipped is picked up next tick.
local MAX_TOGGLES_PER_PASS = 40

function M.forget()
    -- Nothing is remembered between passes any more: the fence is recomputed
    -- from demand every time, and the game's own permissions are the only
    -- persistent state. Kept so callers need not care.
end

-- ---------------------------------------------------------------------------
-- Demand
-- ---------------------------------------------------------------------------

local function cap_reached(cfg, work_name, totals)
    local caps = (cfg.work_caps or {})[work_name]
    if type(caps) ~= "table" then return false end

    local listed = false
    for item, ceiling in pairs(caps) do
        listed = true
        if type(ceiling) == "number" and (totals[item] or 0) < ceiling then
            return false
        end
    end
    return listed
end

-- How many pending jobs of each work type this camp has. A work type whose
-- resource ceiling is met contributes nothing, which is what makes a ceiling
-- release pals to other work rather than merely stop them.
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
            demand[value] = (demand[value] or 0) + 1
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
local function base_allowed(cfg, pal)
    local out = {}
    for i = 1, #workdefs.ORDER do
        local name = workdefs.ORDER[i]
        local value = workdefs.value(name)

        if api.suitability_rank(pal.param, value) >= 1 then
            -- X is the only thing that bars a pal outright. A work type with
            -- no configured priority stays permitted: having no opinion on it
            -- is not the same as forbidding it.
            if store.effective(cfg, pal, name, value) ~= false then
                out[value] = true
            end
        end
    end
    return out
end

-- Returns pal key -> set of work values that pal may do this pass.
local function plan_fences(cfg, pals, demand, stats)
    local plan, fenced = {}, {}
    local taken = {}            -- work value -> pals fenced onto it
    local cap = tonumber(cfg.max_pals_per_work_type)
    local spread = (cfg.assignment_mode ~= "fill")

    -- What a work type can still absorb. Demand is the real limit: three
    -- pending haul jobs never need a fourth hauler, whatever the priorities
    -- say. In spread mode lap tightens it further, so every work type gets
    -- one pal before any gets a second.
    local function room(value, lap)
        local limit = demand[value] or 0
        if cap and cap < limit then limit = cap end
        if spread and lap < limit then limit = lap end
        return (taken[value] or 0) < limit
    end

    for _, pal in ipairs(pals) do
        pal.base = base_allowed(cfg, pal)
    end

    local laps = spread and math.max(cap or #pals, 1) or 1
    for lap = 1, laps do
        for level = 1, store.MAX do
            for _, pal in ipairs(pals) do
                if not fenced[pal.key] then
                    local fence = {}
                    local best, best_rank = nil, -1

                    for value in pairs(pal.base) do
                        local name = workdefs.name(value)
                        if store.effective(cfg, pal, name, value) == level
                            and room(value, lap) then

                            local rank = api.suitability_rank(pal.param, value)
                            if rank >= cfg.min_suitability_rank then
                                fence[value] = true
                                if rank > best_rank then best, best_rank = value, rank end
                            end
                        end
                    end

                    if best then
                        -- Fenced to the whole level, not only the one type it
                        -- is best at: a pal should be free to move between
                        -- equally-wanted jobs without waiting on a re-plan.
                        plan[pal.key] = fence
                        fenced[pal.key] = true
                        taken[best] = (taken[best] or 0) + 1
                        stats.fenced = stats.fenced + 1
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

    for value in pairs(pal.base or {}) do
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

local function needs_totals(cfg)
    local caps = cfg.work_caps
    if type(caps) ~= "table" then return false end
    return next(caps) ~= nil
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

    local works, work_err = api.camp_works(camp)
    if work_err then
        log.debug("camp works unavailable: " .. work_err)
        api.request_work_replication(camp_id, true)
        return
    end

    stats.camps = stats.camps + 1
    stats.pals = stats.pals + #pals
    stats.works = stats.works + #works

    local totals = {}
    if needs_totals(cfg) then
        local chests
        totals, chests = api.camp_item_totals(api.guid_key(camp_id))
        stats.chests = stats.chests + (chests or 0)
    end

    local demand = build_demand(cfg, works, totals, stats)
    for _ in pairs(demand) do stats.demand_types = stats.demand_types + 1 end

    local plan = plan_fences(cfg, pals, demand, stats)

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

        pal.base = nil
    end
end

function M.run_pass(cfg)
    local stats = {
        camps = 0, pals = 0, works = 0, chests = 0,
        fenced = 0, free = 0,
        toggles = 0, would_toggle = 0, failed = 0, deferred = 0, unreadable = 0,
        demand_types = 0,
        unknown_work = 0, unconfigured = 0, capped = 0, ignored = 0,
        lines = {},
    }

    local camps = api.base_camps()
    if #camps == 0 then
        log.debug("no base camps loaded")
        M.last_report = nil
        return stats
    end

    for _, camp in ipairs(camps) do
        local ok, err = pcall(function() run_camp(cfg, camp, stats) end)
        if not ok then
            log.warn("pass threw on a camp: " .. tostring(err))
        end
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

function M.format_stats(cfg, stats)
    local parts = {
        string.format("%d camp(s), %d pal(s), %d work(s) in %d type(s)",
            stats.camps, stats.pals, stats.works, stats.demand_types),
        stats.fenced .. " fenced",
        stats.free .. " free",
    }

    local moved = cfg.dry_run and stats.would_toggle or stats.toggles
    parts[#parts + 1] = moved .. (cfg.dry_run and " would toggle" or " toggled")

    if stats.failed > 0 then parts[#parts + 1] = stats.failed .. " failed" end
    if stats.deferred > 0 then parts[#parts + 1] = stats.deferred .. " deferred" end
    if stats.unreadable > 0 then parts[#parts + 1] = stats.unreadable .. " unreadable" end
    if stats.capped > 0 then parts[#parts + 1] = stats.capped .. " capped" end
    if stats.unknown_work > 0 then parts[#parts + 1] = stats.unknown_work .. " untyped" end
    return table.concat(parts, ", ")
end

return M
