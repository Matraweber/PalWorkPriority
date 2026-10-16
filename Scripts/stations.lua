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

-- The silent station kinds the scheduler checks, with their counters.
M.KINDS = {
    { value = M.GENERATOR, needing = M.generators_needing },
    { value = M.COOLER, needing = M.coolers_needing },
}

return M
