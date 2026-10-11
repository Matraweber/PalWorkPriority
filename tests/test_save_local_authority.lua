local Reader=dofile(TEST_ROOT..'/experiments/save_local_authority.lua')
local function fixture()
    local f={}
    local function obj(fields,id)
        fields.IsValid=function() return true end;fields.GetAddress=function()return id end
        return fields
    end
    f.guild=obj({Id={A=-1,B=2,C=3,D=4}},8)
    f.state=obj({Role=3,bIsDedicatedServer=false},3)
    f.world=obj({GameState=f.state,GetFullName=function()return 'World test' end},1)
    f.level=obj({OwningWorld=f.world},9)
    f.ps=obj({GuildBelongTo=f.guild,GetLevel=function()return f.level end},7)
    f.pc=obj({Role=3,PlayerState=f.ps,GetLevel=function()return f.level end},6)
    f.player=obj({PlayerController=f.pc},5)
    f.instance=obj({LocalPlayers={f.player}},2);f.world.OwningGameInstance=f.instance
    f.view=obj({World=f.world},4)
    f.engine=obj({GameInstance=f.instance,GameViewport=f.view},10)
    f.expected={world='World test',world_address=1,state_address=3,instance_address=2}
    return f
end
do
    local f=fixture();local r=Reader.read(f.engine,f.expected)
    assert(r.authority==true and r.guild=='ffffffff000000020000000300000004')
    assert(r.legacy_guild=='-1-2-3-4')
    for _,v in pairs(r) do assert(type(v)~='table' and type(v)~='userdata' and type(v)~='function') end
end
for _,change in ipairs({
    function(f)f.engine.GameViewport=nil end,
    function(f)f.instance.LocalPlayers={} end,
    function(f)f.state.Role=2 end,
    function(f)f.state.bIsDedicatedServer=true end,
    function(f)f.pc.Role=2 end,
    function(f)f.level.OwningWorld={IsValid=function()return true end,GetAddress=function()return 99 end}end,
    function(f)f.expected.state_address=77 end,
    function(f)f.guild.Id.A=0/0 end,
    function(f)f.guild.Id={A=0,B=0,C=0,D=0}end,
    function(f)f.guild.Id.A=4294967296 end,
    function(f)f.guild.IsValid=function()return false end end,
    function(f)f.ps.GetLevel=function()error('unavailable')end end,
    function(f)f.guild.Id=setmetatable({}, {__index=function()return '1' end})end,
}) do
    local f=fixture();change(f);local r=Reader.read(f.engine,f.expected)
    assert(r.authority~=true and r.guild==nil,'unavailable must never authorize')
end
do
    local f=fixture();local n=0
    f.guild.GetAddress=function() n=n+1;return n==1 and 8 or 18 end
    assert(Reader.read(f.engine,f.expected).authority~=true)
end
do
    local f=fixture();local n=0
    f.guild.Id=setmetatable({}, {__index=function(_,k)
        if k=='A' then n=n+1;return n end
        return 2
    end})
    assert(Reader.read(f.engine,f.expected).authority~=true)
end
print('fresh local authority: same-world local controller/guild, signed aliases, no wrappers, changed/unknown evidence refused')
