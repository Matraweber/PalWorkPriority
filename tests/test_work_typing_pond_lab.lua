-- Fishing pond and research lab typing (measured 2026-10-27 on game 1.0.5).
-- Pond: "Fishing" | FishingPond1_0 | PalWorkFishPond, no declared type,
-- Handiwork per the game's tooltip. Lab: "Research" | Lab_Handcraft_1 |
-- PalWorkLabResearch, no declared type, typed by the research subject.
local workdefs = require('workdefs')
local api = require('palapi')

local function work(name, assign, class)
    return {
        OverrideWorkType = 0,
        AssignDefineDataId = assign,
        GetWorkName = function() return name end,
        GetFullName = function() return class .. ' /Game/Pal/Maps/Test.Work' end,
    }
end
local function typed(w) return workdefs.name(api.work_suitability(w)) end

assert(typed(work('Fishing', 'FishingPond1_0', 'PalWorkFishPond')) == 'Handcraft', 'pond not Handiwork')
assert(typed(work('Research', 'Lab_Handcraft_1', 'PalWorkLabResearch')) == 'Handcraft', 'Handiwork research')
-- Other subjects: only the Handcraft id was seen live; these assume the same
-- Lab_<internal name>_N shape and guard the keyword order.
for internal in pairs({ EmitFlame = 1, Watering = 1, Seeding = 1, GenerateElectricity = 1,
    Deforest = 1, Mining = 1, Cool = 1, ProductMedicine = 1 }) do
    assert(typed(work('Research', 'Lab_' .. internal .. '_1', 'PalWorkLabResearch')) == internal,
        'research subject ' .. internal .. ' typed as ' .. tostring(typed(work('Research', 'Lab_' .. internal .. '_1', 'PalWorkLabResearch'))))
end
print('work typing: fishing pond is Handiwork, research typed by subject')
