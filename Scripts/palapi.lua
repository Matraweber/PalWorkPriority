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
function M.guid_key(g)
    if g == nil then return nil end

    local parts = {}
    local ok = pcall(function()
        for _, field in ipairs({ "A", "B", "C", "D" }) do
            local n = as_int(g[field])
            if n == nil then return end
            parts[#parts + 1] = tostring(n)
        end
    end)

    if ok and #parts == 4 then
        local key = table.concat(parts, "-")
        -- an all-zero guid is a replication placeholder, not an identity
        if key:gsub("[0%-]", "") == "" then return nil end
        return key
    end
    return nil
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
    cdo_cache = {}
    M._suitability_source = nil
    M._unknown_worktype = {}
    M._suitability_warned = false
end

function M.cdo(path)
    local hit = cdo_cache[path]
    if valid(hit) then return hit end
    local obj
    pcall(function() obj = StaticFindObject(path) end)
    if valid(obj) then
        cdo_cache[path] = obj
        return obj
    end
    return nil
end

function M.player_controller()
    local pc
    pcall(function() pc = FindFirstOf("PalPlayerController") end)
    if valid(pc) then return pc end
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

function M.base_camps()
    local camps = {}
    pcall(function()
        for _, c in ipairs(FindAllOf("PalBaseCampModel") or {}) do
            if valid(c) then camps[#camps + 1] = c end
        end
    end)
    return camps
end

function M.camp_id(camp)
    local id
    pcall(function() id = camp:GetId() end)
    return id
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

function M.pal_species(param)
    return name_text(param, "GetCharacterID")
end

function M.pal_name(param)
    return name_text(param, "GetNickname")
        or M.pal_species(param)
        or "<unnamed>"
end

-- Returns a list of { id, param, name, species, slot_index }.
-- slot_index is the claim key for a pass: unique per camp and, unlike an
-- FGuid, usable directly as a Lua table key.
function M.camp_pals(camp)
    local out = {}

    local director = prop(camp, "WorkerDirector")
    if not valid(director) then
        return out, "camp has no readable WorkerDirector"
    end

    local raw = {}
    local ok = pcall(function() director:GetCharacterHandleSlots(raw) end)
    if not ok then
        return out, "GetCharacterHandleSlots threw"
    end

    for i = 1, #raw do
        local slot = unwrap(raw[i])
        if valid(slot) then
            local empty = true
            pcall(function() empty = slot:IsEmpty() end)

            if not empty then
                local handle = unwrap(prop(slot, "Handle"))
                local id, param

                if valid(handle) then
                    pcall(function() id = handle:GetIndividualID() end)
                    if id == nil then id = prop(handle, "ID") end
                    pcall(function() param = handle:TryGetIndividualParameter() end)
                end

                if id == nil then id = prop(slot, "ReplicateHandleID") end
                if not valid(param) then param = prop(slot, "ReplicateIndividualParameter") end

                if id ~= nil and valid(param) then
                    out[#out + 1] = {
                        id = id,
                        param = param,
                        name = M.pal_name(param),
                        species = M.pal_species(param),
                        slot_index = i,
                        -- Identity that survives the roster being reordered,
                        -- and that the stand UI can rebuild from a row's own
                        -- GetIndividualID. The fallbacks only stand in when
                        -- the guids will not read; a pal on one of them still
                        -- schedules correctly, it just cannot be matched to a
                        -- row, so its cell shows the priority without the
                        -- green assigned marker.
                        key = M.instance_key(id) or M.guid_key(id) or ("slot" .. i),
                    }
                end
            end
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

    if type(rank) ~= "number" then return 0 end
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

function M.work_progress_manager()
    local util = M.cdo("/Script/Pal.Default__PalUtility")
    local pc = M.player_controller()
    if not (util and pc) then return nil end

    local wpm
    pcall(function() wpm = util:GetWorkProgressManager(pc) end)
    if valid(wpm) then return wpm end
    return nil
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

    local swept = pcall(function()
        ids:ForEach(function(_, entry)
            pcall(function()
                local w = wpm:GetWork(unwrap(entry))
                if valid(w) then out[#out + 1] = w end
            end)
        end)
    end)
    if not swept then
        return out, "WorkIds sweep threw"
    end

    return out, nil
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

    local wpm = M.work_progress_manager()
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

M.work_text = work_text

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
        local mapped = M.STATION_SUIT[assign]
        if mapped then return workdefs.value(mapped) end
        local kw = workdefs.from_text(assign)
        if kw then return workdefs.value(kw) end
    end

    -- 4. Class name last, because one class serves several work types.
    local cls = work_text(w, "func", "GetFullName", true)
    local kw = cls and workdefs.from_text(cls) or nil
    if kw then return workdefs.value(kw) end

    if not M._suitability_warned then
        M._suitability_warned = true
        log.warn("some work could not be typed. Run '!pwp discover' and read " ..
            "the UNRESOLVED list")
    end
    return nil
end


-- ---------------------------------------------------------------------------
-- Acting on the world
-- ---------------------------------------------------------------------------

function M.assign(camp_id, work_id, individual_id)
    local comp = M.network_component()
    if not valid(comp) then
        return false, "PalNetworkBaseCampComponent unavailable"
    end

    local ok, err = pcall(function()
        comp:RequestFixedAssignWorkInBaseCamp_ToServer(camp_id, work_id, individual_id)
    end)
    if not ok then return false, tostring(err) end
    return true, nil
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
            if v then out[v] = true end
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
function M.set_work_enabled(raw_id, work_value, on)
    if raw_id == nil or type(work_value) ~= "number" then return false end

    local comp = M.network_component()
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
function M.request_work_replication(camp_id, on)
    local comp = M.network_component()
    if not valid(comp) then return false end
    local ok = pcall(function()
        comp:RequestReplicateBaseCampWork_ToServer(camp_id, on and true or false)
    end)
    return ok
end

-- ---------------------------------------------------------------------------
-- Base storage
-- ---------------------------------------------------------------------------

-- What counts as base storage for a resource ceiling. A class that does not
-- resolve on a build is normal; the list is wider than any one version needs.
--
-- Production stations are in the default set alongside chests. A logging site
-- holding 297 wood is wood the base has, and leaving it out makes a ceiling
-- overshoot by whatever every station happens to be sitting on.
--
-- Deliberately NOT here by default, though config can add them:
--   PalMapObjectPalFoodBoxModel         food set aside for pals to eat
--   PalMapObjectConvertItemModel        mid conversion, inputs and outputs mixed
--   PalMapObjectDropItemModel           dropped on the ground
--   PalMapObjectPickupItemOnLevelModel  lying about waiting to be collected
M.DEFAULT_COUNTED = {
    "PalMapObjectItemChestModel",
    "PalMapObjectGuildChestModel",
    "PalMapObjectProductItemModel",
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
local function walk_chests(classes, accept)
    local totals, chests = {}, 0

    for _, cls in ipairs(classes or M.DEFAULT_COUNTED) do
        pcall(function()
            for _, m in ipairs(FindAllOf(cls) or {}) do
                pcall(function()
                    if not valid(m) then return end
                    if not accept(m) then return end

                    local module
                    pcall(function() module = m:GetItemContainerModule() end)
                    if not valid(module) then return end

                    local container = prop(module, "TargetContainer")
                    if not valid(container) then return end

                    local slots = prop(container, "ItemSlotArray")
                    if slots == nil then return end

                    chests = chests + 1

                    local n = 0
                    pcall(function() n = #slots end)
                    for i = 1, n do
                        pcall(function()
                            local slot = slots[i]
                            local sid = slot.ItemId.StaticId:ToString()
                            if sid and sid ~= "None" then
                                totals[sid] = (totals[sid] or 0)
                                    + (tonumber(slot.StackCount) or 0)
                            end
                        end)
                    end
                end)
            end
        end)
    end

    return totals, chests
end

-- Only the chests belonging to one camp.
--
-- A chest whose camp id will not read is skipped rather than counted:
-- crediting someone else's chest to this base would silently inflate the
-- total and suspend work that should still be running.
function M.camp_item_totals(camp_key, classes)
    if not camp_key then return {}, 0 end

    return walk_chests(classes, function(m)
        local cid
        pcall(function() cid = M.guid_key(m:GetBaseCampIdBelongTo()) end)
        return cid == camp_key
    end)
end

-- Every chest that answers, whatever camp owns it.
--
-- The counterpart to camp_item_totals for storage_scope = "global". It can
-- only ever cover bases currently streamed in: an unloaded camp has no chest
-- objects in memory at all, so there is nothing there to add up.
function M.all_chest_totals(classes)
    return walk_chests(classes, function() return true end)
end

-- Every camp-owned map object holding items, whatever its class.
--
-- Diagnostic only. camp_item_totals above counts chests and nothing else, so
-- a resource sitting in some other container is invisible to a ceiling. This
-- is how to find out what those other containers actually are on a live base
-- instead of guessing at the class list.
--
-- Returns a list of { class = string, items = { [StaticId] = count } }.
function M.camp_containers(camp_key)
    local found = {}
    if not camp_key then return found end

    pcall(function()
        -- The concrete-model base rather than the two chest classes, so
        -- anything derived from it turns up: logging sites, mining sites,
        -- feed boxes, breeding pens.
        for _, m in ipairs(FindAllOf("PalMapObjectConcreteModelBase") or {}) do
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

                -- GetFullName leads with the class, which is how work classes
                -- are read elsewhere in this file.
                local cls = "<unknown>"
                pcall(function()
                    local full = m:GetFullName()
                    if type(full) == "string" then cls = full:match("^(%S+)") or full end
                end)

                found[#found + 1] = { class = cls, items = items }
            end)
        end
    end)

    return found
end

return M
