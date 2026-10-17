-- Read-only probe: does a continuous station (generator, cooler) need a worker?
--
-- The game never announces generator work (0 OnRequiredAssignWork pulses in a
-- whole session, 2026-10-14), so the scheduler cannot see an empty generator.
-- Two candidate signals, both reflected PROPERTIES in the modding kit headers:
--   work.CurrentState  EPalWorkProgressState: 0 Init, 1 Workable,
--                      2 NotWorkable, 3 Finish, 4 Dispose
--   work.CachedOwnerMapObjectConcreteModel -> the station model; for a
--                      generator (UPalMapObjectGenerateEnergyModel)
--                      StoredEnergyAmount and MaxEnergyStorage.
-- This prints both side by side so they can be checked against the screen
-- (Power Capacity) before either is trusted by the scheduler.
--
-- Safety: property reads only, on objects obtained in this same call (the
-- work comes from camp_works now, the model from that work now); nothing is
-- stored. Authority only, so no replicated proxy is touched on a client.
local api = require('palapi')
local workdefs = require('workdefs')

local M = {}
local STATE = { [0] = 'Init', [1] = 'Workable', [2] = 'NotWorkable', [3] = 'Finish', [4] = 'Dispose' }
local WATCH = { GenerateElectricity = true, Cool = true }
-- Resource nodes come in dozens, so they are summarised per type instead of
-- one line per work: how many in each state / model / build combination.
local SUMMARISE = { Deforest = true, Mining = true }

local function num(v)
    if type(v) == 'number' then return string.format('%.1f', v) end
    return 'unreadable'
end

function M.report()
    if api.latch_authority() ~= true then
        return 'stations: host/server only (station models are read where the world runs)'
    end
    local lines, seen, summary = {}, 0, {}
    for ci, camp in ipairs(api.base_camps() or {}) do
        for _, w in ipairs(api.camp_works(camp) or {}) do
            local value = api.work_suitability(w)
            local name = value and workdefs.name(value)
            if name and SUMMARISE[name] then
                local st = api.as_int(api.prop(w, 'CurrentState'))
                local model = api.unwrap(api.prop(w, 'CachedOwnerMapObjectConcreteModel'))
                local mtxt, build = 'none', 'n/a'
                if model ~= nil then
                    mtxt = api.valid(model) and 'yes' or 'invalid'
                    if mtxt == 'yes' then
                        local ok, manager = pcall(function() return model:GetOuter() end)
                        local id = api.prop(w, 'OwnerMapObjectModelId')
                        if ok and manager ~= nil and api.valid(manager) and id ~= nil then
                            local found, owner = pcall(function() return manager:FindModel(id) end)
                            owner = found and api.unwrap(owner) or nil
                            if owner ~= nil and api.valid(owner) then
                                local bp = api.unwrap(api.prop(owner, 'BuildProcess'))
                                local bst = bp ~= nil and api.valid(bp) and api.as_int(api.prop(bp, 'State')) or nil
                                build = bst == 1 and 'Completed' or bst == 0 and 'Building'
                                    or (bp == nil and 'no BuildProcess' or 'unreadable')
                            else
                                build = found and 'model not found' or 'FindModel failed'
                            end
                        else
                            build = 'no manager/id'
                        end
                    end
                end
                local k = string.format('camp %d %-9s state=%s model=%s build=%s', ci, name, tostring(st), mtxt, build)
                summary[k] = (summary[k] or 0) + 1
            elseif name and WATCH[name] then
                seen = seen + 1
                local st = api.as_int(api.prop(w, 'CurrentState'))
                local model = api.unwrap(api.prop(w, 'CachedOwnerMapObjectConcreteModel'))
                local has_model = model ~= nil and api.valid(model)
                local stored, max = 'n/a', 'n/a'
                if has_model and name == 'GenerateElectricity' then
                    stored = num(api.prop(model, 'StoredEnergyAmount'))
                    max = num(api.prop(model, 'MaxEnergyStorage'))
                end
                -- Construction state lives on the owning UPalMapObjectModel
                -- (BuildProcess.State: 0 Building, 1 Completed). The concrete
                -- model's outer is the map object manager (seen live), whose
                -- FindModel(InstanceId) is a BlueprintPure UFUNCTION; the work
                -- carries that id as OwnerMapObjectModelId. Same pattern as
                -- palapi's GetWork(id). Host only. Reported, not trusted yet.
                local build = 'n/a'
                if has_model then
                    local ok, manager = pcall(function() return model:GetOuter() end)
                    local id = api.prop(w, 'OwnerMapObjectModelId')
                    if ok and manager ~= nil and api.valid(manager) and id ~= nil then
                        local found, owner = pcall(function() return manager:FindModel(id) end)
                        owner = found and api.unwrap(owner) or nil
                        if owner ~= nil and api.valid(owner) then
                            local bp = api.unwrap(api.prop(owner, 'BuildProcess'))
                            local bst = bp ~= nil and api.valid(bp) and api.as_int(api.prop(bp, 'State')) or nil
                            build = bst == 1 and 'Completed' or bst == 0 and 'Building' or 'unreadable'
                        else
                            build = found and 'model not found' or 'FindModel failed'
                        end
                    else
                        build = 'no manager/id'
                    end
                end
                lines[#lines + 1] = string.format('  camp %d %-20s state=%s (%s) model=%s stored=%s max=%s build=%s',
                    ci, name, tostring(st), STATE[st] or '?', has_model and 'yes' or 'no', stored, max, build)
            end
        end
    end
    local keys = {}
    for k in pairs(summary) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do lines[#lines + 1] = string.format('  %3dx %s', summary[k], k) end
    local okc, sched = pcall(require, 'scheduler')
    local capped = okc and type(sched) == 'table' and sched.last_capped or {}
    for _, n in ipairs({ 'Deforest', 'Mining' }) do
        local c = capped[n]
        lines[#lines + 1] = string.format('  last pass limit %s: %s', n, c and string.format(
            'capped in %d of %d camp(s), unknown %d', c.capped or 0, c.camps or 0, c.unknown or 0) or 'no record')
    end
    table.insert(lines, 1, string.format('stations: %d generator/cooler work(s)', seen))
    return table.concat(lines, '\n')
end

return M
