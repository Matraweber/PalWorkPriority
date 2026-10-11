-- Observation only. Candidate agreement is NOT permission to bind storage.
-- Fresh callback-scoped wrappers; no filesystem reads or game state writes.
local M={}
local function attempt(fn)
    local ok,value=pcall(fn)
    if ok then return value,true end
    return nil,false
end
local function valid(x)
    return x~=nil and attempt(function() return x:IsValid() end)==true
end
local function address(x)
    if not valid(x) then return end
    local n=attempt(function() return x:GetAddress() end)
    if math.type(n)=='integer' and n>0 then return n end
end
local function guid(value,readable)
    if readable==false then return nil,'read_failed' end
    if value==nil then return nil,'unavailable' end
    if type(value)~='string' then
        local ok
        value,ok=attempt(function() return value:ToString() end)
        if not ok then return nil,'read_failed' end
    end
    if value=='' then return nil,'empty' end
    if type(value)~='string' or #value~=32 or not value:match('^%x+$') then return nil,'malformed' end
    if value==string.rep('0',32) then return nil,'zero_guid' end
    return value:lower(),'format_valid'
end
function M.read(engine)
    local out={verified=false,state='unavailable',context_status='unestablished',selected_status='unavailable',autosave_status='unavailable',loaded_status='unavailable'}
    if not valid(engine) then return out end
    local viewport=attempt(function() return engine.GameViewport end)
    if not valid(viewport) then return out end
    local world=attempt(function() return viewport.World end)
    if not valid(world) then return out end
    local name=attempt(function() return world:GetFullName() end)
    if type(name)=='string' and #name<=512 then out.world=name end
    local instance=attempt(function() return world.OwningGameInstance end)
    if not valid(instance) then return out end
    local wid,iid=address(world),address(instance)
    out.selected,out.selected_status=guid(attempt(function() return instance.SelectedWorldSaveDirectoryName end))
    local manager=attempt(function() return instance.SaveGameManager end)
    if valid(manager) then
        out.autosave,out.autosave_status=guid(attempt(function() return manager.AutoSaveWorldDefaultName end))
        local loaded,ok=attempt(function() return manager.bIsLoadedWorldSaveData end)
        out.loaded_status=not ok and 'read_failed' or loaded==nil and 'unavailable'
            or type(loaded)=='boolean' and 'read' or 'malformed'
        if type(loaded)=='boolean' then out.loaded_world=loaded end
        local mid=address(manager)
        local owner=attempt(function() return manager:GetOuter() end)
        if wid and iid and mid and address(owner)==iid then
            -- All tokens come from this callback. A changed root or owner keeps
            -- them absent, so a provider cannot splice a stale loaded flag into
            -- another world's observation. This is NOT active-storage proof.
            local current_view=attempt(function() return engine.GameViewport end)
            local current_world=valid(current_view) and attempt(function() return current_view.World end)
            local current_instance=valid(current_world) and attempt(function() return current_world.OwningGameInstance end)
            local current_manager=valid(current_instance) and attempt(function() return current_instance.SaveGameManager end)
            if address(current_world)==wid and address(current_instance)==iid and address(current_manager)==mid then
                out.world_address,out.instance_address,out.manager_address=wid,iid,mid
                out.context_status='context_agrees'
            else out.context_status='context_changed' end
        else out.context_status='owner_unestablished' end
    end
    out.state=out.selected and out.autosave and
        (out.selected==out.autosave and 'candidates_agree' or 'candidates_conflict')
        or (out.selected or out.autosave) and 'one_candidate' or 'no_candidate'
    -- Deliberately no storage/key/ready field: even matching loaded candidates
    -- need authority/session and persistent save-directory verification.
    return out
end
return M
