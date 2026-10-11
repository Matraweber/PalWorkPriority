-- Headless observation only; never storage authorization. Source checked 2026-10-04:
-- Pal SDK Public/PalGameStateInGame.h: directory and dedicated flag replicated.
-- Public/PalGameMode.h inherits GameState, but finding a GameMode can select a
-- retiring world. Public/PalUtility.h needs context; its .cpp contains stubs.
-- Actual installed UE 5.1 Runtime/Engine source establishes the candidate route:
-- Classes/Engine/GameEngine.h: reflected GameInstance.
-- Private/GameplayStatics.cpp:493 GetGameState(context) -> GetWorldFromContextObject
-- (LogAndReturnNull) -> World.GetGameState; :245 GetGameInstance(state) similarly.
-- Private/UnrealEngine.cpp:12779 resolves context->GetWorld(); Private/GameInstance.cpp:79
-- returns WorldContext->World(). No viewport or selected-save field involved.
-- Actor.h:2975 reflects GetLevel(); Actor.cpp:2351 uses GetTypedOuter<ULevel>().
-- Level.h:485 reflects OwningWorld; World.h reflects GameState/OwningGameInstance.
-- Cross-check those edges and re-read the current root/state after field reads.
-- GetWorld is NOT an Actor UFUNCTION: use GetLevel().OwningWorld instead.
-- Assumption: caller supplies the active process GameEngine. Offline source and
-- agreement checks cannot prove installed-build behavior or load/destination semantics.
local M={}
local function attempt(fn)
    local ok,value=pcall(fn)
    if ok then return value,true end
    return nil,false
end
local function valid(value)
    return value~=nil and attempt(function() return value:IsValid() end)==true
end
local function address(value)
    if not valid(value) then return nil end
    local n=attempt(function() return value:GetAddress() end)
    if type(n)=='number' and n>0 and n<math.huge and n%1==0 then return n end
end
local function guid(value,ok)
    if not ok then return nil,'read_failed' end
    if value==nil then return nil,'unavailable' end
    if type(value)~='string' then
        value,ok=attempt(function() return value:ToString() end)
        if not ok then return nil,'read_failed' end
    end
    if value=='' then return nil,'empty' end
    if type(value)~='string' or #value~=32 or not value:match('^%x+$') then return nil,'malformed' end
    if value==string.rep('0',32) then return nil,'zero_guid' end
    return value:lower(),'format_valid'
end
-- Inject only read-only GameplayStatics GetGameState/GetGameInstance callables.
-- All native wrappers are callback-local; addresses are ephemeral scalar tokens,
-- compared within this read, never persisted as a storage key or permission.
function M.read(engine,get_state,get_instance)
    local out={verified=false,current_world_status='unestablished',
        status='unavailable',engine_status='unavailable',instance_status='unavailable',
        route='GameEngine.GameInstance->GameplayStatics.GetGameState',
        directory_status='not_read',role_status='not_read',dedicated_status='not_read'}
    if type(get_state)~='function' or type(get_instance)~='function' then
        out.status='unsupported_getter';return out
    end
    local ok=pcall(function()
        if not valid(engine) then return end
        out.engine_status='candidate'
        local instance=engine.GameInstance
        if not valid(instance) then return end
        out.instance_status='candidate'
        local state=get_state(instance)
        if not valid(state) then return end
        local iid,sid=address(instance),address(state)
        if not iid or not sid then out.status='identity_unavailable';return end
        local owner=get_instance(state)
        local owner_id=address(owner)
        if not owner_id then out.status='identity_unavailable';return end
        if owner_id~=iid then out.status='context_mismatch';return end
        local level=state:GetLevel()
        if not valid(level) then return end
        local world=level.OwningWorld
        local wid=address(world)
        if not wid then out.status='identity_unavailable';return end
        local world_iid,world_sid=address(world.OwningGameInstance),address(world.GameState)
        if not world_iid or not world_sid then out.status='identity_unavailable';return end
        if world_iid~=iid or world_sid~=sid then out.status='context_mismatch';return end
        local directory,directory_status=guid(attempt(function() return state.WorldSaveDirectoryName end))
        local role,role_ok=attempt(function() return state.Role end)
        local dedicated,dedicated_ok=attempt(function() return state.bIsDedicatedServer end)
        local name=attempt(function() return world:GetFullName() end)
        -- Same instance can span retiring/current worlds: owner agreement alone
        -- is insufficient. Re-query its current state, not an arbitrary actor.
        if address(engine.GameInstance)~=iid or address(get_state(instance))~=sid
            or address(world.GameState)~=sid then
            out.status='context_changed';return
        end
        out.directory,out.directory_status=directory,directory_status
        out.role_status=not role_ok and 'read_failed' or role==nil and 'unavailable' or 'unknown'
        if type(role)=='number' and role%1==0 and role>=0 and role<=3 then
            out.role=role;out.role_status='read'
        end
        out.dedicated_status=not dedicated_ok and 'read_failed' or dedicated==nil and 'unavailable' or 'unknown'
        if type(dedicated)=='boolean' then out.dedicated=dedicated;out.dedicated_status='read' end
        if type(name)=='string' and #name>0 and #name<=512 and not name:find('%c') then out.world=name end
        out.world_address,out.state_address,out.instance_address=wid,sid,iid
        out.current_world_status='context_agrees'
        out.status='observed'
    end)
    if not ok then out.status='read_failed' end
    return out
end
return M
