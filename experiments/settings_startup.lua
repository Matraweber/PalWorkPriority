-- Default-off settings startup coordinator (stream defaults to limits). Not imported by production main.
-- Caller supplies a verified native backend/root and fresh world/guild authority.
-- verify_migration must prove durable backup AND equality of the entire current
-- legacy recovery set while legacy writers are fenced. This module does no FS IO
-- and cannot establish those facts from a boolean or an old proposal itself.
-- priorities additionally requires owns_key(key, copied_context) to freshly prove
-- each durable Pal key belongs to this exact scope, and
-- verify_coverage(copied_context, recovered_copy) to prove actual camp baseline
-- coverage. Only literal true is accepted, with fresh authority before/after.
-- Header metadata and row counts are NOT coverage proof. The coverage callback
-- receives isolated copies and MUST leave their context, envelope and typed
-- settings unchanged. Mutation rejects proof, even on true (a provider cannot
-- fill missing baseline rows in its copy to certify different recovered bytes).
-- Store receives a captured, context-bound owns_key wrapper, never the raw proof.
-- Missing coverage is a recovery failure (retain/fence/drain), not permission.
-- activate/detach must operate on the ORIGINAL bound attachment. detach must
-- confirm that no writer can admit further edits; never detach a newer owner.
-- finalize must clear that same Lua attachment only after confirmed native drain.
-- Serialize calls on the original control thread. drain is explicitly blocking,
-- outside DLL teardown; retain this object until it returns true.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/settings_startup.lua$'))
local Settings=dofile(root..'/settings_session.lua')
local Scope=dofile(root..'/save_scope.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local Gate=require('settings_gate')
local M={}
local function copy(t)
    local r={};for k,v in pairs(t) do r[k]=v end;return r
end
-- Walk the trusted, acyclic original shape. Reject extra fields/metatables and
-- typed-value changes without invoking any callback-supplied metamethods.
local function unchanged(original,candidate)
    if type(original)~=type(candidate) then return false end
    if type(original)~='table' then
        return original==candidate and (type(original)~='number' or math.type(original)==math.type(candidate))
    end
    if getmetatable(candidate)~=nil then return false end
    for k,v in next,original do
        if not unchanged(v,rawget(candidate,k)) then return false end
    end
    for k in next,candidate do if rawget(original,k)==nil then return false end end
    return true
end
function M.new(o)
    if type(o)~='table' or o.enabled~=true then return nil,'disabled' end
    assert(o.backend and o.backend.contract=='PWP-DRAINING-DEV-1','draining backend required')
    -- Optional coordinated gate has the same opaque-token contract. Capture its
    -- functions; no child may release the parent's global startup barrier.
    local gate=Gate
    if o.gate~=nil then
        assert(type(o.gate)=='table' and getmetatable(o.gate)==nil,'invalid coordinated gate')
        gate={}
        for _,name in ipairs({'acquire','held','release'})do
            assert(type(o.gate[name])=='function','incomplete coordinated gate')
            gate[name]=o.gate[name]
        end
    end
    local stream=o.stream
    if stream==nil then stream='limits' end
    assert(stream=='limits' or stream=='priorities','unsupported settings stream')
    local scope=Scope.new(o.storage,o.guild,stream)
    assert(type(o.camp)=='string' and #o.camp>0 and #o.camp<=256,'camp required')
    local alias=o.runtime_guild
    assert(type(alias)=='string' and #alias>0 and #alias<=160,'explicit runtime guild required')
    local authorize,verify,activate,detach,finalize=o.authorize,o.verify_migration,o.activate,o.detach,o.finalize
    assert(type(authorize)=='function' and type(activate)=='function' and type(detach)=='function'
        and type(finalize)=='function','callbacks required')
    assert(verify==nil or type(verify)=='function','migration verifier')
    local owns,coverage=o.owns_key,o.verify_coverage
    assert(stream~='priorities' or type(owns)=='function','priorities ownership proof required')
    assert(coverage==nil or type(coverage)=='function','coverage verifier')
    local body=o.migration_body
    local codec=Codec.new{storage=scope.storage,guild=scope.guild,stream=stream,max_payload_bytes=o.max_payload_bytes}
    assert(body==nil or codec.encode(body),'canonical scoped migration body required')
    local context={scope=scope.key,storage=scope.storage,guild=scope.guild,stream=stream,
        session=o.session,incarnation=o.incarnation,epoch=o.epoch,camp=o.camp,authority=true}
    local state,reason,busy,revoked='idle',nil,false,false
    local opening,activation_attempted,detached,close_attempted,drain_attempted=false,false,false,false,false
    local init_attempted,drained=false,false
    local journal_may_exist,activation_completed=false,false
    local session
    local gate_token
    local function fresh()
        if revoked or gate_token and not gate.held(gate_token) then return false end
        local ok,yes=pcall(authorize,copy(context),alias)
        return ok and yes==true and not revoked and (not gate_token or gate.held(gate_token))
    end
    session=Settings.new{enabled=true,storage=scope.storage,guild=scope.guild,stream=stream,
        session=context.session,incarnation=context.incarnation,epoch=context.epoch,
        backend_kind='PWP-DRAINING-DEV-1',backend=o.backend,lease=o.lease,clock=o.clock,
        timeout=o.timeout,max_payload_bytes=o.max_payload_bytes,authorize=fresh}
    local function call(name,...)
        return session[name](session,copy(context),...)
    end
    local function revoke(why)
        revoked=true;reason=reason or why;state='retiring'
    end
    local proving=false
    local function bound_owns(key,c)
        if proving then revoke('reentrant ownership proof');return false end
        if type(c)~='table' or getmetatable(c) then revoke('ownership context rejected');return false end
        for k,v in pairs(context) do
            -- Writer identities encode storage in scope and omit this redundant
            -- field. A supplied storage must still match; providers always get it.
            if c[k]~=v and not (k=='storage' and c[k]==nil) then
                revoke('ownership context rejected');return false
            end
        end
        local was_busy=busy
        busy,proving=true,true
        local ok,yes=pcall(function()
            if not fresh() then return false end
            return owns(key,copy(context))==true and fresh()
        end)
        busy,proving=was_busy,false
        if not ok or yes~=true then revoke('ownership proof rejected');return false end
        return true
    end
    local function retire_owner()
        -- Even an activation whose return was lost may have installed a writer.
        if activation_attempted and not detached then
            local ok,yes=pcall(detach,copy(context))
            detached=ok and yes==true
        elseif not activation_attempted then detached=true end
        if opening and not close_attempted then
            close_attempted=true
            pcall(call,'close') -- false normally means cleanup still outstanding
            -- A lease refusal/construction failure creates no queue. This is
            -- positive absence from our own controller, not an unknown reply.
            local ok,s=pcall(call,'status')
            if ok and type(s)=='table' and s.drain_state=='unavailable' then opening=false end
        end
    end
    local function guard(fn)
        return function(...)
            if busy then revoke('reentrant startup');return false,'busy' end
            busy=true
            local out=table.pack(pcall(fn,...))
            if not out[1] then revoke('startup callback failed') end
            if revoked and state~='closed' then retire_owner() end
            busy=false
            if not out[1] or revoked and state~='closed' then return false,reason end
            return table.unpack(out,2,out.n)
        end
    end
    local m={}
    m.start=guard(function()
        if state~='idle' then return false,'already started' end
        if not fresh() then revoke('authority unavailable');return false end
        gate_token=gate.acquire()
        if not gate_token then revoke('settings fence unavailable');return false end
        journal_may_exist=true -- absence is unknown until recovery positively proves it
        opening=true;state='recovering' -- retain owner before any backend call
        if call('open')~=true or not fresh() then revoke('open unavailable');return false end
        return true
    end)
    m.poll=guard(function()
        if revoked or state=='idle' or state=='closed' then return false,'inactive' end
        if not fresh() then revoke('authority unavailable');return false end
        call('poll')
        if not fresh() then revoke('authority unavailable');return false end
        local s=call('status')
        if type(s)~='table' then revoke('status unavailable');return false end
        if s.state=='initialization_required' then
            journal_may_exist=false -- positive missing; no initialization dispatched yet
            if init_attempted or body==nil or not verify then revoke('migration proof required');return false end
            init_attempted=true -- verification/admission is one attempt, even on lost return
            -- Existing recovery never calls this verifier or touches legacy bytes.
            if verify(copy(context),body)~=true or not fresh() then revoke('migration proof rejected');return false end
            journal_may_exist=true -- lost admission result cannot license legacy writes
            local receipt=call('initialize',body)
            if type(receipt)~='table' or receipt.scope~=context.scope or receipt.session~=context.session
                or math.type(receipt.revision)~='integer' or receipt.revision<1 or not fresh() then
                revoke('initialization unavailable');return false
            end
            state='initializing';return true,state
        end
        if s.recovered and not activation_attempted then
            journal_may_exist=true
            local recovered=call('take_recovered')
            if type(recovered)~='table' or not fresh() then revoke('recovery unavailable');return false end
            if stream=='priorities' then
                if not coverage or not fresh() then revoke('coverage proof required');return false end
                -- Decode anew rather than share any nested recovery/settings rows.
                local recovered_copy=copy(recovered)
                local encoded=assert(codec.encode(assert(require('store').serialize_snapshot(
                    recovered.settings.data,recovered.settings.baseline))))
                recovered_copy.settings=assert(codec.decode(encoded))
                local coverage_context=copy(context)
                if coverage(coverage_context,recovered_copy)~=true or not fresh()
                    or not unchanged(context,coverage_context) or not unchanged(recovered,recovered_copy) then
                    revoke('coverage proof rejected');return false
                end
            end
            -- Limits need no per-Pal baseline; priorities have explicit proof above.
            if call('register_camp',true)~=true or call('ready')~=true or not fresh() then
                revoke('recovery not ready');return false
            end
            activation_attempted=true
            local yes=activate{enabled=true,context=copy(context),session=session,
                recovery=recovered,runtime_guild=alias,owns_key=stream=='priorities' and bound_owns or nil,
                authorize=function(c,a)
                    for k,v in pairs(context) do if c[k]~=v then return false end end
                    return a==alias and fresh()
                end}
            if yes~=true or not fresh() then revoke('activation unavailable');return false end
            if not gate.release(gate_token) then revoke('settings fence lost');return false end
            gate_token=nil
            activation_completed=true
            state='active';return true,state
        end
        if s.state=='recovering' or s.state=='initializing' or s.state=='saved' or s.state=='saving' then
            return true,state
        end
        revoke('session unavailable');return false
    end)
    m.retire=guard(function()
        if state=='closed' then return true end
        revoke('retired');return false -- nonblocking; not a durability claim
    end)
    m.drain=guard(function()
        if state=='closed' then return true end
        revoke('retired');retire_owner()
        if not detached then return false end
        if not opening then
            if gate_token and not gate.release(gate_token) then return false end
            gate_token=nil;state='closed';return true
        end
        if not drained then
            if drain_attempted then return false end
            drain_attempted=true
            if call('drain')~=true then return false end
            drained=true
        end
        if activation_attempted and finalize(copy(context))~=true then return false end
        if journal_may_exist and not activation_completed then
            state='recovery_required';return false -- keep both writers fenced until fresh startup recovery
        end
        if gate_token and not gate.release(gate_token) then return false end
        gate_token=nil
        state='closed';return true
    end)
    function m:status()
        return {state=state,reason=reason,initialization_attempted=init_attempted,
            activation_attempted=activation_attempted,detached=detached,
            queue_owned=opening,
            owner_retained=opening and not drained and state~='closed'}
    end
    -- Feed this to the migration verifier, not Gate.blocked(): another owner's
    -- fence is not proof that THIS import still owns the protected interval.
    function m:fenced()
        return not revoked and gate_token~=nil and gate.held(gate_token)
    end
    return m
end
return M
