-- Which continuous stations in a camp need a worker right now.
--
-- The game never announces generator work (OnRequiredAssignWork fired 0 times
-- for Generating Electricity in a whole session, 2026-10-14), so the pulse
-- index cannot see an empty generator, and a Pal with Electricity 1 kept
-- building something else while a finished generator sat at 0 %. Verified
-- live against the in-game Power Capacity readout (docs/g4-scheduling-
-- 2026-10-14-stations.md): a generator needs a worker exactly when its build
-- is Completed and StoredEnergyAmount < MaxEnergyStorage.
--
-- Reads, per GenerateElectricity work in the camp, all obtained in this call:
--   work.CachedOwnerMapObjectConcreteModel  (property) -> generator model
--     .StoredEnergyAmount / .MaxEnergyStorage (properties)
--   model:GetOuter() -> map object manager (UE4SS native, seen live)
--   manager:FindModel(work.OwnerMapObjectModelId) (BlueprintPure UFUNCTION,
--     same call shape as palapi's GetWork(id)) -> .BuildProcess.State
--     (0 Building, 1 Completed)
-- Coolers (Cooler Box, Refrigerator) are the same kind of silent station but
-- have no energy store. The game marks their Cooling work Workable only while
-- spoilable food is inside (UPalMapObjectFunctionAffectItemCorruptionBy-
-- WorkStatus.bWorkableOnlyExistsCorruptibleItem). Verified live 2026-10-16 on
-- a Cooler Box: 1656 berries Workable, emptied NotWorkable within 13 s, food
-- back Workable within 13 s, under construction NotWorkable. So a cooler
-- needs a worker when its build is Completed and work.CurrentState is 1.
-- (CurrentState alone is not enough for generators: Workable while a
-- blueprint, seen 2026-10-14.)
-- Resource nodes (trees for Lumbering, rocks and the stone pit for Mining)
-- are silent too: in three days of play on 2026-10-14..16 the game announced
-- them only once each at world load, so Mining and Lumbering never reached
-- the demand index and no Pal mined or chopped while the mod ran (0 of 42
-- samples, even with Mining 1). With the mod off the same base had 1-3
-- miners and 2-5 lumberjacks per sample. Rechecked 2026-10-17 with the
-- limits lifted: announcements stayed at 2 (rocks) and 48 (trees, all at
-- load) while Pals mined and chopped for minutes, so the game never asks
-- again. A node needs a worker while its work.CurrentState is Workable; one
-- that belongs to a building (rocks, the stone pit) must also be built.
-- Ranches are silent as well (0 announcements for the ranch in a session on
-- 2026-10-27, its work Workable the whole time), so Farming never reached the
-- demand index: a Lamball with no other job was fenced to Transporting and
-- the ranch stood empty. A ranch needs a worker while it is built and its
-- work is Workable. One seat per ranch, the rule the other stations use: the
-- ranch's real capacity is not read anywhere (guides say four Pals, one says
-- five), and unknown must not become demand.
-- Fishing ponds and research labs are silent too (2026-10-27): Handiwork was
-- wanted twice at world load (one pond, one lab) and never again in three
-- minutes, while the pond's Pal came and went. Both need a worker while built
-- and Workable (a pond is Workable only with bait and a fish target set, a
-- lab only while a research runs). They are picked out by class, not by type:
-- a workbench is Handiwork work too, but it does announce its orders. Only
-- Handiwork research was seen live; labs researching other subjects are not
-- counted yet.
-- Nothing is stored. Any failed or odd read means "does not need a worker":
-- unknown must never become demand (a full or unbuilt generator counted as a
-- vacancy would park Pals beside it). Authority only; callers run on it.
local api = require('palapi')
local workdefs = require('workdefs')

local M = {}

M.GENERATOR = workdefs.value('GenerateElectricity')
M.COOLER = workdefs.value('Cool')
M.WORKABLE = 1 -- EPalWorkProgressState.Workable
M.FULL_MARGIN = 1.0 -- stored within this of max counts as full

local function completed(work, model)
    local ok, manager = pcall(function() return model:GetOuter() end)
    if not ok or manager == nil or not api.valid(manager) then return false end
    local id = api.prop(work, 'OwnerMapObjectModelId')
    if id == nil then return false end
    local found, owner = pcall(function() return manager:FindModel(id) end)
    owner = found and api.unwrap(owner) or nil
    if owner == nil or not api.valid(owner) then return false end
    local bp = api.unwrap(api.prop(owner, 'BuildProcess'))
    if bp == nil or not api.valid(bp) then return false end
    return api.as_int(api.prop(bp, 'State')) == 1
end

-- Number of generators in `works` that are built and not full.
function M.generators_needing(works)
    local n = 0
    for _, w in ipairs(works or {}) do
        if api.work_suitability(w) == M.GENERATOR then
            local model = api.unwrap(api.prop(w, 'CachedOwnerMapObjectConcreteModel'))
            if model ~= nil and api.valid(model) then
                local stored = api.prop(model, 'StoredEnergyAmount')
                local max = api.prop(model, 'MaxEnergyStorage')
                if type(stored) == 'number' and type(max) == 'number' and max > 0
                    and stored < max - M.FULL_MARGIN and completed(w, model) then
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- Number of coolers in `works` that are built and hold spoilable food.
function M.coolers_needing(works)
    local n = 0
    for _, w in ipairs(works or {}) do
        if api.work_suitability(w) == M.COOLER
            and api.as_int(api.prop(w, 'CurrentState')) == M.WORKABLE then
            local model = api.unwrap(api.prop(w, 'CachedOwnerMapObjectConcreteModel'))
            if model ~= nil and api.valid(model) and completed(w, model) then
                n = n + 1
            end
        end
    end
    return n
end

M.RANCH = workdefs.value('MonsterFarm')

-- Number of ranches in `works` that are built and Workable. One seat each.
function M.ranches_needing(works)
    local n = 0
    for _, w in ipairs(works or {}) do
        if api.work_suitability(w) == M.RANCH
            and api.as_int(api.prop(w, 'CurrentState')) == M.WORKABLE then
            local model = api.unwrap(api.prop(w, 'CachedOwnerMapObjectConcreteModel'))
            if model ~= nil and api.valid(model) and completed(w, model) then
                n = n + 1
            end
        end
    end
    return n
end

M.HANDIWORK = workdefs.value('Handcraft')
M.SILENT_HANDIWORK_CLASSES = { PalWorkFishPond = true, PalWorkLabResearch = true }

-- work key -> class name, for the Handiwork works handed to the counter
-- below. A work's class never changes, and GetFullName is a native string
-- call per work per pass otherwise. Plain strings only; the work itself is
-- never kept. Per camp (camp key -> {work key -> class}) and rebuilt by every
-- call from the keys it was handed, like the scheduler's work_types, so works
-- that are gone (mined-out rocks, removed buildings) drop out instead of
-- growing the memo for the whole session (review 2026-10-29). Cleared on a
-- world change (forget).
local classes = {}

function M.forget()
    classes = {}
end

-- Number of fishing ponds and Handiwork research labs in `works` that are
-- built and Workable. One seat each. `keys[i]`, when given, is works[i]'s
-- work id, so its class is read once; `camp_key` names the camp the works
-- belong to (one shared slot without it).
function M.ponds_and_labs_needing(works, keys, camp_key)
    local n = 0
    local slot = camp_key or ''
    local known, fresh = classes[slot] or {}, {}
    for i, w in ipairs(works or {}) do
        local key = type(keys) == 'table' and keys[i] or nil
        local class = key and known[key] or nil
        if class == nil then
            class = (api.work_full_name(w) or ''):match('^(%S+)')
            -- "<unknown work>" is a failed read, asked again next pass.
            if class and class:sub(1, 1) == '<' then class = nil end
        end
        if key and class then fresh[key] = class end
        if class and M.SILENT_HANDIWORK_CLASSES[class]
            and api.work_suitability(w) == M.HANDIWORK
            and api.as_int(api.prop(w, 'CurrentState')) == M.WORKABLE then
            local model = api.unwrap(api.prop(w, 'CachedOwnerMapObjectConcreteModel'))
            if model ~= nil and api.valid(model) and completed(w, model) then
                n = n + 1
            end
        end
    end
    if type(keys) == 'table' then classes[slot] = next(fresh) and fresh or nil end
    return n
end

M.LUMBERING = workdefs.value('Deforest')
M.MINING = workdefs.value('Mining')

-- Number of `value` resource works in `works` that are Workable (and built,
-- when they belong to a building).
function M.resources_needing(works, value)
    local n = 0
    for _, w in ipairs(works or {}) do
        if api.work_suitability(w) == value
            and api.as_int(api.prop(w, 'CurrentState')) == M.WORKABLE then
            -- A natural tree has no owning model: the property reads as nil or
            -- as an invalid (null) object wrapper, seen live for all 46 trees
            -- on 2026-10-17. Rocks and the stone pit have a model and count
            -- only when its build reads Completed.
            local model = api.unwrap(api.prop(w, 'CachedOwnerMapObjectConcreteModel'))
            if model == nil or not api.valid(model) or completed(w, model) then
                n = n + 1
            end
        end
    end
    return n
end

-- The silent station kinds the scheduler checks, with their counters.
M.KINDS = {
    { value = M.GENERATOR, needing = M.generators_needing },
    { value = M.COOLER, needing = M.coolers_needing },
    { value = M.LUMBERING, needing = function(works) return M.resources_needing(works, M.LUMBERING) end },
    { value = M.MINING, needing = function(works) return M.resources_needing(works, M.MINING) end },
    { value = M.RANCH, needing = M.ranches_needing },
    { value = M.HANDIWORK, needing = M.ponds_and_labs_needing },
}

return M
