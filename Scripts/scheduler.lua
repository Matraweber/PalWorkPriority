-- The priority pass.
--
-- For one base camp:
--   1. every work is bucketed by the suitability it needs
--   2. buckets whose resource ceiling is already met are dropped
--   3. surviving buckets are visited in configured priority order, 1 before 5
--   4. inside a bucket, each work takes the best-suited pal not yet claimed
--
-- A pal is claimed at most once per pass, which is what makes the ordering
-- mean anything: priority 1 gets first pick of the whole roster, priority 5
-- gets whatever is left. A pal set to false for a work type is never a
-- candidate for it.
--
-- Dropping a capped bucket in step 2 is what makes ceilings useful rather
-- than merely restrictive: the pals that would have worked it are still
-- unclaimed when the next priority is reached, so they move down to it
-- instead of standing idle next to a full wood chest.

local log = require("log")
local api = require("palapi")
local workdefs = require("workdefs")

local M = {}

-- work key -> pal key, remembered across passes so an unchanged assignment
-- is not re-sent every cycle.
local last_assignment = {}

M.last_report = nil

function M.forget()
    last_assignment = {}
end

local function priority_for(cfg, pal, work_name)
    local overrides = cfg.pal_overrides or {}
    local entry = overrides[pal.name]
    if entry == nil and pal.species then entry = overrides[pal.species] end

    if type(entry) == "table" then
        local v = entry[work_name]
        if v ~= nil then return v end
    end
    return cfg.work_priority[work_name]
end

-- True when every item listed for this work type is at or above its ceiling.
--
-- "Every" rather than "any" on purpose: a mining cap covering stone plus ore
-- should keep mining alive while either one is still short. A work type with
-- no entry, or an empty entry, is never capped.
--
-- An unreadable storage total counts as zero, which errs toward keeping work
-- running. Suspending a whole work type because a chest failed to reply
-- would be a much worse failure than briefly overshooting a ceiling.
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

-- Picks the pal that should take this work.
--
-- An explicit pal_overrides entry outranks suitability: setting
-- ["Diggy"] = { Mining = 1 } means you want Diggy mining even if a better
-- miner is standing next to them. Only when two pals carry the same priority
-- does raw suitability rank decide, and slot order breaks the remaining ties
-- so repeat passes stay stable and pals do not shuffle jobs for no reason.
local function best_candidate(cfg, pals, claimed, work_name, value)
    local best, best_prio, best_rank = nil, nil, 0

    -- Work filed under Anyone names no skill, so every pal scores 0 on it.
    -- Ranking and the rank floor are both meaningless there; treating every
    -- pal as an equal candidate is the only reading that assigns anybody.
    local unskilled = (work_name == workdefs.ANYONE)

    for _, pal in ipairs(pals) do
        if not claimed[pal.key] then
            local prio = priority_for(cfg, pal, work_name)
            if type(prio) == "number" then
                local rank = unskilled and 1 or api.suitability_rank(pal.param, value)
                if rank >= (unskilled and 1 or cfg.min_suitability_rank) then
                    local wins
                    if best == nil then
                        wins = true
                    elseif prio ~= best_prio then
                        wins = prio < best_prio
                    else
                        wins = rank > best_rank
                    end
                    if wins then
                        best, best_prio, best_rank = pal, prio, rank
                    end
                end
            end
        end
    end

    return best, best_rank
end

local function work_key(w)
    local key = api.guid_key(api.work_id(w))
    if key then return key end
    return api.work_full_name(w)
end

-- Groups the works of a camp by the suitability they need, and returns the
-- groups already sorted into priority order.
local function build_buckets(cfg, works, totals, stats)
    local by_name = {}
    local capped_names = {}

    for _, w in ipairs(works) do
        local value, reason = api.work_suitability(w)
        local name = value and workdefs.name(value) or nil

        if name == nil then
            -- "ignored" is a thing that is deliberately not work, such as an
            -- idle placeholder. Counting it as unreadable would make coverage
            -- look worse than it is.
            if reason == "ignored" then
                stats.ignored = stats.ignored + 1
            else
                stats.unknown_work = stats.unknown_work + 1
            end
        else
            local prio = cfg.work_priority[name]
            if prio == nil then
                stats.unconfigured = stats.unconfigured + 1
            elseif prio == false then
                stats.disabled_work = stats.disabled_work + 1
            elseif cap_reached(cfg, name, totals) then
                stats.capped = stats.capped + 1
                capped_names[name] = true
            else
                by_name[name] = by_name[name]
                    or { name = name, prio = prio, value = value, works = {} }
                table.insert(by_name[name].works, w)
            end
        end
    end

    for name in pairs(capped_names) do
        log.debug("ceiling reached, " .. workdefs.label(name) .. " suspended this pass")
    end

    local ordered = {}
    for _, bucket in pairs(by_name) do
        ordered[#ordered + 1] = bucket
    end
    table.sort(ordered, function(a, b)
        if a.prio ~= b.prio then return a.prio < b.prio end
        return a.name < b.name
    end)

    return ordered
end

-- Storage is only read when at least one ceiling is configured, so a default
-- setup pays nothing for a feature it is not using.
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
    if #works == 0 then
        log.debug("camp has no pending work")
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
        if chests == 0 then
            log.debug("no chests answered for this camp, ceilings treated as unmet")
        end
    end

    -- A pal has to be distinguishable from its neighbours. If identity
    -- collapses, the claim set accepts one pal and every other work in the
    -- base reports as unstaffed — which looks like a ranking problem and is
    -- not one. Worth a line of checking to never chase that again.
    local distinct, seen_keys = 0, {}
    for _, p in ipairs(pals) do
        if p.key ~= nil and not seen_keys[p.key] then
            seen_keys[p.key] = true
            distinct = distinct + 1
        end
    end
    if distinct < #pals then
        log.warn(string.format(
            "pal identity collision: %d pal(s) share only %d key(s) — at most %d will be assigned",
            #pals, distinct, distinct))
    end

    local buckets = build_buckets(cfg, works, totals, stats)

    local claimed, claimed_count = {}, 0
    local taken = {}                  -- work type -> pals placed on it this pass
    local cursor = {}                 -- per bucket, the next work to consider
    for i = 1, #buckets do cursor[i] = 1 end

    local spread = (cfg.assignment_mode ~= "fill")
    local cap = tonumber(cfg.max_pals_per_work_type)

    -- Places one pal on one work. Returns the pal, or nil when nothing
    -- qualified — in which case the work is spent and counted unstaffed.
    local function place(bucket, w)
        local pal, rank = best_candidate(cfg, pals, claimed, bucket.name, bucket.value)
        if not pal then
            stats.unstaffed = stats.unstaffed + 1
            return nil
        end

        claimed[pal.key] = true

        -- Recorded before the unchanged check on purpose: a pal already doing
        -- the right job is still part of what the pass decided, and leaving it
        -- out would make the stand panel look emptier every cycle.
        stats.lines[#stats.lines + 1] = {
            label = workdefs.label(bucket.name),
            prio = bucket.prio,
            pal = pal.name,
            rank = rank,
            -- identity and suitability value, so the stand UI can find the
            -- exact cell this decision belongs to
            key = pal.key,
            value = bucket.value,
        }

        local wkey = work_key(w)
        if last_assignment[wkey] == pal.key then
            stats.unchanged = stats.unchanged + 1
            return pal
        end

        local line = string.format("%s (p%d) -> %s rank %d",
            workdefs.label(bucket.name), bucket.prio, pal.name, rank)

        if cfg.dry_run then
            stats.would_assign = stats.would_assign + 1
            log.info("[dry run] " .. line)
        else
            local ok, err = api.assign(camp_id, api.work_id(w), pal.id)
            if ok then
                last_assignment[wkey] = pal.key
                stats.assigned = stats.assigned + 1
                log.info(line)
            else
                stats.failed = stats.failed + 1
                log.warn("assign failed for " .. line .. ": " .. tostring(err))
            end
        end
        return pal
    end

    -- Buckets are walked in priority order, repeatedly.
    --
    -- In spread mode each visit places at most ONE pal, so every work type
    -- gets somebody before any of them gets a second — a base with 46
    -- pending transport jobs no longer swallows the whole roster before
    -- mining is even considered. In fill mode a visit places as many as it
    -- can, which is the older "priority 1 first, completely" reading.
    --
    -- Either way a work type stops accepting pals once it holds cap of them.
    -- Laps end when one produces no assignment at all, or when every pal is
    -- busy.
    local lap_progress = true
    while lap_progress and claimed_count < #pals do
        lap_progress = false

        for bi, bucket in ipairs(buckets) do
            if claimed_count >= #pals then break end

            local quota = spread and 1 or #bucket.works
            local placed = 0

            while placed < quota
                and cursor[bi] <= #bucket.works
                and claimed_count < #pals
                and not (cap and (taken[bucket.name] or 0) >= cap) do

                local w = bucket.works[cursor[bi]]
                cursor[bi] = cursor[bi] + 1

                if place(bucket, w) then
                    claimed_count = claimed_count + 1
                    taken[bucket.name] = (taken[bucket.name] or 0) + 1
                    placed = placed + 1
                    lap_progress = true
                end
            end
        end
    end

    -- Work never reached: the roster ran out, or its work type hit the cap.
    -- Not a failure to staff, just more work than there are pals to do it.
    for bi, bucket in ipairs(buckets) do
        local left = #bucket.works - (cursor[bi] - 1)
        if left > 0 then stats.queued = stats.queued + left end
    end
end

-- Runs one pass over every loaded camp. Returns a stats table; the caller
-- decides whether to print it.
function M.run_pass(cfg)
    local stats = {
        camps = 0, pals = 0, works = 0, chests = 0,
        assigned = 0, would_assign = 0, unchanged = 0, failed = 0,
        unstaffed = 0, unknown_work = 0, unconfigured = 0, disabled_work = 0,
        ignored = 0, queued = 0,
        -- what the pass decided, for the Monitoring Stand panel
        lines = {},
        capped = 0,
    }

    local camps = api.base_camps()
    if #camps == 0 then
        log.debug("no base camps loaded")
        return stats
    end

    for _, camp in ipairs(camps) do
        local ok, err = pcall(function() run_camp(cfg, camp, stats) end)
        if not ok then
            log.warn("pass threw on a camp: " .. tostring(err))
        end
    end

    -- Held for the stand panel, which renders between passes and has no other
    -- way to know what the last one concluded.
    -- The counts the stand strip needs, kept apart from the log summary:
    -- the strip has roughly fifty characters of room and the log line runs to
    -- a hundred and twenty.
    M.last_report = {
        lines = stats.lines,
        summary = (stats.camps > 0) and M.format_stats(cfg, stats) or "no base camp loaded",
        camps = stats.camps,
        pals = stats.pals,
        placed = (cfg.dry_run and stats.would_assign or stats.assigned) + stats.unchanged,
        queued = stats.queued,
    }

    return stats
end

function M.format_stats(cfg, stats)
    local verb = cfg.dry_run
        and (stats.would_assign .. " would assign")
        or (stats.assigned .. " assigned")

    local parts = {
        string.format("%d camp(s), %d pal(s), %d work(s)", stats.camps, stats.pals, stats.works),
        verb,
        stats.unchanged .. " unchanged",
    }
    if stats.capped > 0 then parts[#parts + 1] = stats.capped .. " capped" end
    if stats.failed > 0 then parts[#parts + 1] = stats.failed .. " failed" end
    if stats.unstaffed > 0 then parts[#parts + 1] = stats.unstaffed .. " unstaffed" end
    if stats.queued > 0 then parts[#parts + 1] = stats.queued .. " queued" end
    if stats.unknown_work > 0 then parts[#parts + 1] = stats.unknown_work .. " unreadable" end
    if stats.unconfigured > 0 then parts[#parts + 1] = stats.unconfigured .. " unconfigured" end
    if stats.disabled_work > 0 then parts[#parts + 1] = stats.disabled_work .. " off" end
    if stats.ignored > 0 then parts[#parts + 1] = stats.ignored .. " not work" end
    return table.concat(parts, ", ")
end

return M
