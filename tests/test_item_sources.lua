-- item_sources: a reached Mining limit switches off only the natural rocks
-- whose main drop is that item, never a building, and switches them back
-- when the stock is below the limit or the limit is gone (2026-10-28).
local function name(s) return { ToString = function() return s end } end
local function drops(list)
    return { ForEach = function(_, fn)
        for i, d in ipairs(list) do
            fn(i, { get = function() return { ItemId = { StaticId = name(d[1]) }, Num = d[2] } end })
        end
    end }
end
local writes, model_reads = 0, 0
local ROCK_MODEL = 'PalMapObjectItemDropOnDamagModel'
local function rock(list, state, model_class)
    local model = { class = model_class or ROCK_MODEL, DropItemInfos = drops(list) }
    local w = { class = 'PalWorkCollectResource', CachedOwnerMapObjectConcreteModel = model,
        CurrentState = state or 1 }
    return setmetatable({}, { __index = w, __newindex = function(_, k, v) writes = writes + 1; w[k] = v end }), w
end
local function pit(item)
    local w = { class = 'PalWorkProgress', CurrentState = 1,
        CachedOwnerMapObjectConcreteModel = { class = 'PalMapObjectProductItemModel',
            GetProductItemId = function() model_reads = model_reads + 1; return name(item) end } }
    return setmetatable({}, { __index = w, __newindex = function(_, k, v) writes = writes + 1; w[k] = v end }), w
end
package.loaded.palapi = {
    -- Like palapi: a failed read is "<unknown work>", never nil.
    work_full_name = function(w) return w.class and (w.class .. ' /Game/Test.Work') or '<unknown work>' end,
    prop = function(o, n) return o[n] end,
    unwrap = function(v) return v end,
    valid = function(o) return o ~= nil and not o.invalid end,
    as_int = function(v) return type(v) == 'number' and math.floor(v) or nil end,
}
package.loaded.item_sources = nil
local src = require('item_sources')
local MINING, LUMBERING = 8, 7

local works = {
    rock({ { 'Stone', 50 }, { 'Pal_crystal_S', 5 }, { 'CopperOre', 2 } }),  -- stone rock
    rock({ { 'CopperOre', 40 } }),                                        -- ore node
    rock({ { 'Pal_crystal_S', 5 } }),                                     -- crystal rock
    pit('Stone'),                                                         -- Stone Pit
}
local keys = { 'stone', 'ore', 'crystal', 'pit' }
local values = { stone = MINING, ore = MINING, crystal = MINING, pit = MINING }
local function limits(t) return function(v) if v == MINING then return t end end end
-- A clean slate between sections. forget() keeps the held list (see the
-- respawn test at the end); forget_world() is the real world change.
local function fresh() src.forget_world() end

-- Main drop: the largest entry.
assert(src.product(works[1], 'stone').item == 'Stone' and src.product(works[1], 'stone').rock)
assert(src.product(works[4], 'pit').item == 'Stone' and not src.product(works[4], 'pit').rock)

-- Stone reached: only the stone rock goes off; ore and crystals still wanted.
local wanted, stopped = src.apply('camp', works, keys, values, limits({ Stone = 100 }),
    { Stone = 150, CopperOre = 10 }, true)
assert(stopped == 1 and works[1].CurrentState == 2, 'stone rock not switched off')
assert(works[2].CurrentState == 1 and works[3].CurrentState == 1, 'other rocks touched')
assert(works[4].CurrentState == 1, 'a building was written')
assert(wanted[MINING] == true, 'mining should stay wanted for ore and crystals')
assert(src.count('camp') == 1 and src.item_stopped('Stone') and not src.item_stopped('CopperOre'))

-- An Ore limit leaves the stone rock (2 ore on the side) to its own rule.
writes = 0
src.apply('camp', works, keys, values, limits({ Stone = 100, CopperOre = 5 }),
    { Stone = 150, CopperOre = 10 }, true)
assert(works[2].CurrentState == 2 and works[1].CurrentState == 2 and src.count('camp') == 2)

-- Everything limited is reached and crystals are limited too: nothing wanted.
wanted = src.apply('camp', works, keys, values,
    limits({ Stone = 100, CopperOre = 5, Pal_crystal_S = 1 }), { Stone = 150, CopperOre = 10, Pal_crystal_S = 3 }, true)
assert(not wanted[MINING], 'all reached: Mining may stop as a whole')

-- Unknown stock switches nothing either way.
writes = 0
src.apply('camp', works, keys, values, limits({ Stone = 100, CopperOre = 5, Pal_crystal_S = 1 }), nil, true)
assert(writes == 0, 'unknown stock wrote a state')
-- The crystal limit is removed: its rock comes back even without a stock count.
local _, _, back = src.apply('camp', works, keys, values, limits({ Stone = 100, CopperOre = 5 }), nil, true)
assert(back == 1 and works[3].CurrentState == 1 and works[1].CurrentState == 2, 'removed limit not released')
writes = 0

-- Dry run writes nothing through apply (the scheduler releases held rocks
-- with release_all first; see below).
src.apply('camp', works, keys, values, limits({ Stone = 1000 }), { Stone = 150 }, false)
assert(writes == 0 and works[1].CurrentState == 2, 'apply wrote a state with writes off')

-- Below the limit: released. Limit removed: released without any stock.
local _, _, started = src.apply('camp', works, keys, values, limits({ Stone = 1000, CopperOre = 5 }),
    { Stone = 150, CopperOre = 10 }, true)
assert(started == 1 and works[1].CurrentState == 1 and works[2].CurrentState == 2)
_, _, started = src.apply('camp', works, keys, values, limits(nil), nil, true)
assert(started == 1 and works[2].CurrentState == 1 and src.count('camp') == 0, 'removed limit kept a rock off')

-- A rock the game itself marked NotWorkable is never switched on by us.
local own = rock({ { 'Stone', 50 } }, 2)
src.apply('camp2', { own }, { 'own' }, { own = MINING }, limits({ Stone = 1000 }), { Stone = 1 }, true)
assert(own.CurrentState == 2, 'released a rock it never switched off')

-- release_all (switched off, pwp restore, test mode): every held rock that
-- still reads NotWorkable goes back, one the game already reset is just
-- dropped, a rock the game holds itself is never touched, and the list is
-- empty afterwards.
fresh()
local a, b = rock({ { 'Stone', 50 } }), rock({ { 'Stone', 50 } })
local game_held = rock({ { 'Stone', 50 } }, 2)
local three = { a, b, game_held }
local tkeys, tvalues = { 'a', 'b', 'g' }, { a = MINING, b = MINING, g = MINING }
src.apply('base', three, tkeys, tvalues, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(src.count('base') == 2 and a.CurrentState == 2 and b.CurrentState == 2)
b.CurrentState = 1 -- the game reset it (grew back)
assert(src.release_all('base', three, tkeys, true) == 1, 'release_all count')
assert(a.CurrentState == 1 and b.CurrentState == 1 and game_held.CurrentState == 2, 'release_all wrote the wrong rock')
assert(src.count('base') == 0 and not src.item_stopped('Stone'), 'release_all left rocks held')
assert(src.release_all('base', three, tkeys, true) == 0 and src.release_all('nobody', {}, {}, true) == 0)

-- A write that does not stick stays held for the next try.
local stuck, stuck_raw = rock({ { 'Stone', 50 } })
src.apply('base', { stuck }, { 's' }, { s = MINING }, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(src.count('base') == 1)
getmetatable(stuck).__newindex = function() writes = writes + 1 end -- writes are ignored
assert(src.release_all('base', { stuck }, { 's' }, true) == 0 and src.count('base') == 1, 'failed release forgotten')
getmetatable(stuck).__newindex = function(_, k, v) stuck_raw[k] = v end
assert(src.release_all('base', { stuck }, { 's' }, true) == 1 and src.count('base') == 0)

-- Partial list: held rocks it did not reach stay held (release_all and
-- apply), and are released once a complete list shows the limit gone.
fresh()
local p1, p2 = rock({ { 'Stone', 50 } }), rock({ { 'Stone', 50 } })
local pkeys, pvalues = { 'p1', 'p2' }, { p1 = MINING, p2 = MINING }
src.apply('base', { p1, p2 }, pkeys, pvalues, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(src.count('base') == 2)
src.apply('base', { p1 }, { 'p1' }, pvalues, limits({ Stone = 10 }), { Stone = 50 }, true, false)
assert(src.count('base') == 2, 'a partial list forgot a held rock')
assert(src.release_all('base', { p1 }, { 'p1' }, false) == 1 and src.count('base') == 1, 'partial release_all')
src.apply('base', { p1, p2 }, pkeys, pvalues, limits(nil), nil, true)
assert(p1.CurrentState == 1 and p2.CurrentState == 1 and src.count('base') == 0, 'removed limit did not release')

-- A held rock whose type is unknown this pass (values has no entry): no
-- error on wanted[nil], and the rock goes back.
fresh()
local u = rock({ { 'Stone', 50 } })
src.apply('base', { u }, { 'u' }, { u = MINING }, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(src.count('base') == 1)
local ok, untyped = pcall(src.apply, 'base', { u }, { 'u' }, {}, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(ok and next(untyped) == nil, 'wanted[nil] threw: ' .. tostring(untyped))
assert(u.CurrentState == 1 and src.count('base') == 0, 'a held rock of unknown type stayed off')

-- A product that cannot be read yet is not remembered as "no product", and
-- under a limit it counts as wanted. Once it reads, the rock is handled.
fresh()
local late, late_raw = rock({ { 'Stone', 50 } })
late_raw.CachedOwnerMapObjectConcreteModel.invalid = true
wanted = src.apply('base', { late }, { 'late' }, { late = MINING }, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(wanted[MINING] and late.CurrentState == 1, 'an unreadable product must count as wanted and switch nothing')
late_raw.CachedOwnerMapObjectConcreteModel.invalid = nil
wanted = src.apply('base', { late }, { 'late' }, { late = MINING }, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(not wanted[MINING] and late.CurrentState == 2, 'the product was cached as missing after a failed read')
-- An unreadable model class is unknown too; a confirmed "None" product is
-- remembered and yields nothing.
fresh()
local noclass = rock({ { 'Stone', 50 } }, 1, false)
noclass.CachedOwnerMapObjectConcreteModel.class = nil
assert(src.product(noclass, 'nc', {}) == nil, 'unreadable model class read as a product')
local idle = pit('None')
local cache = {}
model_reads = 0
assert(src.product(idle, 'idle', cache) == false and src.product(idle, 'idle', cache) == false and model_reads == 1,
    'a confirmed empty product was not remembered')
wanted = src.apply('base', { idle }, { 'idle' }, { idle = MINING }, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(not wanted[MINING], 'a work with no product made Mining wanted')

-- A PalWorkCollectResource on an unexpected owner model is counted but
-- never written (engine review P3-6).
fresh()
local odd = rock({ { 'Stone', 50 } }, 1, 'SomeOtherModel')
local p = src.product(odd, 'odd', {})
assert(p.item == 'Stone' and not p.rock)
writes = 0
src.apply('base', { odd }, { 'odd' }, { odd = MINING }, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(writes == 0 and odd.CurrentState == 1 and src.count('base') == 0, 'a non-rock model was written')

-- Only Mining's limits reach rocks: a Lumbering limit with a rock-shaped
-- work typed Lumbering leaves it Workable.
fresh()
local tree = rock({ { 'Wood', 50 } })
writes = 0
src.apply('base', { tree }, { 't' }, { t = LUMBERING }, limits({ Wood = 1 }), { Wood = 50 }, true)
assert(writes == 0 and tree.CurrentState == 1, 'a Lumbering work was written')

-- A product read once is remembered for the next pass.
fresh()
local fresh_pit = pit('Stone')
model_reads = 0
src.apply('base', { fresh_pit }, { 'fp' }, { fp = MINING }, limits({ Stone = 1000 }), { Stone = 1 }, true)
src.apply('base', { fresh_pit }, { 'fp' }, { fp = MINING }, limits({ Stone = 1000 }), { Stone = 1 }, true)
assert(model_reads == 1, 'a seen work was read again: ' .. model_reads)

-- forget (main's ClientRestart reset: every respawn and same-map reconnect,
-- not only a world change) keeps the held list and drops only products. The
-- rock still reads NotWorkable after a respawn and must still be released
-- (review 2026-10-29, P1).
fresh()
local kept = rock({ { 'Stone', 50 } })
src.apply('base', { kept }, { 'k' }, { k = MINING }, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(src.count('base') == 1 and kept.CurrentState == 2)
src.forget()
assert(src.count('base') == 1, 'forget dropped the held list: the rock stays off for good')
assert(src.release_all('base', { kept }, { 'k' }, true) == 1 and kept.CurrentState == 1, 'held rock not released after forget')
-- After a real reload the rock reads Workable again: a stale entry is
-- dropped by the next complete pass and nothing is written.
src.apply('base', { kept }, { 'k' }, { k = MINING }, limits({ Stone = 10 }), { Stone = 50 }, true)
src.forget()
kept.CurrentState = 1 -- the reload reset it
writes = 0
src.apply('base', {}, {}, {}, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(src.count('base') == 0 and writes == 0, 'a stale held entry survived a complete pass')

-- held_items still names the item after forget: the host's "Rocks stopped"
-- must not vanish for an interval after every respawn (review 2026-10-29).
-- Products of rocks no longer held go with the cache.
fresh()
local held_rock, free_rock = rock({ { 'Stone', 50 } }), rock({ { 'CopperOre', 40 } })
src.apply('base', { held_rock, free_rock }, { 'h', 'f' }, { h = MINING, f = MINING },
    limits({ Stone = 10, CopperOre = 100 }), { Stone = 50, CopperOre = 1 }, true)
assert(src.held_items('base').Stone and src.item_stopped('Stone'))
src.forget()
assert(src.held_items('base').Stone, 'forget made held_items forget the item')
assert(src.item_stopped('Stone') and not src.item_stopped('CopperOre'), 'forget changed item_stopped')
model_reads = 0
local free_pit = pit('Stone')
src.apply('base', { held_rock, free_pit }, { 'h', 'p' }, { h = MINING, p = MINING },
    limits({ Stone = 10 }), { Stone = 50 }, true)
src.forget()
src.apply('base', { held_rock, free_pit }, { 'h', 'p' }, { h = MINING, p = MINING },
    limits({ Stone = 10 }), { Stone = 50 }, true)
assert(model_reads == 2, 'forget kept the product of a work that was not held')

-- forget_world (main, when the world key really changes): the old world's
-- held list and products go. A respawn keeps the key and never calls it.
fresh()
local old_world = rock({ { 'Stone', 50 } })
src.apply('old', { old_world }, { 'o' }, { o = MINING }, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(src.count('old') == 1)
src.forget_world()
assert(next(src.blocked) == nil and next(src.held_items('old')) == nil, 'forget_world kept the old held list')
assert(not src.item_stopped('Stone'))

-- A drop list with one unreadable entry is unreadable as a whole: the entry
-- it missed may be the largest. Not cached, so it is read again (review
-- 2026-10-29).
fresh()
local bad_entry = false
local mixed_list = { ForEach = function(_, fn)
    fn(1, { get = function() return { ItemId = { StaticId = name('Pal_crystal_S') }, Num = 5 } end })
    fn(2, { get = function()
        if bad_entry then return { ItemId = { StaticId = nil }, Num = 50 } end
        return { ItemId = { StaticId = name('Stone') }, Num = 50 }
    end })
end }
local mixed = { class = 'PalWorkCollectResource', CurrentState = 1,
    CachedOwnerMapObjectConcreteModel = { class = ROCK_MODEL, DropItemInfos = mixed_list } }
bad_entry = true
local mcache = {}
assert(src.product(mixed, 'm', mcache) == nil, 'a partly unreadable drop list named a main drop')
assert(mcache.m == nil, 'a partly unreadable drop list was cached')
bad_entry = false
assert(src.product(mixed, 'm', mcache).item == 'Stone', 'the list was not read again')

-- apply reports which work types had a source naming a product. A base with
-- no Mining source (rocks mined out) or only idle pits has none, so the
-- scheduler leaves Mining to the group rule (review 2026-10-29).
fresh()
local _, _, _, sourced = src.apply('base', {}, {}, {}, limits({ Stone = 10 }), { Stone = 50 }, true)
assert(type(sourced) == 'table' and sourced[MINING] == nil, 'no source reported as a source')
_, _, _, sourced = src.apply('base', { pit('None') }, { 'idle' }, { idle = MINING },
    limits({ Stone = 10 }), { Stone = 50 }, true)
assert(sourced[MINING] == nil, 'an idle pit counted as a source')
_, _, _, sourced = src.apply('base', { rock({ { 'Stone', 50 } }) }, { 'r' }, { r = MINING },
    limits({ Stone = 10 }), { Stone = 50 }, true)
assert(sourced[MINING] == true, 'a stone rock was not reported as a Mining source')
print('item sources: main drop, rocks only, release on below/removed/release_all, partial lists, unknown type, unreadable products, model class, held list kept by forget, held items named after forget, forget_world, sources reported')
