local Probe=dofile(TEST_ROOT..'/experiments/save_world_identity_probe.lua')
local Identity=dofile(TEST_ROOT..'/experiments/save_identity_probe.lua')
local local_id,server_id=string.rep('a',32),string.rep('b',32)
local target='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local function fixture()
    local f={forbidden=0,wrappers={}}
    function f.object(fields,allowed)
        fields.IsValid=fields.IsValid or function() return true end
        local proxy=setmetatable({}, {
            __index=function(_,key)
                if fields[key]~=nil then return fields[key] end
                if allowed and allowed[key] then return nil end
                f.forbidden=f.forbidden+1;error('unexpected native access: '..key)
            end,
            __newindex=function() f.forbidden=f.forbidden+1;error('native write') end,
            __pairs=function() f.forbidden=f.forbidden+1;error('native enumeration') end})
        f.wrappers[proxy]=true;return proxy
    end
    f.state={WorldSaveDirectoryName=local_id:upper(),Role=3,bIsDedicatedServer=false}
    f.state_object=f.object(f.state,{WorldSaveDirectoryName=true,Role=true,bIsDedicatedServer=true})
    f.world={GameState=f.state_object,GetFullName=function() return target end}
    f.world_object=f.object(f.world,{GameState=true})
    f.viewport={World=f.world_object};f.viewport_object=f.object(f.viewport,{World=true})
    f.engine_fields={GameViewport=f.viewport_object}
    f.engine=f.object(f.engine_fields,{GameViewport=true})
    local function checked(out)
        assert(out.verified==false and out.storage==nil and out.key==nil and out.ready==nil)
        for _,value in pairs(out) do
            assert(not f.wrappers[value],'retained wrapper')
            assert(type(value)=='string' or type(value)=='number' or type(value)=='boolean')
            if type(value)=='string' then assert(not value:find('PRIVATE',1,true)) end
        end
        assert(f.forbidden==0)
        return out
    end
    function f.read() return checked(Probe.read(f.engine)) end
    function f.read_identity() return checked(Identity.read(f.engine)) end
    return f
end
local f=fixture();local out=f.read()
assert(out.status=='observed' and out.directory==local_id and out.directory_status=='format_valid')
assert(out.role==3 and out.role_status=='read' and out.dedicated==false and out.dedicated_status=='read')
assert(out.world==target)
for _,case in ipairs({{'','empty'},{string.rep('0',32),'zero_guid'},
    {'PRIVATE/display/path','malformed'},{string.rep('x',32),'malformed'},
    {string.rep('a',33),'malformed'},{string.rep('a',100000),'malformed'}}) do
    f=fixture();f.state.WorldSaveDirectoryName=case[1];out=f.read()
    assert(out.directory_status==case[2] and out.directory==nil)
end
f=fixture();f.state.WorldSaveDirectoryName=nil
assert(f.read().directory_status=='unavailable')
f=fixture();f.state.WorldSaveDirectoryName={ToString=function() return server_id:upper() end}
assert(f.read().directory==server_id)
for _,value in ipairs({false,17,{ToString=function() error('PRIVATE_CONVERSION') end},
    {ToString=function() return {} end}}) do
    f=fixture();f.state.WorldSaveDirectoryName=value;out=f.read()
    assert(out.directory==nil and (out.directory_status=='read_failed' or out.directory_status=='malformed'))
end
for _,role in ipairs({0,1,2,3}) do
    f=fixture();f.state.Role=role;out=f.read();assert(out.role==role and out.role_status=='read')
end
for _,role in ipairs({-1,4,1.5,0/0,math.huge,'3',false,{}}) do
    f=fixture();f.state.Role=role;out=f.read();assert(out.role==nil and out.role_status=='unknown')
end
for _,value in ipairs({true,false}) do
    f=fixture();f.state.bIsDedicatedServer=value;assert(f.read().dedicated==value)
end
for _,value in ipairs({0,1,'true',{}}) do
    f=fixture();f.state.bIsDedicatedServer=value;out=f.read()
    assert(out.dedicated==nil and out.dedicated_status=='unknown')
end
-- Each field failure is independent; a successful status never grants proof.
for _,case in ipairs({{'WorldSaveDirectoryName','directory_status'},
    {'Role','role_status'},{'bIsDedicatedServer','dedicated_status'}}) do
    f=fixture();f.state[case[1]]=nil
    assert(f.read()[case[2]]=='unavailable')
    f.world.GameState=setmetatable({}, {__index=function(_,key)
        if key==case[1] then error('PRIVATE_FIELD_FAILURE') end
        return f.state[key]
    end})
    out=f.read();assert(out.status=='observed' and out[case[2]]=='read_failed')
end
for _,part in ipairs({'engine_fields','viewport','world','state'}) do
    f=fixture();f[part].IsValid=function() return false end
    assert(f.read().status=='unavailable')
    f[part].IsValid=function() error('invalid wrapper') end
    assert(f.read().status=='unavailable')
end
for _,edge in ipairs({{'engine_fields','GameViewport'},{'viewport','World'},{'world','GameState'}}) do
    f=fixture();f[edge[1]][edge[2]]=nil;assert(f.read().status=='unavailable')
    f=fixture();f[edge[1]][edge[2]]=nil
    setmetatable(f[edge[1]],{__index=function(_,key)
        if key==edge[2] then error('PRIVATE_PROPERTY_FAILURE') end
    end})
    assert(f.read().status=='read_failed')
end
f=fixture();f.world.GetFullName=function() error('name unavailable') end
out=f.read();assert(out.world==nil and out.directory==local_id)
f.world.GetFullName=function() return string.rep('x',513) end
assert(f.read().world==nil)
assert(Probe.read(nil).status=='unavailable')

-- Same game instance retains local selection on a client while a newly
-- resolved world/GameState supplies a different replicated directory.
local function context_fixture()
    local c=fixture()
    c.world.GetAddress=function() return 101 end
    c.instance={SelectedWorldSaveDirectoryName=local_id,GetAddress=function() return 102 end}
    c.instance_object=c.object(c.instance)
    c.manager={bIsLoadedWorldSaveData=true,AutoSaveWorldDefaultName='',
        GetAddress=function() return 103 end,GetOuter=function() return c.instance_object end}
    c.manager_object=c.object(c.manager)
    c.instance.SaveGameManager=c.manager_object
    c.world.OwningGameInstance=c.instance_object
    return c
end
f=context_fixture()
local host=f.read();assert(host.directory==local_id and host.role==3)
local identity=f.read_identity()
assert(identity.selected==local_id and identity.loaded_world==true)
assert(identity.context_status=='context_agrees' and identity.world_address==101
    and identity.instance_address==102 and identity.manager_address==103)
f.manager.bIsLoadedWorldSaveData=false
local old_state,old_world=f.state,f.world
old_state.IsValid=function() error('stale GameState accessed') end
old_world.IsValid=function() error('stale world accessed') end
local client_state=f.object{WorldSaveDirectoryName=server_id,Role=1,bIsDedicatedServer=true}
local client_world=f.object{GameState=client_state,OwningGameInstance=f.instance_object,
    GetFullName=function() return target end,GetAddress=function() return 104 end}
f.viewport.World=client_world
local client=f.read();local retained=f.read_identity()
assert(client.directory==server_id and client.role==1 and client.dedicated==true)
assert(retained.selected==local_id and retained.loaded_world==false and retained.verified==false)
assert(retained.context_status=='context_agrees' and retained.world_address==104
    and retained.instance_address==102 and retained.manager_address==103)
assert(host.directory==local_id,'prior copied observation was mutated')
-- Replacing the entire engine tree also resolves fresh wrappers.
local next_fixture=fixture();next_fixture.state.WorldSaveDirectoryName=string.rep('c',32)
f.engine=next_fixture.engine;assert(f.read().directory==string.rep('c',32))

-- Candidate/loaded observations can survive an invalid context, but must never
-- acquire current-chain address tokens or storage permission. Keep all strict
-- wrapper/access/privacy assertions active for Identity as well as World.
local function rejected(c,reason)
    local observed=c.read_identity()
    assert(observed.selected==local_id and observed.loaded_world==true)
    assert(observed.context_status==reason)
    assert(observed.world_address==nil and observed.instance_address==nil and observed.manager_address==nil)
end
for _,mode in ipairs({'wrong','nil','invalid','throw'}) do
    local c=context_fixture()
    c.manager.GetOuter=function()
        if mode=='nil' then return nil end
        if mode=='throw' then error('PRIVATE_OWNER_READ_FAILURE') end
        return c.object{IsValid=function() return mode~='invalid' end,
            GetAddress=function() return 999 end}
    end
    rejected(c,'owner_unestablished')
end
for _,part in ipairs({'world','instance','manager'}) do
    for _,mode in ipairs({'nil','zero','negative','fractional','string','throw'}) do
        local c=context_fixture()
        c[part].GetAddress=function()
            if mode=='throw' then error('PRIVATE_ADDRESS_READ_FAILURE') end
            return ({zero=0,negative=-1,fractional=1.5,string='101'})[mode]
        end
        rejected(c,'owner_unestablished')
    end
end
-- Mutate each chain edge during the owner read: checking only the old addresses
-- would incorrectly accept these cases, even though loaded_world remains true.
for _,edge in ipairs({'world','instance','manager','invalid_world'}) do
    local c=context_fixture()
    c.manager.GetOuter=function()
        if edge=='world' or edge=='invalid_world' then
            c.viewport.World=c.object{IsValid=function() return edge~='invalid_world' end,
                GetAddress=function() return 201 end,OwningGameInstance=c.instance_object}
        elseif edge=='instance' then
            c.world.OwningGameInstance=c.object{GetAddress=function() return 202 end,
                SaveGameManager=c.manager_object}
        else
            c.instance.SaveGameManager=c.object{GetAddress=function() return 203 end}
        end
        return c.instance_object
    end
    rejected(c,'context_changed')
end
print('world identity: fresh GameState, current-chain addresses, invalid context rejection, privacy and no storage proof passed')
