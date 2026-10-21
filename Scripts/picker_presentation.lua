-- Capability wording only. No engine reads, cached permissions or writes.
--
-- Labels sit on the tile's second line and stay at 21 characters or fewer
-- (test_picker_label_bounds). Details go to the notice row in full. Wording
-- from the 2026-10-21 new-user review: say that 0.5.0 cannot create limits,
-- and say "group limit" / "whole work type" instead of "legacy group".
local M = {}
local workdefs = require('workdefs')

local NO_NEW = 'Version 0.5.0 cannot create new limits. Per-item limits are planned for 0.6.'

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
    if ok and supported == true then
        return {state='create', label=kind=='legacy' and 'Restore group limit' or 'Add item limit',
            detail=kind=='legacy' and ('Group limit for all '..workdefs.label(work)..' work') or 'Item limit'}
    end
    -- Still unavailable (nothing to create or open here), but no longer
    -- "No item limit support" while another item's limit stops this work.
    local group = covering_group(caps, rules, work, guild)
    if group ~= nil then
        local job = workdefs.label(work)
        return {state='unavailable', group=group, label='Group limit applies',
            detail='Covered by the '..job..' limit, which switches all '..job..' work.'}
    end
    local unsupported = ok and supported == false
    return {state='unavailable', label=unsupported and 'New limits in 0.6' or 'Support unknown',
        detail=unsupported and NO_NEW
            or 'Unavailable: item limit support could not be checked.'}
end

return M
