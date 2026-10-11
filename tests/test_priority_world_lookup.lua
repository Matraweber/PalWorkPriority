local R=dofile(TEST_ROOT..'/experiments/settings_priority_world_lookup.lua')
local function fixture()
    local function obj(n,t)t=t or {};t.IsValid=function()return true end;t.GetAddress=function()return n end;return t end
    local f={expected={world_address=1,state_address=2,instance_address=3,manager_address=4},id={},result={},calls=0}
    f.manager=obj(4);f.inst=obj(3,{SaveGameManager=f.manager});f.state=obj(2)
    f.world=obj(1,{GameState=f.state,OwningGameInstance=f.inst})
    f.view=obj(5,{World=f.world});f.engine=obj(6,{GameViewport=f.view,GameInstance=f.inst})
    f.utility=obj(7,{GetIndividualCharacterParameterByIstanceID=function(_,w,id)
        f.calls=f.calls+1;assert(w==f.world and id==f.id);return f.result end})
    return f
end
local function read(f)return R.read(f.engine,f.expected,f.id,f.utility)end
do local f=fixture();assert(read(f)==f.result and f.calls==1)end
for _,name in ipairs({'world','state','inst','manager'})do
    local f=fixture();f[name].GetAddress=function()return 99 end
    assert(not pcall(read,f) and f.calls==0)
end
for _,name in ipairs({'world','state','inst','manager'})do
    local f=fixture();local original=f.utility.GetIndividualCharacterParameterByIstanceID
    f.utility.GetIndividualCharacterParameterByIstanceID=function(...)
        local result=original(...);f[name].GetAddress=function()return 99 end;return result
    end
    assert(not pcall(read,f) and f.calls==1)
end
do local f=fixture();f.utility.IsValid=function()return false end;assert(not pcall(read,f) and f.calls==0)end
do local f=fixture();f.result=nil;assert(read(f)==nil)end
do local f=fixture();local original=f.utility.GetIndividualCharacterParameterByIstanceID
    f.utility.GetIndividualCharacterParameterByIstanceID=function(...)
        f.expected.world_address=99;return original(...)end
    assert(read(f)==f.result) -- expected scalars copied before callback, no widened proof
end
print('world parameter lookup: exact native input forwarding, fresh world chain before/after, no result on transition')
