-- Pal Work Priority, user configuration.
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
    -- Set this to true to watch a session before letting the mod touch a
    -- base. Every pass then logs what it would change and sends nothing.
    dry_run = false,

    -- Seconds between automatic passes.
    --
    -- Demand is short-lived: a job appears, a pal takes it, and it is gone.
    -- At 30 seconds the mod was sampling far slower than work arrives and
    -- could miss a whole job between passes, so a pal was never fenced to
    -- work that existed only between two samples. The reference reconciles
    -- every few seconds for exactly this reason.
    --
    -- A pass only sends toggles that differ from the game's own state, so a
    -- steady base costs almost nothing per pass.
    interval_seconds = 10,

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


    -- How pals are spread across work types.
    --
    --   "spread" every work type gets one pal in priority order, then the
    --            list is walked again for seconds, and again for thirds
    --   "fill"   a work type takes every pal it can before the next type is
    --            considered at all
    --
    -- Spread is the default because a base with dozens of pending transport
    -- jobs will otherwise put every carrier on hauling and leave mining and
    -- handiwork with nobody. Fill is the stricter reading of "priority" if
    -- that is what you actually want.
    assignment_mode = "spread",

    -- Never put more than this many pals on one work type in a single pass.
    -- Set to false for no limit. Combines with either mode: spread with a
    -- cap of 3 means one each, then seconds, then thirds, and no more.
    max_pals_per_work_type = 3,

    -- A pal needs at least this suitability rank to be considered. 1 means
    -- "has the skill at all"; raise it to stop rank-1 pals clogging jobs a
    -- rank-3 pal should be doing.
    min_suitability_rank = 1,

    -- Resource ceilings. When a base already holds enough of something, the
    -- work that produces it is suspended for that pass and its pals fall
    -- through to the next priority instead of standing idle.
    --
    -- You do not have to edit this. "!pwp limit Lumbering Wood 5000" in chat
    -- does the same thing without a restart and remembers it in caps.txt,
    -- and "!pwp limit" on its own lists what is set against what the base
    -- currently holds. Anything set that way wins over what is written here.
    --
    -- Keyed by work type, then by the item's internal StaticId. Run
    -- "!pwp stock" in game to print the ids and counts actually present in
    -- your base rather than guessing at spellings.
    --
    -- Only chests are counted. "!pwp stock" also names anything else on the
    -- base that is holding items, so you can tell a ceiling that has not
    -- triggered from a resource sitting somewhere that does not count.
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
    -- These sit BELOW anything clicked on the Monitoring Stand: a cell you
    -- have clicked keeps what you clicked, and is stored in priorities.txt
    -- next to this mod rather than here.
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
