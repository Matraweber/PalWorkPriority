-- Limits per item on natural rocks (2026-10-28, user's decision: in 0.5.0).
--
-- A limit switches Pals' permission for a whole work type; that cannot stop
-- stone while ore continues. Every natural rock is its own work object
-- (PalWorkCollectResource) and its owner model lists what it drops
-- (DropItemInfos). Setting such a work's CurrentState to NotWorkable (2)
-- kept every Pal off it: 0 of 12 samples on blocked stone rocks while the
-- miners took ore and crystal rocks instead. A rock's state is not saved
-- (all back to Workable after a reload), so a crash or an uninstall leaves
-- nothing behind. Evidence: docs/per-item-limits-2026-10-27.md.
--
-- Never written: buildings (Stone Pit, logging site, furnaces). Their work
-- state IS saved - a pit set NotWorkable came back NotWorkable after a
-- reload - so writing it would outlive the mod. Their product is still read
-- (GetProductItemId) so the scheduler knows whether a pit is still wanted.
--
-- Which item a rock counts as: its main drop, the entry with the largest
-- count (user's decision). A stone rock (Stone 50, crystals 5, ore 2) is a
-- stone rock; an Ore limit leaves it alone.
--
-- Nothing engine-side is kept between calls: works are passed in per pass,
-- remembered only by their key string.
local api = require('palapi')

local M = {}

local NOT_WORKABLE, WORKABLE = 2, 1

-- work key -> {item = "Stone", rock = true} or false when the work has no
-- readable product. A work's product never changes, so it is read once.
local products = {}
-- camp key -> {[work key] = true} for the rocks this module switched off.
M.blocked = {}

local function text(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == 'string' and s ~= '' and s ~= 'None' then return s end
    return nil
end

-- The largest entry of a rock's drop list; the first one wins a tie.
local function main_drop(model)
    local best, most
    local ok = pcall(function()
        local list = model.DropItemInfos
        if list == nil then return end
        list:ForEach(function(_, entry)
            local e = entry:get()
            local id = text(e.ItemId.StaticId)
            local n = tonumber(e.Num)
            if id and n and (most == nil or n > most) then best, most = id, n end
        end)
    end)
    if ok then return best end
    return nil
end

function M.product(work, key)
    local known = key and products[key]
    if known ~= nil then return known or nil end
    local found = false
    local class = (api.work_full_name(work) or ''):match('^(%S+)')
    local model = api.unwrap(api.prop(work, 'CachedOwnerMapObjectConcreteModel'))
    if model ~= nil and api.valid(model) then
        if class == 'PalWorkCollectResource' then
            local item = main_drop(model)
            if item then found = { item = item, rock = true } end
        else
            local ok, id = pcall(function() return model:GetProductItemId() end)
            local item = ok and text(id) or nil
            if item then found = { item = item, rock = false } end
        end
    end
    if key then products[key] = found end
    return found or nil
end

local function state_of(work)
    return api.as_int(api.prop(work, 'CurrentState'))
end

local function set_state(work, value)
    local ok = pcall(function() work.CurrentState = value end)
    return ok and state_of(work) == value
end

-- One camp, one pass. `works`/`keys` are the camp's works and their keys,
-- `values` maps a key to its work suitability (nil when not typed),
-- `ceilings(value)` returns item -> ceiling for that work type (nil without
-- limits) and `totals` is the camp's stock (nil when unknown).
--
-- Returns `wanted`: work value -> true when some rock or building of that
-- type still produces an item that has no limit or is below it, and the
-- number of rocks switched off and back on in this pass. With unknown stock
-- nothing is switched either way.
function M.apply(camp_key, works, keys, values, ceilings, totals, can_write)
    local wanted, stopped, started = {}, 0, 0
    local was = (camp_key and M.blocked[camp_key]) or {}
    local now = {}
    for i, w in ipairs(works or {}) do
        local key = keys and keys[i]
        local value = key and values[key]
        local limits = value and ceilings(value)
        local source = (limits or (key and was[key])) and M.product(w, key) or nil
        if source then
            local ceiling = limits and limits[source.item]
            local have = totals and totals[source.item]
            local reached = type(ceiling) == 'number' and type(have) == 'number' and have >= ceiling
            if not reached and (type(ceiling) ~= 'number' or totals ~= nil) then
                wanted[value] = true
            end
            -- Unknown stock switches nothing; a rock without a limit (or
            -- whose limit was removed) needs no stock to be switched back.
            local decidable = totals ~= nil or type(ceiling) ~= 'number'
            if source.rock and decidable then
                if reached then
                    if state_of(w) == WORKABLE then
                        if can_write and set_state(w, NOT_WORKABLE) then
                            now[key] = true
                            stopped = stopped + 1
                        end
                    elseif was[key] then
                        now[key] = true
                    end
                elseif was[key] then
                    if state_of(w) == NOT_WORKABLE and can_write and set_state(w, WORKABLE) then
                        started = started + 1
                    elseif state_of(w) == NOT_WORKABLE then
                        now[key] = true
                    end
                end
            elseif source.rock and was[key] then
                now[key] = true
            end
        end
    end
    -- A rock that is gone (mined out) is forgotten with its key.
    if camp_key then M.blocked[camp_key] = next(now) and now or nil end
    return wanted, stopped, started
end

-- Rocks this module holds switched off in a camp.
function M.count(camp_key)
    local n = 0
    for _ in pairs((camp_key and M.blocked[camp_key]) or {}) do n = n + 1 end
    return n
end

-- Whether any camp has rocks switched off for this item (panel wording).
function M.item_stopped(item)
    for _, keys in pairs(M.blocked) do
        for key in pairs(keys) do
            local p = products[key]
            if p and p.item == item then return true end
        end
    end
    return false
end

return M
