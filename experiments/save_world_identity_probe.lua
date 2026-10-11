-- Property-only, fresh world-scoped observation. Never authorizes storage.
local M={}
local function attempt(fn)
    local ok,value=pcall(fn)
    if ok then return value,true end
    return nil,false
end
local function valid(value)
    return value~=nil and attempt(function() return value:IsValid() end)==true
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
function M.read(engine)
    local out={verified=false,status='unavailable',directory_status='unavailable',
        role_status='unavailable',dedicated_status='unavailable'}
    local ok=pcall(function()
        if not valid(engine) then return end
        local viewport=engine.GameViewport
        if not valid(viewport) then return end
        local world=viewport.World
        if not valid(world) then return end
        local name=attempt(function() return world:GetFullName() end)
        if type(name)=='string' and #name<=512 then out.world=name end
        local state=world.GameState
        if not valid(state) then return end
        out.directory,out.directory_status=guid(attempt(function() return state.WorldSaveDirectoryName end))
        local role,readable=attempt(function() return state.Role end)
        out.role_status=not readable and 'read_failed' or role==nil and 'unavailable' or 'unknown'
        if type(role)=='number' and role%1==0 and role>=0 and role<=3 then
            out.role=role;out.role_status='read'
        end
        local dedicated,read=attempt(function() return state.bIsDedicatedServer end)
        out.dedicated_status=not read and 'read_failed' or dedicated==nil and 'unavailable' or 'unknown'
        if type(dedicated)=='boolean' then out.dedicated=dedicated;out.dedicated_status='read' end
        out.status='observed'
    end)
    if not ok then out.status='read_failed' end
    -- Replicated directory on a client is not a local save or write permission.
    return out
end
return M
