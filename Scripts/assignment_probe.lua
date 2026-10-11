-- Read-only, one-shot native assignment census. Never permission evidence yet.
-- SDK: PalWorkAssign { AssignedIndividualId, HandleId, State, bFixed };
-- GetWork(), GetWorkSuitability(); PalWorkBase.BaseCampIdBelongTo.
-- No out-array UFunctions, recursive schema dumps, or saved engine wrappers.
-- A native comparison with Current Task and deliberate fixed/unfixed changes
-- must establish these semantics before wiring a scheduler reader.
local api = require('palapi')
local workdefs = require('workdefs')
local assignments = require('assignments')
local M = {}
local MAX_CAMPS, MAX_ASSIGNMENTS = 32, 4096

local function integer(n)
    if type(n) == 'number' then return math.tointeger(n) end
    return nil
end

local function invoke(obj, name)
    local ok, value = pcall(function() return obj[name](obj) end)
    if ok then return value end
    return nil
end

local function unknown(reason)
    return {state='unknown', reason=reason}
end

-- Existing camp->WorkerDirector route; dump-confirmed scalar fields only.
-- These describe lifecycle/player tracking, never manual or occupied work.
local director_states = {[0]='Init', [1]='WaitForLoadingAround', [2]='Active'}
local function observe_director(camp, cid)
    local out={camp=cid, available=false, reason='director unavailable'}
    local ok=pcall(function()
        local director=api.prop(camp,'WorkerDirector')
        if not api.valid(director) then return end
        if not cid or api.guid_key(api.prop(director,'BaseCampId'))~=cid then
            out.reason='director camp unavailable or mismatched';return
        end
        out.state=integer(api.prop(director,'State'))
        out.state_name=director_states[out.state] or 'unknown'
        local tracking=api.prop(director,'bEnableWorkerPlayerTracking')
        if type(tracking)=='boolean' then out.tracking=tracking end
        out.available=director_states[out.state]~=nil and out.tracking~=nil
        out.reason=out.available and 'lifecycle observation only' or 'director fields unavailable or unsupported'
    end)
    if not ok then
        return {camp=cid,available=false,reason='director read failed'}
    end
    return out
end

-- Public for isolated contract regressions. Inputs must be ordinary Lua data.
-- State is deliberately observational; Reserve/Leave are not called completed
-- work, and no record is never promoted to a verified idle/manual=false result.
function M.classify(row, camp)
    if type(camp) ~= 'string' or camp == '' or row.camp ~= camp then
        return unknown('camp unavailable or mismatched')
    end
    if type(row.id) ~= 'string' or row.id == '' or row.handle_work ~= row.id then
        return unknown('job identity unavailable or inconsistent')
    end
    if type(row.fixed) ~= 'boolean' then return unknown('fixed flag unavailable') end
    local state, value = integer(row.native_state), integer(row.value)
    if not value or value < 1 or value >= workdefs.value(workdefs.ANYONE) then
        return unknown('suitability unavailable')
    end
    if state ~= 1 and state ~= 2 then
        return unknown(state == 3 and 'leaving assignment' or 'assignment state unavailable')
    end
    return {id=row.id, value=value, manual=row.fixed,
        state=state == 2 and 'occupied' or 'reserved', reason='native candidate; not scheduler verified'}
end

function M.read()
    local report = {rows={}, directors={}, assignments=0, failures=0, complete=false, authoritative=false}
    -- Refresh authority before touching server-only Pal data. A client command
    -- reports unavailable instead of attempting to resolve replicated workers.
    if api.latch_authority() ~= true then report.reason='authority unavailable'; return report end
    report.authoritative=true
    local camps = api.base_camps()
    if api.camps_available ~= true or #camps > MAX_CAMPS then
        report.reason='camp enumeration incomplete or over budget'; return report
    end
    local by_key = {}
    for _, camp in ipairs(camps) do
        local cid = api.guid_key(api.camp_id(camp))
        -- At most one observation per enumerated camp (MAX_CAMPS). Missing
        -- diagnostic fields do not change assignment census completeness.
        report.directors[#report.directors+1]=observe_director(camp,cid)
        local pals, err = api.camp_pals(camp)
        if not cid or err then report.failures=report.failures+1 end
        for _, pal in ipairs(pals) do
            local row = {key=pal.key, name=pal.name, camp=cid,
                current=api.current_work_suitability(pal.param), candidates={},
                evidence=unknown('no matching assignment observed')}
            row.direct=assignments.read(pal, camp)
            report.rows[#report.rows+1]=row
            if type(pal.key) ~= 'string' or pal.key:match('^slot%d+$') then
                row.evidence=unknown('unstable Pal identity'); report.failures=report.failures+1
            elseif by_key[pal.key] then
                by_key[pal.key].duplicate=true; row.duplicate=true
                report.failures=report.failures+1
            else by_key[pal.key]=row end
        end
    end
    local ok, all = pcall(FindAllOf, 'PalWorkAssign')
    -- UE4SS returns nil when no instances exist. This completes the census
    -- only; no matching record still cannot prove idle or non-manual state.
    if ok and all == nil then all = {} end
    if not ok or type(all) ~= 'table' or #all > MAX_ASSIGNMENTS then
        report.reason='assignment enumeration incomplete or over budget'; return report
    end
    for _, assignment in ipairs(all) do
        report.assignments=report.assignments+1
        local read_ok = pcall(function()
            if not api.valid(assignment) then error('invalid assignment') end
            local key = api.instance_key(api.prop(assignment, 'AssignedIndividualId'))
            local row = key and by_key[key]
            if not row then return end
            local work = invoke(assignment, 'GetWork')
            if not api.valid(work) then error('work unavailable') end
            local handle = api.prop(assignment, 'HandleId')
            local raw = {
                id=api.guid_key(invoke(work, 'GetWorkId')),
                handle_work=api.guid_key(api.prop(handle, 'WorkId')),
                camp=api.guid_key(api.prop(work, 'BaseCampIdBelongTo')),
                fixed=api.prop(assignment, 'bFixed'),
                native_state=api.prop(assignment, 'State'),
                value=invoke(assignment, 'GetWorkSuitability'),
            }
            -- Copy only typed primitives, never an unreadable TrivialObject.
            local candidate={id=raw.id, handle_work=raw.handle_work, camp=raw.camp,
                native_state=integer(raw.native_state), value=integer(raw.value)}
            if type(raw.fixed) == 'boolean' then candidate.fixed=raw.fixed end
            row.candidates[#row.candidates+1]=candidate
        end)
        if not read_ok then report.failures=report.failures+1 end
    end
    for _, row in ipairs(report.rows) do
        if row.duplicate then row.evidence=unknown('duplicate Pal identity')
        elseif #row.candidates > 1 then row.evidence=unknown('multiple assignment records')
        elseif #row.candidates == 1 then row.evidence=M.classify(row.candidates[1], row.camp) end
    end
    report.complete=report.failures == 0
    -- Completeness means the bounded census finished, not proven idle state,
    -- supported native semantics, or authorization to change permissions.
    return report
end

local function field(value)
    if value == nil then return 'unavailable' end
    return tostring(value):gsub('[\r\n]', ' ')
end

function M.format(report)
    local lines={string.format('assignment census (read-only; NOT scheduler verification): %d Pals, %d records, %d failures; complete=%s',
        #report.rows, report.assignments, report.failures, tostring(report.complete))}
    if report.reason then lines[#lines+1]=report.reason end
    for _, director in ipairs(report.directors or {}) do
        lines[#lines+1]=string.format('  director camp=%s state=%s (%s) player_tracking=%s; available=%s (%s; NOT assignment evidence)',
            field(director.camp), field(director.state), field(director.state_name),
            field(director.tracking), tostring(director.available), field(director.reason))
    end
    for _, row in ipairs(report.rows) do
        lines[#lines+1]=string.format('  %s [%s] camp=%s current=%s candidates=%d: %s (%s)',
            field(row.name), field(row.key), field(row.camp), field(row.current), #row.candidates,
            row.evidence.state, row.evidence.reason)
        if row.direct then
            lines[#lines+1]=string.format('    direct: state=%s fixed=%s suitability=%s job=%s (%s)',
                field(row.direct.state), field(row.direct.manual), field(row.direct.value),
                field(row.direct.id), field(row.direct.reason))
        end
        for _, a in ipairs(row.candidates) do
            lines[#lines+1]=string.format('    job=%s handle=%s camp=%s state=%s fixed=%s suitability=%s',
                field(a.id), field(a.handle_work), field(a.camp), field(a.native_state), field(a.fixed), field(a.value))
        end
    end
    return table.concat(lines, '\n')
end

return M
