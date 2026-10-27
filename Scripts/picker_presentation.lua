-- Capability wording only. No engine reads, cached permissions or writes.
--
-- Labels sit on the tile's second line and stay at 21 characters or fewer
-- (test_picker_label_bounds). Details go to the notice row in full. Wording
-- from the 2026-10-21 new-user review: say "group limit" / "whole work type"
-- instead of "legacy group". New limits can be created again (2026-10-27);
-- the detail says what one switches before the click that adds it.
local M = {}
local workdefs = require('workdefs')

local NO_LIMIT = 'This item cannot have a limit.'

-- A group (legacy) limit on this work type that covers the item without
-- being its own rule: a Stone limit stops ore mining too. Only rules the
-- caps module itself calls legacy count; an item rule covers only its item.
local function covering_group(caps, rules, work, guild)
    if not caps.rule_kind then return nil end
    for other in pairs(rules[work] or {}) do
        local ok, kind = pcall(caps.rule_kind, work, other, guild)
        if ok and kind == 'legacy' then return other end
    end
end

function M.describe(caps, rules, work, item, guild)
    if not guild then
        return {state='unavailable', label='No guild for limits', detail='Join a guild before editing limits.'}
    end
    local amount = (rules[work] or {})[item]
    local kind = caps.rule_kind and caps.rule_kind(work, item, guild)
    if amount ~= nil and amount ~= false then
        return {state='existing', amount=amount,
            label=kind=='legacy' and 'Edit group limit' or 'Edit existing limit',
            detail=kind=='legacy' and ('Group limit for all '..workdefs.label(work)..' work') or 'Existing item limit'}
    end
    local ok, supported = false, false
    if caps.support then ok, supported = pcall(caps.support, work, item, guild) end
    local job = workdefs.label(work)
    local group = covering_group(caps, rules, work, guild)
    if ok and supported == true then
        -- A second item joins the type's group: the work stops only once
        -- every one of them is reached (scheduler.cap_state).
        local detail = group ~= nil
            and ('Joins the '..job..' limits: '..job..' stops once every one is reached.')
            or ('Stops all '..job..' work once reached, not only this item.')
        return {state='create', group=group,
            label=kind=='legacy' and 'Restore group limit' or 'Add group limit', detail=detail}
    end
    if group ~= nil then
        return {state='unavailable', group=group, label='Group limit applies',
            detail='Covered by the '..job..' limit, which switches all '..job..' work.'}
    end
    local unsupported = ok and supported == false
    return {state='unavailable', label=unsupported and 'Cannot be limited' or 'Support unknown',
        detail=unsupported and NO_LIMIT
            or 'Unavailable: item limit support could not be checked.'}
end

return M
