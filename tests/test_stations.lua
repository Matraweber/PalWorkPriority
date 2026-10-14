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
    valid = function(o) return o ~= nil end,
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
