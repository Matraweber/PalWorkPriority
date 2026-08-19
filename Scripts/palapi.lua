-- Every call into Palworld's own objects lives in this file.
--
-- The rest of the mod talks in plain Lua tables. When a game update renames
-- something, this is the only file that needs touching.
--
-- Symbol provenance — all of these are taken from mods that run on game
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
-- carrying out — re-assigning every cycle would make workers drop their job
-- and re-path constantly. Returns nil when the guid cannot be read, and the
-- caller falls back to the work's full name.
function M.guid_key(g)
    if g == nil then return nil end
    local parts = {}
    local ok = pcall(function()
        for _, field in ipairs({ "A", "B", "C", "D" }) do
            parts[#parts + 1] = tostring(g[field])
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
                        -- Identity that survives the roster being reordered.
                        -- Slot position only stands in when the guid will
                        -- not read.
                        key = M.guid_key(id) or ("slot" .. i),
                    }
                end
            end
        end
    end

    return out, nil
end

function M.suitability_rank(param, value)
    if type(value) ~= "number" then return 0 end
    local rank = 0
    pcall(function() rank = param:GetWorkSuitabilityRank(value) end)
    if type(rank) ~= "number" then return 0 end
    return rank
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
-- PalWorkBase carries no such field. The live schema on revision 82182 has
-- AssignDefineDataId, OverrideWorkType and GetWorkName, and the requirement
-- is not stored on the work object at all — it lives in an assign-define
-- data row the work only references by name.
--
-- What the work does expose is text that names the job:
-- PalWorkDeforestFoliage, PalWorkTransportItemInBaseCamp. So the type is
-- read out of that text, trying the most specific source first.
--
-- A warning about probing by property name: UE4SS returns a live-looking
-- TrivialObject for ANY property name, including ones that do not exist. A
-- non-nil read proves nothing, which is exactly how the first four
-- candidates all appeared to answer while meaning nothing. Only text that
-- resolves to a known work type is accepted here.
-- first_token trims a full object name down to its leading class token
-- before matching. GetFullName returns the whole path, and a map or level
-- name that happens to contain "cool" or "farm" would otherwise classify a
-- work by its address rather than its job.
M.SUITABILITY_SOURCES = {
    { kind = "prop", name = "AssignDefineDataId" },
    { kind = "func", name = "GetWorkName" },
    { kind = "func", name = "GetFullName", first_token = true },
}

M._suitability_source = nil
M._suitability_warned = false

local function source_text(w, source)
    local raw
    if source.kind == "func" then
        local ok = pcall(function() raw = w[source.name](w) end)
        if not ok then return nil end
    else
        raw = prop(w, source.name)
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
    if source.first_token then text = text:match("^(%S+)") or text end
    return text
end

-- Returns the integer suitability this work needs, or nil when the work
-- cannot be classified. Warns once per session rather than once per work.
function M.work_suitability(w)
    local workdefs = require("workdefs")

    -- OverrideWorkType wins when it is set to something meaningful: it is an
    -- explicit statement on the work, where the text below is inference.
    -- Validated against the known range, because a bogus enum read would
    -- otherwise file the work under whatever integer happened to come back.
    local override = as_int(prop(w, "OverrideWorkType"))
    if override and workdefs.name(override) then
        return override
    end

    local ordered = M.SUITABILITY_SOURCES
    if M._suitability_source then
        ordered = { M._suitability_source }
    end

    for _, source in ipairs(ordered) do
        local text = source_text(w, source)
        local name = text and workdefs.from_text(text) or nil
        if name then
            if M._suitability_source == nil then
                M._suitability_source = source
                log.info(string.format("reading work type from %s '%s'",
                    source.kind, source.name))
            end
            return workdefs.value(name)
        end
    end

    -- The cached source failed on this particular work. Fall back to the
    -- full list for it rather than reporting it unreadable, since works of
    -- different classes do not all name themselves the same way.
    if M._suitability_source then
        for _, source in ipairs(M.SUITABILITY_SOURCES) do
            local text = source_text(w, source)
            local name = text and workdefs.from_text(text) or nil
            if name then return workdefs.value(name) end
        end
    end

    if not M._suitability_warned then
        M._suitability_warned = true
        log.warn("could not read a work type from any source on this build — " ..
            "run '!pwp discover' and check the live work probes section")
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

-- Chest concrete-model classes. A class that does not resolve on a build is
-- normal; the list is deliberately wider than any one version needs.
M.CHEST_CLASSES = {
    "PalMapObjectItemChestModel",
    "PalMapObjectGuildChestModel",
}

-- Totals every item held in one camp's chests: { [StaticId] = count }.
--
-- Every hop here is a replicated property read rather than an out-param
-- UFunction call, which is why this also answers on a dedicated-server
-- client. GetBaseCampIdBelongTo is the exception and is a UFunction on
-- concrete models.
--
-- A chest whose camp id will not read is skipped rather than counted:
-- crediting someone else's chest to this base would silently inflate the
-- total and suspend work that should still be running. The second return
-- value is how many chests actually answered, so a caller can tell "no
-- wood" apart from "read nothing".
function M.camp_item_totals(camp_key)
    local totals, chests = {}, 0
    if not camp_key then return totals, 0 end

    for _, cls in ipairs(M.CHEST_CLASSES) do
        pcall(function()
            for _, m in ipairs(FindAllOf(cls) or {}) do
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

return M
