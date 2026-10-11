-- Default-off, one-owner sidecar in the SAME Lua VM as settings_startup.
-- Install early, before InitGameState. No native setup, engine discovery, timers,
-- wrapper retention, or second Lua state. All injected calls must be serialized,
-- synchronous and non-yielding. Drain is blocking: integration owns hook safety.
-- new{enabled=true,report=optional function(scalar_record)}; colon instance APIs:
-- :install(api), :epoch(), :admit(verify_epoch), :attach(startup,authority),
-- :close(reason), :status(). Proof revoke/status are dot functions; owner methods
-- are colon functions. Repeated successful admission is idempotent (no reverify).
-- admit requires fresh literal-true proof and an observed complete init route;
-- epoch exposes only the actual admitted lifecycle token, never a candidate.
-- attach BEFORE starting the coordinator; rejected attachments remain caller-owned.
-- One admission and one owner for this sidecar's lifetime, no replacement/rearm.
-- Authority uses settings_startup_authority's revoke/status contract; startup uses
-- settings_startup's retire/drain/status contract. false from retire is normal.
-- Cleanup calls are attempted once. Lost replies/exceptions retain both objects.
-- report receives at most closing then cleanup_complete. The latter includes
-- final cleanup/retention fields, even on hook-driven closure. Reporting may
-- return nil or true; false/throw is uncertain. A lost completion report rolls
-- back reference release, never cleanup or reporting. A record cannot certify
-- its own delivery; status() remains authoritative if reporting fails/reenters.
-- Normal main-session ClientRestart invalidation MUST explicitly call close().
-- EndPlay reasons 0..3 do not identify our session; only Quit=4 closes it.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/settings_startup_lifecycle.lua$'))
local Epoch=dofile(root..'/save_lifecycle_epoch.lua')
local M={}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function text(s) return type(s)=='string' and #s>0 and #s<=128 and not s:find('%c') end
local names={'RegisterLoadMapPreHook','RegisterLoadMapPostHook',
    'RegisterInitGameStatePreHook','RegisterInitGameStatePostHook','RegisterEndPlayPreHook'}
function M.new(o)
    if not plain(o) or o.enabled~=true then return nil,'disabled' end
    if o.report~=nil and type(o.report)~='function' then return nil,'invalid_report' end
    local report=o.report
    local lifecycle,api
    local installed,install_attempted,admitted,attached=false,false,false,false
    local terminal,busy,cleanup_attempted,cleanup_verified,uncertain=false,false,false,false,false
    local reason,startup,authority,retire,drain,startup_status,revoke,authority_status
    local revoke_attempted,retire_attempted,drain_attempted,reported=false,false,false,false
    local function status()
        local s=lifecycle:status()
        return {state=terminal and (startup and 'retained' or 'closed')
                or attached and 'attached' or admitted and 'admitted' or installed and 'waiting' or 'uninstalled',
            reason=reason,installed=installed,install_attempted=install_attempted,
            admitted=admitted,attached=attached,epoch=s.epoch,terminal=terminal,
            owner_retained=startup~=nil,cleanup_attempted=cleanup_attempted,
            cleanup_verified=cleanup_verified,uncertain=uncertain,
            revoke_attempted=revoke_attempted,retire_attempted=retire_attempted,drain_attempted=drain_attempted}
    end
    local function fence(why)
        if not terminal then
            terminal=true;reason=why
            lifecycle:revoke()
            -- Signal the bootstrap before touching authority/owner callbacks,
            -- including closure during another operation. It must fence legacy
            -- writers and stop deferred work immediately. One scalar event only.
            if report and not reported then
                reported=true
                local was_busy=busy;busy=true
                local event=status();event.event='closing'
                local ok,value=pcall(report,event)
                if not ok or value==false then uncertain=true end
                busy=was_busy
            end
        end
    end
    local function cleanup()
        if busy or not terminal or cleanup_attempted then return end
        cleanup_attempted=true;busy=true
        if startup then
            -- Flags precede external calls. Nested hooks/close cannot replay them.
            revoke_attempted=true
            local ok,value=pcall(revoke)
            if not ok or type(value)~='boolean' then uncertain=true end
            local good,s=pcall(authority_status)
            if not good or not plain(s) or s.state~='revoked' then uncertain=true end
            retire_attempted=true
            ok,value=pcall(retire,startup)
            if not ok or type(value)~='boolean' then uncertain=true end
            -- Even a failed revoke/retire must not prevent original-owner drain.
            drain_attempted=true
            ok,value=pcall(drain,startup)
            if not ok or value~=true then uncertain=true end
            good,s=pcall(startup_status,startup)
            if not good or not plain(s) or s.state~='closed' or s.owner_retained~=false then uncertain=true end
        end
        cleanup_verified=not uncertain
        -- Keep rollback references until the one completion report returns.
        -- Expose the completed state to the reporter, but conservatively retain
        -- the original owner if the reply is lost or the reporter reenters.
        local old_startup,old_authority=startup,authority
        local old_retire,old_drain,old_status=retire,drain,startup_status
        local old_revoke,old_authority_status=revoke,authority_status
        if cleanup_verified then
            startup,authority,retire,drain,startup_status,revoke,authority_status=nil,nil,nil,nil,nil,nil,nil
        end
        if report then
            local event=status();event.event='cleanup_complete'
            local ok,value=pcall(report,event)
            if not ok or value==false then uncertain=true end
        end
        cleanup_verified=not uncertain
        if not cleanup_verified then
            startup,authority=old_startup,old_authority
            retire,drain,startup_status=old_retire,old_drain,old_status
            revoke,authority_status=old_revoke,old_authority_status
        end
        busy=false
    end
    local function close(why)
        if not text(why) then why='invalid_close_reason' end
        fence(why)
        if busy then uncertain=true;return false end
        cleanup()
        return cleanup_verified
    end
    local function reentrant()
        if not busy then return false end
        uncertain=true;fence('reentrant');return true
    end
    lifecycle=Epoch.new{enabled=true,observe=function(event,s)
        if not terminal then
            if not installed then fence('unregistered_callback')
            elseif admitted or busy then
                if event=='load_pre' or event=='init_pre' or not s.ready then fence(event) end
            end
        end
        cleanup()
        return nil
    end}
    local function quit(_,param)
        if terminal then return nil end -- duplicate Quit does not even read wrapper
        if not installed then close('unregistered_callback');return nil end
        if reentrant() then return nil end
        busy=true
        local ok,value=pcall(function()
            assert(type(param)=='table' or type(param)=='userdata')
            return param:get() -- callback-local enum only; never inspect actor
        end)
        busy=false
        if not ok or math.type(value)~='integer' or value<0 or value>4 then fence('invalid_endplay_reason')
        elseif value==4 then fence('quit') end
        cleanup()
        return nil
    end
    api={}
    function api:install(engine_api)
        if reentrant() then return false end
        if terminal or install_attempted then return false end
        install_attempted=true
        if type(engine_api)~='table' then close('hooks_unavailable');return false end
        local registrars={}
        for _,name in ipairs(names) do
            local fn=rawget(engine_api,name)
            if type(fn)~='function' then close('missing_'..name);return false end
            registrars[name]=fn
        end
        busy=true
        local ok,yes=pcall(lifecycle.install,lifecycle,registrars)
        if not ok or yes~=true then fence('lifecycle_registration_failed') end
        if not terminal then
            local good,value=pcall(registrars.RegisterEndPlayPreHook,quit)
            -- Pinned registrars return no values. Explicit false or throw fails.
            if not good or value==false then fence('quit_registration_failed') end
        end
        busy=false
        if terminal then cleanup();return false end
        installed=true
        return true
    end
    function api:epoch()
        local s=lifecycle:status()
        local supported=installed and not terminal and not s.terminal
        local token
        if supported and not busy then token=lifecycle:admit() end
        return {available=token~=nil,supported=supported,epoch=s.epoch,token=token}
    end
    function api:admit(verify)
        if reentrant() then return false end
        if terminal then return false end
        if admitted then
            if lifecycle:admit()~=nil then return true end
            close('admission_lost');return false
        end
        if not installed then close('hooks_unavailable');return false end
        local candidate=lifecycle:candidate()
        if not candidate or type(verify)~='function' then close('candidate_unavailable');return false end
        busy=true
        local ok,yes=pcall(lifecycle.authorize,lifecycle,candidate,verify)
        busy=false
        if not ok or yes~=true or terminal or lifecycle:admit()~=candidate then
            fence('admission_failed');cleanup();return false
        end
        admitted=true
        return true
    end
    function api:attach(owner,auth)
        if reentrant() then return false end
        if terminal then return false end
        if attached then close('duplicate_attachment');return false end
        if not admitted or not api:epoch().available then close('not_admitted');return false end
        if not plain(owner) or not plain(auth) or type(owner.retire)~='function'
            or type(owner.drain)~='function' or type(owner.status)~='function'
            or type(auth.revoke)~='function' or type(auth.status)~='function' then
            close('invalid_attachment');return false
        end
        startup,authority=owner,auth
        retire,drain,startup_status=owner.retire,owner.drain,owner.status
        revoke,authority_status=auth.revoke,auth.status
        attached=true
        return true
    end
    function api:close(why) return close(why) end
    api.status=status
    return api
end
return M
