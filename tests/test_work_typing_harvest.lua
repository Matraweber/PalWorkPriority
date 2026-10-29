-- Work typing for plantation harvests (found 2026-10-27 in the 2026-10-17
-- census): FarmBlockV2_Berries_* reports OverrideWorkType 0 and the display
-- name "Harvest", so the station id reached the "farm" keyword and the job was
-- typed as ranch work. Crop harvest is Gathering (Collection) work.
local workdefs = require('workdefs')
local api = require('palapi')

local function work(override, name, assign, class)
    return {
        OverrideWorkType = override,
        AssignDefineDataId = assign,
        GetWorkName = function() return name end,
        GetFullName = function() return class .. ' /Game/Pal/Maps/Test.Work' end,
    }
end

local collection = workdefs.value('Collection')
local farm = workdefs.value('MonsterFarm')
assert(collection and farm and collection ~= farm)

-- The census shape: no declared type, "Harvest", a berry plantation id.
local harvest = work(0, 'Harvest', 'FarmBlockV2_Berries_4', 'PalWorkProgress')
assert(api.work_suitability(harvest) == collection, 'berry harvest still typed as ' .. tostring(workdefs.name(api.work_suitability(harvest))))
-- The declared FarmHarvest type maps the same way.
assert(api.work_suitability(work(5, nil, nil, 'PalWorkProgress')) == collection, 'FarmHarvest (5) not Gathering')
-- A real ranch keeps its type, and the other plantation jobs keep theirs.
assert(api.work_suitability(work(26, nil, 'MonsterFarm_0', 'PalWorkProgress')) == farm, 'ranch lost its type')
assert(api.work_suitability(work(0, 'Planting', 'FarmBlockV2_Berries_4', 'PalWorkProgress')) == workdefs.value('Seeding'))
assert(api.work_suitability(work(0, 'Watering', 'FarmBlockV2_Berries_4', 'PalWorkProgress')) == workdefs.value('Watering'))
-- An untyped work is named in the one-time warning, and Construction (a
-- standing blueprint, untyped in g4-old-reports 2026-10-27) is explained,
-- not hidden: no discover dump has confirmed it is the one a host sees, so
-- it stays out of WORK_IGNORE (review 2026-10-29).
local warned = {}
require('log').warn = function(msg) warned[#warned + 1] = msg end
api._suitability_warned = false
local blueprint = work(0, 'Construction', 'BuildWork_0', 'PalWorkProgress')
assert(api.work_suitability(blueprint) == nil and api.WORK_IGNORE.Construction == nil)
assert(#warned == 1, 'untyped work did not warn once')
assert(warned[1]:find('Construction, BuildWork_0, PalWorkProgress', 1, true), 'warning does not name the work: ' .. warned[1])
assert(warned[1]:find('building not finished yet', 1, true) and warned[1]:find('!pwp discover', 1, true))
assert(not warned[1]:find(string.char(226, 128, 148), 1, true), 'em dash in the warning')
api.work_suitability(work(0, 'Something', 'Other_0', 'PalWorkProgress'))
assert(#warned == 1, 'the warning repeated')
print('work typing: plantation harvest is Gathering, ranch and other plantation jobs unchanged, untyped work named once')
