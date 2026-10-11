local Probe=dofile(TEST_ROOT..'/experiments/save_headless_identity_probe.lua')
local local_id,server_id=string.rep('a',32),string.rep('b',32)
local function fixture()
    local f={forbidden=0,wrappers={},calls=0}
    function f.object(fields,id,allowed)
        fields.IsValid=fields.IsValid or function() return true end
        fields.GetAddress=fields.GetAddress or function() return id end
        local proxy=setmetatable({}, {__index=function(_,key)
            if fields[key]~=nil then return fields[key] end
            if allowed and allowed[key] then return nil end
            f.forbidden=f.forbidden+1;error('PRIVATE unexpected '..key)
        end,__newindex=function() f.forbidden=f.forbidden+1;error('native write') end,
        __pairs=function() f.forbidden=f.forbidden+1;error('native enumeration') end})
        f.wrappers[proxy]=true;return proxy
    end
    f.instance={SelectedWorldSaveDirectoryName=local_id};f.instance_object=f.object(f.instance,1)
    f.state={WorldSaveDirectoryName=server_id:upper(),Role=3,bIsDedicatedServer=true}
    f.state_object=f.object(f.state,2,{WorldSaveDirectoryName=true,Role=true,bIsDedicatedServer=true})
    f.world={GameState=f.state_object,OwningGameInstance=f.instance_object,
        GetFullName=function() return 'World same-map' end}
    f.world_object=f.object(f.world,3,{GameState=true,OwningGameInstance=true})
    f.level={OwningWorld=f.world_object};f.level_object=f.object(f.level,4,{OwningWorld=true})
    f.state.GetLevel=function() return f.level_object end
    f.engine_fields={GameInstance=f.instance_object};f.engine=f.object(f.engine_fields,5,{GameInstance=true})
    f.current=f.state_object;f.owner=f.instance_object
    function f.get_state(context)
        assert(context==f.instance_object);f.calls=f.calls+1
        if f.change and f.calls==2 then return f.change end
        return f.current
    end
    function f.get_instance(context) assert(context==f.state_object);return f.owner end
    function f.read(status)
        local out=Probe.read(f.engine,f.get_state,f.get_instance)
        assert(out.status==(status or 'observed'),out.status)
        assert(out.verified==false and out.storage==nil and out.key==nil and out.ready==nil)
        for _,value in pairs(out) do
            assert(not f.wrappers[value],'retained wrapper')
            assert(type(value)=='string' or type(value)=='number' or type(value)=='boolean')
            assert(type(value)~='string' or not value:find('PRIVATE',1,true))
        end
        if out.status~='observed' then
            assert(out.directory==nil and out.world_address==nil and out.current_world_status=='unestablished')
        end
        assert(f.forbidden==0);return out
    end
    return f
end
local f=fixture();local out=f.read()
assert(out.directory==server_id and out.role==3 and out.dedicated==true and f.calls==2)
assert(out.current_world_status=='context_agrees' and out.world_address==3)
assert(out.directory~=f.instance.SelectedWorldSaveDirectoryName)
-- Distinct Lua wrappers for the same native object compare by native address.
f=fixture();f.owner=f.object({},1);f.world.GameState=f.object({},2);f.read()
for _,case in ipairs({{'','empty'},{string.rep('0',32),'zero_guid'},{'PRIVATE/path','malformed'},
    {string.rep('x',32),'malformed'},{string.rep('a',33),'malformed'},{string.rep('a',100000),'malformed'}}) do
    f=fixture();f.state.WorldSaveDirectoryName=case[1];out=f.read()
    assert(out.directory==nil and out.directory_status==case[2])
end
f=fixture();f.state.WorldSaveDirectoryName={ToString=function() return server_id:upper() end}
assert(f.read().directory==server_id)
for _,value in ipairs({false,17,{ToString=function() error('PRIVATE conversion') end},
    {ToString=function() return {} end}}) do
    f=fixture();f.state.WorldSaveDirectoryName=value;assert(f.read().directory==nil)
end
for _,role in ipairs({0,1,2,3,-1,4,1.5,0/0,math.huge,'3',false,{}}) do
    f=fixture();f.state.Role=role;out=f.read()
    local good=type(role)=='number' and role%1==0 and role>=0 and role<=3
    assert(out.role_status==(good and 'read' or 'unknown'))
end
for _,value in ipairs({true,false,0,1,'true',{}}) do
    f=fixture();f.state.bIsDedicatedServer=value;out=f.read()
    assert(out.dedicated_status==(type(value)=='boolean' and 'read' or 'unknown'))
end
for _,case in ipairs({{'WorldSaveDirectoryName','directory_status'},{'Role','role_status'},
    {'bIsDedicatedServer','dedicated_status'}}) do
    f=fixture();f.state[case[1]]=nil;assert(f.read()[case[2]]=='unavailable')
    setmetatable(f.state,{__index=function(_,key) if key==case[1] then error('PRIVATE field') end end})
    assert(f.read()[case[2]]=='read_failed')
end
-- Foreign context rejected; retiring state can share instance/map/directory/role.
f=fixture();f.owner=f.object({},99);f.read('context_mismatch')
f=fixture();f.world.OwningGameInstance=f.object({},99);f.read('context_mismatch')
f=fixture();f.world.GameState=f.object({},99);f.read('context_mismatch')
f=fixture();f.change=f.object({},99);f.read('context_changed')
f=fixture();f.state.GetLevel=function()
    f.engine_fields.GameInstance=f.object({},99);return f.level_object
end;f.read('context_changed')
for _,part in ipairs({'engine_fields','instance','state','level','world'}) do
    f=fixture();f[part].IsValid=function() return false end
    out=Probe.read(f.engine,f.get_state,f.get_instance);assert(out.status~='observed' and out.directory==nil)
    f[part].IsValid=function() error('PRIVATE invalid') end
    out=Probe.read(f.engine,f.get_state,f.get_instance);assert(out.status~='observed' and out.directory==nil)
end
for _,value in ipairs({0,-1,0/0,math.huge,'1',1.5}) do
    f=fixture();f.instance.GetAddress=function() return value end;f.read('identity_unavailable')
end
for _,part in ipairs({'instance','state','world'}) do
    f=fixture();f[part].GetAddress=function() error('PRIVATE address') end;f.read('identity_unavailable')
end
f=fixture();f.current=nil;f.read('unavailable')
f=fixture();f.owner=nil;f.read('identity_unavailable')
f=fixture();f.engine=nil;f.read('unavailable')
f=fixture();f.engine_fields.GameInstance=nil;f.read('unavailable')
f=fixture();f.level.OwningWorld=nil;f.read('identity_unavailable')
for _,getter in ipairs({'get_state','get_instance'}) do
    f=fixture();f[getter]=nil;f.read('unsupported_getter')
    f[getter]=function() error('PRIVATE getter') end;f.read('read_failed')
end
for _,name in ipairs({string.rep('x',513),'World\nforged-log',false,''}) do
    f=fixture();f.world.GetFullName=function() return name end;assert(f.read().world==nil)
end
f=fixture();f.world.GetFullName=function() error('PRIVATE name') end;assert(f.read().world==nil)
-- Fresh trees for same-map transitions; the previous wrappers become unusable.
f=fixture();local previous=f.read()
for _,part in ipairs({'engine_fields','instance','state','level','world'}) do
    f[part].IsValid=function() error('retired wrapper') end
end
f=fixture();f.state.WorldSaveDirectoryName=local_id;f.state.Role=1
out=f.read();assert(out.directory==local_id and out.role==1 and previous.directory==server_id)
print('headless probe: fresh context route, stale selection, foreign/retiring state, nil/failures, fields and no storage proof passed')
