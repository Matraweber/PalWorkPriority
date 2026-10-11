local Pair=dofile(TEST_ROOT..'/experiments/save_context_pair_probe.lua')
local id=string.rep('a',32)
local cases=0
local function fixture(base)
    base=base or 100
    local f={forbidden=0,calls=0,owner_calls=0,outer_calls=0,wrappers=setmetatable({}, {__mode='k'})}
    function f.object(fields,n,allowed)
        fields.IsValid=fields.IsValid or function() return true end
        fields.GetAddress=fields.GetAddress or function() return n end
        local proxy=setmetatable({}, {__index=function(_,key)
            local value=fields[key]
            if value~=nil then return value end
            if allowed and allowed[key] then return nil end
            f.forbidden=f.forbidden+1;error('PRIVATE unexpected '..key)
        end,__newindex=function() f.forbidden=f.forbidden+1;error('native write') end,
            __pairs=function() f.forbidden=f.forbidden+1;error('wrapper enumeration') end,
            __tostring=function() f.forbidden=f.forbidden+1;error('wrapper tostring') end})
        f.wrappers[proxy]=true;return proxy
    end
    f.instance={SelectedWorldSaveDirectoryName=id}
    f.instance_object=f.object(f.instance,base+2,{SelectedWorldSaveDirectoryName=true,SaveGameManager=true})
    f.manager={AutoSaveWorldDefaultName='',bIsLoadedWorldSaveData=true,
        GetOuter=function() f.outer_calls=f.outer_calls+1;return f.instance_object end}
    f.manager_object=f.object(f.manager,base+4,{AutoSaveWorldDefaultName=true,bIsLoadedWorldSaveData=true})
    f.instance.SaveGameManager=f.manager_object
    f.state={WorldSaveDirectoryName=id,Role=3,bIsDedicatedServer=false}
    f.state_object=f.object(f.state,base+3,{WorldSaveDirectoryName=true,Role=true,bIsDedicatedServer=true})
    f.world={GameState=f.state_object,OwningGameInstance=f.instance_object,
        GetFullName=function() return 'World same map' end}
    f.world_object=f.object(f.world,base+1,{GameState=true,OwningGameInstance=true})
    f.level={OwningWorld=f.world_object};f.level_object=f.object(f.level,base+5,{OwningWorld=true})
    f.state.GetLevel=function() return f.level_object end
    f.view={World=f.world_object};f.view_object=f.object(f.view,base+6,{World=true})
    f.engine_fields={GameViewport=f.view_object,GameInstance=f.instance_object}
    f.engine=f.object(f.engine_fields,base+7,{GameViewport=true,GameInstance=true})
    f.current=f.state_object;f.owner=f.instance_object
    f.get_state=function(instance)
        assert(instance==f.engine_fields.GameInstance);f.calls=f.calls+1
        return f.current
    end
    f.get_instance=function(state)
        assert(state==f.current);f.owner_calls=f.owner_calls+1;return f.owner
    end
    function f.read(expected)
        local out=Pair.read(f.engine,f.get_state,f.get_instance);cases=cases+1
        assert(out.status==expected, out.status..' expected '..expected)
        assert(out.agrees==(expected=='context_agrees'))
        assert(out.verified==false and out.active==false and out.storage_grant==false)
        assert(out.ready==nil and out.storage==nil and out.key==nil and out.epoch==nil and out.authority==nil)
        for _,v in pairs(out) do
            assert(type(v)=='string' or type(v)=='number' or type(v)=='boolean','non-scalar output')
            assert(not f.wrappers[v],'retained wrapper')
            if type(v)=='string' then assert(#v<=512 and not v:find('PRIVATE',1,true) and not v:find('%c')) end
        end
        if not out.agrees then
            assert(out.world_address==nil and out.state_address==nil and out.instance_address==nil
                and out.manager_address==nil and out.directory==nil and out.world==nil)
        end
        assert(f.forbidden==0,'unexpected native access')
        return out
    end
    return f
end

do
    local f=fixture();local out=f.read('context_agrees')
    assert(out.world_address==101 and out.instance_address==102 and out.state_address==103 and out.manager_address==104)
    assert(out.directory==id and out.identity_selected==id and out.identity_loaded_world==true)
    assert(f.calls==2 and f.owner_calls==1 and f.outer_calls==1, 'bounded real-reader calls')
    out.world_address=999;out.directory='changed';assert(f.read('context_agrees').directory==id)
    f.instance.SelectedWorldSaveDirectoryName=nil;f.manager.bIsLoadedWorldSaveData=false
    out=f.read('context_agrees') -- observed new-world edge, no storage readiness inferred
    assert(out.identity_selected==nil and out.identity_selected_status=='unavailable'
        and out.identity_loaded_world==false and out.role==3)
    f.instance.SelectedWorldSaveDirectoryName=string.rep('b',32);f.state.Role=1;f.state.bIsDedicatedServer=true
    out=f.read('context_agrees') -- selected ID is not a contextual ownership check
    assert(out.role==1 and out.dedicated==true and out.directory~=out.identity_selected)
    f.manager.bIsLoadedWorldSaveData=nil
    assert(f.read('context_agrees').identity_loaded_status=='unavailable')
    f.state.Role=3.0;assert(f.read('context_agrees').role==3, 'collector permits integral numeric roles')
end

-- Same native addresses in fresh wrappers are legitimate within this read.
do
    local f=fixture();f.owner=f.object({},102)
    f.read('context_agrees')
end
-- Same names/fields do not prove the headless root is the viewport root.
do
    local f,other=fixture(),fixture(200)
    f.engine_fields.GameInstance=other.instance_object
    f.current,f.owner=other.state_object,other.instance_object
    f.read('context_mismatch');assert(other.forbidden==0)
end
for _,part in ipairs({'engine_fields','view','world','instance','state','manager'}) do
    for _,bad in ipairs({'nil','false','throw'}) do
        local f=fixture()
        f[part].IsValid=function()
            if bad=='throw' then error('PRIVATE validity') end
            if bad=='false' then return false end
        end
        f.read('context_unavailable')
    end
end
for _,part in ipairs({'world','instance','state','manager'}) do
    for _,bad in ipairs({0,-1,1.5,'101',math.huge,0/0}) do
        local f=fixture();f[part].GetAddress=function() return bad end
        f.read('context_unavailable')
    end
    local f=fixture();f[part].GetAddress=function() error('PRIVATE address') end
    f.read('context_unavailable')
end
for _,edge in ipairs({{'engine_fields','GameViewport'},{'engine_fields','GameInstance'},
    {'view','World'},{'world','GameState'},{'world','OwningGameInstance'},{'instance','SaveGameManager'}}) do
    local f=fixture();f[edge[1]][edge[2]]=nil;f.read('context_unavailable')
end
for _,getter in ipairs({'get_state','get_instance'}) do
    local f=fixture();f[getter]=nil;f.read('unsupported_getter')
    assert(f.calls==0 and f.outer_calls==0)
    f=fixture();f[getter]=function() error('PRIVATE getter') end;f.read('headless_unavailable')
end
do
    local f=fixture();f.owner=f.object({},999);f.read('headless_unavailable')
    f=fixture();f.get_instance=function() return f.instance_object end
    -- Explicit unavailable level, not a permissive mock swallowing unknown APIs.
    f.current=f.object({GetLevel=function() return nil end},999);f.read('headless_unavailable')
    f=fixture();f.level.OwningWorld=nil;f.read('headless_unavailable')
    f=fixture();f.manager.GetOuter=function() return f.object({},999) end;f.read('identity_unavailable')
    f=fixture();f.manager.GetOuter=function() error('PRIVATE owner') end;f.read('identity_unavailable')
end
-- Chain transitions after the first viewport capture, including manager-only
-- replacement, must withhold all combined addresses, even if fields agree.
for _,edge in ipairs({'world','instance','state','manager','root'}) do
    local f,other=fixture(),fixture(200)
    f.manager.GetOuter=function()
        if edge=='world' then f.view.World=other.world_object
        elseif edge=='instance' then f.world.OwningGameInstance=other.instance_object
        elseif edge=='state' then f.world.GameState=other.state_object
        elseif edge=='manager' then f.instance.SaveGameManager=other.manager_object
        else f.engine_fields.GameInstance=other.instance_object end
        return f.instance_object
    end
    f.read('context_changed');assert(other.forbidden==0)
end
-- World-only field changes on a stable-address route cannot silently agree.
for _,field in ipairs({'WorldSaveDirectoryName','Role','bIsDedicatedServer'}) do
    local f=fixture();local original=f.state[field];f.state[field]=nil
    local reads=0
    setmetatable(f.state,{__index=function(_,k)
        if k==field then
            reads=reads+1
            if reads==1 then return original end
            if field=='WorldSaveDirectoryName' then return string.rep('b',32)
            elseif field=='Role' then return 1 else return true end
        end
    end})
    f.read('field_mismatch')
end
do
    local f=fixture();local reads=0
    f.world.GetFullName=function() reads=reads+1;return reads==1 and 'World old' or 'World new' end
    f.read('field_mismatch')
    for _,part in ipairs({'WorldSaveDirectoryName','Role','bIsDedicatedServer'}) do
        f=fixture();f.state[part]=nil;f.read('headless_unavailable')
    end
    f=fixture();f.world.GetFullName=function() return 'PRIVATE\nlog injection' end
    f.read('headless_unavailable')
    f=fixture();f.state.WorldSaveDirectoryName='PRIVATE/path';f.read('headless_unavailable')
    f=fixture();local reads2=0
    f.world.GetFullName=function() reads2=reads2+1;if reads2~=2 then return 'World same map' end end
    f.read('viewport_unavailable')
    f=fixture();local reads3=0
    f.world.GetFullName=function() reads3=reads3+1;return reads3==3 and 'World identity other' or 'World same map' end
    f.read('field_mismatch')
    f=fixture();f.get_state=function()
        f.calls=f.calls+1
        return f.calls==1 and f.state_object or f.object({},999)
    end
    f.read('headless_unavailable')
end
-- No captured engine/getter wrappers, cached result, history or cross-call lease.
do
    local weak=setmetatable({}, {__mode='v'})
    local saved
    do
        local f=fixture();weak[1]=f.engine;weak[2]=f.instance_object;weak[3]=f.state_object
        saved=f.read('context_agrees')
    end
    collectgarbage('collect');collectgarbage('collect');assert(next(weak)==nil)
    local next_world=fixture(300);local next_result=next_world.read('context_agrees')
    assert(saved.world_address==101 and next_result.world_address==301)
end
print('context pair: '..cases..' full-collector cases passed; scalar-only correlation, no authorization')
