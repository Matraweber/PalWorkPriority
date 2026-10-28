-- Pal Work Priority, shipped configuration defaults.
--
-- Edit config.lua in the mod root, beside priorities.txt, then restart or
-- use !pwp reload. Existing Scripts/config.lua is backed up and migrated on
-- first load. Release packages name these defaults default_config.lua.

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
    -- Passes send changed permissions only. Native lookup cost still needs
    -- measurement; unchanged toggles do not establish low frame-time cost.
    interval_seconds = 10,

    -- "debug" | "info" | "warn" | "error"
    log_level = "info",

    -- Run a pass automatically when a world finishes loading.
    run_on_world_load = true,

    -- Legacy-install defaults: 1 is highest, 5 lowest, false is X. A verified
    -- fresh installation captures vanilla checked=1/unchecked=X per Pal first.
    -- Existing saved per-Pal values take precedence over this table.
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
        Anyone = 3,              -- INERT, see README: nothing ever resolves work to this type
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

    -- Maximum automatic eligibility per type. Verified manual assignments
    -- and unreadable existing assignments can cause a reported conflict;
    -- permission counts alone do not prove actual worker occupancy.
    -- Set to false for no limit. Combines with either mode: spread with a
    -- cap of 3 means one each, then seconds, then thirds, and no more.
    max_pals_per_work_type = 3,

    -- A Pal whose allowed jobs all have the same number (a fresh install's
    -- "all 1", or a Pal you never edited) is left to the game: it may do every
    -- job that is not X or stopped by a production limit, and the game picks.
    -- Give one job a different number and the mod steers that Pal. false
    -- steers every Pal, as 0.4.1 did.
    leave_unordered_pals_to_game = true,

    -- A reached Mining limit stops only the natural rocks whose main drop is
    -- that item (stone rocks for a Stone limit; ore keeps being mined).
    -- Rocks forget this on a reload, so nothing stays behind in your world.
    -- false switches the whole Mining work type, as 0.4.1 did.
    item_limits_on_rocks = true,

    -- A pal needs at least this suitability rank to be considered. 1 means
    -- "has the skill at all"; raise it to stop rank-1 pals clogging jobs a
    -- rank-3 pal should be doing.
    min_suitability_rank = 1,

    -- Which containers do NOT count as storage for a ceiling.
    --
    -- Everything else on the base does, chests and every station alike, so a
    -- station type this file has never heard of still counts. Listing what to
    -- include instead was the wrong way round: Palworld has more station
    -- types than any hand written list will name, and each one missed is a
    -- ceiling quietly overshooting by whatever that station is holding.
    --
    -- Press Alt+F3, or run "!pwp stock", to print what every container
    -- on your base is holding.
    -- Empty: everything on the base counts towards a ceiling.
    --
    -- Three classes used to be excluded, and the reasoning was that a feed box
    -- holds food set aside to be eaten rather than stock, so counting it would
    -- stop a ranch that was only keeping pace with what the pals get through.
    --
    -- What that actually produced was a lie on the screen. A base with 20,454
    -- Berries in its feed box and a 3,000 ceiling reported "0 in storage" and
    -- went on planting, because the only berries it had were in the one
    -- container it refused to look at. A limit that ignores most of what you
    -- own is not a limit, and "in storage" has to mean in storage.
    --
    -- The ranch case is real but it is a hysteresis problem, not a counting
    -- one: the box drains as the pals eat, and work resumes when it falls back
    -- under the ceiling. Put the classes back here if you would rather have
    -- the old behaviour - "!pwp stock" prints every container by class name.
    uncounted_containers = {},

    -- Set this to a list of class names to count ONLY those and nothing else,
    -- ignoring uncounted_containers. Chests alone would be:
    --   counted_containers = { "PalMapObjectItemChestModel",
    --                          "PalMapObjectGuildChestModel" },
    counted_containers = nil,

    -- Which verified storage a legacy group ceiling is measured against.
    -- "camp": selected base. "global": all loaded bases of the same guild.
    -- Unknown ownership/quantities remain unavailable. Other guilds are never
    -- included. Shared guild storage needs native identity/deduplication proof.
    -- Whether a distant camp remains loaded depends on the running game;
    -- a player's distance is not proof that its stock is absent.
    storage_scope = "camp",

    -- LEGACY GROUP LIMITS. These stop an entire work suitability only after
    -- EVERY listed item reaches its threshold. A stone-only Mining group can
    -- stop ore too; multiple items can overshoot their individual thresholds.
    -- Limits added in the Production Limits panel work the same way.
    --
    -- MINING is the exception (item_limits_on_rocks below): a reached Mining
    -- limit switches off only the natural rocks whose main drop is that item,
    -- and Mining stops as a whole only when no rock or pit still produces
    -- something without a limit or below it. Stone Pits and other buildings
    -- cannot be stopped on their own and keep producing until then.
    --
    -- Per-guild edits override these inherited groups. Clearing an inherited
    -- group item stores an OFF mask for that guild without changing others.
    -- Use the item's StaticId, as reported by !pwp stock. Command output is
    -- written to priority.log, not echoed into the game chat.
    -- work_caps = { Mining = { Stone = 3000, Ore = 2000 } },
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
