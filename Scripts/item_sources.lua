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

-- The owner model every natural rock had in the probe (2026-10-27). A
-- PalWorkCollectResource on any other model is read for its product but
-- never written: nothing was measured about whether its state is saved.
M.ROCK_MODEL = 'PalMapObjectItemDropOnDamagModel'

-- camp key -> {[work key] = {item = "Stone", rock = true} or false}. False
-- is only a confirmed "no product" (a valid model that names nothing); an
-- unreadable work is not remembered and is asked again next pass. A work's
-- product never changes, so a read answer is kept, but only for the keys
-- seen in the camp's last pass: mined-out rocks drop out with their key.
local products = {}
-- camp key -> {[work key] = true} for the rocks this module switched off.
-- Kept across forget(): see there.
M.blocked = {}

-- A name as a string, false for a readable empty name ("None"), nil when it
-- could not be read at all. Unknown must not read as "nothing".
local function name_of(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if not ok or type(s) ~= 'string' then return nil end
    if s == '' or s == 'None' then return false end
    return s
end

local function class_of(object)
    local class = (api.work_full_name(object) or ''):match('^(%S+)')
    if class == nil or class:sub(1, 1) == '<' then return nil end -- "<unknown work>"
    return class
end

-- The largest entry of a rock's drop list; the first one wins a tie. Second
-- value: whether the list was read in full. An empty list read in full is a
-- confirmed "no drop". A list with an unreadable entry is unreadable as a
-- whole, even when another entry read: the entry it missed may be the
-- largest, so the best of the rest is a guess (review 2026-10-29). It is not
-- cached, so it is asked again next pass.
local function main_drop(model)
    local best, most, unreadable
    local ok = pcall(function()
        local list = model.DropItemInfos
        if list == nil then unreadable = true; return end
        list:ForEach(function(_, entry)
            local e = entry:get()
            local id = name_of(e.ItemId.StaticId)
            local n = tonumber(e.Num)
            if id == nil or n == nil then
                unreadable = true
            elseif id and (most == nil or n > most) then
                best, most = id, n
            end
        end)
    end)
    if not ok or unreadable then return nil, false end
    return best, true
end

-- What a work produces, read from the engine now: {item, rock}, false when
-- the work names no product, nil when it could not be read.
local function read_product(work)
    local class = class_of(work)
    local model = api.unwrap(api.prop(work, 'CachedOwnerMapObjectConcreteModel'))
    if class == nil or model == nil or not api.valid(model) then return nil end
    if class == 'PalWorkCollectResource' then
        local item, read = main_drop(model)
        if not read then return nil end
        if not item then return false end
        local model_class = class_of(model)
        if model_class == nil then return nil end
        return { item = item, rock = model_class == M.ROCK_MODEL }
    end
    local ok, id = pcall(function() return model:GetProductItemId() end)
    if not ok then return nil end
    local item = name_of(id)
    if item == nil then return nil end
    return item and { item = item, rock = false } or false
end

-- `cache` is optional: without it the work is read every time (the rocks
-- command). Returns {item, rock}, false (confirmed no product) or nil.
function M.product(work, key, cache)
    local known = key and cache and cache[key]
    if known ~= nil then return known end
    local found = read_product(work)
    if key and cache and found ~= nil then cache[key] = found end
    return found
end

local function state_of(work)
    return api.as_int(api.prop(work, 'CurrentState'))
end

local function set_state(work, value)
    local ok = pcall(function() work.CurrentState = value end)
    return ok and state_of(work) == value
end

-- Undo this module's own write on one rock. "released" when it was written
-- back, "gone" when it no longer reads NotWorkable (the game reset it, or it
-- grew back as a new rock), "kept" when it still needs releasing (state
-- unreadable, writes not allowed, or the write did not stick).
local function release(work, can_write)
    local state = state_of(work)
    if state == nil then return 'kept' end
    if state ~= NOT_WORKABLE then return 'gone' end
    if can_write and set_state(work, WORKABLE) then return 'released' end
    return 'kept'
end

-- One camp, one pass. `works`/`keys` are the camp's works and their keys,
-- `values` maps a key to its work suitability (nil when not typed),
-- `ceilings(value)` returns item -> ceiling for that work type (nil without
-- limits) and `totals` is the camp's stock (nil when unknown). `complete`
-- false says the list is partial: held rocks it did not reach stay held
-- instead of being forgotten while still switched off.
--
-- Returns `wanted`: work value -> true when some rock or building of that
-- type still produces an item that has no limit or is below it, or whose
-- product could not be read (unknown counts as wanted), the number of rocks
-- switched off and back on in this pass, and `sourced`: work value -> true
-- when a work of that type under limits named a product. A base whose rocks
-- are all mined out has no Mining source at all; that is not "every limit
-- reached", so the caller leaves it to the group rule (review 2026-10-29).
-- With unknown stock nothing is switched off, and a held rock stays held.
function M.apply(camp_key, works, keys, values, ceilings, totals, can_write, complete)
    local wanted, stopped, started, sourced = {}, 0, 0, {}
    local was = (camp_key and M.blocked[camp_key]) or {}
    local old = (camp_key and products[camp_key]) or {}
    local now, cache, seen = {}, {}, {}
    for i, w in ipairs(works or {}) do
        local key = keys and keys[i]
        if key then seen[key] = true end
        local value = key and values[key]
        local limits = value and ceilings(value)
        local held = key and was[key]
        local source
        if limits or held then
            source = M.product(w, key, old)
            if source ~= nil then cache[key] = source end
        end
        local ceiling = source and limits and limits[source.item]
        local have = source and totals and totals[source.item]
        local reached = type(ceiling) == 'number' and type(have) == 'number' and have >= ceiling
        local numeric = type(ceiling) == 'number'
        if value and limits and source then sourced[value] = true end
        if value and limits and (source == nil
            or (source and not reached and (not numeric or totals ~= nil))) then
            wanted[value] = true
        end
        if held then
            -- A held rock stays off while its limit is reached, and while it
            -- cannot be decided (unreadable product, unknown stock). It goes
            -- back when the limit is gone or its type is unknown, when it is
            -- below the limit, or when it no longer reads as a rock.
            local keep = limits and (source == nil
                or (source and source.rock and (reached or (numeric and totals == nil))))
            if keep then
                local state = state_of(w)
                if state == NOT_WORKABLE or state == nil then
                    now[key] = true
                elseif reached and state == WORKABLE and can_write and set_state(w, NOT_WORKABLE) then
                    now[key] = true
                    stopped = stopped + 1
                end
            else
                local r = release(w, can_write)
                if r == 'released' then started = started + 1 elseif r == 'kept' then now[key] = true end
            end
        elseif source and source.rock and reached and state_of(w) == WORKABLE
            and can_write and set_state(w, NOT_WORKABLE) then
            now[key] = true
            stopped = stopped + 1
        end
    end
    if complete == false then
        for key in pairs(was) do
            if not seen[key] then now[key] = true end
        end
        for key, p in pairs(old) do
            if not seen[key] then cache[key] = p end
        end
    end
    -- A rock that is gone (mined out) is forgotten with its key.
    if camp_key then
        M.blocked[camp_key] = next(now) and now or nil
        products[camp_key] = next(cache) and cache or nil
    end
    return wanted, stopped, started, sourced
end

-- Gives back every rock this module holds off in a camp: switched off,
-- `pwp restore`, test mode, or per-item limits switched off in config. It
-- writes only where the rock still reads NotWorkable, so it undoes this
-- module's own writes and nothing else; that is why test mode may run it.
-- A rock whose write did not stick stays on the list for the next try, as
-- do rocks a partial list (`complete` false) did not reach. Returns how many
-- were released.
function M.release_all(camp_key, works, keys, complete)
    local was = camp_key and M.blocked[camp_key]
    if not was then return 0 end
    local now, seen, started = {}, {}, 0
    for i, w in ipairs(works or {}) do
        local key = keys and keys[i]
        if key and was[key] then
            seen[key] = true
            local r = release(w, true)
            if r == 'released' then started = started + 1 elseif r == 'kept' then now[key] = true end
        end
    end
    if complete == false then
        for key in pairs(was) do
            if not seen[key] then now[key] = true end
        end
    end
    M.blocked[camp_key] = next(now) and now or nil
    return started
end

-- Session reset: the product cache goes, the held list stays. main's
-- ClientRestart reset runs on every local respawn and same-map reconnect, not
-- only on a world change, and there the rocks still read NotWorkable: a
-- dropped list left them off for good, through off, restore and a removed
-- limit (review 2026-10-29, P1). Keeping it is safe after a real reload too.
-- Keys are work GUIDs, so nothing in another world matches them; release()
-- writes only where a rock still reads NotWorkable; and the next complete
-- pass drops every key it does not see, while reloaded rocks read Workable.
-- Products are only a cache and are read again where needed, except those of
-- held rocks: held_items names them, and the host's "Rocks stopped" went
-- missing for an interval after every respawn (review 2026-10-29). A work's
-- product never changes, so keeping them is safe.
function M.forget()
    local kept = {}
    for camp_key, held in pairs(M.blocked) do
        local known, mine = products[camp_key], {}
        for key in pairs(held) do
            if known and known[key] then mine[key] = known[key] end
        end
        if next(mine) then kept[camp_key] = mine end
    end
    products = kept
end

-- A real world change (main's world key differs from the last one): the
-- rocks of the old world are gone with it, so its held list goes too. Not on
-- a respawn or a same-map reconnect, which keep the world key (forget above).
function M.forget_world()
    products = {}
    M.blocked = {}
end

-- Rocks this module holds switched off in a camp.
function M.count(camp_key)
    local n = 0
    for _ in pairs((camp_key and M.blocked[camp_key]) or {}) do n = n + 1 end
    return n
end

-- Items whose rocks this module holds off in one camp. A server answers a
-- client's scope with it (schema 5) instead of item_stopped, which looks at
-- every camp at once, other guilds' included.
function M.held_items(camp_key)
    local out = {}
    local known = (camp_key and products[camp_key]) or {}
    for key in pairs((camp_key and M.blocked[camp_key]) or {}) do
        local p = known[key]
        if p and p.item then out[p.item] = true end
    end
    return out
end

-- Whether any camp has rocks switched off for this item (panel wording).
function M.item_stopped(item)
    for camp_key, keys in pairs(M.blocked) do
        local known = products[camp_key] or {}
        for key in pairs(keys) do
            local p = known[key]
            if p and p.item == item then return true end
        end
    end
    return false
end

return M
