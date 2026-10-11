-- Capability wording only. No engine reads, cached permissions or writes.
local M = {}
local workdefs = require('workdefs')

function M.describe(caps, rules, work, item, guild)
    if not guild then
        return {state='unavailable', label='No guild for limits', detail='Join a guild before editing limits.'}
    end
    local amount = (rules[work] or {})[item]
    local kind = caps.rule_kind and caps.rule_kind(work, item, guild)
    if amount ~= nil and amount ~= false then
        return {state='existing', amount=amount,
            label=kind=='legacy' and 'Edit legacy group' or 'Edit existing limit',
            detail=kind=='legacy' and ('Legacy group affects all '..workdefs.label(work)) or 'Existing item limit'}
    end
    local ok, supported = false, false
    if caps.support then ok, supported = pcall(caps.support, work, item, guild) end
    if ok and supported == true then
        return {state='create', label=kind=='legacy' and 'Restore legacy group' or 'Add item limit',
            detail=kind=='legacy' and ('Legacy group affects all '..workdefs.label(work)) or 'Item limit'}
    end
    local unsupported = ok and supported == false
    return {state='unavailable', label=unsupported and 'No item limit support' or 'Support unknown',
        detail=unsupported and 'Unavailable: this item cannot have a separate production limit.'
            or 'Unavailable: item limit support could not be checked.'}
end

return M
