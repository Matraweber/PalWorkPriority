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
print('work typing: plantation harvest is Gathering, ranch and other plantation jobs unchanged')
