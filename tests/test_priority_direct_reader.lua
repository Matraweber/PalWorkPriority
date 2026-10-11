-- Actual bridge, guild, parameter, world and membership modules together.
-- Native methods are fixtures; userdata IDs model const-ref forwarding only.
-- This does not claim native UE4SS marshalling/lifetime validation.
local Bridge=dofile(TEST_ROOT..'/experiments/settings_priority_live_reader.lua')
local API=require('palapi')
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

local function integrated(edit)
    local f=fixture();f.lookups=0;f.scans=0
    local handles={}
    -- A temporary file provides a Lua-owned userdata shell. Restore its original
    -- metatable before closing; no IO is performed through the fake struct.
    for _,entry in ipairs(f.items) do
        local fields=entry.HandleId
        local u=assert(io.tmpfile());local mt=debug.getmetatable(u)
        handles[#handles+1]={u=u,mt=mt}
        debug.setmetatable(u,{__index=fields})
        entry.HandleId=u
    end
    f.api.instance_key=API.instance_key
    f.parameter={IndividualId=f.items[2].HandleId,
        IsValid=function()return true end,GetAddress=function()return 99 end,
        GetGroupId=function()return f.guild.Id end}
    local utility={IsValid=function()return true end,GetAddress=function()return 100 end}
    utility.GetIndividualCharacterParameterByIstanceID=function(_,w,id)
        f.lookups=f.lookups+1
        assert(w==f.world and type(id)=='userdata' and id==f.items[2].HandleId)
        if f.lookup then return f.lookup(id)end
        return f.parameter
    end
    f.api.cdo=function(name)assert(name=='/Script/Pal.Default__PalUtility');return utility end
    local storage=string.rep('1',32)
    local c={storage=storage,guild=f.expected.guild,stream='priorities',session='boot',
        incarnation='inc',epoch=1,camp='camp',authority=true}
    c.scope='PWP-SCOPE-1:'..storage..':'..c.guild..':priorities'
    local snapshot={};for k,v in pairs(f.expected)do snapshot[k]=v end
    snapshot.storage=storage;snapshot.alias=f.expected.legacy_guild
    local b=assert(Bridge.new{enabled=true,context=c,runtime_guild=snapshot.alias,
        read_context=function()return snapshot end,get_engine=function()return f.engine end,
        enumerate=function()f.scans=f.scans+1;error('global scan forbidden')end,
        api=f.api,authorize=function()return true end})
    local ok,err=pcall(function()
        if edit then edit(f,b,c)else
            assert(b.owns_key(key(1),c));assert(f.lookups==4 and f.scans==0)
            assert(b.owns_key(key(1),c));assert(f.lookups==8 and f.scans==0)
        end
        assert(f.scans==0)
    end)
    for _,h in ipairs(handles)do debug.setmetatable(h.u,h.mt);h.u:close()end
    assert(ok,err)
end
integrated()
for _,failure in ipairs({
    function(f)f.items[2]=nil end,
    function(f)f.lookup=function()return nil end end,
    -- A successful visitor does not survive a later array/context failure.
    function(f)f.lookup=function()f.items[3]={HandleId=identity(3)};return f.parameter end end,
    function(f)f.items[3]=f.items[2] end,
    function(f)f.parameter.GetGroupId=function()return {A=9,B=2,C=3,D=4}end end,
    function(f)f.parameter.IndividualId=f.items[1].HandleId end,
    function(f)f.lookup=function()f.world.GameState=f.guild;return f.parameter end end,
    function(f)f.lookup=function()f.items[1].HandleId.InstanceId.D=0/0;return f.parameter end end,
    function(f)f.lookup=function()if f.lookups==3 then f.parameter.GetAddress=function()return 101 end end;return f.parameter end end,
    function(f)f.lookup=function()f.items[2].HandleId.InstanceId.D=1.5;return f.parameter end end,
})do
    integrated(function(f,b,c)
        failure(f);assert(not b.owns_key(key(1),c) and b.status().state=='revoked')
        local n=f.lookups;assert(not b.owns_key(key(1),c) and f.lookups==n)
    end)
end
print('direct priority reader: actual modules, zero global scans, fresh native-ID forwarding, missing/foreign/transition/malformed refusal')
