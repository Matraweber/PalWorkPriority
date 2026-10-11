-- Isolated same-callback diagnostic, NOT evidence usable as an IO grant.
-- Caller supplies one freshly resolved GameEngine and read-only GameplayStatics
-- getters, then calls read synchronously/non-yielding on the game thread. No
-- discovery, timers, IO, cached wrappers, epoch inference or active-provider wiring.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/save_context_pair_probe.lua$'))
local Headless=dofile(root..'/save_headless_identity_probe.lua')
local World=dofile(root..'/save_world_identity_probe.lua')
local Identity=dofile(root..'/save_identity_probe.lua')
local M={}
local function integer(n) return math.type(n)=='integer' and n>0 end
local function name(s) return type(s)=='string' and #s>0 and #s<=512 and not s:find('%c') end
local function guid(s)
    return type(s)=='string' and #s==32 and s:match('^[0-9a-f]+$') and s~=string.rep('0',32)
end
local function address(object)
    assert(object and object:IsValid()==true, 'invalid context')
    local n=object:GetAddress()
    assert(integer(n), 'address unavailable')
    return n
end
-- World.read has no address contract. Independently bracket its exact viewport
-- route so matching map/directory names cannot hide another world or GameState.
local function viewport(engine)
    assert(engine and engine:IsValid()==true)
    local view=engine.GameViewport
    assert(view and view:IsValid()==true)
    local world=view.World
    local wid=address(world)
    local instance=world.OwningGameInstance
    local iid=address(instance)
    return {world_address=wid,instance_address=iid,state_address=address(world.GameState),
        manager_address=address(instance.SaveGameManager),root_instance_address=address(engine.GameInstance)}
end
local function result(reason)
    return {status=reason,agrees=false,verified=false,active=false,storage_grant=false}
end
local function fields_read(s)
    return s.status=='observed' and name(s.world) and s.directory_status=='format_valid'
        and guid(s.directory) and s.role_status=='read' and type(s.role)=='number' and s.role%1==0
        and s.role>=0 and s.role<=3 and s.dedicated_status=='read' and type(s.dedicated)=='boolean'
end
function M.read(engine,get_state,get_instance)
    if type(get_state)~='function' or type(get_instance)~='function' then
        return result('unsupported_getter')
    end
    local ok,out=pcall(function()
        local before=viewport(engine)
        local h=Headless.read(engine,get_state,get_instance)
        local w=World.read(engine)
        local i=Identity.read(engine)
        local after=viewport(engine)
        for k,v in pairs(before) do
            if after[k]~=v then return result('context_changed') end
        end
        if h.current_world_status~='context_agrees' or not fields_read(h)
            or not integer(h.world_address) or not integer(h.state_address) or not integer(h.instance_address) then
            return result('headless_unavailable')
        end
        if not fields_read(w) then return result('viewport_unavailable') end
        if i.context_status~='context_agrees' or not name(i.world)
            or not integer(i.world_address) or not integer(i.instance_address) or not integer(i.manager_address) then
            return result('identity_unavailable')
        end
        if before.root_instance_address~=before.instance_address
            or h.world_address~=before.world_address or h.state_address~=before.state_address
            or h.instance_address~=before.instance_address or i.world_address~=before.world_address
            or i.instance_address~=before.instance_address or i.manager_address~=before.manager_address then
            return result('context_mismatch')
        end
        if h.world~=w.world or h.world~=i.world or h.directory~=w.directory
            or h.role~=w.role or h.dedicated~=w.dedicated then return result('field_mismatch') end
        local observed=result('context_agrees')
        observed.agrees=true
        observed.world,observed.directory,observed.role,observed.dedicated=h.world,h.directory,h.role,h.dedicated
        observed.world_address,observed.state_address=h.world_address,h.state_address
        observed.instance_address,observed.manager_address=h.instance_address,i.manager_address
        -- Selection/loaded data is diagnostic only. Known absent selection in a
        -- new world does not falsify contextual ownership or imply non-authority.
        -- Copy a fixed whitelist of bounded scalars, never raw result tables.
        for _,k in ipairs({'selected','selected_status','autosave','autosave_status','loaded_world','loaded_status'}) do
            local value=i[k]
            if type(value)=='boolean' or (type(value)=='string' and #value<=64 and not value:find('%c')) then
                observed['identity_'..k]=value
            end
        end
        return observed
    end)
    if not ok then return result('context_unavailable') end
    return out
end
return M
