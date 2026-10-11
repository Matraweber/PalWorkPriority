-- Durable per-Pal choices. Client snapshots never enter this table.
local log = require('log')
local file = require('datafile')
local settings_gate = require('settings_gate')
local M = { MAX = 5, path = nil, data = {}, decided = false, submit = nil,
    on_change = nil, state = 'unavailable', error = nil, generation = 0,
    baseline = false, is_client = false }
local dirty_at, retry_at, failures = nil, 0, 0
local notify_pending = false
-- nil = none, {key=...} = one Pal, {full=true} = several Pals.
local pending_scope = nil
local persistence, retiring, owns_key
local network_runtime
local published_body,published_revision
local retirement_snapshot
local persistence_epoch,persistence_blocked=0,false
local activating,activation_poison,attaching=false,false,false
local flush_scope,edit_revision=0,0
local function activation_busy()
    if activating then activation_poison=true;return true end
    return false
end
function M.detach_persistence()
    if activation_busy() then return false,'activation_busy' end
    network_runtime=nil
    published_body,published_revision=nil,nil
    persistence_epoch=persistence_epoch+1
    local old=persistence
    if old then
        -- Capture before close makes matches() unavailable. Only exact accepted
        -- bytes may clear pending state after a confirmed original-owner drain.
        local ok,snapshot=pcall(function()
            local text=M.serialize()
            if text and old:matches(text) then
                return {owner=old,epoch=persistence_epoch,text=text,session=M.session,
                    decided=M.decided,is_client=M.is_client,submit=M.submit}
            end
        end)
        retirement_snapshot=ok and snapshot or nil
    end
    persistence,owns_key=nil,nil
    if old then persistence_blocked=true;retiring=old;return old:close() end
    return retiring==nil
end
-- Lifecycle coordinator boundary: fence only the originally bound writer.
-- First result means edits are fenced, NOT that native data is drained. The
-- coordinator must still call the original settings_session:drain explicitly.
function M.retire_persistence(expected)
    if activation_busy() or attaching then return false,'activation_busy' end
    if type(expected)~='table' or getmetatable(expected) then return false,'invalid_context' end
    local p=persistence or retiring
    if not p then return true end
    local identity=p:identity()
    for _,k in ipairs({'scope','session','incarnation','guild','stream','camp','epoch','authority'}) do
        if expected[k]~=identity[k] then return false,'owner_mismatch' end
    end
    if persistence then M.detach_persistence() else p:close() end
    return true
end
-- Clear only this writer after the native owner has actually drained. The
-- writer drain merely observes session closure; it never starts a native join.
function M.finish_retirement(expected)
    if activation_busy() or attaching or persistence then return false end
    if type(expected)~='table' or getmetatable(expected) then return false end
    local p=retiring
    if not p then return true end
    local identity=p:identity()
    for _,k in ipairs({'scope','session','incarnation','guild','stream','camp','epoch','authority'}) do
        if expected[k]~=identity[k] then return false end
    end
    if p:drain()~=true or retiring~=p or persistence then return false end
    local status=p:status()
    local captured=retirement_snapshot
    if captured and captured.owner==p and captured.epoch==persistence_epoch
        and captured.session==M.session and captured.decided==M.decided
        and captured.is_client==M.is_client and captured.submit==M.submit
        and captured.text==M.serialize() and status.drained==true and not status.uncertain
        and not status.candidate_retained then
        -- No on_change/ACK: this is old-owner cleanup, not a current-session edit.
        dirty_at,retry_at,failures=nil,0,0
        notify_pending,pending_scope=false,nil
        M.state,M.error,M.persisted_revision='saved',nil,status.revision
    end
    retirement_snapshot=nil
    retiring=nil
    return true
end

function M.durable_key(key)
    return type(key) == 'string' and #key > 0 and #key <= 160
        and not key:find('[^%w%-]') and not key:lower():match('^slot%d+$')
end

local function valid(key, value, prio, clearing)
    if type(value) ~= "number" then return false end
    local n = math.tointeger(value)
    if not M.durable_key(key) or not n or n < 1 or n > 64 then return false end
    if clearing or prio == false then return true end
    if type(prio) ~= "number" then return false end
    local p = math.tointeger(prio)
    return p ~= nil and p >= 1 and p <= M.MAX
end

local function decode(text)
    local result = { data = {}, count = 0, baseline = false, transient = 0 }
    for line in (text .. '\n'):gmatch('(.-)\n') do
        line = line:gsub('\r$', '')
        if line == '# baseline=vanilla' then result.baseline = true end
        if line ~= '' and line:sub(1, 1) ~= '#' then
            local key, value, token = line:match('^([%w%-]+)|(%d+)|(%w+)$')
            value = tonumber(value)
            local prio
            if token == 'X' then prio = false else prio = tonumber(token) end
            if key and key:lower():match('^slot%d+$') then
                result.transient = result.transient + 1
            elseif not valid(key, value, prio) then return nil, 'invalid priority row'
            else
                result.data[key] = result.data[key] or {}
                if result.data[key][value] ~= nil then return nil, 'duplicate priority row' end
                result.data[key][value] = prio
                result.count = result.count + 1
            end
        end
    end
    return result
end

-- Pure, bounded recovery validation. Unlike legacy load(), a new scoped
-- snapshot must not silently discard temporary identifiers. No state/IO change;
-- callers still have to prove scope and durable generation before installing it.
function M.decode_snapshot(text)
    if type(text) ~= 'string' or #text > 8 * 1024 * 1024 then
        return nil, 'invalid priority snapshot size/type'
    end
    local result, why = decode(text)
    if not result then return nil, why end
    if result.transient > 0 then return nil, 'temporary identifiers in priority snapshot' end
    return result
end

function M.load(path)
    if activation_busy() then return 0,'activation_busy' end
    if settings_gate.blocked() then return 0,'settings_recovering' end
    M.detach_persistence();persistence_blocked=false;M.persisted_revision=nil
    M.path, M.data, M.error, M.generation, M.baseline = path, {}, nil, 0, false
    dirty_at, retry_at, failures, notify_pending = nil, 0, 0, false
    pending_scope = nil
    local result, meta = file.read(path, decode)
    if not result then
        M.state, M.error = meta.state, meta.error
        if M.error then log.error('priorities unavailable: ' .. M.error) end
        return 0
    end
    M.data, M.generation, M.baseline = result.data, meta.generation, result.baseline
    M.state = 'saved'
    if meta.recovered then
        log.warn('recovered priorities from ' .. meta.source)
        dirty_at, M.state = os.clock(), 'saving'
    end
    if result.transient > 0 then
        log.warn('ignored ' .. result.transient .. ' temporary slot identifiers; these cannot identify a Pal after restart')
    end
    return result.count
end

local function changed(key)
    edit_revision=edit_revision+1
    dirty_at, retry_at, failures = os.clock(), 0, 0
    M.state, M.error = 'saving', nil
    notify_pending = true
    if pending_scope == nil then pending_scope = {key=key}
    elseif not pending_scope.full and pending_scope.key ~= key then pending_scope = {full=true} end
end

-- Immutable full snapshot; serialization alone performs no IO and never marks
-- edits saved. Shared by the synchronous writer and future async admission.
-- Formats caller-owned records only. Does not establish scope, ownership or
-- durability. Callers must copy/partition records before invoking this API.
function M.serialize_snapshot(data, baseline)
    local out = { '# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n' }
    if baseline then out[#out + 1] = '# baseline=vanilla\n' end
    local keys = {}
    for key in pairs(data) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local values = {}
        for value in pairs(data[key]) do values[#values + 1] = value end
        table.sort(values)
        for _, value in ipairs(values) do
            local prio = data[key][value]
            if not valid(key, value, prio) then
                return nil, 'invalid priority in memory; previous save retained'
            end
            local token = prio == false and 'X' or tostring(math.tointeger(prio))
            out[#out + 1] = string.format('%s|%d|%s\n', key, value, token)
        end
    end
    return table.concat(out)
end

function M.serialize()
    return M.serialize_snapshot(M.data, M.baseline)
end

-- Explicit attachment only. Recovery/registration/authority are owned by the
-- injected settings_session; neither legacy import nor native setup occurs here.
local function attach_persistence(o,activate)
    local captured={}
    for k,v in pairs(o) do captured[k]=v end
    if type(o.context)=="table" then captured.context={};for k,v in pairs(o.context) do captured.context[k]=v end end
    if type(o.recovery)=="table" then captured.recovery={};for k,v in pairs(o.recovery) do captured.recovery[k]=v end end
    o=captured
    if type(o)~='table' or o.enabled~=true or persistence or retiring or not M.decided or M.is_client
        or M.submit or M.state~='saved' or dirty_at~=nil or type(o.owns_key)~='function'
        or type(o.context)~='table' or o.context.stream~='priorities' then return false,'unavailable' end
    if activate and type(o.authorize)~='function' then return false,'activation_proof_required' end
    local epoch,session=persistence_epoch,M.session
    local current=M.serialize()
    local candidate,baseline
    local ok,recovered=pcall(function()
        local settings=o.recovery.settings
        if activate then
            if type(settings)~='table' or getmetatable(settings) or type(settings.data)~='table'
                or getmetatable(settings.data) or type(settings.baseline)~='boolean' then return end
            for k in pairs(settings) do
                if k~='data' and k~='count' and k~='baseline' and k~='transient' then return end
            end
            if settings.transient~=nil and settings.transient~=0 then return end
            candidate,baseline={},settings.baseline
            local count=0
            for key,row in pairs(settings.data) do
                if not M.durable_key(key) or type(row)~='table' or getmetatable(row) or next(row)==nil then return end
                candidate[key]={}
                for value,prio in pairs(row) do
                    if math.type(value)~='integer' or (prio~=false and math.type(prio)~='integer')
                        or not valid(key,value,prio) then return end
                    candidate[key][value]=prio;count=count+1
                end
            end
            if math.type(settings.count)~='integer' or settings.count~=count then return end
            return M.serialize_snapshot(candidate,baseline)
        end
        return M.serialize_snapshot(settings.data,settings.baseline)
    end)
    if not ok or not current or not recovered or (not activate and current~=recovered) then return false,'recovery_mismatch' end
    -- Prove the union, including legacy-only rows which replacement would drop.
    -- A fresh scalar context per key prevents proof callbacks changing identity.
    local keys={}
    for key in pairs(M.data) do keys[key]=true end
    for key in pairs(candidate or M.data) do keys[key]=true end
    local function authorized()
        if not activate then return true end
        local c={};for k,v in pairs(o.context) do c[k]=v end
        return o.authorize(c,o.runtime_guild or o.context.guild)==true
    end
    local function fresh()
        if not authorized() then return false end
        for key in pairs(keys) do
            local c={};for _,k in ipairs({'scope','session','incarnation','epoch','guild','stream','camp','authority'}) do c[k]=o.context[k] end
            local yes,value=pcall(o.owns_key,key,c)
            if not yes or value~=true then return false end
        end
        return authorized()
    end
    local function unchanged()
        return not persistence and not retiring and persistence_epoch==epoch and M.session==session
            and M.decided and not M.is_client and not M.submit and M.state=='saved' and dirty_at==nil
            and not activation_poison and M.serialize()==current
    end
    if not fresh() or not unchanged() then return false,'foreign_priority' end
    local p,why=require('settings_writer').new{enabled=true,session=o.session,context=o.context,
        recovery=o.recovery,body=activate and recovered or current,recovery_body=recovered}
    if not p then return false,why end
    -- Keep the owner even if a final callback throws/loses proof. No candidate
    -- is installed until all callback crossings have succeeded.
    local checked,stable=pcall(function() return fresh() and unchanged() end)
    if not checked or not stable then
        retiring=p;persistence_blocked=true;p:close()
        return false,activate and 'stale_activation' or 'stale_attachment'
    end
    if activate then M.data,M.baseline=candidate,baseline end
    persistence,owns_key,persistence_blocked=p,o.owns_key,false
    M.persisted_revision=o.recovery.revision
    published_body,published_revision=activate and recovered or current,o.recovery.revision
    network_runtime=activate and (o.runtime_guild or o.context.guild) or nil
    return true
end

-- Fence callbacks in ownership proof and recovered-session validation.
function M.attach_persistence(o)
    if activation_busy() then return false,'attachment_busy' end
    if attaching or type(o)~='table' then return false,'attachment_busy' end
    attaching=true
    local ok,result,why=pcall(attach_persistence,o)
    attaching=false
    if not ok then return false,'attachment_exception' end
    return result,why
end

-- Explicit, default-off cutover from take_recovered's typed envelope. owns_key
-- must freshly prove membership for EVERY current and recovered Pal key; durable
-- key syntax alone is never ownership evidence. authorize(context,runtime_guild)
-- must freshly prove current authority (context-only callbacks are supported).
-- Session readiness/authority is checked by settings_writer. No IO, notifications or migration here. The shared
-- settings_gate fences normal APIs during coordinator recovery; cutover itself
-- is allowed under that fence, like Caps. Failure blocks synchronous fallback.
function M.activate_recovered(o)
    if activating then activation_poison=true;return false,'attachment_busy' end
    if attaching then return false,'attachment_busy' end
    if type(o)~='table' or o.enabled~=true then return false,'disabled' end
    if persistence or retiring then return false,'unavailable' end
    persistence_blocked=true
    if getmetatable(o) or type(o.context)~='table' or getmetatable(o.context)
        or type(o.recovery)~='table' or getmetatable(o.recovery) then return false,'invalid_activation' end
    for _,v in pairs(o.context) do
        if type(v)~='string' and type(v)~='number' and type(v)~='boolean' then return false,'invalid_context' end
    end
    activating,activation_poison,attaching=true,false,true
    local ok,result,why=pcall(attach_persistence,o,true)
    activating,attaching=false,false
    if not ok then return false,'activation_exception' end
    return result,why
end

function M.poll_persistence(defer_notification)
    if activation_busy() then return false,'activation_busy' end
    if settings_gate.blocked() then return false,'settings_recovering' end
    if retiring then M.finish_retirement(retiring:identity()) end
    local p,epoch=persistence,persistence_epoch
    if not p or not M.decided or M.is_client or M.submit then return false,nil,'unavailable' end
    local r=p:poll()
    if persistence~=p or persistence_epoch~=epoch or not M.decided or M.is_client or M.submit then return false,nil,'stale' end
    if r.state~='saved' then
        M.state=(r.state=='saving' or r.state=='pending') and 'saving' or 'error'
        M.error=M.state=='error' and (r.reason or r.state) or nil
        return false,nil,r.state
    end
    if M.serialize()~=r.body then M.state,M.error='error','snapshot_changed';return false,nil,'snapshot_changed' end
    dirty_at,failures,retry_at=nil,0,0
    M.state,M.error,M.persisted_revision='saved',nil,r.revision
    published_body,published_revision=r.body,r.revision
    local scope=pending_scope;pending_scope=nil
    local notify=notify_pending;notify_pending=false
    if notify and M.on_change and defer_notification~=true then
        local ok,why=pcall(M.on_change,scope and scope.key)
        if not ok then log.warn('priority notification failed: '..tostring(why)) end
    end
    if persistence~=p or persistence_epoch~=epoch or M.state~='saved' or M.serialize()~=r.body then return false,nil,'changed_during_notification' end
    return true,scope
end

-- Internal admission identity for the explicitly enabled deferred transport.
-- Only recovered activation with its authenticated runtime alias is eligible.
-- False means ordinary synchronous storage; nil means unavailable, not legacy.
function M.pending_owner(guild)
    if activating or attaching or settings_gate.blocked() or not M.decided
        or M.is_client or M.submit or retiring or persistence_blocked then return nil end
    if not persistence then return false end
    if guild~=network_runtime or M.state~='saved' or M.error~=nil then return nil end
    return persistence:identity()
end

-- A publication lease covers only this plain-data snapshot. It does not poll
-- storage or retain engine objects. Native send boundaries must recheck it.
-- Legacy unsaved snapshots retain their explicit applied_unsaved protocol;
-- an attached async stream may publish ONLY its last normally committed body.
function M.publication_guard(expected_body,expected_revision)
    if activation_busy() or attaching or settings_gate.blocked() or not M.decided
        or M.is_client or M.submit or retiring or persistence_blocked then return nil end
    local p,epoch,session=persistence,persistence_epoch,M.session
    local text=M.serialize()
    if type(text)~='string' then return nil end
    local body,revision=published_body,published_revision
    if expected_body~=nil and (not p or body~=expected_body or revision~=expected_revision) then return nil end
    local function current()
        local text_now=M.serialize()
        local body_now=p and text_now or nil
        if activating or attaching or settings_gate.blocked() or persistence~=p
            or persistence_epoch~=epoch or M.session~=session or not M.decided
            or M.is_client or M.submit or retiring or persistence_blocked
            or text_now~=text then return false end
        if not p then return true end
        return M.state=='saved' and M.error==nil and M.persisted_revision==revision
            and published_revision==revision and published_body==body
            and type(body)=='string' and body_now==body
    end
    if not current() then return nil end
    return current
end

-- Internal receipt query for a future deferred network acknowledgement. Only
-- this live attachment can answer; retirement and public counters grant nothing.
-- Normal flush still owns notification and transition to the saved UI state.
function M.receipt_status(receipt)
    if activation_busy() or attaching or settings_gate.blocked()
        or not M.decided or M.is_client or M.submit then return {state='unavailable'} end
    local p,epoch=persistence,persistence_epoch
    if not p or retiring or persistence_blocked then return {state='stale'} end
    local r=p:receipt_status(receipt)
    if persistence~=p or persistence_epoch~=epoch or not M.decided or M.is_client
        or M.submit or settings_gate.blocked() then return {state='stale'} end
    if r.state=='saved' then
        if M.serialize()~=r.body then return {state='error',reason='snapshot_changed'} end
        if M.state~='saved' or M.error~=nil or M.persisted_revision~=r.revision then
            return {state='saving',reason='awaiting_module_commit'}
        end
    end
    return r
end

local function async_candidate(data,baseline,key,capture)
    local p,epoch=persistence,persistence_epoch
    local before=M.serialize()
    if not p or not p:matches(before) then return false,'snapshot_changed' end
    local function owned(k) local ok,yes=pcall(owns_key,k,p:identity());return ok and yes==true end
    if not owned(key) then return false,'foreign_priority' end
    for k in pairs(data) do if not owned(k) then return false,'foreign_priority' end end
    if persistence~=p or persistence_epoch~=epoch or not M.decided or M.is_client or M.submit then return false,'stale' end
    if M.serialize()~=before then return false,'snapshot_changed' end
    local body,why=M.serialize_snapshot(data,baseline)
    if not body then return false,why end
    local r=p:submit(body,capture)
    if persistence~=p or persistence_epoch~=epoch or not M.decided or M.is_client or M.submit then return false,'stale' end
    if M.serialize()~=before then M.detach_persistence();M.state,M.error='error','snapshot_changed';return false,'snapshot_changed' end
    if r.state=='pending' then
        M.data,M.baseline=data,baseline;changed(key)
        return false,'pending',r.receipt
    end
    if r.state~='rejected' then M.state,M.error='error',r.reason or r.state end
    return false,r.state
end
local function candidate_data()
    local out={};for key,row in pairs(M.data) do out[key]={};for value,prio in pairs(row) do out[key][value]=prio end end;return out
end

-- Only the synchronous network edit handler defers notification: it must
-- broadcast the returned committed scope before returning its acknowledgement.
-- This flag belongs to this call, never to a later failed-save retry.
function M.save(defer_notification)
    if activation_busy() then return false,'activation_busy' end
    if settings_gate.blocked() then return false,'settings_recovering' end
    if persistence then return M.poll_persistence(defer_notification) end
    if persistence_blocked then return false,nil,'detached' end
    if not M.path or not M.decided or M.is_client or M.submit then return false end
    if M.state == 'error' and dirty_at == nil then return false end
    local payload, why = M.serialize()
    if not payload then M.state, M.error = 'error', why; return false end
    local ok, err, gen = file.write(M.path, payload, M.generation, decode)
    if not ok then
        failures = failures + 1
        retry_at = os.clock() + math.min(60, 2 ^ math.min(failures, 6))
        dirty_at = dirty_at or os.clock()
        M.state = 'error'
        if M.error ~= err then log.warn('priorities not saved: ' .. tostring(err)) end
        M.error = err
        return false
    end
    dirty_at, failures, retry_at = nil, 0, 0
    M.state, M.error, M.generation = 'saved', nil, gen
    local committed_scope = pending_scope
    pending_scope = nil
    if notify_pending then
        notify_pending = false
        if M.on_change and defer_notification ~= true then
            local sent, why = pcall(M.on_change, committed_scope and committed_scope.key)
            if not sent then log.warn("priority notification failed: " .. tostring(why)) end
        end
    end
    return true, committed_scope
end

function M.flush(now, force, defer_notification)
    if activation_busy() then return false,'activation_busy' end
    if settings_gate.blocked() then return false,'settings_recovering' end
    if persistence then return M.poll_persistence(defer_notification) end
    if retiring then M.finish_retirement(retiring:identity()) end
    if persistence_blocked then return false,nil,'detached' end
    now = now or os.clock()
    if dirty_at == nil then return true end
    if not force and (now - dirty_at < 2 or now < retry_at) then return false end
    return M.save(defer_notification)
end

-- Deduplicate one already-successful flush within the supplied synchronous
-- callback only. This is a maintenance receipt, never an authority grant.
-- Standalone refreshes, pending/error replies and changed state still flush.
function M.with_flush_receipt(flush,body)
    flush_scope=flush_scope+1
    local scope=flush_scope
    local yes=flush()
    local live,used,snapshot=true,false,nil
    local function state()
        return {owner=persistence,epoch=persistence_epoch,retiring=retiring,
            session=M.session,data=M.data,path=M.path,baseline=M.baseline,
            generation=M.generation,revision=M.persisted_revision,edit=edit_revision,
            submit=M.submit,notify=M.on_change,decided=M.decided,client=M.is_client}
    end
    local function clean()
        return scope==flush_scope and not activating and not attaching
            and not settings_gate.blocked() and not persistence_blocked and not retiring
            and dirty_at==nil and not notify_pending and pending_scope==nil
            and M.decided and not M.is_client and not M.submit
            and M.state=='saved' and M.error==nil
    end
    if yes==true and clean() then
        snapshot=state();snapshot.text=M.serialize()
        if not snapshot.text then snapshot=nil end
    end
    local function consume()
        if not live or used then return false end
        used=true
        if not snapshot or not clean() then return false end
        local current=state()
        for k,v in pairs(current)do if snapshot[k]~=v then return false end end
        for k,v in pairs(snapshot)do if k~='text' and current[k]~=v then return false end end
        return M.serialize()==snapshot.text and clean()
    end
    local result=table.pack(pcall(body,consume))
    live=false;snapshot=nil
    if not result[1] then error(result[2],0) end
    return table.unpack(result,2,result.n)
end

function M.set_role(role, session)
    if activation_busy() then return false,'activation_busy' end
    if M.session~=session or M.is_client~=(role=='client') or role==nil or not M.decided then
        M.detach_persistence()
    end
    M.session=session
    M.decided, M.is_client = role ~= nil, role == 'client'
    M.submit, M.on_change = nil, nil
end

function M.get(key, value)
    local by_pal = key and M.data[key]
    if by_pal then return by_pal[value] end
end

function M.set(key, value, prio)
    if activation_busy() then return false,'activation_busy' end
    if settings_gate.blocked() then return false,'settings_recovering' end
    if not M.decided or not valid(key, value, prio) then return false end
    if M.submit then return M.submit('set', key, value, prio) end
    if persistence then return M.apply_set(key,value,prio) end
    if persistence_blocked then return false,'detached' end
    if not M.apply_set(key, value, prio) then return false end
    return M.flush(nil, true) -- a click must survive an immediate quit.
end

function M.apply_set(key, value, prio)
    if activation_busy() then return false,'activation_busy' end
    if settings_gate.blocked() then return false,'settings_recovering' end
    if M.is_client or not M.decided or not valid(key, value, prio)
        or (M.state == 'error' and dirty_at == nil) then return false end
    if persistence then local data=candidate_data();data[key]=data[key] or {};data[key][value]=prio
        return async_candidate(data,M.baseline,key,false) end
    if persistence_blocked then return false,'detached' end
    M.data[key] = M.data[key] or {}
    M.data[key][value] = prio
    changed(key)
    return true -- accepted in memory; state remains "saving" until flush succeeds.
end

function M.clear(key, value)
    if activation_busy() then return false,'activation_busy' end
    if settings_gate.blocked() then return false,'settings_recovering' end
    if not M.decided or not valid(key, value, nil, true) then return false end
    if M.submit then return M.submit('clear', key, value, nil) end
    if persistence then return M.apply_clear(key,value) end
    if persistence_blocked then return false,'detached' end
    if not M.apply_clear(key, value) then return false end
    return M.flush(nil, true)
end

function M.apply_clear(key, value)
    if activation_busy() then return false,'activation_busy' end
    if settings_gate.blocked() then return false,'settings_recovering' end
    if M.is_client or not M.decided or not valid(key, value, nil, true) then return false end
    if M.state == "error" and dirty_at == nil then return false end
    if persistence then
        local data=candidate_data();if data[key] then data[key][value]=nil;if next(data[key])==nil then data[key]=nil end end
        return async_candidate(data,M.baseline,key,false)
    end
    if persistence_blocked then return false,'detached' end
    local row = M.data[key]
    if not row or row[value] == nil then return true end
    row[value] = nil
    if next(row) == nil then M.data[key] = nil end
    changed(key)
    return true
end

-- Only before a never-managed Pal's first permission change on a fresh install.
function M.capture_baseline(key, capable, off)
    if activation_busy() then return false,'activation_busy' end
    if settings_gate.blocked() then return false,'settings_recovering' end
    if not M.baseline or not M.decided or M.is_client or M.data[key] ~= nil
        or not M.durable_key(key) or type(off) ~= 'table' then return false end
    local row = {}
    for value in pairs(capable) do
        if valid(key, value, 1) then
            if off[value] then row[value] = false else row[value] = 1 end
        end
    end
    if persistence then local data=candidate_data();data[key]=row;return async_candidate(data,M.baseline,key,true) end
    if persistence_blocked then return false,'detached' end
    M.data[key] = row
    changed(key)
    return M.save() -- don't fence until original choices are durable.
end

function M.effective(cfg, pal, work_name, work_value)
    if pal.key and work_value then
        local edit = M.get(pal.key, work_value)
        if edit ~= nil then return edit end
    end
    local overrides = cfg.pal_overrides or {}
    local entry = pal.name and overrides[pal.name] or nil
    if entry == nil and pal.species then entry = overrides[pal.species] end
    if type(entry) == 'table' and entry[work_name] ~= nil then return entry[work_name] end
    if M.baseline then return nil end -- unknown baseline must not become permission.
    return (cfg.work_priority or {})[work_name]
end

function M.cycle(current, dir)
    if current == nil then current = 1 end
    if dir < 0 then
        if current == false then return M.MAX end
        if current <= 1 then return false end
        return current - 1
    end
    if current == false then return 1 end
    if current >= M.MAX then return false end
    return current + 1
end

return M
