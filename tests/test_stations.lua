-- stations.generators_needing: built AND not full counts; anything unknown,
-- unbuilt, full or not a generator counts as nothing.
local owners = { built = { BuildProcess = { State = 1 } }, blueprint = { BuildProcess = { State = 0 } },
    nobp = {} }
local manager = {}
function manager:FindModel(id) return owners[id] end
local function gen(stored, max, owner, bad_outer)
    local m = { StoredEnergyAmount = stored, MaxEnergyStorage = max }
    m.GetOuter = bad_outer and function() error('boom') end or function() return manager end
    return { value = 4, CachedOwnerMapObjectConcreteModel = m, OwnerMapObjectModelId = owner }
end
package.loaded.palapi = {
    work_suitability = function(w) return w.value end,
    prop = function(o, n) return o[n] end,
    unwrap = function(v) return v end,
    valid = function(o) return o ~= nil and o ~= 'null' end,
    as_int = function(v) return type(v) == 'number' and math.floor(v) or nil end,
}
package.loaded.stations = nil
local stations = require('stations')
assert(stations.GENERATOR == 4)
local n = stations.generators_needing({
    gen(0, 250000, 'built'),            -- empty, built: needs
    gen(120000, 250000, 'built'),       -- charging, built: needs
    gen(250000, 250000, 'built'),       -- full: no
    gen(249999.5, 250000, 'built'),     -- within margin: full
    gen(0, 250000, 'blueprint'),        -- unbuilt: no
    gen(0, 250000, 'missing'),          -- model not found: no
    gen(0, 250000, 'nobp'),             -- no build process: no
    gen(0, 250000, 'built', true),      -- GetOuter throws: no
    gen('x', 250000, 'built'),          -- unreadable stored: no
    gen(0, 0, 'built'),                 -- max 0: no
    { value = 4, CachedOwnerMapObjectConcreteModel = nil }, -- no model: no
    { value = 7 },                      -- a tree: never
})
assert(n == 2, 'expected 2 generators needing a worker, got ' .. tostring(n))
assert(stations.generators_needing(nil) == 0 and stations.generators_needing({}) == 0)

-- stations.coolers_needing: built AND Workable (spoilable food inside) counts;
-- empty (NotWorkable), unbuilt, unknown or a generator count as nothing.
assert(stations.COOLER == 11)
local function cooler(state, owner, bad_outer)
    local m = {}
    m.GetOuter = bad_outer and function() error('boom') end or function() return manager end
    return { value = 11, CurrentState = state, CachedOwnerMapObjectConcreteModel = m, OwnerMapObjectModelId = owner }
end
local c = stations.coolers_needing({
    cooler(1, 'built'),                 -- food inside, built: needs
    cooler(2, 'built'),                 -- empty: no
    cooler(1, 'blueprint'),             -- unbuilt: no
    cooler(2, 'blueprint'),             -- under construction (seen live): no
    cooler(0, 'built'),                 -- Init: no
    cooler(nil, 'built'),               -- unreadable state: no
    cooler(1, 'missing'),               -- model not found: no
    cooler(1, 'nobp'),                  -- no build process: no
    cooler(1, 'built', true),           -- GetOuter throws: no
    { value = 11, CurrentState = 1 },   -- no model: no
    gen(0, 250000, 'built'),            -- a generator is not a cooler
})
assert(c == 1, 'expected 1 cooler needing a worker, got ' .. tostring(c))
assert(stations.coolers_needing(nil) == 0 and stations.coolers_needing({}) == 0)
assert(#stations.KINDS == 6 and stations.KINDS[1].value == 4 and stations.KINDS[2].value == 11
    and stations.KINDS[2].needing == stations.coolers_needing)

-- stations.resources_needing: Workable trees/rocks count; a node owned by a
-- building (stone pit) only when built; anything else counts as nothing.
assert(stations.LUMBERING == 7 and stations.MINING == 8)
assert(stations.KINDS[3].value == 7 and stations.KINDS[4].value == 8)
local function node(value, state, owner, bad_model)
    local w = { value = value, CurrentState = state }
    if owner then
        w.CachedOwnerMapObjectConcreteModel = { GetOuter = function() return manager end }
        w.OwnerMapObjectModelId = owner
    end
    if bad_model then w.CachedOwnerMapObjectConcreteModel = 'null' end
    return w
end
local works = {
    node(8, 1),                 -- rock, Workable: needs
    node(8, 1),                 -- rock, Workable: needs
    node(8, 2),                 -- rock, NotWorkable: no
    node(8, nil),               -- rock, unreadable state: no
    node(8, 1, 'built'),        -- built stone pit: needs
    node(8, 1, 'blueprint'),    -- unbuilt stone pit: no
    node(8, 1, 'missing'),      -- pit model not found: no
    node(8, 1, nil, true),      -- null model wrapper (a natural node): needs
    node(7, 1),                 -- tree, Workable: Lumbering only
    node(7, 3),                 -- tree, Finish: no
    cooler(1, 'built'),         -- a cooler is not a resource
}
local mined = stations.resources_needing(works, 8)
assert(mined == 4, 'expected 4 mining works needing a worker, got ' .. tostring(mined))
assert(stations.resources_needing(works, 7) == 1)
assert(stations.KINDS[4].needing(works) == 4 and stations.KINDS[3].needing(works) == 1)
assert(stations.resources_needing(nil, 8) == 0)

-- stations.ranches_needing: a built, Workable ranch is one seat (2026-10-27:
-- the ranch never announces, so Farming was never wanted and ranch Pals were
-- fenced away from it). Unbuilt, not Workable, unknown or another kind: none.
assert(stations.RANCH == 13 and stations.KINDS[5].value == 13
    and stations.KINDS[5].needing == stations.ranches_needing)
local function ranch(state, owner, bad_outer)
    local m = {}
    m.GetOuter = bad_outer and function() error('boom') end or function() return manager end
    return { value = 13, CurrentState = state, CachedOwnerMapObjectConcreteModel = m, OwnerMapObjectModelId = owner }
end
local r = stations.ranches_needing({
    ranch(1, 'built'),                  -- the live shape: Workable, built
    ranch(1, 'built'),                  -- a second ranch: one more seat
    ranch(2, 'built'),                  -- not Workable: no
    ranch(1, 'blueprint'),              -- unbuilt: no
    ranch(nil, 'built'),                -- unreadable state: no
    ranch(1, 'missing'),                -- model not found: no
    ranch(1, 'built', true),            -- GetOuter throws: no
    { value = 13, CurrentState = 1 },   -- no model: no
    cooler(1, 'built'),                 -- a cooler is not a ranch
})
assert(r == 2, 'expected 2 ranches needing a worker, got ' .. tostring(r))
assert(stations.ranches_needing(nil) == 0)

-- stations.ponds_and_labs_needing: a built, Workable fishing pond or Handiwork
-- research lab is one seat (2026-10-27: both announced only at world load).
-- A workbench is Handiwork work too but announces its orders: never counted.
assert(stations.HANDIWORK == 5 and stations.KINDS[6].value == 5
    and stations.KINDS[6].needing == stations.ponds_and_labs_needing)
package.loaded.palapi.work_full_name = function(w) return w.class end
local function silent(class, state, owner)
    local m = {}
    m.GetOuter = function() return manager end
    return { value = 5, class = class .. ' /Game/Pal/Maps/Test.Work', CurrentState = state,
        CachedOwnerMapObjectConcreteModel = m, OwnerMapObjectModelId = owner }
end
local p = stations.ponds_and_labs_needing({
    silent('PalWorkFishPond', 1, 'built'),        -- bait and target set: needs
    silent('PalWorkLabResearch', 1, 'built'),     -- research running: needs
    silent('PalWorkFishPond', 2, 'built'),        -- no bait: no
    silent('PalWorkFishPond', 1, 'blueprint'),    -- unbuilt: no
    silent('PalWorkProgress', 1, 'built'),        -- a workbench: never
    { value = 5, CurrentState = 1 },              -- no class: no
})
assert(p == 2, 'expected 2 silent Handiwork stations, got ' .. tostring(p))
