-- stations.ponds_and_labs_needing reads each work's class once per work id
-- instead of calling GetFullName on every Handiwork work every pass (review
-- 2026-10-28, bundle F). A failed read is asked again; forget() starts over.
local names = 0
package.loaded.palapi = {
    work_full_name = function(w)
        names = names + 1
        return w.class or '<unknown work>'
    end,
    work_suitability = function(w) return w.value end,
    prop = function(o, n) return o[n] end,
    unwrap = function(v) return v end,
    valid = function(o) return o ~= nil end,
    as_int = function(v) return type(v) == 'number' and math.floor(v) or nil end,
}
package.loaded.stations = nil
local stations = require('stations')
local H = stations.HANDIWORK

local built = { State = 1 }
local manager = { FindModel = function() return { BuildProcess = built } end }
local function work(class)
    return { value = H, class = class and (class .. ' /Game/Pal/Maps/Test.Work'), CurrentState = 1,
        OwnerMapObjectModelId = 'id',
        CachedOwnerMapObjectConcreteModel = { GetOuter = function() return manager end } }
end
local works = { work('PalWorkFishPond'), work('PalWorkLabResearch'), work('PalWorkProgress'), work(nil) }
local keys = { 'pond', 'lab', 'bench', 'blank' }

assert(stations.ponds_and_labs_needing(works, keys) == 2 and names == 4)
names = 0
assert(stations.ponds_and_labs_needing(works, keys) == 2)
assert(names == 1, 'classes were read again: ' .. names .. ' (only the unreadable one should be)')
-- Without ids every class is read, as before.
names = 0
assert(stations.ponds_and_labs_needing(works) == 2 and names == 4)
-- World change: the remembered classes go.
stations.forget()
names = 0
stations.ponds_and_labs_needing(works, keys)
assert(names == 4, 'forget kept remembered classes')

-- The memo is per camp and rebuilt from the keys of each call, like the
-- scheduler's work_types: works that are gone drop out instead of growing
-- it for the whole session (review 2026-10-29, performance).
stations.forget()
stations.ponds_and_labs_needing(works, keys, 'c1')
stations.ponds_and_labs_needing(works, keys, 'c2')
names = 0
assert(stations.ponds_and_labs_needing({ works[1] }, { 'pond' }, 'c1') == 1 and names == 0)
names = 0
stations.ponds_and_labs_needing(works, keys, 'c1')
assert(names == 3, 'gone works stayed remembered: ' .. names .. ' reads (lab, bench, blank expected)')
names = 0
stations.ponds_and_labs_needing(works, keys, 'c2')
assert(names == 1, "one camp's call rebuilt another camp's memo: " .. names)
-- Without keys the memo is left alone.
names = 0
stations.ponds_and_labs_needing(works, nil, 'c2')
names = 0
stations.ponds_and_labs_needing(works, keys, 'c2')
assert(names == 1, 'a call without keys dropped the memo')
print('stations: pond/lab class read once per work id, failed reads asked again, forget starts over, memo per camp shrinks with the works')
