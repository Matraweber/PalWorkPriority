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
local writes = 0
local function rock(list, state)
    local w = { class = 'PalWorkCollectResource', CachedOwnerMapObjectConcreteModel = { DropItemInfos = drops(list) },
        CurrentState = state or 1 }
    return setmetatable({}, { __index = w, __newindex = function(_, k, v) writes = writes + 1; w[k] = v end })
end
local function pit(item)
    local w = { class = 'PalWorkProgress', CurrentState = 1,
        CachedOwnerMapObjectConcreteModel = { GetProductItemId = function() return name(item) end } }
    return setmetatable({}, { __index = w, __newindex = function(_, k, v) writes = writes + 1; w[k] = v end })
end
package.loaded.palapi = {
    work_full_name = function(w) return w.class .. ' /Game/Test.Work' end,
    prop = function(o, n) return o[n] end,
    unwrap = function(v) return v end,
    valid = function(o) return o ~= nil end,
    as_int = function(v) return type(v) == 'number' and math.floor(v) or nil end,
}
package.loaded.item_sources = nil
local src = require('item_sources')
local MINING = 8

local works = {
    rock({ { 'Stone', 50 }, { 'Pal_crystal_S', 5 }, { 'CopperOre', 2 } }),  -- stone rock
    rock({ { 'CopperOre', 40 } }),                                        -- ore node
    rock({ { 'Pal_crystal_S', 5 } }),                                     -- crystal rock
    pit('Stone'),                                                         -- Stone Pit
}
local keys = { 'stone', 'ore', 'crystal', 'pit' }
local values = { stone = MINING, ore = MINING, crystal = MINING, pit = MINING }
local function limits(t) return function(v) if v == MINING then return t end end end

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

-- Dry run writes nothing.
src.apply('camp', works, keys, values, limits({ Stone = 1000 }), { Stone = 150 }, false)
assert(writes == 0 and works[1].CurrentState == 2, 'dry run released a rock')

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
print('item sources: main drop, rocks only, release on below/removed, unknown stock and dry run write nothing')
