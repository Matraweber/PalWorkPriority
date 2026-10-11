-- Callback-local assignment reader. No object lookup sweep or retained wrapper.
-- Only the authority may use this route; absent actors/fields stay unknown.
local api = require('palapi')
local workdefs = require('workdefs')
local M = {}

local function call(obj, name)
    local ok, value = pcall(function() return obj[name](obj) end)
    return ok, value
end

local function unknown(reason)
    return {state='unknown', reason=reason}
end

function M.read(pal, camp)
    if api.has_authority() ~= true then return unknown('authority unavailable') end
    local cid = api.guid_key(api.camp_id(camp))
    if not cid or type(pal.key) ~= 'string' or pal.key:match('^slot%d+$') then
        return unknown('scope or Pal identity unavailable')
    end
    if not api.valid(pal.handle) then return unknown('Pal handle unavailable') end
    local ok, actor = call(pal.handle, 'TryGetIndividualActor')
    if not ok or not api.valid(actor) then return unknown('Pal actor unavailable') end
    local component = api.prop(actor, 'CharacterParameterComponent')
    if not api.valid(component) then return unknown('Pal component unavailable') end
    local scope_ok, scope = call(component, 'GetBaseCampId')
    local handle = api.prop(component, 'IndividualHandle')
    if not api.valid(handle) then return unknown('component owner unavailable') end
    local id_ok, id = call(handle, 'GetIndividualID')
    if not scope_ok or api.guid_key(scope) ~= cid or not id_ok or api.instance_key(id) ~= pal.key then
        return unknown('component owner or camp mismatch')
    end
    local assigned_ok, assigned = call(component, 'IsAssignedToAnyWork')
    local fixed_ok, fixed = call(component, 'IsAssignedFixed')
    if not assigned_ok or type(assigned) ~= 'boolean' or not fixed_ok or type(fixed) ~= 'boolean' then
        return unknown('assignment flags unavailable')
    end
    local work_ok, assignment = call(component, 'GetWorkAssign')
    if not work_ok then return unknown('assignment read failed') end
    if not assigned then
        if fixed or api.valid(assignment) then return unknown('conflicting unassigned state') end
        return {state='ready', manual=false, reason='explicitly unassigned and not fixed'}
    end
    if not api.valid(assignment) then return unknown('assigned record unavailable') end
    if api.instance_key(api.prop(assignment, 'AssignedIndividualId')) ~= pal.key
        or api.prop(assignment, 'bFixed') ~= fixed then
        return unknown('assignment owner or fixed flag mismatch')
    end
    local job_ok, job = call(assignment, 'GetWork')
    if not job_ok or not api.valid(job) then return unknown('assigned job unavailable') end
    local job_id_ok, job_id = call(job, 'GetWorkId')
    local key = job_id_ok and api.guid_key(job_id) or nil
    local assign_handle = api.prop(assignment, 'HandleId')
    if not key or key ~= api.guid_key(api.prop(assign_handle, 'WorkId'))
        or api.guid_key(api.prop(job, 'BaseCampIdBelongTo')) ~= cid then
        return unknown('assigned job identity or camp mismatch')
    end
    local value_ok, value = call(assignment, 'GetWorkSuitability')
    value = value_ok and type(value)=='number' and math.tointeger(value) or nil
    local state = api.prop(assignment, 'State')
    state = type(state)=='number' and math.tointeger(state) or nil
    if not value or value < 1 or value >= workdefs.value(workdefs.ANYONE)
        or (state ~= 1 and state ~= 2 and state ~= 3) then
        return unknown('assigned type or state unavailable')
    end
    -- Reserve is an identified job, not occupied work. Leave is not completion
    -- of a production job. Preserve the proven manual intent in both cases.
    return {id=key, value=value, manual=fixed,
        state=state == 2 and 'occupied' or (state == 1 and 'ready' or 'unknown'),
        reason='direct component assignment', native_state=state}
end

return M
