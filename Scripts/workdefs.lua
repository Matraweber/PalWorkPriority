-- EPalWorkSuitability: names, and the integer GetWorkSuitabilityRank wants.
--
-- Confirmed against a live dump on game revision 82182:
--   0 = None, 1 = EmitFlame ... 13 = MonsterFarm, 14 = Anyone
-- so the enum is 1-based for real work types, with 0 reserved for None.
-- enum_offset stays 1 and ORDER starts at EmitFlame.

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
    "Anyone",
}

M.enum_offset = 1

-- Work that names no skill requirement. Suitability rank is meaningless
-- here, so the rank gate is skipped for it and any pal will do.
M.ANYONE = "Anyone"

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
    Anyone = "Any Pal",
}

-- Reverse of LABEL. GetWorkName returns the game's own display name for a
-- work, and for some works that string IS the suitability label. A job
-- reporting "Gathering" is Collection work whatever its class is called.
M.BY_LABEL = {}
for name, label in pairs(M.LABEL) do
    M.BY_LABEL[label:lower()] = name
end

function M.from_label(text)
    if type(text) ~= "string" then return nil end
    return M.BY_LABEL[text:lower()]
end

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

function M.is_known(name)
    return M.value(name) ~= nil
end

-- Work objects carry no suitability field. What they do carry is an
-- AssignDefineDataId, a work name and a class name, and on this build those
-- read like PalWorkDeforestFoliage or PalWorkTransportItemInBaseCamp, so the
-- work type is in the text. This table turns that text into a suitability.
--
-- Ordered, not a hash: the first pattern that matches wins, so narrower
-- patterns must come before the ones that could also swallow them.
M.KEYWORDS = {
    { "generateelectricity", "GenerateElectricity" },
    { "electric",            "GenerateElectricity" },
    { "generator",           "GenerateElectricity" },
    { "productmedicine",     "ProductMedicine" },
    { "medicine",            "ProductMedicine" },
    { "oilextraction",       "OilExtraction" },
    { "oil",                 "OilExtraction" },
    { "monsterfarm",         "MonsterFarm" },
    { "ranch",               "MonsterFarm" },
    { "deforest",            "Deforest" },
    { "lumber",              "Deforest" },
    { "transport",           "Transport" },
    { "carry",               "Transport" },
    { "handcraft",           "Handcraft" },
    { "craft",               "Handcraft" },
    { "collect",             "Collection" },
    { "gather",              "Collection" },
    { "pickup",              "Collection" },
    { "mining",              "Mining" },
    { "watering",            "Watering" },
    { "water",               "Watering" },
    { "seeding",             "Seeding" },
    { "seed",                "Seeding" },
    { "plant",               "Seeding" },
    { "emitflame",           "EmitFlame" },
    { "flame",               "EmitFlame" },
    { "kindl",               "EmitFlame" },
    { "cooling",             "Cool" },
    { "cool",                "Cool" },
    -- "farm" last: it also appears inside words that are not the ranch,
    -- and MonsterFarm has already had its shot above.
    { "farm",                "MonsterFarm" },
}

-- Resolves a work type name from arbitrary engine text, or nil if nothing
-- in it looks like a work type. Never guesses a default: a work this cannot
-- classify is reported as unreadable rather than silently filed as Handiwork.
function M.from_text(text)
    if type(text) ~= "string" or text == "" then return nil end
    local haystack = text:lower()

    for _, entry in ipairs(M.KEYWORDS) do
        if haystack:find(entry[1], 1, true) then
            return entry[2]
        end
    end
    return nil
end

-- Which job produces an item.
--
-- So that setting a rule does not have to ask. Picking the work type was a
-- second screen and thirteen choices for a question that usually has one
-- obvious answer, and being wrong is visible on the rule itself and fixable
-- by clicking it.
--
-- Ordered, first match wins, so narrower patterns come before the ones that
-- would swallow them. These are matched against the internal item id, which
-- F12 prints.
M.ITEM_WORK = {
    -- smelting and cooking are both the furnace, which is Kindling work
    { "ingot",        "EmitFlame" },
    { "baked",        "EmitFlame" },
    { "grilled",      "EmitFlame" },
    { "cooked",       "EmitFlame" },
    { "roasted",      "EmitFlame" },
    { "pizza",        "EmitFlame" },
    { "quiche",       "EmitFlame" },
    { "soup",         "EmitFlame" },
    { "stew",         "EmitFlame" },
    { "charcoal",     "EmitFlame" },
    { "cement",       "EmitFlame" },
    { "brick",        "EmitFlame" },
    { "glass",        "EmitFlame" },

    -- the ranch
    { "wool",         "MonsterFarm" },
    { "milk",         "MonsterFarm" },
    { "egg",          "MonsterFarm" },
    { "honey",        "MonsterFarm" },
    { "palfluids",    "MonsterFarm" },
    { "leather",      "MonsterFarm" },
    { "horn",         "MonsterFarm" },
    { "bone",         "MonsterFarm" },

    -- the plantation. seeds before the crops they grow into, or BerrySeeds
    -- matches Berries and lands on the wrong job.
    { "seed",         "Seeding" },
    { "berries",      "Seeding" },
    { "wheat",        "Seeding" },
    { "lettuce",      "Seeding" },
    { "tomato",       "Seeding" },
    { "carrot",       "Seeding" },
    { "onion",        "Seeding" },

    -- the mine
    { "ore",          "Mining" },
    { "stone",        "Mining" },
    { "coal",         "Mining" },
    { "sulfur",       "Mining" },
    { "quartz",       "Mining" },
    { "crystal",      "Mining" },
    { "sand",         "Mining" },

    -- oil before anything that could swallow it
    { "oil",          "OilExtraction" },
    { "medicine",     "ProductMedicine" },

    -- the logging site. processed wood is a workbench product, so the plain
    -- wood entry comes after it.
    { "processed_wood", "Handcraft" },
    { "lumber",       "Deforest" },
    { "wood",         "Deforest" },
    { "fiber",        "Deforest" },

    -- workbench and the production lines
    { "cloth",        "Handcraft" },
    { "sphere",       "Handcraft" },
    { "nail",         "Handcraft" },
    { "ammo",         "Handcraft" },
    { "circuit",      "Handcraft" },
    { "arrow",        "Handcraft" },
    { "bullet",       "Handcraft" },
    { "shell",        "Handcraft" },
    { "gunpowder",    "Handcraft" },
    { "explosive",    "Handcraft" },
    { "polymer",      "Handcraft" },
    { "carbon",       "Handcraft" },
    { "plate",        "Handcraft" },
    { "rope",         "Handcraft" },
    { "flour",        "Handcraft" },
    { "rifle",        "Handcraft" },
    { "handgun",      "Handcraft" },
    { "shotgun",      "Handcraft" },
    { "crossbow",     "Handcraft" },
    { "launcher",     "Handcraft" },
    { "furnitur",     "Handcraft" },

    -- more of the cooking pot
    { "cake",         "EmitFlame" },
    { "pie",          "EmitFlame" },
    { "salad",        "EmitFlame" },
    { "juice",        "EmitFlame" },
    { "jam",          "EmitFlame" },
    { "curry",        "EmitFlame" },
    { "sauteed",      "EmitFlame" },
    { "steamed",      "EmitFlame" },
    { "fried",        "EmitFlame" },
    { "bread",        "EmitFlame" },

    -- more of the plantation
    { "cotton",       "Seeding" },
    { "pumpkin",      "Seeding" },
    { "bamboo",       "Deforest" },

    -- more of the mine
    { "paldium",      "Mining" },
    { "fragment",     "Mining" },
    { "ingot_ore",    "Mining" },
}

-- Where an item lands when the table cannot name its job. Unreachable while
-- the picker only offers items the table knows, and here so that an id which
-- slips through becomes a rule that can be corrected in place rather than a
-- dead end asking a question with no good answer.
M.DEFAULT_WORK = "Handcraft"

-- The work type that most likely produces this item, or nil when nothing in
-- the table matches.
--
-- nil now means "the base does not make this", because the picker uses this
-- to decide what to show at all. Pal drops and world loot match nothing here
-- and that is exactly what keeps them out of a menu about base production.
function M.work_for_item(item_id)
    if type(item_id) ~= "string" or item_id == "" then return nil end
    local hay = item_id:lower()

    for _, entry in ipairs(M.ITEM_WORK) do
        if hay:find(entry[1], 1, true) then return entry[2] end
    end
    return nil
end

return M
