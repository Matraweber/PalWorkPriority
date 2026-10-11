-- Isolated local-host provider; no engine access, IO, scheduling or activation.
-- Reuses save_scope for encoding and save_authorization for proof validation.
-- Neither observed GameState directory, selected ID, ProjectSavedDir nor scratch
-- recovery is an active-storage proof. Without verify_storage, authorize=false.
--
-- read_evidence() must run fresh/non-yielding on the game thread and return plain
-- copied records: {epoch,authority_status='read',authority,guild_status='format_valid',
-- guild,state=<save_headless_identity_probe result>,identity=<save_identity_probe
-- result PLUS world_address/instance_address from that SAME fresh identity route>}.
-- Existing name-only identity results are insufficient and intentionally denied.
-- epoch must advance on EVERY lifecycle boundary, even travel between samples;
-- map names, pointer reuse, and polling cannot detect an unobserved ABA transition.
-- boot must be unique across process/provider replacement; do not use map names.
-- Source adapters/epoch coverage and active-storage verification remain live-unproven.
--
-- Only observed local host: role=3, dedicated=false, loaded=true. Dedicated/client
-- routes do not inherit this contract. Guild ownership is a fresh caller assertion.
-- sample() returns a CANDIDATE with active=false/verified=false, never an IO grant.
-- authorize(owner,incarnation) composes the existing verifier and re-reads evidence.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/save_active_provider.lua$'))
local Scope=dofile(root..'/save_scope.lua')
local Auth=dofile(root..'/save_authorization.lua')
local M={}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function guid(s)
    return type(s)=='string' and #s==32 and s:match('^[0-9a-f]+$') and s~=string.rep('0',32)
end
local function integer(n) return math.type(n)=='integer' and n>0 end
local function name(s) return type(s)=='string' and #s>0 and #s<=512 and not s:find('%c') end
function M.new(options)
    options=options or {}
    local enabled=options.enabled==true
    local boot,stream,read,verify=options.boot,options.stream,options.read_evidence,options.verify_storage
    local configured=type(boot)=='string' and #boot>0 and #boot<=64 and boot:match('^[%w%-]+$')
        and (stream=='priorities' or stream=='limits') and type(read)=='function'
    local last,serial,high_epoch,busy,poison=nil,0,0,false,false
    local function unavailable(reason)
        last=nil -- any gap retires the prior incarnation, even if pointers return
        return {status=reason,verified=false,active=false}
    end
    local function capture()
        local e=read()
        if not plain(e) or not integer(e.epoch) then return nil,'lifecycle_unavailable' end
        if e.epoch<high_epoch then return nil,'stale_epoch' end
        high_epoch=e.epoch
        if e.authority_status~='read' or type(e.authority)~='boolean' then return nil,'authority_unavailable' end
        if e.authority~=true then return nil,'not_authority' end
        if e.guild_status~='format_valid' or not guid(e.guild) then return nil,'guild_unavailable' end
        local s,i=e.state,e.identity
        if not plain(s) or not plain(i) or s.status~='observed' or s.current_world_status~='context_agrees'
            or not name(s.world) or s.directory_status~='format_valid' or not guid(s.directory)
            or not integer(s.world_address) or not integer(s.instance_address) or not integer(s.state_address) then
            return nil,'world_identity_unavailable'
        end
        if s.role_status~='read' or s.role~=3 or s.dedicated_status~='read'
            or type(s.dedicated)~='boolean' then return nil,'authority_conflict' end
        if s.dedicated~=false then return nil,'unsupported_dedicated_route' end
        if i.world~=s.world or i.world_address~=s.world_address or i.instance_address~=s.instance_address then
            return nil,'identity_context_mismatch'
        end
        if i.loaded_status~='read' or i.loaded_world~=true then return nil,'loaded_storage_unavailable' end
        if i.selected_status~='format_valid' or i.selected~=s.directory then return nil,'selection_conflict' end
        if not (i.autosave_status=='empty' and i.autosave==nil)
            and not (i.autosave_status=='format_valid' and i.autosave==s.directory) then
            return nil,'autosave_conflict'
        end
        -- Copy only scalar evidence before any other provider can run.
        return {epoch=e.epoch,guild=e.guild,world=s.world,storage=s.directory,
            world_address=s.world_address,instance_address=s.instance_address,state_address=s.state_address,
            selected=i.selected,autosave_status=i.autosave_status,autosave=i.autosave}
    end
    local provider={}
    function provider.sample()
        if not enabled then return unavailable('disabled') end
        if not configured then return unavailable('unconfigured') end
        if busy then poison=true;return unavailable('reentrant_read') end
        busy,poison=true,false
        local ok,e,reason=pcall(capture)
        busy=false
        if poison then return unavailable('reentrant_read') end
        if not ok then return unavailable('read_failed') end
        if not e then return unavailable(reason) end
        -- Fixed-width GUIDs and numeric identities: map name is not the token.
        local signature=table.concat({e.epoch,e.guild,e.storage,e.world_address,e.instance_address,e.state_address},':')
            ..':'..#e.world..':'..e.world
        if signature~=last then
            if serial>=256 then return unavailable('incarnation_capacity') end
            serial=serial+1;last=signature
        end
        return {status='candidate',verified=false,active=false,scope=Scope.new(e.storage,e.guild,stream),
            incarnation=boot..':'..serial,epoch=e.epoch,world=e.world,
            selected=e.selected,autosave_status=e.autosave_status,autosave=e.autosave}
    end
    provider.authorize=Auth.new{enabled=enabled,stream=stream,
        read_context=function()
            local s=provider.sample()
            if s.status~='candidate' then return nil end
            -- Context readiness only; Auth still requires ACTIVE-STORAGE-1 proof.
            return {incarnation=s.incarnation,epoch=s.epoch,world=s.world,guild=s.scope.guild,
                role='authority',ready=true}
        end,
        read_identity=function()
            local s=provider.sample()
            if s.status~='candidate' then return nil end
            return {world=s.world,loaded_status='read',loaded_world=true,
                selected_status='format_valid',selected=s.selected,
                autosave_status=s.autosave_status,autosave=s.autosave,verified=false}
        end,
        verify_storage=type(verify)=='function' and verify or nil}
    return provider
end
return M
