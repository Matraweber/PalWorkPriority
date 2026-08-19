-- Pal Work Priority — user configuration.
--
-- Edit this file and either restart the game or run the !pwp reload chat
-- command. Nothing here is written back automatically, so your settings
-- survive a mod update only if you keep a copy of this file.

return {
    -- Master switch. false leaves the game completely untouched.
    enabled = true,

    -- true  = work out every assignment and log it, send nothing to the server
    -- false = actually assign pals
    --
    -- Ships as true on purpose. Run one pass, read the log, confirm the
    -- assignments look sane on your build, then set this to false.
    dry_run = true,

    -- Seconds between automatic passes. A pass is cheap but not free; below
    -- about 15 seconds you are just adding hitches.
    interval_seconds = 30,

    -- "debug" | "info" | "warn" | "error"
    log_level = "info",

    -- Run a pass automatically when a world finishes loading.
    run_on_world_load = true,

    -- Priority per work type: 1 is filled first, 5 last. false means never
    -- assign a pal to this work type at all.
    --
    -- These are the internal names, not the in-game labels. The mapping is
    -- in workdefs.lua if you want the English names.
    work_priority = {
        Transport = 1,           -- Transporting
        ProductMedicine = 1,     -- Medicine Production
        Cool = 2,                -- Cooling
        GenerateElectricity = 2, -- Generating Electricity
        Collection = 2,          -- Gathering
        Handcraft = 3,           -- Handiwork
        EmitFlame = 3,           -- Kindling
        Watering = 3,            -- Watering
        Seeding = 3,             -- Planting
        Deforest = 4,            -- Lumbering
        Mining = 4,              -- Mining
        OilExtraction = 4,       -- Oil Extraction
        MonsterFarm = 5,         -- Farming
        Anyone = 3,              -- work needing no particular skill
    },

    -- A pal needs at least this suitability rank to be considered. 1 means
    -- "has the skill at all"; raise it to stop rank-1 pals clogging jobs a
    -- rank-3 pal should be doing.
    min_suitability_rank = 1,

    -- Resource ceilings. When a base already holds enough of something, the
    -- work that produces it is suspended for that pass and its pals fall
    -- through to the next priority instead of standing idle.
    --
    -- Keyed by work type, then by the item's internal StaticId. Run
    -- "!pwp stock" in game to print the ids and counts actually present in
    -- your base rather than guessing at spellings.
    --
    -- A work type with several items listed is suspended only when every
    -- one of them is at or above its ceiling, so mining keeps running while
    -- either stone or ore is still short.
    --
    -- work_caps = {
    --     Deforest = { Wood = 5000 },
    --     Mining   = { Stone = 3000, Ore = 2000 },
    --     Seeding  = { WheatSeeds = 500 },
    -- },
    work_caps = {},

    -- Per-pal overrides, keyed by nickname first and species name second.
    -- Any work type you leave out falls back to work_priority above.
    --
    -- pal_overrides = {
    --     ["Diggy"]    = { Mining = 1, Transport = false },
    --     ["Anubis"]   = { Handcraft = 1 },
    --     ["Lifmunk"]  = { Handcraft = false },
    -- },
    pal_overrides = {},

    -- Chat command prefix. Type "!pwp help" in game for the command list.
    chat_prefix = "!pwp",
}
