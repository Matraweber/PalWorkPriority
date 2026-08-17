-- The priority pass.
--
-- For one base camp:
--   1. every work is bucketed by the suitability it needs
--   2. buckets are visited in configured priority order, 1 before 5
--   3. inside a bucket, each work takes the best-suited pal not yet claimed
--
-- A pal is claimed at most once per pass, which is what makes the ordering
-- mean anything: priority 1 gets first pick of the whole roster, priority 5
-- gets whatever is left. A pal set to false for a work type is never a
-- candidate for it.

local log = require("log")
local api = require("palapi")
local workdefs = require("workdefs")

local M = {}

-- work key -> pal slot key, remembered across passes so an unchanged
-- assignment is not re-sent every cycle.
local last_assignment = {}

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

-- Highest suitability rank wins; ties break on slot order so the result is
-- stable between passes and pals do not shuffle jobs for no reason.
local function best_candidate(cfg, pals, claimed, work_name, value)
    local best, best_rank = nil, 0

    for _, pal in ipairs(pals) do
        if not claimed[pal.slot_index] then
            local prio = priority_for(cfg, pal, work_name)
            if prio ~= nil and prio ~= false then
                local rank = api.suitability_rank(pal.param, value)
                if rank >= cfg.min_suitability_rank and rank > best_rank then
                    best, best_rank = pal, rank
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

-- Groups a camp's works by the suitability name they need, and returns the
-- groups already sorted into priority order.
local function build_buckets(cfg, works, stats)
    local by_name = {}

    for _, w in ipairs(works) do
        local value = api.work_suitability(w)
        local name = value and workdefs.name(value) or nil

        if name == nil then
            stats.unknown_work = stats.unknown_work + 1
        else
            local prio = cfg.work_priority[name]
            if prio == nil then
                stats.unconfigured = stats.unconfigured + 1
            elseif prio == false then
                stats.disabled_work = stats.disabled_work + 1
            else
                by_name[name] = by_name[name] or { name = name, prio = prio, value = value, works = {} }
                table.insert(by_name[name].works, w)
            end
        end
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

    local buckets = build_buckets(cfg, works, stats)
    local claimed = {}

    for _, bucket in ipairs(buckets) do
        for _, w in ipairs(bucket.works) do
            local pal, rank = best_candidate(cfg, pals, claimed, bucket.name, bucket.value)

            if pal then
                claimed[pal.slot_index] = true

                local wkey = work_key(w)
                if last_assignment[wkey] == pal.slot_index then
                    stats.unchanged = stats.unchanged + 1
                else
                    local line = string.format(
                        "%s (p%d) -> %s rank %d",
                        workdefs.label(bucket.name), bucket.prio, pal.name, rank)

                    if cfg.dry_run then
                        stats.would_assign = stats.would_assign + 1
                        log.info("[dry run] " .. line)
                    else
                        local ok, err = api.assign(camp_id, api.work_id(w), pal.id)
                        if ok then
                            last_assignment[wkey] = pal.slot_index
                            stats.assigned = stats.assigned + 1
                            log.info(line)
                        else
                            stats.failed = stats.failed + 1
                            log.warn("assign failed for " .. line .. ": " .. tostring(err))
                        end
                    end
                end
            else
                stats.unstaffed = stats.unstaffed + 1
            end
        end
    end
end

-- Runs one pass over every loaded camp. Returns a stats table; the caller
-- decides whether to print it.
function M.run_pass(cfg)
    local stats = {
        camps = 0, pals = 0, works = 0,
        assigned = 0, would_assign = 0, unchanged = 0, failed = 0,
        unstaffed = 0, unknown_work = 0, unconfigured = 0, disabled_work = 0,
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

    return stats
end

function M.format_stats(cfg, stats)
    local verb = cfg.dry_run and (stats.would_assign .. " would assign") or (stats.assigned .. " assigned")
    local parts = {
        string.format("%d camp(s), %d pal(s), %d work(s)", stats.camps, stats.pals, stats.works),
        verb,
        stats.unchanged .. " unchanged",
    }
    if stats.failed > 0 then parts[#parts + 1] = stats.failed .. " failed" end
    if stats.unstaffed > 0 then parts[#parts + 1] = stats.unstaffed .. " unstaffed" end
    if stats.unknown_work > 0 then parts[#parts + 1] = stats.unknown_work .. " unreadable" end
    if stats.unconfigured > 0 then parts[#parts + 1] = stats.unconfigured .. " unconfigured" end
    if stats.disabled_work > 0 then parts[#parts + 1] = stats.disabled_work .. " off" end
    return table.concat(parts, ", ")
end

return M
