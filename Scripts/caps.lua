-- Group limits and a strictly separate session view for clients. A limit
-- switches its whole work type off once every limit on that type is reached
-- (scheduler.cap_state); new ones can be created again since 2026-10-27
-- (user's decision, DECISIONS). Item-specific control waits for producers.lua.
local log = require("log")
local file = require("datafile")
local settings_gate = require('settings_gate')
local workdefs = require("workdefs")
local M = { MAX_CEILING = 9999999, MAX_ID_LEN = 64, MAX_RULES = 500, ANY_GUILD = "*",
    LADDER = {100,250,500,1000,2000,3000,5000,7500,10000,15000,20000,30000,50000},
    data = {}, remote = nil, decided = false, is_client = false, state = "unavailable",
    generation = 0 }
local dirty, retry_at, failures, offered = false, 0, 0, false
local persistence,retiring,runtime_guild,persistence_guild
local network_runtime
local published_body,published_revision
local retirement_snapshot
local persistence_epoch,persistence_blocked=0,false
local activating,activation_poison,attaching=false,false,false
local function activation_busy()
    if activating then activation_poison=true;return true end
    return false
end
function M.detach_persistence()
    network_runtime=nil
    published_body,published_revision=nil,nil
    persistence_epoch=persistence_epoch+1
    local old=persistence
    if old then
        -- Capture before close makes matches() unavailable. Only exact accepted
        -- bytes may clear pending state after a confirmed original-owner drain.
        local ok,snapshot=pcall(function()
            for guild in pairs(M.data) do if guild~=runtime_guild then return end end
            local mapped={}
            if M.data[runtime_guild] then mapped[persistence_guild]=M.data[runtime_guild] end
            local body=M.serialize_snapshot(mapped)
            local text=M.serialize()
            if body and text and old:matches(body) then
                return {owner=old,epoch=persistence_epoch,text=text,session=M.session,
                    decided=M.decided,is_client=M.is_client,submit=M.submit}
            end
        end)
        retirement_snapshot=ok and snapshot or nil
    end
    persistence,runtime_guild,persistence_guild=nil,nil,nil
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
        dirty,retry_at,failures=false,0,0
        M.state,M.error,M.persisted_revision='saved',nil,status.revision
    end
    retirement_snapshot=nil
    retiring=nil
    return true
end
local config_rules = {}
local config_source,config_epoch=nil,0
function M.configure(cfg)
    config_epoch=config_epoch+1
    config_source=cfg
    config_rules = (cfg or {}).work_caps or {}
end
-- Bound plain defaults, including OFF masks. Read the property afresh so replacing
-- work_caps cannot leave a guard validating an obsolete table.
local function defaults_text(cfg)
    if cfg==nil then return '' end
    if type(cfg)~='table' or getmetatable(cfg) then return nil end
    local rules=cfg.work_caps or {}
    if type(rules)~='table' or getmetatable(rules) then return nil end
    local rows,n={},0
    for work,items in pairs(rules)do
        if type(work)~='string' or not workdefs.is_known(work)
            or type(items)~='table' or getmetatable(items) then return nil end
        for item,value in pairs(items)do
            n=n+1;if n>M.MAX_RULES then return nil end
            if type(item)~='string' or #item>M.MAX_ID_LEN or item==''
                or item:find('[^%w_%.%-]') then return nil end
            if value~=false and (type(value)~='number' or math.tointeger(value)==nil
                or value<1 or value>M.MAX_CEILING) then return nil end
            rows[#rows+1]=work..'|'..item..'|'..(value==false and 'OFF' or tostring(value))
        end
    end
    table.sort(rows);return table.concat(rows,'\n')
end

function M.valid_rule(work, item, ceiling)
    if not workdefs.is_known(work) then return false, "unknown work type" end
    if type(item) ~= "string" or item == "" or #item > M.MAX_ID_LEN
        or item:find("[^%w_%.%-]") then return false, "invalid item id" end
    local n = math.tointeger(tonumber(ceiling))
    if not n or n < 1 or n > M.MAX_CEILING then return false, "ceiling out of range" end
    return true, nil, n
end

local function guild_ok(guild)
    return type(guild) == "string" and #guild > 0 and #guild <= 160
        and not guild:find("[^%w%-%*]")
end

local function put(data, guild, work, item, ceiling)
    data[guild] = data[guild] or {}
    data[guild][work] = data[guild][work] or {}
    data[guild][work][item] = ceiling
end

local function decode(text)
    local result = { data = {}, count = 0 }
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\r$", "")
        if line ~= "" and line:sub(1,1) ~= "#" then
            local guild,work,item,amount = line:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
            if not guild then
                work,item,amount = line:match("^([^|]+)|([^|]+)|([^|]+)$")
                guild = M.ANY_GUILD
            end
            local ok, _, clean = M.valid_rule(work, item, amount == "OFF" and 1 or amount)
            if amount == "OFF" then clean = false end
            if not guild_ok(guild) or not ok then return nil, "invalid ceiling row" end
            if result.data[guild] and result.data[guild][work]
                and result.data[guild][work][item] ~= nil then return nil, "duplicate ceiling row" end
            put(result.data, guild, work, item, clean)
            result.count = result.count + 1
        end
    end
    return result
end

-- Pure parser for recovered snapshot bytes. No IO, remote-view replacement or
-- saved-state change. Scope/authority and generation remain caller obligations.
function M.decode_snapshot(text)
    if type(text) ~= 'string' or #text > 8 * 1024 * 1024 then
        return nil, 'invalid ceiling snapshot size/type'
    end
    return decode(text)
end

function M.load(path)
    if settings_gate.blocked() then return 0,'settings_recovering' end
    if activation_busy() then return 0 end
    M.detach_persistence();persistence_blocked=false;M.persisted_revision=nil
    M.path, M.data, M.remote = path, {}, nil
    M.generation, M.error, dirty, retry_at, failures = 0, nil, false, 0, 0
    local decoded, meta = file.read(path, decode)
    if not decoded then
        M.state, M.error = meta.state, meta.error
        if M.error then log.error("limits unavailable: " .. M.error) end
        return 0
    end
    M.data, M.generation, M.state = decoded.data, meta.generation, "saved"
    if meta.recovered then
        dirty, M.state = true, "saving"
        log.warn("recovered limits from " .. meta.source)
    end
    return decoded.count
end

-- Copy current durable rules into text without IO, notifications or saved-state
-- changes. Remote snapshots remain separate and are never serialized here.
-- Raw records, not all(cfg,guild): retain wildcard provenance and OFF masks.
-- Formatting alone establishes neither scope nor durable completion.
function M.serialize_snapshot(data)
    local rows = {}
    for guild, works in pairs(data) do
        for work, items in pairs(works) do
            for item, ceiling in pairs(items) do
                if not guild_ok(guild) or not M.valid_rule(work, item, ceiling == false and 1 or ceiling) then
                    return nil, "invalid ceiling in memory; previous save retained"
                end
                local amount = ceiling == false and "OFF" or tostring(math.tointeger(ceiling))
                rows[#rows+1] = string.format("%s|%s|%s|%s\n",guild,work,item,amount)
            end
        end
    end
    table.sort(rows)
    local payload = "# Legacy work-type groups: may stop unrelated products of the same suitability.\n"
        .. "# guild|work|item|ceiling (OFF masks an inherited group rule for this guild)\n" .. table.concat(rows)
    return payload
end

function M.serialize()
    return M.serialize_snapshot(M.data)
end

local function only_guild(data,guild)
    if type(data)~='table' then return false end
    for key in pairs(data) do if key~=guild or key==M.ANY_GUILD then return false end end
    return true
end
-- Mathematical identity only, NOT an ownership/authority proof. The caller must
-- explicitly supply a proven runtime alias; the injected session still performs
-- fresh authorization against its canonical context at attachment and admission.
local function same_guild(runtime,canonical)
    if type(canonical)~='string' or #canonical~=32 or canonical:find('[^0-9a-f]')
        or canonical==string.rep('0',32) or type(runtime)~='string' then return false end
    if runtime==canonical then return true end
    if #runtime>160 then return false end
    local a,b,c,d=runtime:match('^(%-?%d+)%-(%-?%d+)%-(%-?%d+)%-(%-?%d+)$')
    if not a then return false end
    local parts={}
    for i,part in ipairs({a,b,c,d}) do
        local n=math.tointeger(tonumber(part))
        if not n or n < -2147483648 or n > 4294967295 or tostring(n)~=part then return false end
        parts[i]=string.format('%08x',n & 0xffffffff)
    end
    return table.concat(parts)==canonical
end
local function persistence_snapshot(data,runtime,canonical)
    if not only_guild(data,runtime) then return nil,'foreign_guild' end
    -- Temporary serialization view only: never rename keys in the runtime table.
    -- Reject every other key, including an equivalent alias or canonical collision.
    local mapped={}
    if data[runtime] then mapped[canonical]=data[runtime] end
    return M.serialize_snapshot(mapped)
end
-- attach_persistence{..., runtime_guild=<explicitly proven legacy guild key>}
-- keeps data/lookups/edit callbacks in runtime form and compares/submits only
-- mapped canonical bytes. Omit it for canonical runtime data; detach forgets it.
local function attach_persistence(o,activate)
    local captured={}
    for k,v in pairs(o) do captured[k]=v end
    if type(o.context)=="table" then captured.context={};for k,v in pairs(o.context) do captured.context[k]=v end end
    if type(o.recovery)=="table" then captured.recovery={};for k,v in pairs(o.recovery) do captured.recovery[k]=v end end
    o=captured
    if type(o)~='table' or o.enabled~=true or persistence or retiring or not M.decided or M.is_client
        or M.submit or M.state~='saved' or dirty or type(o.context)~='table'
        or o.context.stream~='limits' then return false,'unavailable' end
    -- Omission preserves the original canonical-only attachment contract.
    local runtime=o.runtime_guild
    if activate and (runtime==nil or type(o.authorize)~='function') then return false,'activation_proof_required' end
    if runtime==nil then runtime=o.context.guild end
    local canonical=o.context.guild
    if not same_guild(runtime,canonical) or not only_guild(M.data,runtime) then return false,'foreign_guild' end
    local epoch=persistence_epoch
    local before=M.serialize()
    local current=persistence_snapshot(M.data,runtime,canonical)
    local candidate
    local ok,recovered=pcall(function()
        if not only_guild(o.recovery.settings.data,o.context.guild) then return end
        if activate then
            -- A typed limits result contains integer ceilings/OFF, never string
            -- coercions, baseline metadata, metatables or foreign empty groups.
            local settings=o.recovery.settings
            if getmetatable(settings) or getmetatable(settings.data) then return end
            for k in pairs(settings) do if k~='data' and k~='count' then return end end
            local count=0
            candidate={}
            for _,works in pairs(settings.data) do
                if type(works)~='table' or getmetatable(works) or next(works)==nil then return end
                candidate[runtime]={}
                for work,items in pairs(works) do
                    if not workdefs.is_known(work) or type(items)~='table' or getmetatable(items) or next(items)==nil then return end
                    candidate[runtime][work]={}
                    for item,n in pairs(items) do
                        if n~=false and math.type(n)~='integer' then return end
                        if not M.valid_rule(work,item,n==false and 1 or n) then return end
                        candidate[runtime][work][item]=n;count=count+1
                    end
                end
            end
            if math.type(settings.count)~='integer' or settings.count~=count or count>M.MAX_RULES then return end
        end
        return M.serialize_snapshot(o.recovery.settings.data)
    end)
    if not ok or not current or not recovered or (not activate and current~=recovered) then return false,'recovery_mismatch' end
    local function fresh()
        local c={};for k,v in pairs(o.context) do c[k]=v end
        return o.authorize(c,runtime)==true
    end
    local function unchanged()
        return not persistence and not retiring and persistence_epoch==epoch and M.decided and not M.is_client
            and not M.submit and M.state=='saved' and not dirty and not activation_poison
            and M.serialize()==before and persistence_snapshot(M.data,runtime,canonical)==current
    end
    if activate and (not fresh() or not unchanged()) then return false,'activation_unauthorized' end
    local p,why=require('settings_writer').new{enabled=true,session=o.session,context=o.context,
        recovery=o.recovery,body=activate and recovered or current,recovery_body=recovered}
    if not p then return false,why end
    if activate then
        -- Retain the writer before crossing the final caller callback; even a
        -- thrown return must not discard an accepted session/native owner.
        local authorized,yes=pcall(fresh)
        local checked,stable=pcall(unchanged)
        if not authorized or not yes or not checked or not stable then
            retiring=p;p:close();return false,'stale_activation'
        end
        M.data=candidate
    end
    if not activate and (persistence or retiring or persistence_epoch~=epoch or not M.decided or M.is_client or M.submit
        or M.serialize()~=before or persistence_snapshot(M.data,runtime,canonical)~=current) then
        p:close();retiring=p;return false,'stale_attachment'
    end
    persistence,persistence_blocked=p,false;M.persisted_revision=o.recovery.revision
    runtime_guild,persistence_guild=runtime,canonical
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

-- Explicit cutover only. The caller supplies take_recovered's typed envelope,
-- a ready SettingsSession, and authorize(context,runtime_guild), which must
-- freshly prove BOTH current authority and this exact runtime alias. No native
-- setup, writes, notifications or main activation occur here. An enabled failed
-- attempt blocks legacy fallback until an explicit load establishes a new owner.
function M.activate_recovered(o)
    if activating then activation_poison=true;return false,'attachment_busy' end
    if attaching then return false,'attachment_busy' end
    if type(o)~='table' or o.enabled~=true then return false,'disabled' end
    if persistence or retiring then return false,'unavailable' end -- retain old owner
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

function M.poll_persistence()
    if settings_gate.blocked() then return false,'settings_recovering' end
    if activation_busy() then return false,'activation_busy' end
    if retiring then M.finish_retirement(retiring:identity()) end
    local p,epoch,runtime,canonical=persistence,persistence_epoch,runtime_guild,persistence_guild
    if not p or not M.decided or M.is_client or M.submit then return false,'unavailable' end
    local r=p:poll()
    if persistence~=p or persistence_epoch~=epoch or not M.decided or M.is_client or M.submit then return false,'stale' end
    if r.state~='saved' then
        M.state=(r.state=='saving' or r.state=='pending') and 'saving' or 'error'
        M.error=M.state=='error' and (r.reason or r.state) or nil
        return false,r.state
    end
    if persistence_snapshot(M.data,runtime,canonical)~=r.body then M.state,M.error='error','snapshot_changed';return false,'snapshot_changed' end
    local notify=dirty
    M.state,M.error,M.persisted_revision='saved',nil,r.revision
    published_body,published_revision=r.body,r.revision
    dirty,retry_at,failures=false,0,0
    if notify and M.on_change then
        local ok,why=pcall(M.on_change);if not ok then log.warn('limit notification failed: '..tostring(why)) end
    end
    if persistence~=p or persistence_epoch~=epoch or M.state~='saved'
        or persistence_snapshot(M.data,runtime,canonical)~=r.body then return false,'changed_during_notification' end
    return true
end
local function candidate_data()
    local out={};for guild,works in pairs(M.data) do out[guild]={};for work,items in pairs(works) do
        out[guild][work]={};for item,amount in pairs(items) do out[guild][work][item]=amount end
    end end;return out
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
function M.publication_guard(expected_body,expected_revision,cfg)
    if activation_busy() or attaching or settings_gate.blocked() or not M.decided
        or M.is_client or M.submit or retiring or persistence_blocked then return nil end
    local p,epoch,session=persistence,persistence_epoch,M.session
    local defaults_epoch=config_epoch
    cfg=cfg or config_source
    local defaults=defaults_text(cfg)
    if defaults==nil then return nil end
    local text=M.serialize()
    if type(text)~='string' then return nil end
    local body,revision=published_body,published_revision
    if expected_body~=nil and (not p or body~=expected_body or revision~=expected_revision) then return nil end
    local function current()
        local defaults_now=defaults_text(cfg)
        local text_now=M.serialize()
        local body_now=p and persistence_snapshot(M.data,runtime_guild,persistence_guild) or nil
        if activating or attaching or settings_gate.blocked() or persistence~=p
            or persistence_epoch~=epoch or M.session~=session or not M.decided
            or M.is_client or M.submit or retiring or persistence_blocked
            or text_now~=text or config_epoch~=defaults_epoch
            or defaults_now~=defaults then return false end
        if not p then return true end
        return M.state=='saved' and M.error==nil and M.persisted_revision==revision
            and published_revision==revision and published_body==body
            and type(body)=='string' and body_now==body
    end
    if not current() then return nil end
    return current
end

-- Internal-only query; successful native completion is not announced until
-- normal module maintenance has published that exact durable snapshot.
function M.receipt_status(receipt)
    if activation_busy() or attaching or settings_gate.blocked()
        or not M.decided or M.is_client or M.submit then return {state='unavailable'} end
    local p,epoch,runtime,canonical=persistence,persistence_epoch,runtime_guild,persistence_guild
    if not p or retiring or persistence_blocked then return {state='stale'} end
    local r=p:receipt_status(receipt)
    if persistence~=p or persistence_epoch~=epoch or not M.decided or M.is_client
        or M.submit or settings_gate.blocked() then return {state='stale'} end
    if r.state=='saved' then
        if persistence_snapshot(M.data,runtime,canonical)~=r.body then
            return {state='error',reason='snapshot_changed'}
        end
        if M.state~='saved' or M.error~=nil or M.persisted_revision~=r.revision then
            return {state='saving',reason='awaiting_module_commit'}
        end
    end
    return r
end

local function async_candidate(data,guild)
    local p,epoch,runtime,canonical=persistence,persistence_epoch,runtime_guild,persistence_guild
    local before=M.serialize()
    if not p or runtime~=guild or not only_guild(data,runtime) then return false,'foreign_guild' end
    local mapped_before=persistence_snapshot(M.data,runtime,canonical)
    if not mapped_before or not p:matches(mapped_before) then return false,'snapshot_changed' end
    local body,why=persistence_snapshot(data,runtime,canonical);if not body then return false,why end
    local r=p:submit(body,false)
    if persistence~=p or persistence_epoch~=epoch or not M.decided or M.is_client or M.submit then return false,'stale' end
    if M.serialize()~=before or persistence_snapshot(M.data,runtime,canonical)~=mapped_before then
        M.detach_persistence();M.state,M.error='error','snapshot_changed';return false,'snapshot_changed'
    end
    if r.state=='pending' then
        M.data=data;dirty=true;M.state,M.error='saving',nil
        return false,'pending',r.receipt
    end
    if r.state~='rejected' then M.state,M.error='error',r.reason or r.state end
    return false,r.state
end

function M.save()
    if settings_gate.blocked() then return false,'settings_recovering' end
    if activation_busy() then return false,'activation_busy' end
    if persistence then return M.poll_persistence() end
    if persistence_blocked then return false,'detached' end
    if not M.path or not M.decided or M.is_client or M.submit then return false end
    if M.state == "error" and not dirty then return false end
    local payload, why = M.serialize()
    if not payload then M.state, M.error = "error", why; return false end
    local ok, err, gen = file.write(M.path, payload, M.generation, decode)
    if not ok then
        dirty, failures, M.state = true, failures+1, "error"
        retry_at = os.clock() + math.min(60, 2^math.min(failures,6))
        if M.error ~= err then log.warn("limits not saved: " .. tostring(err)) end
        M.error = err
        return false
    end
    M.state, M.error, M.generation = "saved", nil, gen
    dirty, retry_at, failures = false, 0, 0
    if M.on_change then
        local called, why = pcall(M.on_change)
        if not called then log.warn("limit notification failed: " .. tostring(why)) end
    end
    return true
end

function M.flush(now)
    if settings_gate.blocked() then return false,'settings_recovering' end
    if activation_busy() then return false,'activation_busy' end
    if persistence then return M.poll_persistence() end
    if retiring then M.finish_retirement(retiring:identity()) end
    if persistence_blocked then return false,'detached' end
    if not dirty then return true end
    if (now or os.clock()) < retry_at then return false end
    return M.save()
end

function M.set_role(role, session)
    local changed = M.session ~= session or M.is_client ~= (role == "client") or role == nil
    -- Repeating the same decided role is a refresh, not an owner transition.
    -- Startup's delayed role checks must not retire an attached durable writer.
    if changed or not M.decided then M.detach_persistence() end
    M.decided, M.is_client = role ~= nil, role == "client"
    M.submit, M.on_change, M.session = nil, nil, session
    if changed then
        M.remote, M.remote_scope = nil, nil
        M.remote_state, M.remote_error = "connecting", nil
    end
end

function M.view_status()
    if settings_gate.status() == 'restart_required' then
        return 'unavailable','Settings locked after a session change or save failure. Restart the game to edit priorities and limits.'
    end
    if settings_gate.blocked() then return 'unavailable','Settings recovery is in progress' end
    if not M.decided then return "unavailable", "Session role is not established" end
    if M.is_client then return M.remote_state or "connecting", M.remote_error end
    return M.state, M.error
end

function M.rule_kind(work, item, guild)
    local source = M.is_client and (M.remote or {}) or M.data
    local own, shared = source[guild], source[M.ANY_GUILD]
    if (own and own[work] and own[work][item] ~= nil)
        or (not M.is_client and config_rules[work] and config_rules[work][item] ~= nil)
        or (shared and shared[work] and shared[work][item] ~= nil) then return "legacy" end
    return "item"
end

-- Any valid work and item can have a group limit (locked 2026-10-11, open
-- again 2026-10-27: 0.4.1 users could add them and nobody asked for the lock).
-- rule_kind still tells an existing rule ("legacy") from a new one ("item");
-- both are stored and enforced the same way, as a group.
function M.support(work,item,guild)
    local ok, why = M.valid_rule(work, item, 1)
    if not ok then return false, why end
    return true, "Group limit: affects the entire work type"
end

function M.set(work,item,ceiling,guild)
    if settings_gate.blocked() then return false,'settings_recovering' end
    if activation_busy() then return false,'activation_busy' end
    if not M.decided then return false end
    if M.submit then return M.submit("set",work,item,ceiling,guild) end
    return M.apply_set(work,item,ceiling,guild)
end

function M.clear(work,item,guild)
    if settings_gate.blocked() then return false,'settings_recovering' end
    if activation_busy() then return false,'activation_busy' end
    if not M.decided then return false end
    if M.submit then return M.submit("clear",work,item,0,guild) end
    return M.apply_clear(work,item,guild)
end

function M.apply_set(work,item,ceiling,guild)
    if settings_gate.blocked() then return false,'settings_recovering' end
    if activation_busy() then return false,'activation_busy' end
    local ok, why, clean = M.valid_rule(work,item,ceiling)
    if not ok or not guild_ok(guild) or guild == M.ANY_GUILD
        or not M.decided or M.is_client then M.error=why or "scope unavailable"; return false end
    if M.state == "error" and not dirty then return false end
    local supported, reason = M.support(work,item,guild)
    if not supported then M.error=reason; log.say(reason); return false,'unsupported_limit' end
    if persistence then local data=candidate_data();put(data,guild,work,item,clean);return async_candidate(data,guild) end
    if persistence_blocked then return false,'detached' end
    put(M.data,guild,work,item,clean)
    dirty, M.state = true, "saving"
    local saved = M.save()
    return saved, not saved and "applied_unsaved" or nil
end

function M.apply_clear(work,item,guild)
    if settings_gate.blocked() then return false,'settings_recovering' end
    if activation_busy() then return false,'activation_busy' end
    if not M.decided or M.is_client or not guild_ok(guild)
        or guild == M.ANY_GUILD or not M.valid_rule(work,item,1) then return false end
    if M.state == "error" and not dirty then return false end
    local row = M.data[guild] and M.data[guild][work]
    local shared = M.data[M.ANY_GUILD]
    local inherited = (shared and shared[work] and shared[work][item] ~= nil)
        or (config_rules[work] and config_rules[work][item] ~= nil)
    if (not row or row[item] == nil) and not inherited then
        M.error = "No active legacy rule for this guild"
        return false,'no_active_legacy_rule'
    end
    if persistence then
        local data=candidate_data()
        if inherited then put(data,guild,work,item,false)
        else
            data[guild][work][item]=nil
            if next(data[guild][work])==nil then data[guild][work]=nil end
            if next(data[guild])==nil then data[guild]=nil end
        end
        return async_candidate(data,guild)
    end
    if persistence_blocked then return false,'detached' end
    if inherited then
        -- Removing an override must not expose a lower, inherited ceiling and
        -- announce a deletion that never happened. The mask is guild-local;
        -- another guild's inherited rule and the original config stay intact.
        put(M.data,guild,work,item,false)
    else
        row[item] = nil
        if next(row) == nil then M.data[guild][work] = nil end
        if next(M.data[guild]) == nil then M.data[guild] = nil end
    end
    dirty, M.state = true, "saving"
    local saved = M.save()
    return saved, not saved and "applied_unsaved" or nil
end

function M.replace_all(rows, session, guild)
    if not M.is_client or session ~= M.session or not guild_ok(guild)
        or type(rows) ~= "table" or #rows > M.MAX_RULES then return false end
    local view = {}
    for _, row in ipairs(rows) do
        local ok, _, clean = M.valid_rule(row.work,row.item,row.amount)
        if not ok or (row.guild ~= nil and row.guild ~= guild) then return false end
        if view[guild] and view[guild][row.work]
            and view[guild][row.work][row.item] ~= nil then return false end
        put(view,guild,row.work,row.item,clean)
    end
    M.remote, M.remote_scope = view, { session=session, guild=guild }
    return #rows
end

function M.offer_adopt(guild)
    if offered or not guild_ok(guild) or not M.data[M.ANY_GUILD] then return false end
    offered = true
    log.say("Shared legacy group limits exist. '!pwp adopt' moves them to this guild; check other guilds before doing so.")
    return true
end

function M.adopt_wildcard(guild)
    if settings_gate.blocked() then return 0,'settings_recovering' end
    if activation_busy() then return 0 end
    if persistence or persistence_blocked then return 0 end -- no implicit scoped migration
    if not M.decided or M.is_client or not guild_ok(guild) or guild == M.ANY_GUILD then return 0 end
    local shared, n = M.data[M.ANY_GUILD], 0
    if not shared then return 0 end
    for work, items in pairs(shared) do
        for item, ceiling in pairs(items) do
            if not (M.data[guild] and M.data[guild][work] and M.data[guild][work][item] ~= nil) then
                put(M.data,guild,work,item,ceiling)
                n=n+1
            end
        end
    end
    M.data[M.ANY_GUILD] = nil
    dirty, M.state = true, "saving"
    if not M.save() then return 0 end
    return n
end

function M.all(cfg,guild)
    local out = {}
    local function layer(works)
        for work, items in pairs(works or {}) do
            out[work] = out[work] or {}
            for item, ceiling in pairs(items) do
                if ceiling == false then out[work][item] = nil else out[work][item] = ceiling end
            end
        end
    end
    if not M.is_client then layer((cfg or {}).work_caps) end
    local source = M.is_client and (M.remote or {}) or M.data
    layer(source[M.ANY_GUILD])
    if guild and guild ~= M.ANY_GUILD then layer(source[guild]) end
    for work, items in pairs(out) do if next(items) == nil then out[work] = nil end end
    return out
end

function M.for_work(cfg,work,guild)
    local items = M.all(cfg,guild)[work]
    if items and next(items) then return items end
end

function M.any(cfg)
    local source = M.is_client and (M.remote or {}) or M.data
    if next(source) ~= nil then return true end
    return not M.is_client and type((cfg or {}).work_caps) == "table" and next(cfg.work_caps) ~= nil
end

return M
