-- Every call into Palworld's own objects lives in this file.
--
-- The rest of the mod talks in plain Lua tables. When a game update renames
-- something, this is the only file that needs touching.
--
-- Symbol provenance. All of these are taken from mods that run on game
-- revision 82182, not guessed:
--   BaseCampModel.WorkerDirector, GetCharacterHandleSlots, IsEmpty,
--   Handle:GetIndividualID, Handle:TryGetIndividualParameter,
--   Param:GetWorkSuitabilityRank, and
--   PalNetworkBaseCampComponent:RequestFixedAssignWorkInBaseCamp_ToServer
--     come from AutoAssignResearchLab.
--   PalUtility:GetWorkProgressManager, BaseCampModel.WorkCollection.WorkIds,
--   WorkProgressManager:GetWork and Work:GetWorkId come from BreedingHelper.
--
-- Confirmed by a live schema dump on that same revision:
--   PalIndividualCharacterParameter exposes GetNickname and GetCharacterID
--     as UFUNCTIONS, not properties.
--   PalWorkBase has NO work-suitability field. It carries AssignDefineDataId,
--     OverrideWorkType and GetWorkName; the requirement itself lives in an
--     assign-define data row the work only references by name.
--
-- Beware of probing UE4SS by property name: it returns a live-looking
-- TrivialObject for ANY name, including ones that do not exist, so a
-- non-nil read proves nothing about whether a field is real.

local log = require("log")
local trace = require("trace")

local M = {}

-- ---------------------------------------------------------------------------
-- Shape helpers
-- ---------------------------------------------------------------------------

-- Hook callbacks hand out RemoteUnrealParam wrappers; direct property reads
-- return the object itself. Both shapes arrive here.
function M.unwrap(v)
    if type(v) ~= "userdata" then return v end
    local ok, inner = pcall(function()
        if v.get then return v:get() end
        return nil
    end)
    if ok and inner ~= nil then return inner end
    return v
end

function M.valid(o)
    if o == nil then return false end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end

local unwrap, valid = M.unwrap, M.valid

-- Whether this machine is the authority. nil means not yet asked.
-- Declared here rather than beside has_authority because M.reset, which
-- clears it, is defined further up this file - and a local declared below its
-- first use is a silent global write, not a shared variable.
local auth = nil

-- Walk-fallback rationing for player_controller; the reasoning is at the
-- usage site. Declared up here because M.reset clears it.
local pc_walk_misses = 0
local pc_walk_next = 0
local PC_WALK_PATIENCE = 5
local PC_WALK_GAP = 10.0
local PC_WALK_GAP_MAX = 120.0

-- Whether UEHelpers.GetGameInstance (a FindFirstOf on its first call) has
-- already come back empty in this world. headless_game_instance explains it;
-- declared up here because M.reset clears it.
local gi_search_missed = false

-- The owned base camp component, remembered by NAME between resolutions.
--
-- Strings only, never wrappers: a full name cannot dangle, which is what the
-- never-store rule is actually about. The fast path re-resolves both objects
-- through StaticFindObject (~11ms each on this build) and then re-proves the
-- whole ownership chain - transmitter still owned by this pc, component still
-- inside that transmitter - before believing anything. Instance names are NOT
-- unique across destroy/recreate (the Monitoring Stand taught that), so a
-- name that resolves is a candidate, not an answer; the re-proof is the
-- answer. Any doubt drops the memo and pays the two full walks again, which
-- at 27-34ms each per pass is exactly the cost this exists to remove.
local owned_memo = nil

-- The component's UClass, resolved once per session and kept.
--
-- Keeping a wrapper is forbidden for OBJECTS; this is a /Script/ UClass,
-- which the engine does not collect - the same carve-out cdo() documents
-- for its cache. One StaticFindObject at first use, then free forever.
local owned_comp_class = nil

local function comp_class()
    if owned_comp_class ~= nil and valid(owned_comp_class) then
        return owned_comp_class
    end
    pcall(function()
        owned_comp_class =
            StaticFindObject("/Script/Pal.PalNetworkBaseCampComponent")
    end)
    if owned_comp_class ~= nil and valid(owned_comp_class) then
        return owned_comp_class
    end
    return nil
end

local function object_path(full)
    -- GetFullName answers "ClassName /Path/To.Object". StaticFindObject wants
    -- only the path half.
    if type(full) ~= "string" then return nil end
    return full:match("^%S+%s+(.+)$")
end

-- Whether one of the game's own full-screen menus is up.
--
-- Declared HERE, in the module that owns the table, because main.lua writes it
-- from inside a hook while overlay.lua and panel.lua read it as a gate.
-- Nothing declared it, so no static check could see the contract and a rename
-- would have failed silently - and if both hook paths fail it stayed nil for
-- ever, so "api.game_ui_active ~= true" was always true and the cursor was
-- restored over the player's own open inventory.
--
-- false rather than nil, so the default is a definite answer, and M.reset puts
-- it back with the rest of the world state.
--
-- Being honest about what this does NOT fix: every reader tests `~= true`, and
-- false is not true either, so a session where both hook paths fail behaves
-- exactly as it did before and the cursor is still restored over the game's
-- own menus. What changed is that the field is declared where it lives, so a
-- static check can see the contract and a rename cannot fail silently. The
-- behavioural half needs the readers to distinguish "no" from "not known",
-- which none of them currently do.
M.game_ui_active = nil -- no native UI observation yet

-- Reads a property without letting a missing name take the pass down.
local function prop(obj, name)
    local ok, v = pcall(function() return obj[name] end)
    if ok then return v end
    return nil
end

local function as_int(v)
    if type(v) == "number" then return math.floor(v) end
    if type(v) == "userdata" then
        local ok, n = pcall(function() return v:get() end)
        if ok and type(n) == "number" then return math.floor(n) end
    end
    return nil
end

-- A stable string key for an FGuid. Used to remember what was assigned
-- where, so a repeat pass does not re-issue an assignment a pal is already
-- carrying out. Re-assigning every cycle would make workers drop their job
-- and re-path constantly. Returns nil when the guid cannot be read, and the
-- caller falls back to the work's full name.
-- Each component must come back as a real NUMBER. tostring() is not good
-- enough: on a value that is not actually an FGuid, UE4SS answers every
-- field with a TrivialObject wrapper, and those stringify to a reused
-- address, so all four parts match, and so does every other object's key.
-- That silently collapses distinct pals onto one identity, and a claim set
-- keyed on it accepts exactly one pal per pass.
local function guid_integer(value)
    if type(value) == "number" then return math.tointeger(value) end
    if type(value) == "userdata" then
        local ok, number = pcall(function() return value:get() end)
        if ok and type(number) == "number" then return math.tointeger(number) end
    end
    return nil
end

local function read_guid(g)
    if g == nil then return nil, "scope_missing_guid" end

    local a, b, c, d
    local ok = pcall(function()
        a = guid_integer(g.A); if a == nil then return end
        b = guid_integer(g.B); if b == nil then return end
        c = guid_integer(g.C); if c == nil then return end
        d = guid_integer(g.D)
    end)

    if ok and a ~= nil and b ~= nil and c ~= nil and d ~= nil then
        -- An all-zero GUID is unset, not a usable identity. Its cause (for
        -- example a replication placeholder) is not established by the bits.
        -- Check the numbers before allocating an identity string. The saved
        -- September 13 scan has 534 such unknown observations per sweep.
        if a == 0 and b == 0 and c == 0 and d == 0 then return nil, "scope_zero_guid" end
        return tostring(a).."-"..tostring(b).."-"..tostring(c).."-"..tostring(d)
    end
    return nil, ok and "scope_guid_fields" or "scope_guid_read"
end

function M.guid_key(g)
    -- Keep the public single-value contract. The storage reader uses the
    -- private reason from these same four reads, never a second GUID probe.
    local key = read_guid(g)
    return key
end

-- Identity key for an FPalInstanceID (the shape GetIndividualID returns):
-- PlayerUId and InstanceId are each an FGuid, so the key is built from all
-- eight ints. The int32 fields come back sign-extended; masking to unsigned
-- keeps the same pal producing the same key every time. This must stay the
-- one key both the scheduler and the stand UI use, or a row on the stand can
-- never find its pal's assignment.
function M.instance_key(id)
    if id == nil then return nil end
    local parts = {}
    local ok = pcall(function()
        for _, guid_name in ipairs({ "PlayerUId", "InstanceId" }) do
            local g = id[guid_name]
            for _, field in ipairs({ "A", "B", "C", "D" }) do
                local n = as_int(g[field])
                if n == nil then return end
                parts[#parts + 1] = string.format("%08X", n % 0x100000000)
            end
        end
    end)
    if ok and #parts == 8 then
        return table.concat(parts)
    end
    return nil
end

M.prop = prop
M.as_int = as_int

-- ---------------------------------------------------------------------------
-- Object lookup
-- ---------------------------------------------------------------------------

-- Engine wrappers must never outlive a world switch, so the cache is dropped
-- on every world load. reset() is called from main.lua's load hook.
local cdo_cache = {}

function M.reset()
    M.last_storage_scan = nil
    M.last_camp_scan = nil
    M.camps_available, M.camps_error = nil, nil
    -- The authority answer belongs to the world, so it goes with it.
    auth = nil
    owned_memo = nil
    if M.pc_memo_end then M.pc_memo_end() end

    -- A new world is a new chance for a controller to exist, so the walk
    -- starts trusted again rather than serving out a backoff earned by the
    -- last one.
    pc_walk_misses = 0
    pc_walk_next = 0
    gi_search_missed = false
    M.game_ui_active = nil

    cdo_cache = {}
    M._suitability_source = nil
    M._unknown_worktype = {}
    M._suitability_warned = false
end

function M.cdo(path)
    -- valid() on a kept wrapper is the one dereference this file permits, and
    -- only because every path cached here is a UClass or a class default
    -- under /Script/, which the engine does not collect. A /Game/ path would
    -- be a real asset, collectable, and this would become the crash the whole
    -- codebase is built to avoid - so it is refused rather than trusted to
    -- stay out by convention.
    local cacheable = path:sub(1, 8) == "/Script/"

    if cacheable then
        local hit = cdo_cache[path]
        if valid(hit) then return hit end
    end

    local obj
    pcall(function() obj = StaticFindObject(path) end)
    if valid(obj) then
        if cacheable then cdo_cache[path] = obj end
        return obj
    end
    return nil
end

-- The local player's controller, found at most once per clock beat.
--
-- FindFirstOf can only early-exit on a class that is COMMON, and there is
-- exactly one PalPlayerController in an array of tens of thousands - measured
-- on this build at 9ms, against 1ms for a class like Texture2D. Twelve places
-- in this mod ask for it, and a single panel refresh asks twice on its own:
-- once through overlay.host's owner check and once through reassert_input.
-- That was most of a 40ms refresh spent finding the same object repeatedly.
--
-- Beat scoped, and the scope is the point. BreedingHelper's sync.lua carries
-- the same memo with the same reasoning ("one active beat walks through here
-- 2-4 times, each a fresh GUObjectArray lookup at 10Hz") and clears it on
-- entry AND exit so its lifetime is exactly one beat. A wall-clock TTL is the
-- version that would be wrong: an object held past the beat that found it is
-- the use-after-free this whole codebase is built to avoid, and clock.lua's
-- beat is one synchronous call - the same window rule one already calls safe.
local pc_memo = nil
local pc_memo_open = false
-- Separate from the fallback controller: a populated dedicated server may
-- return a remote controller from the walk, which never proves a viewport.
local local_pc_memo = nil

function M.pc_memo_begin()
    pc_memo, pc_memo_open = nil, true
    local_pc_memo = nil
end

function M.pc_memo_end()
    pc_memo, pc_memo_open = nil, false
    local_pc_memo = nil
end

-- Walked down from the engine rather than searched for.
--
-- FindFirstOf("PalPlayerController") costs 9.8ms on this build and was, after
-- the beat memo landed, the entire remaining cost of a panel refresh. It is
-- slow for a structural reason that no amount of caching fixes: FindFirstOf
-- can only stop early on a class with many instances, and there is exactly
-- one player controller in a GUObjectArray of tens of thousands, so it reads
-- all of it. UEHelpers.GetPlayerController is the same call and the same
-- 9.6ms.
--
-- The engine knows where its own controller is. GameViewport.World
-- .OwningGameInstance.LocalPlayers[1].PlayerController returns the identical
-- object - verified against FindFirstOf, same instance name - in 0.00ms,
-- because every step is a pointer read rather than a search. GetEngine costs
-- 2ms once and is cached by UEHelpers after that.
--
-- Nothing is held. The chain is re-read from the engine on every call, so it
-- is exactly as fresh as the search it replaces, and the beat memo above is
-- still the only thing that keeps an object alive across calls.
--
-- It is also more correct. FindFirstOf returns SOME PalPlayerController; on a
-- listen server the host has both its own and every client's in the array,
-- and which one comes back is array order. LocalPlayers[1] is the local
-- player's by construction, which is what all twelve callers actually meant.
--
-- StaticFindObject on the widget's own path was measured too, as the other
-- way to answer this. It is 11ms. overlay.lua records why.
-- Counted, not logged. A warning here would either fire ten times a second
-- for the rest of the session or fire once at a world change and mean
-- nothing; `!pwp panel routes` reports the count instead.
M.pc_fallbacks = 0

-- The walk fallback backs off; the chain never does.
--
-- Measured on the headless test server: 7.3ms per player_controller() call,
-- 6.4ms/s forever, because the closed panel polled the pad chord once a
-- second (that poll is gone since 2026-10-28) and on that machine the chain has no GameViewport to read, so
-- every poll fell through to FindFirstOf("PalPlayerController") - the
-- pathological walk, hunting one instance of a class that has ZERO on a
-- server, which means no early exit and a full array read to answer "no".
-- For a gamepad nobody is holding, on a machine with no screen.
--
-- Only the WALK is rationed, and only after it has actually failed several
-- times running. The chain is still attempted on every single call, which
-- is the property the comment above insists on: the instant a controller
-- exists the fast path returns it, with no waiting out of any backoff. A
-- machine that legitimately has a controller reaches the walk only in the
-- moments before the world is up, where both routes fail anyway.

local function via_engine()
    local pc
    pcall(function()
        local ue = require("UEHelpers")
        pc = ue.GetEngine().GameViewport.World
            .OwningGameInstance.LocalPlayers[1].PlayerController
    end)
    return pc
end

-- Is there a screen on this machine?
--
-- The honest test, and NOT the one tried first: a dedicated server has
-- player controllers - one per connected player - so asking "is there a
-- controller" says yes on a populated server and lets client-only code run
-- on a machine with no renderer. That mistake killed the test server twice
-- on 28 August, both times through '!pwp panel routes', which names what
-- each lookup returned and faults on the wrappers a headless machine hands
-- back. GameViewport is the thing that actually differs: every client has
-- one, no headless server does. Read fresh, nothing kept, and a failure to
-- read at all counts as "no screen" - the safe direction here, since the
-- worst case is refusing a diagnostic rather than ending the process.
function M.has_viewport()
    return M.local_player_controller() ~= nil
end

-- A non-nil result also proves the viewport gate, using the same existing
-- chain and validity checks as has_viewport. Positive results may be reused
-- only inside the caller's synchronous begin/end scope; misses stay fresh.
-- Never substitute pc_memo here: its FindFirstOf route is not local evidence.
-- Is the player on a controller right now? PalUtility:GetCurrentInputType is
-- reflected in this build (Functions.txt; Perfect Placement reads it too). Its
-- enum is CommonUI's ECommonInputType: 0 mouse and keyboard, 1 gamepad, 2
-- touch. The raw value is kept for diagnostics. nil means "could not ask",
-- which callers treat as "not a controller" (they only add help, never block).
function M.input_is_gamepad()
    local ok, value = pcall(function()
        local util = M.cdo("/Script/Pal.Default__PalUtility")
        local pc = M.local_player_controller()
        if util == nil or pc == nil then return nil end
        return util:GetCurrentInputType(pc)
    end)
    if not ok then return nil end
    M.last_input_type = value
    if type(value) ~= "number" then return nil end
    return value == 1
end

function M.local_player_controller()
    if local_pc_memo ~= nil then return local_pc_memo end
    local pc
    pcall(function()
        local ue = require("UEHelpers")
        local viewport = ue.GetEngine().GameViewport
        if not valid(viewport) then return end
        local world = viewport.World
        if not valid(world) then return end
        local candidate = world.OwningGameInstance.LocalPlayers[1].PlayerController
        if valid(candidate) then pc = candidate end
    end)
    if pc ~= nil and pc_memo_open then local_pc_memo = pc end
    return pc
end

-- The game instance, as a world context on a machine with no screen.
--
-- A headless server has no GameViewport, so every chain above throws there,
-- and the only other world context the mod knew was a player controller -
-- which an empty server does not have. The search for one read the whole
-- object array every pass to find nothing (2026-10-29: 20.5 ms on the GPortal
-- server for the authority probe, 20.5 ms again for the work manager). The
-- game instance exists for the whole process, and any UObject whose GetWorld
-- answers is a valid world context for a PalUtility call.
--
-- nil wherever a viewport exists: a client, a listen host and singleplayer
-- keep their own paths exactly as they were. Read fresh, nothing kept here.
-- UGameEngine.GameInstance is one pointer read. UEHelpers.GetGameInstance is
-- a FindFirstOf on its first call (UEHelpers keeps the answer, as it keeps
-- the engine), so after one miss it is not asked again in this world: a
-- failing route must not add a walk of its own to every pass.
-- The name check is the TrivialObject guard used for GameMode below.
local function headless_game_instance()
    local gi
    pcall(function()
        local ue = require("UEHelpers")
        local engine = ue.GetEngine()
        if not valid(engine) or valid(engine.GameViewport) then return end
        local function named(o)
            if not valid(o) then return false end
            local name
            pcall(function() name = o:GetFullName() end)
            return type(name) == "string" and name:find("GameInstance", 1, true) ~= nil
        end
        local candidate
        pcall(function() candidate = engine.GameInstance end)
        if named(candidate) then gi = candidate; return end
        if gi_search_missed or type(ue.GetGameInstance) ~= "function" then return end
        log.count("api: game instance search")
        pcall(function() candidate = ue.GetGameInstance() end)
        if named(candidate) then gi = candidate else gi_search_missed = true end
    end)
    return gi
end

-- A player just spawned on this machine (main.lua's ClientRestart hook on a
-- dedicated server), so a controller exists now: the next walk is not held
-- back by misses earned while the server was empty. Without this, the first
-- player after a long empty spell waited up to the two-minute cap before
-- the pass could find a controller, and so a write route.
function M.pc_walk_retry()
    pc_walk_misses = 0
    pc_walk_next = 0
end

function M.player_controller()
    if pc_memo ~= nil then return pc_memo end
    if local_pc_memo ~= nil then return local_pc_memo end

    local pc = via_engine()

    -- The chain is tried every time rather than being switched off after a
    -- few misses. Failing costs nothing - it is a pcall over a nil index -
    -- and a miss is usually a world load, where GameViewport.World does not
    -- exist yet, not a build without the chain. Latching on those early
    -- misses would have given up the fast path permanently at startup, which
    -- is precisely when they happen.
    if not valid(pc) then
        M.pc_fallbacks = M.pc_fallbacks + 1

        local now = os.clock()
        if pc_walk_misses < PC_WALK_PATIENCE or now >= pc_walk_next then
            log.count("api: pc walk")
            pcall(function() pc = FindFirstOf("PalPlayerController") end)

            if valid(pc) then
                pc_walk_misses = 0
            else
                -- The gap doubles with every miss past the patience, up to
                -- two minutes. A fixed 10 s never engaged on the GPortal
                -- server (2026-10-29): its passes are 11.5 s apart, so every
                -- pass walked the whole array to find no player. A hit resets
                -- it, and so does a world change.
                pc_walk_misses = pc_walk_misses + 1
                local over = math.max(0, math.min(pc_walk_misses - PC_WALK_PATIENCE, 8))
                pc_walk_next = now + math.min(PC_WALK_GAP * 2 ^ over, PC_WALK_GAP_MAX)
            end
        else
            log.count("api: pc walk skipped")
        end
    end

    if valid(pc) then
        if pc_memo_open then pc_memo = pc end
        return pc
    end
    return nil
end

-- The component carrying the base-camp server RPCs. Present as a standalone
-- object in most sessions; on some builds it only exists hanging off the
-- player character, hence the fallback.
function M.network_component()
    local comp
    pcall(function() comp = FindFirstOf("PalNetworkBaseCampComponent") end)
    if valid(comp) then return comp end

    local player
    pcall(function() player = FindFirstOf("PalPlayerCharacter") end)
    if valid(player) then
        local cls = M.cdo("/Script/Pal.PalNetworkBaseCampComponent")
        if cls then
            local found
            pcall(function() found = player:GetComponentByClass(cls) end)
            if valid(found) then return found end
        end
    end
    return nil
end

-- Whether this machine is the authority for the world.
--
-- PalGameMode exists only where the game is being run: single player, or the
-- host of a co-op session. A client connected to a dedicated server does not
-- have one. The technique is lifted from the resource sharing mod, which uses
-- the same probe to decide whether it may touch storage at all.
--
-- This matters more than it looks. The demand hook is on
-- OnRequiredAssignWork_ServerInternal, which by definition only runs on the
-- authority, so a client registers that hook successfully and then never
-- receives a single pulse.
-- The base camp component owned by this machine's player.
--
-- Every RequestX_ToServer on this component is a client to server RPC, and
-- Unreal drops one before it reaches the wire unless the object carrying it
-- belongs to the caller's connection - silently, so the call returns and
-- nothing happens.
--
-- There are always exactly two candidates, each the BaseCamp component of a
-- PalNetworkTransmitter: one transmitter owned by the local
-- BP_PalPlayerController_C, one owned by BP_PalGameStateInGame_C. FindFirstOf
-- answers with whichever the engine lists first, and that order is not stable
-- across a reconnect. Measured on 23 August: it broke the rule transport
-- outright, and the same coin flip is why work suitability toggles were
-- re-sent every pass for the life of the mod without ever landing.
--
-- Transmitters are read from FindAllOf and matched by name rather than
-- reached through the component's outer: GetOuter hands back a wrapper
-- without the actor function table, so GetOwner on it silently fails.
--
-- Resolved per call and never stored. nil when nothing owned is found, and
-- callers fall back to the old answer rather than sending nothing at all.
function M.owned_network_component()
    local pc = M.player_controller()
    if not valid(pc) then return nil end

    -- Fastest path: the controller's own Children.
    --
    -- AActor.Children is the actors this actor OWNS, and the probe read it
    -- live on this build: the player-owned PalNetworkTransmitter sits right
    -- in it. Ownership is therefore proven by construction - no name
    -- comparison against a remembered string, no StaticFindObject, just
    -- pointer reads off an object obtained in this call. The component then
    -- comes from the transmitter itself via GetComponentByClass. Everything
    -- is resolved fresh and nothing survives the call, which is the age
    -- rule satisfied by shape rather than by discipline.
    --
    -- Any miss falls through silently to the name memo, and from there to
    -- the full double walk - three routes, ordered by price, all proving
    -- the same ownership.
    do
        local comp
        pcall(function()
            local kids = pc.Children
            local n = #kids
            for i = 1, n do
                local child = kids[i]
                if valid(child) then
                    local fn
                    pcall(function() fn = child:GetFullName() end)
                    if type(fn) == "string"
                        and fn:sub(1, 22) == "PalNetworkTransmitter " then
                        local cls = comp_class()
                        if cls ~= nil then
                            local c = child:GetComponentByClass(cls)
                            if valid(c) then comp = c end
                        end
                        break
                    end
                end
            end
        end)

        if comp ~= nil then
            log.count("api: owned comp via children")
            return comp
        end
    end

    -- The children route proves ownership structurally and needs no player
    -- name. Only the name-memo/full-walk fallbacks need this native read.
    local mine
    pcall(function() mine = pc:GetFullName() end)
    if type(mine) ~= "string" then return nil end

    -- Fast path: same player as last time, so try the remembered names.
    if owned_memo ~= nil and owned_memo.pc == mine then
        local comp
        pcall(function()
            local tx = StaticFindObject(owned_memo.tx_path)
            if not valid(tx) then return end

            local owner
            pcall(function() owner = tx:GetOwner() end)
            if not valid(owner) then return end
            local oname
            pcall(function() oname = owner:GetFullName() end)
            if oname ~= mine then return end

            local c = StaticFindObject(owned_memo.comp_path)
            if not valid(c) then return end

            local outer, xname
            pcall(function() outer = c:GetOuter() end)
            if not valid(outer) then return end
            pcall(function() xname = outer:GetFullName() end)
            if xname ~= owned_memo.tx_full then return end

            comp = c
        end)

        if comp ~= nil then
            log.count("api: owned comp via memo")
            return comp
        end

        -- The remembered pair no longer proves out - reconnect coin flip,
        -- teardown, or name reuse. Forget it and resolve from scratch.
        owned_memo = nil
    end
    log.count("api: owned comp full walk")

    local wanted
    local tx
    pcall(function() tx = FindAllOf("PalNetworkTransmitter") end)
    for _, t in ipairs(tx or {}) do
        if valid(t) then
            local owner, oname
            pcall(function() owner = t:GetOwner() end)
            if valid(owner) then
                pcall(function() oname = owner:GetFullName() end)
                if oname == mine then
                    pcall(function() wanted = t:GetFullName() end)
                    break
                end
            end
        end
    end
    if type(wanted) ~= "string" then return nil end

    local all
    pcall(function() all = FindAllOf("PalNetworkBaseCampComponent") end)
    for _, comp in ipairs(all or {}) do
        if valid(comp) then
            local outer, oname
            pcall(function() outer = comp:GetOuter() end)
            if valid(outer) then
                pcall(function() oname = outer:GetFullName() end)
                if oname == wanted then
                    -- Remember the pair by name for the next pass. Only with
                    -- both paths extractable; a memo that cannot re-resolve
                    -- is worse than none.
                    local cfull
                    pcall(function() cfull = comp:GetFullName() end)
                    local tp, cp = object_path(wanted), object_path(cfull)
                    if tp and cp then
                        owned_memo = {
                            pc = mine,
                            tx_full = wanted, tx_path = tp,
                            comp_full = cfull, comp_path = cp,
                        }
                    end
                    return comp
                end
            end
        end
    end
    return nil
end

-- Memoised, because on a client this is the single most expensive question
-- the mod asks and it is asked hundreds of times per grid repaint.
--
-- FindFirstOf can only stop early on a class with MANY instances - the comment
-- on pc_memo above measures it at 9.8ms and explains why. PalGameMode is the
-- pathological case of that rule: there are ZERO instances on a client, so no
-- early exit is possible even in principle and every call reads the entire
-- GUObjectArray. On the machine with the largest array, because a client holds
-- every replicated actor.
--
-- The "never keep an engine object" rule does not apply. This keeps a boolean.
-- There is no wrapper to go stale, only an answer - and the answer cannot
-- change inside a world: a machine does not stop being the authority without a
-- world change, and M.reset clears the memo on exactly that.
--
-- Unlatched it still probes, so an early caller gets a correct answer at the
-- old price rather than a cheap wrong one.
function M.has_authority()
    if auth ~= nil then return auth end
    return M.latch_authority()
end

-- The walk-free probe: the world names its own authority.
--
-- UWorld.AuthorityGameMode is set on the machine running the game mode and
-- null everywhere else, and the chain down to it is the same pointer walk
-- via_engine() already uses for the player controller - fresh on every call,
-- nothing kept. It answers only when it actually reached a world:
--
--   true   the property held an object that names itself something with
--          "GameMode" in it
--   nil    everything else - no world through this route, a nil read, or a
--          wrapper that would not name itself. All of it means "this route
--          cannot say", never "no".
--
-- The chain is NOT allowed to answer false, and the first deployment is why.
-- It treated "the world was reached and the property read nil" as a definite
-- no - and on this build the property reads nil ON THE AUTHORITY TOO, because
-- AuthorityGameMode is not in the reflection data UE4SS sees. A singleplayer
-- host latched "client", has_authority went false, and every pass stopped:
-- the mod sat fully idle in the one mode most people run it in. "Property
-- missing" and "property null" are the same nil up here, and only one of
-- them means no - so nil means fall back to the walk, which knows.
--
-- The name check exists because of the recorded TrivialObject hazard: UE4SS
-- can hand back a live-looking wrapper for a property read. A wrapper that
-- answers GetFullName with a GameMode-ish string is real; one that cannot is
-- not treated as proof of anything, and the caller falls back to the walk.
-- Evidence from elsewhere in the mod that this machine IS the authority.
--
-- Injected rather than required: the natural witness lives in demand.lua
-- (its hook is on a _ServerInternal function, which by definition only runs
-- on the authority), and palapi must not require demand - main.lua owns the
-- wiring. The hint may answer true or abstain with nil; it is never allowed
-- to answer false, for the same reason nil never means no anywhere else in
-- this file.
local authority_hint = nil

function M.set_authority_hint(fn)
    authority_hint = fn
end

local function authority_via_world()
    local answer = nil
    pcall(function()
        local ue = require("UEHelpers")
        local world = ue.GetEngine().GameViewport.World
        if world == nil then return end

        local gm = world.AuthorityGameMode
        if gm ~= nil then
            local name
            pcall(function() name = gm:GetFullName() end)
            if type(name) == "string" and name ~= "" then
                -- lower(): the live object is "BP_PalGamemode_C", lowercase m,
                -- and a case-sensitive find made this whole route a silent
                -- no-op that the walk quietly covered for. The probe caught it.
                if name:lower():find("gamemode", 1, true) ~= nil then
                    answer = true
                    return
                end
            end
        end

        -- The property is not reflected on this build, but the FUNCTION is:
        -- PalUtility.GetPalGameMode has a verified signature in the class
        -- dump, and the cdo-call pattern is the same one GetItemName has
        -- used for two thousand item names. Same one-way contract as the
        -- property: a real object that names itself GameMode-ish is a yes,
        -- everything else stays nil and falls through to the walk - a null
        -- return on a client and a marshalling refusal look identical from
        -- here, and only one of them means no.
        local util = M.cdo("/Script/Pal.Default__PalUtility")
        if util == nil then return end

        local gm2
        pcall(function() gm2 = util:GetPalGameMode(world) end)
        if gm2 == nil then return end

        local name2
        pcall(function() name2 = gm2:GetFullName() end)
        if type(name2) == "string" and name2:lower():find("gamemode", 1, true) then
            answer = true
        end
    end)
    return answer
end

-- The same GetPalGameMode question on a machine with no screen, asked with
-- the game instance as its world context (headless_game_instance). Same
-- one-way contract: a GameMode-ish object is a yes, anything else is nil and
-- the walk decides. Never false - a dedicated server is the authority, and a
-- client never reaches this (it has a viewport).
local function authority_via_instance()
    local gi = headless_game_instance()
    if gi == nil then return nil end
    local answer = nil
    pcall(function()
        local util = M.cdo("/Script/Pal.Default__PalUtility")
        if util == nil then return end
        local gm
        pcall(function() gm = util:GetPalGameMode(gi) end)
        if gm == nil then return end
        local name
        pcall(function() name = gm:GetFullName() end)
        if type(name) == "string" and name:lower():find("gamemode", 1, true) then
            answer = true
        end
    end)
    return answer
end

-- Probe once and remember. Always probes, never reads the memo, so a second
-- call can correct a first one taken before the world was fully up - and
-- so a stale "yes" carried from hosting into joining (world_key may not
-- differ) survives at most one interval. The probe stays fresh; what changed
-- is its price: the pointer chain answers where it can (the game instance
-- on a headless server), and the full FindFirstOf walk remains the fallback
-- for anything the chain cannot see.
function M.latch_authority()
    -- A local autonomous proxy belongs to the current client connection.
    -- Global object enumeration may still find a retiring world's GameMode;
    -- that must never override this affirmative client evidence.
    local pc = M.local_player_controller()
    local role
    if pc then pcall(function() role = as_int(pc.Role) end) end
    if role == 2 then auth = false; return false end
    -- Free evidence first: a demand pulse newer than this spawn can only
    -- have been produced by this machine running the authority's scheduler.
    -- The hint abstains with nil; only an explicit true is believed. main.lua
    -- currently wires no hint at all, so this costs nothing and says nothing.
    if authority_hint ~= nil then
        local yes
        pcall(function() yes = authority_hint() end)
        if yes == true then
            log.count("api: authority via pulse")
            auth = true
            return auth
        end
    end

    local via = authority_via_world()
    if via == true then
        log.count("api: authority via world chain")
        auth = true
        return auth
    end

    -- A headless server: no viewport, so the chain above threw, and with the
    -- pulse hint unwired (main.lua) the walk below ran on every pass, every
    -- remote ClientRestart, client push and storage refresh. Asked fresh on
    -- every call like the rest (N-pass caching was rejected 2026-08-27).
    if authority_via_instance() == true then
        log.count("api: authority via game instance")
        auth = true
        return auth
    end

    log.count("api: authority via walk")
    local gm
    local ok = pcall(function() gm = FindFirstOf("PalGameMode") end)
    if ok and valid(gm) then auth = true; return true end
    -- Absence may mean loading, an unavailable property, or a failed lookup.
    -- A local autonomous proxy is affirmative client evidence.
    auth = nil
    return nil
end

-- A string that changes when the world does, and does not change when the
-- player merely respawns.
--
-- ClientRestart fires on every spawn, not only on a world load, so the mod
-- needs to tell the two apart before it throws away every cache it holds. The
-- level's own object path is the cheapest thing that answers: a new map means
-- a new PersistentLevel, a respawn means the same one. Read fresh and returned
-- as a string, so nothing is kept but text.
function M.world_key()
    local key

    -- The engine names its own world in one pointer chain - and this runs on
    -- EVERY spawn, deaths included, where the FindFirstOf below was a full
    -- array walk (37ms on a grown session) to learn a string the engine
    -- already holds. The walk stays as the fallback: on a headless server
    -- there is no GameViewport and the chain read throws into its pcall.
    pcall(function()
        local ue = require("UEHelpers")
        local world = ue.GetEngine().GameViewport.World
        if world ~= nil then key = world:GetFullName() end
    end)
    if type(key) == "string" and key ~= "" then return key end

    pcall(function()
        local pc = FindFirstOf("PlayerController")
        if pc == nil then return end
        local world = pc:GetWorld()
        if world == nil then return end
        key = world:GetFullName()
    end)
    if type(key) == "string" and key ~= "" then return key end
    return nil
end

function M.base_camps()
    -- main.lua's saved elimination-route evidence establishes that
    -- GetBaseCampManager exposes configuration, not a reflected live-camp
    -- container. Its superclass walk crashed. Keep the proven fresh sweep;
    -- do not retry that probe or infer a native collection from field names.
    local camps = {}
    local ok, err = pcall(function()
        local all = FindAllOf("PalBaseCampModel")
        if all == nil then error("camp enumeration unavailable") end
        for _, camp in ipairs(all) do
            -- An unreadable entry makes this a partial observation, not proof
            -- that the remaining camps do not exist. Preserve the existing
            -- partial-list return and mark its availability unknown.
            if not valid(camp) then error("camp entry unavailable") end
            camps[#camps + 1] = camp
        end
    end)
    M.camps_available = ok
    M.camps_error = not ok and tostring(err) or nil
    -- Observation of this sweep only: no additional reads or kept wrappers.
    M.last_camp_scan = {route="class_walk", complete=ok, camps=#camps}
    return camps
end

function M.camp_id(camp)
    local id
    pcall(function() id = camp:GetId() end)
    return id
end

-- The guild a base camp belongs to, as a stable string key.
--
-- Measured on 23 August rather than assumed. PalBaseCampModel declares
-- GetGroupIdBelongTo, and the FGuid it answers with is the same value a
-- player's PalGroupGuild reports as its Id: both camps in the test world and
-- the player all answered -758686034-1314655308-1294252187-537966059. That
-- shared id is what lets a ceiling set by one guild stay off another's base.
--
-- nil when the camp will not say. Callers must read that as "no scope known",
-- never as "applies everywhere" - guessing wide is how one guild's rule ends
-- up capping the whole server, which is the bug this exists to fix.
function M.camp_guild(camp)
    local gid
    pcall(function() gid = camp:GetGroupIdBelongTo() end)
    return M.guid_key(gid)
end

-- The guild this machine's player belongs to, in the same key space.
--
-- Three hops, because GuildBelongTo is an OBJECT and not an id:
--   controller -> PlayerState -> GuildBelongTo -> Id
--
-- Resolved per call and never stored, like everything else that touches an
-- engine object. nil before the world has settled, and off a guild entirely,
-- which is a real state: a player with no guild owns no bases and so has no
-- rules to see.
function M.guild_of(pc)
    if not valid(pc) then return nil end

    local ps = prop(pc, "PlayerState")
    if not valid(ps) then return nil end

    local guild = prop(ps, "GuildBelongTo")
    if not valid(guild) then return nil end

    return M.guid_key(prop(guild, "Id"))
end

-- The same question about this machine's own player.
--
-- Split from guild_of because the server needs to ask it about somebody else:
-- a rule arriving from a client is filed under the guild of whoever sent it,
-- resolved from the object it came in on, never from what the client claims.
function M.my_guild()
    return M.guild_of(M.player_controller())
end

-- This machine's own player id, as a key comparable with a chat message's
-- SenderPlayerUId.
--
-- Measured on this build: PlayerState.PlayerUId answers, and guid_key reads it
-- as "1390738380-0-0-0". PlayerState.IndividualHandleId.PlayerUId holds the
-- same value, and PlayerID/PlayerId are a small session integer rather than
-- the id a chat message carries.
--
-- The list is kept, and the one that answered is logged once, because a game
-- update renaming this would otherwise be a silent loss of the sender check
-- rather than a visible one. Every read is a plain property read on the local
-- PlayerState - never a call - so the worst case is nil rather than the
-- access violation a wrong UFunction would be.
local uid_prop = nil

function M.my_player_uid()
    local pc = M.player_controller()
    if not valid(pc) then return nil end

    local ps = prop(pc, "PlayerState")
    if not valid(ps) then return nil end

    if uid_prop then return M.guid_key(prop(ps, uid_prop)) end

    for _, name in ipairs({
        "PlayerUId", "PlayerUid", "PlayerID", "PlayerId", "UId", "Uid",
    }) do
        local key = M.guid_key(prop(ps, name))
        if key then
            uid_prop = name
            log.say("player id read from PlayerState." .. name)
            return key
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Pals in a base
-- ---------------------------------------------------------------------------

-- Nickname and species are UFUNCTIONS on PalIndividualCharacterParameter,
-- not properties. Reading them as properties returns a TrivialObject that
-- looks valid and stringifies to nothing, which is how every pal came back
-- as <unnamed> on the first field run.
--
-- Note the capitalisation: GetNickname, but GetCharacterID.
local function name_text(param, fn)
    local out
    pcall(function()
        local v = param[fn](param)
        if v == nil then return end
        if type(v) == "string" then
            out = v
        elseif v.ToString then
            out = v:ToString()
        end
    end)
    if type(out) == "string" and out ~= "" and out ~= "None" then return out end
    return nil
end

-- The nickname is the exception: a property read, not GetNickname. On game
-- 1.0.5 GetNickname wants an out parameter, so calling it with none raised
-- an error every time; pcall hid it, every name fell back to the species,
-- and building that error cost about 0.5 ms per pal. That was 93% of every
-- roster read, once per pass per camp and once a second per stand row
-- (measured 2026-10-19, docs/g5-performance-2026-10-19.md). SaveParameter is
-- the saved struct behind the parameter; NickName is "" for unnamed pals and
-- reads in under the clock's resolution.
local function nickname(param)
    local out
    pcall(function()
        local v = param.SaveParameter.NickName
        if v == nil then return end
        if type(v) == "string" then
            out = v
        elseif v.ToString then
            out = v:ToString()
        end
    end)
    if type(out) == "string" and out ~= "" and out ~= "None" then return out end
    return nil
end

function M.pal_species(param)
    return name_text(param, "GetCharacterID")
end

function M.pal_name(param)
    return nickname(param)
        or M.pal_species(param)
        or "<unnamed>"
end

-- Returns a list of { id, param, name, species, slot_index }.
-- slot_index is the claim key for a pass: unique per camp and, unlike an
-- FGuid, usable directly as a Lua table key.
function M.camp_pals(camp)
    local out = {}
    local director = prop(camp, "WorkerDirector")
    if not valid(director) then return out, "camp has no readable WorkerDirector" end
    local container = prop(director, "CharacterContainer")
    if not valid(container) then return out, "camp has no readable CharacterContainer" end
    local slots = prop(container, "SlotArray")
    if slots == nil then return out, "camp slot array is unavailable" end
    local ok, count = pcall(function() return #slots end)
    count = ok and type(count) == "number" and math.tointeger(count) or nil
    if count == nil or count < 0 or count > 2048 then return out, "invalid camp slot count" end
    -- A read zero is an empty roster. Do not pass a Lua out-table into
    -- GetCharacterHandleSlots as a fallback: that native boundary was never
    -- proven safe. Missing properties are unavailable rather than empty.
    for i = 1, count do
        local read, raw = pcall(function() return slots[i] end)
        local slot = read and unwrap(raw) or nil
        if not valid(slot) then return out, "unreadable camp slot " .. i end
        local empty_ok, empty = pcall(function() return slot:IsEmpty() end)
        if not empty_ok or type(empty) ~= "boolean" then return out, "unknown camp slot occupancy" end
        if not empty then
            local handle = unwrap(prop(slot, "Handle"))
            local id, param, param_ok
            if valid(handle) then
                pcall(function() id = handle:GetIndividualID() end)
                if id == nil then id = prop(handle, "ID") end
                pcall(function() param = handle:TryGetIndividualParameter() end)
                if valid(param) then
                    param_ok = true
                end
            end
            if id == nil then id = prop(slot, "ReplicateHandleID") end
            if not param_ok then
                param = prop(slot, "ReplicateIndividualParameter")
                param_ok = valid(param)
            end
            if id == nil or not param_ok then return out, "occupied slot has unavailable Pal data" end

            local key = M.instance_key(id) or M.guid_key(id)
            if type(key) ~= "string" or key == "" then return out, "occupied slot has no durable Pal identity" end
            local name = nickname(param)
            local species
            if not name then
                species = name_text(param, "GetCharacterID")
                name = species or "<unnamed>"
            end
            -- Reuse only a successful read within this roster call. A failed
            -- display-name fallback retains the separate species read/retry.
            species = species or name_text(param, "GetCharacterID")
            -- Like param, handle is callback-local. Never publish this roster
            -- to a timer/cache; assignment reads resolve its actor afresh.
            out[#out+1] = { id=id, param=param, handle=handle, name=name, species=species, slot_index=i, key=key }
        end
    end
    return out, nil
end

-- GetWorkSuitabilityRankWithCharacterRank folds in the pal's character rank,
-- so a condenser-upgraded pal reads at the rank it actually works at rather
-- than its base rank. Falls back to the plain call on builds without it.
-- (Function name via PalPriority.)
function M.suitability_rank(param, value)
    if type(value) ~= "number" then return 0 end

    local rank
    pcall(function() rank = param:GetWorkSuitabilityRankWithCharacterRank(value) end)
    if type(rank) ~= "number" then
        pcall(function() rank = param:GetWorkSuitabilityRank(value) end)
    end

    if type(rank) ~= "number" or rank ~= rank or rank < 0 or rank == math.huge then return nil end
    return rank
end

-- What this pal is doing right now, as an EPalWorkSuitability value, or nil.
--
-- This is what keeps a fence from being pulled out from under a job in
-- progress: once a work is assigned to a pal it stops asking for one, so by
-- demand alone it looks finished the moment it actually starts.
-- (Function name via PalPriority.)
function M.current_work_suitability(param)
    local v
    pcall(function() v = param:GetCurrentWorkSuitability() end)
    local n = as_int(v)
    if n and n > 0 then return n end
    return nil
end

-- ---------------------------------------------------------------------------
-- Works in a base
-- ---------------------------------------------------------------------------

-- The controller is only a world context here. It used to come from
-- player_controller(), whose walk fallback is what a headless server always
-- got: no viewport, so the walk ran every pass, and with nobody online it
-- found nothing. No manager meant no works, so on an empty server the
-- station counters and per-item rock limits silently did nothing
-- (2026-10-29). The local controller (any machine with a screen) or the game
-- instance (a headless server) answers without a search. The walk stays only
-- as the last resort, for a server build where the game instance is refused
-- as a context; its rationing then keeps the cost down.
function M.work_progress_manager()
    local util = M.cdo("/Script/Pal.Default__PalUtility")
    if not util then return nil end

    local function ask(ctx)
        if ctx == nil then return nil end
        local wpm
        pcall(function() wpm = util:GetWorkProgressManager(ctx) end)
        if valid(wpm) then return wpm end
        return nil
    end

    local local_pc = M.local_player_controller()
    if local_pc ~= nil then return ask(local_pc) end
    local wpm = ask(headless_game_instance())
    if wpm ~= nil then return wpm end
    return ask(M.player_controller())
end

-- The camp channel: BaseCampModel -> WorkCollection.WorkIds -> GetWork(id).
-- This resolves on a host or standalone world, where this process is the
-- server. On a pure multiplayer client GetWork misses and the list comes
-- back empty; request_work_replication() is the lever for that case.
function M.camp_works(camp)
    local out = {}

    local wpm = M.work_progress_manager()
    if not wpm then
        return out, "no work progress manager (pure client, or world not loaded)"
    end

    local col = prop(camp, "WorkCollection")
    if not valid(col) then
        return out, "camp has no readable WorkCollection"
    end

    local ids = prop(col, "WorkIds")
    if ids == nil then
        return out, "WorkCollection has no WorkIds"
    end

    -- keys[i] is out[i]'s work id as a plain string (nil when unreadable), so
    -- a caller can remember facts about a work across passes without keeping
    -- the work itself.
    --
    -- The fourth value counts entries that threw and were left out. The list
    -- is still usable (the error stays nil, so the demand fallback and the
    -- rocks command keep working), but it is not complete: a held rock among
    -- the skipped entries must not read as gone (review 2026-10-29, engine
    -- P2-3). An id that resolves to no valid work is not a skip; the work is
    -- gone.
    local keys, skipped = {}, 0
    local swept = pcall(function()
        ids:ForEach(function(_, entry)
            local ok = pcall(function()
                local id = unwrap(entry)
                local w = wpm:GetWork(id)
                if valid(w) then
                    out[#out + 1] = w
                    keys[#out] = M.guid_key(id)
                end
            end)
            if not ok then skipped = skipped + 1 end
        end)
    end)
    if not swept then
        return out, "WorkIds sweep threw", keys, skipped
    end

    return out, nil, keys, skipped
end

-- The works this camp currently wants a worker for.
--
-- This is the game's own list, and it is NOT the same as "every work object
-- in the camp". A station has a work object for as long as the station
-- exists, whether or not there is anything to do at it: a cold campfire
-- still has one. Counting those as demand fences pals onto work that does
-- not need them, and they stand idle next to jobs they were barred from.
--
-- Returns nil when the list cannot be read at all, which the caller must
-- treat differently from an empty list.
function M.camp_required_works(camp)
    local director = prop(camp, "WorkerDirector")
    if not valid(director) then return nil end

    local list = prop(director, "RequiredAssignWorks")
    if list == nil then return nil end

    local wpm, manager_asked
    local out, ok, seen = {}, false, 0

    -- An entry may be the work itself, the work's id, or a struct carrying
    -- the id. IsValid() cannot tell them apart, since it answers true for a plain
    -- struct wrapper too, which is how a list of ids was accepted as a list
    -- of works and every one of them came back untyped.
    --
    -- The test is therefore behavioural: a real work answers GetWorkId with
    -- something that reads as a guid. Nothing else does.
    local function resolve(entry)
        local id
        if pcall(function() id = entry:GetWorkId() end) and M.guid_key(id) then
            return entry
        end

        -- Empty lists and direct work objects need no manager at all. The
        -- verified getter is resolved at most once in this synchronous read,
        -- including misses, and its wrapper never survives this call.
        if not manager_asked then
            manager_asked = true
            wpm = M.work_progress_manager()
        end
        if wpm == nil then return nil end

        local w
        pcall(function() w = wpm:GetWork(entry) end)
        if valid(w) then return w end

        pcall(function() w = wpm:GetWork(entry.WorkId) end)
        if valid(w) then return w end

        return nil
    end

    pcall(function()
        list:ForEach(function(_, entry)
            local e = unwrap(entry)
            if e == nil then return end
            seen = seen + 1

            local w = resolve(e)
            if w then out[#out + 1] = w end
        end)
        ok = true
    end)

    if not ok then return nil end
    return out, seen
end

function M.work_id(w)
    local id
    pcall(function() id = w:GetWorkId() end)
    return id
end

function M.work_full_name(w)
    local n
    pcall(function() n = w:GetFullName() end)
    if type(n) == "string" then return n end
    return "<unknown work>"
end

-- Which suitability a work needs.
--
-- PalWorkBase carries no such field: the requirement lives in an
-- assign-define data row the work only references by name. What a work does
-- expose is OverrideWorkType plus some text, and the ORDER these are
-- consulted in matters more than any one of them.
--
-- OverrideWorkType is EPalWorkType, a different enum from
-- EPalWorkSuitability, and it is the job's own declaration of what it is.
-- One class carries several of them: the transport class was observed
-- reporting 7, 11, 16 and 17. Reading the class name first therefore files
-- every pickable-collection job under Transport and hides it from pals set
-- to Collection. On this save that was 26 of 79 works. That OverrideWorkType
-- is EPalWorkType, and that it has to outrank the class name, are both
-- credited to PalPriority (see README).
--
-- Built from a UEnum reflection dump of EPalWorkType on revision 82182. The
-- name on the right of each line is the enum's own name for that value, so
-- these are readable against a fresh dump rather than taken on trust.
--
-- Values are absent where the enum name does not imply a work
-- suitability. An unmapped value falls through to the text sources below and
-- is logged once; a WRONG entry is far worse, because it fences pals onto
-- work that does not need them and away from work that does.
M.WORKTYPE_TO_SUIT = {
    [3]  = "Handcraft",           -- Architecture
    [4]  = "Handcraft",           -- RepairBuildObject
    [5]  = "Collection",          -- FarmHarvest
    [6]  = "Collection",          -- HarvestLevelObject
    [7]  = "Transport",           -- TransportFoodItemInBaseCamp
    [8]  = "Seeding",             -- Seeding
    [9]  = "Watering",            -- Watering
    [10] = "EmitFlame",           -- Cooking
    [11] = "Transport",           -- TransportDisposableItemInBaseCamp
    [12] = "Handcraft",           -- ConvertItem
    [13] = "Handcraft",           -- ProductItem
    [14] = "EmitFlame",           -- Smelting
    [15] = "ProductMedicine",     -- ProductMedicine
    [16] = "Transport",           -- TransportItemInBaseCamp
    [17] = "Collection",          -- CollectResourcePickable
    [18] = "Deforest",            -- ProductResource_Deforest
    [19] = "Mining",              -- ProductResource_Mining
    [20] = "Deforest",            -- ProductResource_Deforest_OnFacility
    [21] = "Mining",              -- ProductResource_Mining_OnFacility
    [22] = "GenerateElectricity", -- GenerateEnergy
    [23] = "EmitFlame",           -- Ignition
    [26] = "MonsterFarm",         -- MonsterFarm
    [28] = "Cool",                -- Cool
    [29] = "Watering",            -- Watering_Farm
    [44] = "Transport",           -- CollectItemToStorage
    [45] = "Transport",           -- TransportItem
    [46] = "Collection",          -- CollectResource

    -- Read from the enum name alone, never yet seen on a live base. If one of
    -- these turns out wrong it will show as pals sent to the wrong station.
    [27] = "Watering",            -- ExtinguishBurn
    [40] = "Handcraft",           -- LabResearch

    -- Left out on purpose: 1 CommonTemp, 2 ReviveCharacter, 24 Defense,
    -- 25 BreedFarm, 30-39 DedicatedWork01-10, 41 FishPond,
    -- 42 AncientBreedFarm, 43 Attack, 47 GrowupPromotion. Either not gated on
    -- work suitability, or not understood well enough to map.
}

-- Stations whose job reports OverrideWorkType = 0 under the generic
-- PalWorkProgress class, where AssignDefineDataId is the only thing that
-- tells a furnace from a bench. Only ids actually observed on a live build
-- belong here.
M.STATION_SUIT = {
    ["CampFire_0"] = "EmitFlame",
    ["BlastFurnace_0"] = "EmitFlame",
}

-- Not work at all. Listed so it reports as skipped instead of padding the
-- unreadable count and looking like a gap in coverage.
M.WORK_IGNORE = {
    ["Idle"] = true,
}

-- The same, keyed by the station id without its _N suffix, for jobs whose
-- display name says nothing. The egg incubator's hatch timer is a work
-- object ("Busy" | HatchingPalEgg_0 | PalWorkProgress, GPortal server
-- 2026-10-29) but no Pal works it: the egg hatches on its own.
M.ASSIGN_IGNORE = {
    ["HatchingPalEgg"] = true,
}

M._unknown_worktype = {}
M._suitability_warned = false

local function work_text(w, kind, name, first_token)
    local raw
    if kind == "func" then
        local ok = pcall(function() raw = w[name](w) end)
        if not ok then return nil end
    else
        raw = prop(w, name)
    end

    local text
    if raw == nil then
        return nil
    elseif type(raw) == "string" then
        text = raw
    else
        pcall(function()
            if raw.ToString then text = raw:ToString() end
        end)
    end

    if type(text) ~= "string" or text == "" or text == "None" then return nil end
    if first_token then text = text:match("^(%S+)") or text end
    return text
end


-- Returns (value, reason). value is the integer suitability, or nil when the
-- work could not be typed. reason is "ignored" for things that are
-- deliberately not work.
function M.work_suitability(w)
    local workdefs = require("workdefs")

    -- 1. The job's own declaration.
    local wt = as_int(prop(w, "OverrideWorkType"))
    if wt and wt ~= 0 then
        local name = M.WORKTYPE_TO_SUIT[wt]
        if name then return workdefs.value(name) end
        if not M._unknown_worktype[wt] then
            M._unknown_worktype[wt] = true
            log.debug("unmapped EPalWorkType " .. tostring(wt) ..
                ". Run '!pwp discover' to dump the enum")
        end
    end

    -- 2. The game's own display name. For several jobs this string IS the
    --    suitability label, and it is right in exactly the cases where the
    --    class name misleads.
    local work_name = work_text(w, "func", "GetWorkName")
    if work_name then
        if M.WORK_IGNORE[work_name] then return nil, "ignored" end
        local labelled = workdefs.from_label(work_name)
        if labelled then return workdefs.value(labelled) end
    end

    -- 3. Station identity, for the generic PalWorkProgress objects.
    local assign = work_text(w, "prop", "AssignDefineDataId")
    if assign then
        if M.ASSIGN_IGNORE[assign:match("^(.-)_%d+$") or assign] then return nil, "ignored" end
        local mapped = M.STATION_SUIT[assign]
        if mapped then return workdefs.value(mapped) end
        local kw = workdefs.from_text(assign)
        if kw then return workdefs.value(kw) end
    end

    -- 4. Class name last, because one class serves several work types.
    local cls = work_text(w, "func", "GetFullName", true)
    local kw = cls and workdefs.from_text(cls) or nil
    if kw then return workdefs.value(kw) end

    -- Named, because a host saw this at every join with nothing to go on
    -- (review 2026-10-29). The likely one is Construction (BuildWork_0,
    -- PalWorkProgress, untyped while a blueprint stands: g4-old-reports
    -- 2026-10-27), but no discover dump has confirmed it, so it is not put
    -- in WORK_IGNORE: whether Pals' building is gated by a suitability is
    -- not known.
    if not M._suitability_warned then
        M._suitability_warned = true
        local seen = {}
        if work_name then seen[#seen + 1] = work_name end
        if assign then seen[#seen + 1] = assign end
        if cls then seen[#seen + 1] = cls end
        log.warn("some work could not be typed and is not counted: " ..
            (#seen > 0 and table.concat(seen, ", ") or "no readable name") ..
            ". The game still assigns it as usual; a building not finished yet " ..
            "is one known case. '!pwp discover' lists every untyped work")
    end
    return nil
end



-- The work types this pal currently has switched OFF, as a set. This is the
-- game's own record and the only ground truth for what a pal is allowed to
-- do, so the fencer diffs against it rather than against what it believes it
-- set last time. Returns nil when it cannot be read at all, which is
-- different from "nothing is off" and must not be treated as an empty set.
function M.work_off_set(param)
    if not valid(param) then return nil end

    local out, ok = {}, false
    pcall(function()
        local list = param.SaveParameter.WorkSuitabilityOptionInfo.OffWorkSuitabilityList
        if list == nil then return end
        list:ForEach(function(_, entry)
            local v = as_int(unwrap(entry))
            if type(v) ~= "number" or math.tointeger(v) == nil or v < 0 or v > 255 then
                error("unreadable off-list entry")
            end
            out[v] = true
        end)
        ok = true
    end)

    if not ok then return nil end
    return out
end

-- Turns one work type on or off for one pal, which is what the vanilla
-- checkbox does. This is the game's OWN permission flag, and it is the only
-- thing that actually stops the AI handing a pal that job. Declining
-- to fixed-assign them ourselves does nothing about it.
--
-- raw_id carries the unmasked guid ints straight from GetIndividualID; the
-- hex key used everywhere else is lossy for this purpose.
-- comp: the network component, resolved by the caller for this pass.
--
-- This used to call M.network_component() itself, which is an uncached
-- FindFirstOf measured at 9ms - once per toggle. A 40-toggle pass spent well
-- over a third of a second re-answering one question, and every "pwp mode",
-- "cap", "limit" and "scope" command forces a pass, so it landed on a
-- keypress. The component is the same for every toggle in a pass, and one
-- synchronous pass is one call, which is the age at which an engine object is
-- safe to hold.
--
-- Still resolved here when the caller passes nothing, so single callers and
-- the console commands keep working.
function M.set_work_enabled(raw_id, work_value, on, comp)
    if raw_id == nil or type(work_value) ~= "number" then return false end

    -- Owned first. An unowned component is not a slower path for a server
    -- RPC, it is a silent no-op, which is exactly what made every toggle
    -- repeat forever.
    if comp == nil then
        comp = M.owned_network_component()
        -- Same authority-only fallback as net.to_server. A missing owned
        -- route on a client is not permission to use a world transmitter.
        if comp == nil and M.has_authority() == true then comp = M.network_component() end
    end
    if not valid(comp) then return false, "PalNetworkBaseCampComponent unavailable" end

    local ok, err = pcall(function()
        comp:RequestChangeWorkSuitability_ToServer(
            { PlayerUId = raw_id.PlayerUId, InstanceId = raw_id.InstanceId, DebugName = "" },
            work_value, on and true or false)
    end)
    if not ok then return false, tostring(err) end
    return true
end

-- On a multiplayer client the camp's work data is not replicated until it is
-- asked for. Harmless on a host.
function M.request_work_replication(camp_id, on, owned_comp)
    -- The owned one, like every other RequestX_ToServer on this component.
    --
    -- This was the last call still going through FindFirstOf, which picks by
    -- engine order and flips after a server restart: half the time it returns
    -- the game state's transmitter instead of the player's, and a client to
    -- server RPC on that one is dropped in silence with sent_up still
    -- counting it. That single mistake caused both the rule transport bug and
    -- the toggle churn; this is the same mistake, latent because the branch
    -- only runs under run_pass and run_pass is authority gated.
    local comp = owned_comp
    if comp == nil then
        comp = M.owned_network_component()
        if comp == nil and M.has_authority() == true then comp = M.network_component() end
    end
    if not valid(comp) then return false end
    local ok = pcall(function()
        comp:RequestReplicateBaseCampWork_ToServer(camp_id, on and true or false)
    end)
    return ok
end

-- ---------------------------------------------------------------------------
-- Base storage
-- ---------------------------------------------------------------------------

-- Base storage for a resource ceiling is every container on the base, minus
-- the few below.
--
-- This was a list of classes to include and that was the wrong way round.
-- Palworld has far more station types than any list written by hand will
-- name, and each one missing is a ceiling quietly overshooting by whatever
-- that station is holding. Counting everything and naming the exceptions
-- means a station type nobody here has ever seen still counts.
--
-- Everything derives from this, chests and stations alike.
M.CONTAINER_BASE_CLASS = "PalMapObjectConcreteModelBase"

-- The fallback when config names nothing, which is NOT what ships: config.lua
-- sets uncounted_containers to an empty table, so everything on the base
-- counts. Kept here because a config that fails to load should still leave
-- the mod with a defensible answer, and because these three are the classes
-- anyone excluding something is most likely to want.
M.DEFAULT_UNCOUNTED = {
    "PalMapObjectPalFoodBoxModel",
    "PalMapObjectDropItemModel",
    "PalMapObjectPickupItemOnLevelModel",
}

-- Totals the items in every chest `accept` says yes to: { [StaticId] = n }.
--
-- Every hop here is a replicated property read rather than an out-param
-- UFunction call, which is why this also answers on a dedicated-server
-- client. GetBaseCampIdBelongTo, used by the camp-scoped caller below, is
-- the exception and is a UFunction on concrete models.
--
-- The second return value is how many chests actually answered, so a caller
-- can tell "no wood" apart from "read nothing".
-- GetFullName leads with the class, which is how work classes are read
-- elsewhere in this file.
function M.model_class(m)
    local cls
    pcall(function()
        local full = m:GetFullName()
        if type(full) == "string" then cls = full:match("^(%S+)") end
    end)
    return cls or "<unknown>"
end

-- opts.include, when given, is a list of class names to count and nothing
-- else. Otherwise every container is counted except the names in
-- opts.exclude. One scan of the base class covers both, since every chest and
-- station derives from it.
-- One walk, many buckets.
--
-- keyfor(m) is asked once per item-holding container and answers the bucket
-- its contents belong in, or nil to skip it. The camp-scoped sweep used to
-- run this walk once PER CAMP with a boolean filter, which under the shipped
-- camp scope meant two full FindAllOf sweeps back to back on every pass whose
-- cache had expired - identical walks, different filter. Bucketing by the
-- camp id read the sweep was already paying for makes the second walk free.
--
-- The slot-reading loop is preserved exactly as it was, crash comments and
-- all; only where the numbers land has changed.
local function walk_containers(opts, keyfor, reader)
    opts = opts or {}
    local buckets, counts, seen = {}, {}, {}
    local evidence = {complete=true, deduplicated=true, unknown_scope=0, failed_reads=0, reasons={}, outside_camp_loot=0}
    local class_reads, class_skips = 0, 0
    local traversal_token
    local function failed(reason)
        evidence.complete=false
        evidence.failed_reads=evidence.failed_reads+1
        evidence.reasons[reason]=(evidence.reasons[reason] or 0)+1
    end
    local function finish()
        if traversal_token and log.finish then log.finish(traversal_token) end
        -- Fixed reason labels and scalar counts only. No error strings, object
        -- identities or wrappers survive the scan; status never repeats it.
        local reasons={}
        for reason,n in pairs(evidence.reasons) do reasons[reason]=n end
        M.last_storage_scan={reader=reader, complete=evidence.complete,
            deduplicated=evidence.deduplicated, unknown_scope=evidence.unknown_scope,
            failed_reads=evidence.failed_reads, reasons=reasons,
            outside_camp_loot=evidence.outside_camp_loot,
            class_reads=class_reads, class_skips=class_skips}
        return buckets,counts,evidence
    end
    local include, exclude = nil, {}
    if opts.include then include={}; for _,cls in ipairs(opts.include) do include[cls]=true end end
    for _,cls in ipairs(opts.exclude or M.DEFAULT_UNCOUNTED) do exclude[cls]=true end
    local filtered = include ~= nil or next(exclude) ~= nil
    local enumeration_token=log.begin and log.begin("storage: model enumeration")
    local ok, all = pcall(FindAllOf,M.CONTAINER_BASE_CLASS)
    if enumeration_token and log.finish then log.finish(enumeration_token) end
    if not ok or type(all) ~= "table" then failed("enumeration"); return finish() end
    traversal_token=log.begin and log.begin("storage: container traversal")
    for _,model in ipairs(all) do
        local stage="model_validity"
        local read_ok = pcall(function()
            local cls
            local function class_for()
                if cls == nil then class_reads=class_reads+1; cls=M.model_class(model) end
                return cls
            end
            if not valid(model) then failed(stage); return end
            stage="container_module"
            local module = model:GetItemContainerModule()
            if not valid(module) then return end -- scenery has no container module
            -- A configured class filter must be checked before scope: an
            -- excluded zero-GUID holder is intentionally outside that query.
            -- With no filter, only the known no-base loot exception needs a
            -- class name before counting. Reuse it rather than reading twice.
            -- Discover the module first: scenery is not unknown storage.
            if filtered then
                stage="model_class"
                local name = class_for()
                if name == "<unknown>" then failed(stage); return end
                if (include and not include[name]) or (not include and exclude[name]) then return end
            end
            stage="scope"
            local bucket, why = keyfor(model, class_for)
            if bucket == nil then
                if cls == nil then class_skips=class_skips+1 end
                if why == "outside_camp_loot" then
                    evidence.outside_camp_loot=evidence.outside_camp_loot+1
                elseif why ~= "excluded" then evidence.unknown_scope=evidence.unknown_scope+1; failed(why or stage) end
                return
            end
            if not filtered then
                -- Preserve the existing class-read failure contract for
                -- containers whose contents will actually be counted.
                stage="model_class"
                if class_for() == "<unknown>" then failed(stage); return end
            end
            stage="target_container"
            local container=module.TargetContainer
            if not valid(container) then failed(stage); return end
            stage="container_identity"
            local identity=container:GetFullName()
            if type(identity) ~= "string" or identity=="" then failed(stage); return end
            if seen[identity] then
                if seen[identity] ~= bucket then
                    evidence.unknown_scope=evidence.unknown_scope+1
                    evidence.deduplicated=false
                    failed("duplicate_scope")
                end
                return
            end
            seen[identity]=bucket
            stage="slot_array"
            local slots=container.ItemSlotArray
            if slots==nil then failed(stage); return end
            stage="slot_count"
            local n=#slots
            if type(n) ~= "number" or n<0 then failed(stage); return end
            local total={}
            for i=1,n do
                local slot_stage="slots_changed"
                local slot_ok=pcall(function()
                    if i>#slots then error("container changed while reading") end
                    slot_stage="slot_read"
                    local slot=slots[i]
                    if slot==nil then error("slot unavailable") end
                    slot_stage="slot_validity"
                    local asked, live=pcall(function() return slot:IsValid() end)
                    if asked and live==false then error("slot no longer live") end
                    slot_stage="item_identity"
                    local id=slot.ItemId.StaticId:ToString()
                    if type(id) ~= "string" then error("item identity unavailable") end
                    if id~="None" and id~="" then
                        slot_stage="quantity"
                        local amount=tonumber(slot.StackCount)
                        if not amount or amount~=amount or amount<0 or amount==math.huge then error("quantity unavailable") end
                        total[id]=(total[id] or 0)+amount
                    end
                end)
                if not slot_ok then failed(slot_stage) end
            end
            stage="slots_changed"
            if #slots~=n then failed(stage) end
            stage="aggregation"
            buckets[bucket]=buckets[bucket] or {}
            for id,amount in pairs(total) do buckets[bucket][id]=(buckets[bucket][id] or 0)+amount end
            counts[bucket]=(counts[bucket] or 0)+1
        end)
        if not read_ok then failed(stage) end
    end
    return finish()
end

-- The single-bucket shape every existing caller was written against.
local function walk_chests(opts, accept, reader)
    local buckets, counts, evidence = walk_containers(opts, function(m, class_for)
        local accepted, why = accept(m, class_for)
        if accepted == true then return "only" end
        if accepted == false then return nil, "excluded" end
        return nil, why
    end, reader)
    return buckets.only or {}, counts.only or 0, evidence
end

-- Only the chests belonging to one camp.
--
-- A chest whose camp id will not read is skipped rather than counted:
-- crediting someone else's chest to this base would silently inflate the
-- total and suspend work that should still be running.
-- Exact world-loot types observed in the September 13 census. A successful
-- numeric zero base ID means these pickups have no base for this sample.
-- This is a scope rule, NOT a storage allowlist: owned pickups still count;
-- unrecognized types, storage/stations, failed or malformed IDs stay unknown.
-- In particular a guild chest with a zero base ID needs its own verified route.
local NO_BASE_WORLD_LOOT = {
    PalMapObjectTreasureBoxModel=true,
    BP_MapObjectTreasureBoxModel_C=true,
    PalMapObjectPickupItemOnLevelModel=true,
    PalMapObjectPalEggModel=true,
    -- Aged-session census: dropped piles also exist without a base. Recheck
    -- their current ID every scan; the same class carries legitimate base stock.
    PalMapObjectDropItemModel=true,
}
local function container_camp_key(model, class_for)
    local ok, guid = pcall(function() return model:GetBaseCampIdBelongTo() end)
    if not ok then return nil, "scope_call" end
    local id, why = read_guid(guid)
    -- Never infer absence from a client's possibly pending replication.
    -- The scheduler confirms authority before storage; reset clears auth.
    if why == "scope_zero_guid" and auth == true then
        local cls = class_for and class_for() or M.model_class(model)
        if NO_BASE_WORLD_LOOT[cls] then return nil, "outside_camp_loot" end
    end
    return id, why
end

function M.camp_item_totals(camp_key, opts)
    if not camp_key then return {}, 0, {complete=false,deduplicated=false,unknown_scope=1} end

    return walk_chests(opts, function(m, class_for)
        local cid, why = container_camp_key(m, class_for)
        if cid == nil then return nil, why end
        return cid == camp_key
    end, "camp")
end

-- Every camp's chests in ONE walk, keyed by camp id.
--
-- Returns (totals_by_camp, chests_by_camp), both keyed by guid_key strings.
-- A container whose camp id will not read is skipped, same as the per-camp
-- filter always did: crediting an unowned chest to some base would silently
-- inflate its totals and suspend work that should still be running.
function M.chest_totals_by_camp(opts)
    return walk_containers(opts, container_camp_key, "by_camp")
end

-- Every chest that answers, whatever camp owns it.
--
-- The counterpart to camp_item_totals for storage_scope = "global". It can
-- only ever cover bases currently streamed in: an unloaded camp has no chest
-- objects in memory at all, so there is nothing there to add up.
function M.all_chest_totals(opts)
    return walk_chests(opts, function() return true end, "all")
end

-- Every camp-owned map object holding items, whatever its class.
--
-- Diagnostic only. Shows the contents of camp-owned holders, including those
-- omitted by configured class filters, without guessing a station allowlist.
--
-- Returns a list of { class = string, items = { [StaticId] = count } }.
function M.camp_containers(camp_key)
    local found = {}
    if not camp_key then return found end

    pcall(function()
        -- The concrete-model base rather than the two chest classes, so
        -- anything derived from it turns up: logging sites, mining sites,
        -- feed boxes, breeding pens.
        for _, m in ipairs(FindAllOf(M.CONTAINER_BASE_CLASS) or {}) do
            pcall(function()
                if not valid(m) then return end

                local cid
                pcall(function() cid = M.guid_key(m:GetBaseCampIdBelongTo()) end)
                if cid ~= camp_key then return end

                local module
                pcall(function() module = m:GetItemContainerModule() end)
                if not valid(module) then return end

                local container = prop(module, "TargetContainer")
                if not valid(container) then return end

                local slots = prop(container, "ItemSlotArray")
                if slots == nil then return end

                local items, n, total = {}, 0, 0
                pcall(function() n = #slots end)
                for i = 1, n do
                    pcall(function()
                        local slot = slots[i]
                        local sid = slot.ItemId.StaticId:ToString()
                        if sid and sid ~= "None" then
                            local count = tonumber(slot.StackCount) or 0
                            items[sid] = (items[sid] or 0) + count
                            total = total + count
                        end
                    end)
                end

                -- Empty containers say nothing useful and there are a lot of
                -- them on a built-up base.
                if total == 0 then return end

                found[#found + 1] = { class = M.model_class(m), items = items }
            end)
        end
    end)

    return found
end

return M
