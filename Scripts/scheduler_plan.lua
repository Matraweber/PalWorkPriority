-- Pure permission allocation. Inputs contain Lua values only, never engine
-- objects. A seat is a permission to work a type, including fallback/widened
-- permissions; counting only a pal's preferred job does not enforce a limit.
local M = {}

M.HOLD_SECONDS = 90

local function priority(pal, value)
    local p = pal.priorities[value]
    return type(p) == "number" and p or math.huge
end

local function rank(pal, value)
    return pal.ranks[value] or 0
end

-- A Pal whose allowed jobs all share one number has no order to follow: a
-- fresh install's captured "all 1", an all-1 setup, or a Pal nobody edited.
-- It is left to the game (user's decision 2026-10-27): every job it may do
-- stays allowed, X and stock limits still apply (they are already out of
-- pal.base), and it takes no seat from the Pals the mod steers.
--
-- Judged on every job the Pal can do that has a number, capped or not, and
-- only with two or more of them: the same rule as the stand's "same number"
-- hint (ui.lua same_number), so the grid and the scheduler agree. Judging on
-- pal.base made a stock limit decide it: Mining 1 and the rest 2 with Mining
-- capped read as unordered, and a Pal with one numbered job was "left to the
-- game" although the stand showed nothing (review round 4, scheduler P3-1).
function M.unordered(pal)
    local seen, count = nil, 0
    for value in pairs(pal.capable or pal.priorities or {}) do
        local p = pal.priorities and pal.priorities[value]
        if type(p) == "number" then
            if seen ~= nil and seen ~= p then return false end
            seen, count = p, count + 1
        end
    end
    return count >= 2
end

local function sorted_pals(pals)
    local out = {}
    for _, pal in ipairs(pals) do out[#out + 1] = pal end
    table.sort(out, function(a, b) return tostring(a.key) < tostring(b.key) end)
    return out
end

-- Only evidence for THIS assignment may extend a hold. A recent pulse for a
-- different job of the same suitability says nothing about this worker.
local function retained(pal, holds, now, interval)
    local a, key = pal.assignment, pal.hold_key or pal.key
    if type(key) ~= "string" or key:match("^slot%d+$") then return nil end
    if type(a) ~= "table" or type(a.id) ~= "string" or a.id == ""
        or not pal.base[a.value] then
        holds[key] = nil
        return nil
    end
    if a.state == "occupied" then
        holds[key] = { id = a.id, value = a.value, seen = now, last = now }
        return a.value
    end
    local h = holds[key]
    if a.state == "unknown" and h and h.id == a.id and h.value == a.value
        and now >= h.seen and now - h.seen < M.HOLD_SECONDS
        and now - h.last <= 2 * interval then
        h.last = now
        return a.value
    end
    holds[key] = nil
    return nil
end

local function better(a, b)
    if a.rank ~= b.rank then return a.rank > b.rank end
    if a.held ~= b.held then return a.held end
    if a.pal.key ~= b.pal.key then
        return tostring(a.pal.key) < tostring(b.pal.key)
    end
    return a.value < b.value
end

function M.plan(cfg, pals, demand, holds, now)
    holds, now = holds or {}, now or os.time()
    local cap = tonumber(cfg.max_pals_per_work_type)
    if not cap or cap <= 0 then cap = math.huge else cap = math.floor(cap) end
    local spread = cfg.assignment_mode ~= "fill"
    local minimum = tonumber(cfg.min_suitability_rank) or 1
    local interval = tonumber(cfg.interval_seconds) or 10
    local plan, chosen, taken, active, holding = {}, {}, {}, {}, {}
    local report = {
        fenced = 0, free = 0, held = 0, staff_limited = 0,
        manual_conflicts = 0, manual_limit_conflicts = 0,
        assignment_unknown = 0, manual_unavailable = 0, unverified_limit_conflicts = 0,
        unsteered = 0,
    }
    local steered = {}
    local leave = cfg.leave_unordered_pals_to_game ~= false
    for _, pal in ipairs(pals) do
        if leave and M.unordered(pal) then
            local all = {}
            for value in pairs(pal.base or {}) do all[value] = true end
            plan[pal.key] = all
            report.unsteered = report.unsteered + 1
        else
            steered[#steered + 1] = pal
        end
    end
    local roster = sorted_pals(steered)

    for key, h in pairs(holds) do
        if now < h.seen or now - h.last > M.HOLD_SECONDS + 2 * interval then
            holds[key] = nil
        end
    end
    for _, pal in ipairs(roster) do
        plan[pal.key] = {}
        local value = retained(pal, holds, now, interval)
        holding[pal.key] = value
        if value then active[value] = (active[value] or 0) + 1 end
        if not pal.assignment or pal.assignment.state == "unknown" then
            report.assignment_unknown = report.assignment_unknown + 1
        end
    end

    local function grant(pal, value)
        if not plan[pal.key][value] then
            plan[pal.key][value] = true
            taken[value] = (taken[value] or 0) + 1
        end
    end

    -- A verified deliberate assignment outranks automatic redistribution.
    -- X/production conflicts remain explicit. If fixed assignments already
    -- exceed the configured staffing maximum, retain them and report the
    -- conflict; no additional automatic worker is admitted to that type.
    for _, pal in ipairs(roster) do
        local a = pal.assignment
        if a and a.manual == true and a.state ~= "completed" then
            if pal.base[a.value] and type(a.id) == "string" and a.id ~= "" then
                grant(pal, a.value)
                chosen[pal.key] = { value = a.value, manual = true }
                if taken[a.value] > cap then
                    report.manual_limit_conflicts = report.manual_limit_conflicts + 1
                end
            else
                report.manual_conflicts = report.manual_conflicts + 1
            end
        elseif not a or a.manual == nil then
            -- A current suitability does not identify an assignment or say
            -- whether the player fixed it deliberately. Preserve an already
            -- enabled types until that distinction is readable. A missing
            -- current suitability also conflates idle with unreadable. It
            -- still consumes capacity; excess unverified workers are visible
            -- and no further automatic worker may be admitted. X and legacy
            -- production restrictions in pal.base remain absolute.
            report.manual_unavailable = report.manual_unavailable + 1
            local observed = pal.observed_on or {}
            if pal.current and pal.current_permitted then observed[pal.current] = true end
            for value in pairs(observed) do
                if pal.base[value] then
                    grant(pal, value)
                    -- No selected assignment/priority is known here. The
                    -- reservation accounts for permissions only, not work.
                    chosen[pal.key] = { unverified = true }
                    if taken[value] > cap then
                        report.unverified_limit_conflicts = report.unverified_limit_conflicts + 1
                    end
                end
            end
        end
    end

    local function room(value, lap)
        -- Pulse counts describe vacant work; current workers consume seats
        -- too. Unknown/expired work is never promoted to ready work here.
        local limit = math.min(cap, (demand[value] or 0) + (active[value] or 0))
        if spread then limit = math.min(limit, lap) end
        return (taken[value] or 0) < limit
    end

    local laps = spread and math.min(#roster, cap) or 1
    for lap = 1, laps do
        for level = 1, 5 do
            local candidates = {}
            for _, pal in ipairs(roster) do
                if not chosen[pal.key] and pal.assignment and pal.assignment.manual == false then
                    for value in pairs(pal.base) do
                        local held = holding[pal.key] == value
                        if priority(pal, value) == level and rank(pal, value) >= minimum
                            and ((demand[value] or 0) > 0 or held) then
                            candidates[#candidates + 1] = {
                                pal = pal, value = value, rank = rank(pal, value), held = held,
                            }
                        end
                    end
                end
            end
            table.sort(candidates, better)
            for _, c in ipairs(candidates) do
                if not chosen[c.pal.key] and room(c.value, lap) then
                    grant(c.pal, c.value)
                    chosen[c.pal.key] = { value = c.value, held = c.held }
                end
            end
        end
    end

    -- Reserve each selected job first, then consider equal/higher priorities
    -- and unfenced fallback permissions against the SAME capacity ledger.
    -- Rank comparisons are across the roster, with identity as a stable tie.
    local extras = {}
    for _, pal in ipairs(roster) do
        local selected = chosen[pal.key]
        local level = selected and priority(pal, selected.value) or math.huge
        for value in pairs(pal.base) do
            if not plan[pal.key][value] and priority(pal, value) <= level
                and rank(pal, value) >= minimum and not (selected and selected.manual)
                -- Unknown manual intent preserves observed permissions only.
                -- Fallback must not bypass that boundary by adding new types.
                and pal.assignment and pal.assignment.manual == false then
                extras[#extras + 1] = {
                    pal = pal, value = value, rank = rank(pal, value),
                    held = holding[pal.key] == value,
                    priority = priority(pal, value),
                }
            end
        end
    end
    table.sort(extras, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return better(a, b)
    end)
    for _, c in ipairs(extras) do
        if (taken[c.value] or 0) < cap then
            grant(c.pal, c.value)
        else
            report.staff_limited = report.staff_limited + 1
        end
    end

    for _, pal in ipairs(roster) do
        local selected = chosen[pal.key]
        if selected then
            report.fenced = report.fenced + 1
            if selected.held then report.held = report.held + 1 end
        else
            report.free = report.free + 1
        end
    end
    return plan, report
end

return M
