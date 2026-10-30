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

-- Mining limits stop only the rocks of their item (item_sources.lua) unless
-- the player switched that off in config. On a client the server's setting
-- counts, which panel_status answers once it knows it (2026-10-28); an older
-- panel_status has no per_item and this machine's config is the fallback.
local function per_item(cfg, work)
    if work ~= 'Mining' then return false end
    local status = package.loaded.panel_status
    if type(status) == 'table' and type(status.per_item) == 'function' then
        local ok, on = pcall(status.per_item, cfg)
        if ok and type(on) == 'boolean' then return on end
    end
    return not (type(cfg) == 'table' and cfg.item_limits_on_rocks == false)
end

function M.describe(caps, rules, work, item, guild, cfg)
    if not guild then
        return {state='unavailable', label='No guild for limits', detail='Join a guild before editing limits.'}
    end
    local amount = (rules[work] or {})[item]
    -- A rule for this item under another work type that also matches it is
    -- its rule too (scheduler round 5, P3-2): a Mining Sandwich limit from
    -- before Sandwich moved to Kindling offered "Add group limit", and a
    -- second rule for the same item. The result names that work, so a click
    -- opens the rule that exists. A rule under a work that does not match
    -- the item stays its own scope (test_picker_capability).
    if (amount == nil or amount == false) and workdefs.works_for_item then
        for _, other in ipairs(workdefs.works_for_item(item)) do
            local by_item = other ~= work and rules[other]
            local there = by_item and by_item[item]
            if there ~= nil and there ~= false then
                local found = M.describe(caps, rules, other, item, guild, cfg)
                found.work = other
                return found
            end
        end
    end
    local kind = caps.rule_kind and caps.rule_kind(work, item, guild)
    -- A Mining limit with per-item on is an item limit whatever its stored
    -- kind: it stops only that item's rocks (review C, 2026-10-28). The tile
    -- said "Edit group limit" on it.
    local item_limit = per_item(cfg, work)
    if amount ~= nil and amount ~= false then
        if item_limit then
            return {state='existing', amount=amount, label='Edit item limit',
                detail='Item limit for '..workdefs.label(work)..': stops only the rocks that mainly give this item'}
        end
        return {state='existing', amount=amount,
            label=kind=='legacy' and 'Edit group limit' or 'Edit existing limit',
            detail=kind=='legacy' and ('Group limit for all '..workdefs.label(work)..' work') or 'Existing item limit'}
    end
    local ok, supported = false, false
    if caps.support then ok, supported = pcall(caps.support, work, item, guild) end
    local job = workdefs.label(work)
    local group = covering_group(caps, rules, work, guild)
    -- A per-item Mining limit on an item no rock mainly gives would stop no
    -- rock at all (newcomer round 4, P2-5: Thermal Core showed "Add item
    -- limit"). A limit already set is still shown above, to edit or remove.
    if ok and supported == true and item_limit and not workdefs.rock_drop(item) then
        return {state='unavailable', label='Cannot be limited',
            detail='No rock mainly gives this item, so it cannot have a Mining limit.'}
    end
    if ok and supported == true then
        -- A second item joins the type's group: the work stops only once
        -- every one of them is reached (scheduler.cap_state).
        local detail = group ~= nil
            and ('Joins the '..job..' limits: '..job..' stops once every one is reached.')
            or ('Stops all '..job..' work once reached, not only this item.')
        if item_limit then
            detail = 'Stops the rocks that mainly give this item once reached; other mining goes on while it is still wanted.'
        end
        local label = item_limit and 'item limit' or 'group limit'
        return {state='create', group=group,
            label=(kind=='legacy' and 'Restore ' or 'Add ')..label, detail=detail}
    end
    if group ~= nil and not item_limit then
        return {state='unavailable', group=group, label='Group limit applies',
            detail='Covered by the '..job..' limit, which switches all '..job..' work.'}
    end
    local unsupported = ok and supported == false
    return {state='unavailable', label=unsupported and 'Cannot be limited' or 'Support unknown',
        detail=unsupported and NO_LIMIT
            -- With a next step (round 3, newcomer P3-7). describe runs on
            -- every draw, so a later draw asks again by itself.
            or 'Item limit support could not be checked yet. Try again in a moment.'}
end

return M
