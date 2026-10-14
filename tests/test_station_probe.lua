-- station_probe: authority-only, reads generator energy and build state,
-- ignores other work.
local authority = true
local owners = {
    built = { BuildProcess = { State = 1 } },
    blueprint = { BuildProcess = { State = 0 } },
}
local manager = {}
function manager:FindModel(id) return owners[id] end
local model = { StoredEnergyAmount = 120.0, MaxEnergyStorage = 1000.0, GetOuter = function() return manager end }
local unbuilt = { StoredEnergyAmount = 0.0, MaxEnergyStorage = 1000.0, GetOuter = function() return manager end }
local works = {
    { kind = 4, CurrentState = 1, CachedOwnerMapObjectConcreteModel = model, OwnerMapObjectModelId = 'built' },
    { kind = 4, CurrentState = 3, CachedOwnerMapObjectConcreteModel = nil },
    { kind = 4, CurrentState = 1, CachedOwnerMapObjectConcreteModel = unbuilt, OwnerMapObjectModelId = 'blueprint' },
    { kind = 4, CurrentState = 1, CachedOwnerMapObjectConcreteModel = unbuilt, OwnerMapObjectModelId = 'gone' },
    { kind = 7, CurrentState = 1 }, -- a tree: must not be listed
}
package.loaded.palapi = {
    latch_authority = function() return authority end,
    base_camps = function() return { 'camp' } end,
    camp_works = function() return works end,
    work_suitability = function(w) return w.kind end,
    prop = function(o, n) return o[n] end,
    unwrap = function(v) return v end,
    valid = function(o) return o ~= nil end,
    as_int = function(v) return type(v) == 'number' and math.floor(v) or nil end,
}
package.loaded.station_probe = nil
local probe = require('station_probe')

local out = probe.report()
assert(out:find('4 generator/cooler work', 1, true), out)
assert(out:find('state=1 (Workable) model=yes stored=120.0 max=1000.0 build=Completed', 1, true), out)
assert(out:find('stored=0.0 max=1000.0 build=Building', 1, true), out)
assert(out:find('build=model not found', 1, true), out)
assert(out:find('state=3 (Finish) model=no stored=n/a max=n/a build=n/a', 1, true), out)
assert(not out:find('Lumbering', 1, true) and not out:find('Deforest', 1, true), 'tree listed: ' .. out)

authority = nil
assert(probe.report():find('host/server only', 1, true), 'client or unknown authority must not read models')
