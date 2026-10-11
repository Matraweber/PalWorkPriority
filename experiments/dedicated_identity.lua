-- Observation only. No writer, registry admission, or storage grant.
local M={}
local function address(o)
    if not o or o:IsValid()~=true then return nil end
    local n=o:GetAddress()
    if type(n)=='number' and n>0 and n<math.huge and n%1==0 then return n end
end
local function guid(s)
    return type(s)=='string' and #s==32 and s:match('^%x+$')
        and s~=string.rep('0',32) and s:lower() or nil
end
local function path(s)
    if type(s)~='string' then s=s:ToString() end
    if type(s)~='string' or #s==0 or #s>2048 or s:find('[%c|]') then return nil end
    local normalized=s:gsub('\\','/'):gsub('/$','')
    local kind='relative_unresolved'
    if normalized:match('^[A-Za-z]:/') then kind='absolute_observed'
    elseif normalized:find(':',1,true) or normalized:sub(1,1)=='/' then kind='unsupported' end
    if normalized:find('[<>"?*]') or normalized:find('//',1,true) then kind='unsupported' end
    if kind=='absolute_observed' then
        for part in normalized:sub(4):gmatch('[^/]+') do
            if part=='.' or part=='..' or part:find('[ .]$') then kind='unsupported' end
        end
    end
    return s,kind,normalized:lower()
end
function M.read(headless,engine,get_state,get_instance,get_saved,configured,expected_saved)
    local failed={status='unavailable',verified=false,active=false,storage_grant=false}
    local ok,out=pcall(function()
        local wanted=guid(configured)
        if not wanted then return nil end
        local first=headless.read(engine,get_state,get_instance)
        if first.status~='observed' or first.current_world_status~='context_agrees'
            or first.directory~=wanted or first.role~=3 or first.dedicated~=true then return nil end
        local instance=engine.GameInstance
        if address(instance)~=first.instance_address then return nil end
        local manager=instance.SaveGameManager
        local mid=address(manager)
        if not mid or address(manager:GetOuter())~=first.instance_address then return nil end
        local loaded=manager.bIsLoadedWorldSaveData
        if type(loaded)~='boolean' then return nil end
        local root,format,normalized=path(get_saved())
        if not root then return nil end
        local _,expected_format,expected=path(expected_saved)
        local second=headless.read(engine,get_state,get_instance)
        for _,key in ipairs({'status','current_world_status','directory','role','dedicated',
            'world_address','state_address','instance_address'}) do
            if first[key]~=second[key] then return nil end
        end
        -- Headless's closing read does not revalidate every ownership edge.
        -- Recheck them here after that read; only callback-local wrappers exist.
        local state=get_state(instance)
        if address(state)~=first.state_address
            or address(get_instance(state))~=first.instance_address then return nil end
        local level=state:GetLevel()
        if not address(level) then return nil end
        local world=level.OwningWorld
        if address(world)~=first.world_address
            or address(world.OwningGameInstance)~=first.instance_address
            or address(world.GameState)~=first.state_address then return nil end
        if address(manager:GetOuter())~=first.instance_address
            or address(engine.GameInstance)~=first.instance_address
            or address(instance.SaveGameManager)~=mid
            or manager.bIsLoadedWorldSaveData~=loaded then return nil end
        return {status='context_agrees',verified=false,active=false,storage_grant=false,
            directory=wanted,project_saved=root,path_status=format,
            expected_root_matches=format=='absolute_observed' and expected_format=='absolute_observed'
                and normalized==expected,
            world_address=first.world_address,
            state_address=first.state_address,instance_address=first.instance_address,
            manager_address=mid,loaded_world=loaded,role=3,dedicated=true}
    end)
    return ok and out or failed
end
return M
