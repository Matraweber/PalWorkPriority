-- Read-only diagnostic. Process keys are observations, never storage proof.
local M={}
local function attempt(fn)
    local ok,value=pcall(fn)
    if ok then return value,true end
    return nil,false
end
local function valid(value)
    return value~=nil and attempt(function() return value:IsValid() end)==true
end
local function key_shape(param)
    local value=param:get()
    if type(value)~='string' then value=value:ToString() end
    if type(value)~='string' or #value>1024 then return 'unavailable' end
    if #value==32 and value:match('^%x+$') and value~=string.rep('0',32) then
        return 'guid',value:lower()
    end
    -- Do not retain arbitrary paths, account names or save display names.
    local normalized=value:gsub('\\','/')
    if normalized=='Level' or normalized=='Level.sav' then return 'level_leaf' end
    if normalized:sub(1,1)=='/' or normalized:find(':',1,true)
        or normalized:find('[%c]') or normalized:find('//',1,true) then return 'other' end
    for part in normalized:gmatch('[^/]+') do
        if part=='.' or part=='..' then return 'other' end
    end
    local id=normalized:match('(%x+)/Level%.sav$') or normalized:match('(%x+)/Level$')
    if id and #id==32 and id~=string.rep('0',32)
        and (normalized:sub(1,32)==id or normalized:find('/'..id..'/',1,true)) then
        return 'guid_level_path',id:lower()
    end
    return value=='' and 'empty' or 'other'
end
function M.read(engine)
    local out={verified=false,status='unavailable',entries={}}
    local function read()
        if not valid(engine) then return end
        local viewport=engine.GameViewport
        if not valid(viewport) then return end
        local world=viewport.World
        if not valid(world) then return end
        local instance=world.OwningGameInstance
        if not valid(instance) then return end
        local manager=instance.SaveGameManager
        if not valid(manager) then return end
        local map=manager.WorldSaveProcess.ProcessMap
        if map==nil then return end
        if map:type()~='TMap' then out.status='unavailable';return end
        local count=#map
        if type(count)~='number' or count%1~=0 or count<0 then out.status='invalid_count';return end
        out.count=count
        if count>16 then out.status='oversize';return end
        if count==0 then out.status='empty';return end
        out.status='reading'
        local seen=0
        map:ForEach(function(key,value)
            seen=seen+1
            if seen>16 then out.status='changed_during_read';return true end
            local entry={key_status='read_failed',state_status='read_failed',pre_status='read_failed'}
            local ok,shape,id=pcall(key_shape,key)
            if ok then entry.key_status=shape;entry.candidate=id end
            local process,readable=attempt(function() return value:get() end)
            if readable and process~=nil then
                local state,state_ok=attempt(function() return process.State end)
                if state_ok then
                    entry.state_status=type(state)=='number' and state%1==0 and state>=0 and state<=4 and 'read' or 'unknown'
                    if entry.state_status=='read' then entry.state=state end
                end
                local pre,pre_ok=attempt(function() return process.bPreDelegateSuccess end)
                if pre_ok then
                    entry.pre_status=type(pre)=='boolean' and 'read' or 'unknown'
                    if entry.pre_status=='read' then entry.pre_success=pre end
                end
            end
            out.entries[#out.entries+1]=entry
            -- Stop at the preflight size, even if the underlying map grew.
            if seen>=count then return true end
        end)
        local after=#map
        out.status=seen~=count and 'incomplete' or 'observed'
        if after~=count then out.status='changed_during_read' end
    end
    if not pcall(read) then out.status='read_failed' end
    return out
end
return M
