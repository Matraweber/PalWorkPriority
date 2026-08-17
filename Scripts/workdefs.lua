-- EPalWorkSuitability: names, and the integer GetWorkSuitabilityRank wants.
--
-- The declaration order below is stable across Palworld versions. What is
-- NOT stable, and what no public documentation pins down, is whether the
-- enum starts at 0 or at 1. AutoAssignResearchLab ships offset 1 against
-- game revision 82182 and demonstrably works, so that is the default here.
-- discover.lua re-derives the offset from the live UEnum and warns loudly if
-- this build disagrees, rather than silently assigning every pal to the
-- wrong job.

local M = {}

M.ORDER = {
    "EmitFlame",
    "Watering",
    "Seeding",
    "GenerateElectricity",
    "Handcraft",
    "Collection",
    "Deforest",
    "Mining",
    "OilExtraction",
    "ProductMedicine",
    "Cool",
    "Transport",
    "MonsterFarm",
}

M.enum_offset = 1

-- Human-facing labels, matching the in-game work suitability icons.
M.LABEL = {
    EmitFlame = "Kindling",
    Watering = "Watering",
    Seeding = "Planting",
    GenerateElectricity = "Generating Electricity",
    Handcraft = "Handiwork",
    Collection = "Gathering",
    Deforest = "Lumbering",
    Mining = "Mining",
    OilExtraction = "Oil Extraction",
    ProductMedicine = "Medicine Production",
    Cool = "Cooling",
    Transport = "Transporting",
    MonsterFarm = "Farming",
}

function M.value(name)
    for i, n in ipairs(M.ORDER) do
        if n == name then
            return i - 1 + M.enum_offset
        end
    end
    return nil
end

function M.name(value)
    if type(value) ~= "number" then return nil end
    return M.ORDER[value - M.enum_offset + 1]
end

function M.label(name)
    return M.LABEL[name] or name
end

-- Reports whether a name is one this build knows about, so a typo in
-- config.lua surfaces as a warning instead of a silently ignored line.
function M.is_known(name)
    return M.value(name) ~= nil
end

return M
