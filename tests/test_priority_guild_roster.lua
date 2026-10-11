local Reader=dofile(TEST_ROOT..'/experiments/settings_priority_guild_roster.lua')
local function key(n) return string.rep('0',32)..string.format('%032X',n) end
local function identity(n)
    return {key=key(n),PlayerUId={A=0,B=0,C=0,D=0},InstanceId={A=0,B=0,C=0,D=n}}
end
local function fixture()
    local f={calls=0,unwraps=0}
    local function object(id,fields)
        fields=fields or {}
        fields.IsValid=function() return true end
        fields.GetAddress=function() return id end
        return fields
    end
    -- Struct/array traps make any accidental native method use fail the test.
    local function struct(fields)
        return setmetatable(fields,{__index=function(_,k) error('unexpected struct access '..k) end})
    end
    f.items={struct({HandleId=identity(2)}),struct({HandleId=identity(1)})}
    f.array=object(11,{IndividualCharacterHandleIds=struct({Items=f.items})})
    f.guild=object(8,{Id=struct({A=-1,B=2,C=3,D=4}),IndividualIdArray=f.array})
    f.ps=object(7,{GuildBelongTo=f.guild})
    f.pc=object(6,{PlayerState=f.ps})
    f.player=object(5,{PlayerController=f.pc})
    f.manager=object(12)
    f.instance=object(2,{LocalPlayers={f.player},SaveGameManager=f.manager})
    f.state=object(3)
    f.world=object(1,{OwningGameInstance=f.instance,GameState=f.state})
    f.view=object(4,{World=f.world})
    f.engine=object(10,{GameViewport=f.view,GameInstance=f.instance})
    f.expected={world='World fixture',guild='ffffffff000000020000000300000004',legacy_guild='-1-2-3-4',
        world_address=1,state_address=3,instance_address=2,player_address=5,controller_address=6,
        player_state_address=7,guild_address=8,manager_address=12}
    f.api={unwrap=function(v) f.unwraps=f.unwraps+1; return v end,
        instance_key=function(id) f.calls=f.calls+1; return id.key end}
    return f
end
local function read(f) return Reader.read(f.engine,f.expected,f.api) end
local function scalar_report(r)
    assert(type(r.complete)=='boolean' and type(r.reason)=='string' and type(r.count)=='number')
    assert(getmetatable(r)==nil and getmetatable(r.keys)==nil and #r.keys==r.count)
    for k,v in pairs(r) do
        if k=='keys' then for i,id in pairs(v) do assert(type(i)=='number' and type(id)=='string') end
        else assert(type(v)=='number' or type(v)=='string' or type(v)=='boolean') end
    end
end
do
    local f=fixture(); local n=0
    f.array.GetAddress=function() n=n+1;return 11 end
    local r=read(f);scalar_report(r)
    assert(r.complete and r.count==2 and r.array_address==11 and r.keys[1]==key(1) and r.keys[2]==key(2))
    assert(n==2 and f.calls==2 and f.unwraps>0)
    f.items[1].HandleId.key=key(9);assert(r.keys[2]==key(2))
    assert(read(f).keys[2]==key(9)) -- every read is fresh
end
do local f=fixture(); f.array.IndividualCharacterHandleIds.Items={}
    local r=read(f);assert(r.complete and r.count==0) end
do -- Do not filter human-shaped IDs (nonzero player GUID and instance GUID).
    local f=fixture(); f.items[1].HandleId.key=string.rep('A',64)
    assert(read(f).complete) end
do local f=fixture(); f.expected.engine_address=10;f.expected.viewport_address=4
    assert(read(f).complete);f.expected.engine_address=99;assert(not read(f).complete) end
do local f=fixture(); f.expected.manager_address=nil;f.instance.SaveGameManager=nil
    assert(read(f).complete) end

local failures={
    function(f)f.engine.GameViewport=nil end,
    function(f)f.view.World=nil end,
    function(f)f.world.OwningGameInstance=nil end,
    function(f)f.world.GameState=nil end,
    function(f)f.engine.GameInstance=f.guild end,
    function(f)f.instance.LocalPlayers={} end,
    function(f)f.player.PlayerController=nil end,
    function(f)f.pc.PlayerState=nil end,
    function(f)f.ps.GuildBelongTo=nil end,
    function(f)f.instance.SaveGameManager=nil end,
    function(f)f.guild.Id=nil end,
    function(f)f.guild.Id.A=0/0 end,
    function(f)f.guild.Id.A=4294967296 end,
    function(f)f.guild.Id={A=0,B=0,C=0,D=0} end,
    function(f)f.guild.IndividualIdArray=nil end,
    function(f)f.array.IsValid=function()return false end end,
    function(f)f.array.GetAddress=function()return {} end end,
    function(f)f.array.IndividualCharacterHandleIds=nil end,
    function(f)f.array.IndividualCharacterHandleIds.Items=nil end,
    function(f)f.array.IndividualCharacterHandleIds.Items='' end,
    function(f)f.items[2]=f.items[1] end,
    function(f)f.items[1].HandleId=nil end,
    function(f)f.api.unwrap=function()return nil end end,
    function(f)f.api.instance_key=function()error(f.guild)end end,
    function(f)f.items[4]=f.items[2];f.items[2]=nil end,
    function(f)f.items.extra=true end,
    function(f)for i=3,4097 do f.items[i]={HandleId=identity(i)} end end,
}
for i,edit in ipairs(failures) do
    local f=fixture(); edit(f);local r=read(f);scalar_report(r)
    assert(not r.complete and r.count==0 and #r.keys==0,'failure '..i)
end
for _,bad in ipairs({false,{},'abc',string.rep('a',64),string.rep('0',64),
    string.rep('A',32)..string.rep('0',32),string.rep('A',63),string.rep('G',64)}) do
    local f=fixture();f.api.instance_key=function()return bad end
    assert(not read(f).complete)
end
do local f=fixture();f.api.instance_key=function()return nil end;assert(not read(f).complete)end
for _,field in ipairs({'world_address','state_address','instance_address','player_address',
    'controller_address','player_state_address','guild_address'}) do
    for _,bad in ipairs({false,{},'1',0,-1,0/0,math.huge,1.5}) do
        local f=fixture();f.expected[field]=bad;local r=read(f)
        assert(not r.complete and r.reason=='invalid_expected' and f.calls==0)
    end
    local f=fixture();f.expected[field]=nil;assert(not read(f).complete)
    f=fixture();f.expected[field]=99;assert(not read(f).complete)
end
for _,field in ipairs({'guild','legacy_guild','world'}) do
    local f=fixture();f.expected[field]=nil;assert(not read(f).complete)
end
for _,edit in ipairs({
    function(f)f.api={} end,
    function(f)f.api.instance_key=false end,
    function(f)f.api.unwrap=nil end,
    function(f)setmetatable(f.api,{__index=function()error('must not access')end})end,
    function(f)setmetatable(f.expected,{__index=function()error('must not access')end})end,
    function(f)f.expected.guild=string.rep('A',32)end,
    function(f)f.expected.legacy_guild='1-2-3-4'end,
}) do local f=fixture();edit(f);assert(not read(f).complete) end
assert(not Reader.read(nil,nil,nil).complete)

-- Mutate each link during normalization: the second fresh chain must refuse it.
for _,name in ipairs({'engine','view','world','state','instance','player','pc','ps','guild','array','manager'}) do
    local f=fixture();local original=f.api.instance_key
    f.api.instance_key=function(id)
        f[name].GetAddress=function()return 999 end
        return original(id)
    end
    local r=read(f);assert(not r.complete and r.reason=='context_or_array_changed',name)
end
for _,edit in ipairs({
    function(f)f.items[3]={HandleId=identity(3)}end,
    function(f)f.items[2]=nil end,
    function(f)f.guild.Id.A=2 end,
    function(f)f.guild.IndividualIdArray={IsValid=function()return true end,GetAddress=function()return 99 end,
        IndividualCharacterHandleIds={Items=f.items}}end,
}) do
    local f=fixture();local original=f.api.instance_key
    f.api.instance_key=function(id)local k=original(id);if f.calls==2 then edit(f)end;return k end
    local r=read(f);assert(not r.complete and r.count==0)
end
do -- Reflected array facade: length checked before each index, no array/struct method calls.
    local f=fixture();local lengths=0
    f.array.IndividualCharacterHandleIds.Items=setmetatable({}, {
        __len=function() lengths=lengths+1;return 2 end,
        __index=function(_,i)assert(type(i)=='number');return f.items[i]end})
    assert(read(f).complete and lengths==4)
end
for _,count in ipairs({-1,1.5,4097,math.huge,0/0,'2',false}) do
    local f=fixture()
    f.array.IndividualCharacterHandleIds.Items=setmetatable({}, {__len=function()return count end})
    assert(not read(f).complete)
end
do -- Unwrap remote entry parameters before accessing HandleId.
    local f=fixture();local old=f.api.unwrap
    local wrapped={inner=f.items[1]};f.items[1]=wrapped
    f.api.unwrap=function(v)if v==wrapped then return wrapped.inner end;return old(v)end
    assert(read(f).complete)
end
do local f=fixture()
    for i=3,4096 do f.items[i]={HandleId=identity(i)}end
    local r=read(f);assert(r.complete and r.count==4096) end
do -- Neither successful reports nor caught wrapper exceptions retain inputs.
    for _,fail in ipairs({false,true}) do
        local weak=setmetatable({}, {__mode='v'})
        local function run()
            local f=fixture();local n=0
            for _,v in pairs(f)do if type(v)=='table'then n=n+1;weak[n]=v end end
            weak[n+1]=f.items[1];weak[n+2]=f.items[1].HandleId
            if fail then f.api.instance_key=function()error(f.guild)end end
            return read(f)
        end
        local r=run();collectgarbage('collect');collectgarbage('collect')
        assert(next(weak)==nil,'wrapper retained');scalar_report(r);assert(r.complete==not fail)
    end
end
print('guild roster: declared property route, scalar sorted IDs, context/array fences, no retention')

do -- Empty LocalPlayers must never invoke numeric indexing.
    local f=fixture();local indexed=false
    f.instance.LocalPlayers=setmetatable({}, {__len=function()return 0 end,
        __index=function()indexed=true;error('unsafe index')end})
    assert(not read(f).complete and not indexed)
end
do -- A shrinking reflected array must refuse before its next numeric read.
    local f=fixture();local count=2;local indices={}
    f.array.IndividualCharacterHandleIds.Items=setmetatable({}, {
        __len=function()return count end,
        __index=function(_,i)indices[#indices+1]=i;return f.items[i]end})
    local original=f.api.instance_key
    f.api.instance_key=function(id)local k=original(id);count=0;return k end
    local r=read(f)
    assert(not r.complete and r.count==0 and #indices==1 and indices[1]==1)
end

-- Invalid words must not reach either formatting or a native visitor.
for _, name in ipairs({'PlayerUId','InstanceId'}) do
    for _, field in ipairs({'A','B','C','D'}) do
        for _, bad in ipairs({false,'1',1.5,0/0,math.huge,-2147483649,4294967296}) do
            local f=fixture();f.items[1].HandleId[name][field]=bad
            local visits=0
            local r=Reader.read(f.engine,f.expected,f.api,function()visits=visits+1 end)
            assert(not r.complete and f.calls==0 and visits==0)
        end
    end
end
do
    local f=fixture();local visits=0
    local r=Reader.read(f.engine,f.expected,f.api,function(k,id)
        visits=visits+1;assert(id==f.items[visits].HandleId and k==id.key)
    end)
    assert(r.complete and visits==2)
end
do
    local f=fixture()
    local r=Reader.read(f.engine,f.expected,f.api,function()error('visitor failed')end)
    assert(not r.complete and r.count==0 and #r.keys==0)
end
do
    local f=fixture()
    local r=Reader.read(f.engine,f.expected,f.api,function()f.world.GetAddress=function()return 999 end end)
    assert(not r.complete and r.count==0)
end

-- Same-count replacement after a visitor must fail that read, not rely on a
-- later paired observation. Poison the old struct to catch stale dereferences.
do
    local f=fixture();local visits=0;local stale=false
    local r=Reader.read(f.engine,f.expected,f.api,function(k,id)
        visits=visits+1
        local old=f.items[1].HandleId
        f.items[1]={HandleId=identity(9)}
        for name in pairs(old)do old[name]=nil end
        setmetatable(old,{__index=function()stale=true;error('stale identity touched')end})
    end,key(2))
    assert(not r.complete and r.count==0 and visits==1 and not stale)
end
do
    local f=fixture();local visits=0
    local r=Reader.read(f.engine,f.expected,f.api,function(k)
        visits=visits+1;assert(k==key(1))
    end,key(1))
    assert(r.complete and visits==1)
end
