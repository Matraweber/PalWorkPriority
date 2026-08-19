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
local demandidx = require("demand")

local M = {}

M.last_report = nil

-- One pass never issues an unbounded number of RPCs. Steady state sends
-- almost nothing because only differences go out; this bounds the first pass
-- over a large base, and whatever is skipped is picked up next tick.
local MAX_TOGGLES_PER_PASS = 40

-- How long a pal may be held on work that no longer announces itself.
--
-- The hold exists to stop a fence being released mid-job, which takes
-- seconds to a minute. It must NOT outlast the job: a workbench keeps its
-- work object forever, and a pal that has finished crafting still reports
-- Handiwork as its current work, so an unbounded hold pins it at the bench
-- with everything else switched off and nothing left to do.
--
-- Real demand resets the clock, so a pal that keeps getting genuine work of
-- that type is never aged out — only one that has run dry.
local HOLD_SECONDS = 90

-- pal key -> { value, since }. Which work each pal is being held on and when
-- that hold began.
local hold_since = {}

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
--
-- `works` here must be the camp's REQUIRED works, not every work object it
-- owns. A station keeps a work object for as long as it stands, so counting
-- all of them makes a cold campfire look like pending kindling — and a pal
-- fenced to kindling on the strength of it stands idle while the logging it
-- was barred from goes undone.
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

-- How many work objects of each type exist in this camp, announcing or not.
--
-- This is NOT demand. A station keeps its work object while it stands, so
-- these counts happily include a cold campfire. It answers a narrower
-- question: is there any work of this type left at all? That is enough to
-- decide whether a pal already doing that work should carry on, without
-- being enough to pull an idle pal in.
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
local function plan_fences(cfg, pals, demand, objects, stats)
    local plan, fenced = {}, {}
    local taken = {}            -- work value -> pals fenced onto it
    local cap = tonumber(cfg.max_pals_per_work_type)
    local spread = (cfg.assignment_mode ~= "fill")

    local function wanted(value)
        return (demand[value] or 0) > 0
    end

    -- Whether a work type can still absorb ANOTHER pal. Demand is the real
    -- limit: three pending haul jobs never need a fourth hauler, whatever the
    -- priorities say. In spread mode lap tightens it further, so every work
    -- type gets one pal before any gets a second.
    --
    -- This decides only whether a pal is PULLED to a level. It must not
    -- decide what goes in the fence — doing both meant a pal with two
    -- priority-1 types lost one of them the moment another pal took the last
    -- slot on it, and got that work switched off while it was still wanted.
    local function room(value, lap)
        local limit = demand[value] or 0
        if cap and cap < limit then limit = cap end
        if spread and lap < limit then limit = lap end
        return (taken[value] or 0) < limit
    end

    for _, pal in ipairs(pals) do
        pal.base = base_allowed(cfg, pal)
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

    -- A pal already working a type keeps it while any work of that type
    -- remains, even when none of it is announcing.
    --
    -- This is the asymmetry that makes the whole thing hold together. To PULL
    -- a pal to a work type takes a real pulse, so nobody is sent to a cold
    -- station. To KEEP a pal where it already is takes only that work of that
    -- type still exists. Without it a fence is released the instant a job is
    -- assigned - because an assigned job stops asking for anyone, so by demand
    -- alone it looks finished the moment it truly starts. The pal then has its
    -- other work types switched back on mid-swing and wanders off to a lower
    -- priority the moment the tree falls, with the whole logging site still
    -- standing.
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
                                -- the job it is already doing — but that one
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

    local totals = {}
    if needs_totals(cfg) then
        local chests
        totals, chests = api.camp_item_totals(api.guid_key(camp_id))
        stats.chests = stats.chests + (chests or 0)
    end

    -- What the camp actually wants doing, from the game's own pulses.
    --
    -- The all-works fallback runs only when the hook did not REGISTER. It
    -- must not key off the pulse count: a base whose pals are asleep produces
    -- no pulses, and falling back there would fence the whole roster onto
    -- night work that does not exist. No pulses with a live hook means
    -- nothing wants doing, which is a real answer.
    local camp_key = api.guid_key(camp_id)
    local demand, live = demandidx.for_camp(camp_key)
    local counted = live

    if not demandidx.hooked then
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
    -- here — a live pass was seen reporting 0 works between passes reporting
    -- 200. Unfencing the whole base on it costs a dozen toggles and another
    -- dozen to put back, so the existing fences are left exactly as they are.
    -- An idle base loses nothing by staying fenced; there is no work either
    -- way.
    if next(demand) == nil then
        stats.idle_skipped = stats.idle_skipped + 1
        return
    end

    local objects = count_work_objects(camp)
    local plan = plan_fences(cfg, pals, demand, objects, stats)

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

    for _, camp in ipairs(camps) do
        local ok, err = pcall(function() run_camp(cfg, camp, stats) end)
        if not ok then
            log.warn("pass threw on a camp: " .. tostring(err))
        end
    end

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

-- "3 type(s)" says nothing about WHICH three, and which they are is the
-- whole question when a pal is on the wrong job. Name them.
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
