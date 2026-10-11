local R=dofile(TEST_ROOT..'/experiments/settings_priority_parameter_roster.lua')
local function key(n)return string.rep('0',32)..string.format('%032X',n)end
local API=require('palapi')
local function id(n)return {PlayerUId={A=0,B=0,C=0,D=0},InstanceId={A=0,B=0,C=0,D=n}}end
local group='00000001000000020000000300000004'
local function fixture()
    local p={IndividualId=id(1)}
    p.IsValid=function()return true end;p.GetAddress=function()return 123 end
    p.GetGroupId=function()return {A=1,B=2,C=3,D=4}end
    return {params={p},api={unwrap=function(v)return v end,instance_key=API.instance_key},wanted={[key(1)]=true}}
end
local function read(f)return R.read(function()return f.params end,f.api,group,f.wanted)end
do local f=fixture();local r=read(f)
    assert(r.complete and r.matched==1 and r.observed==1 and r.requested==1)
    assert(r.records[1].group==group and not r.activation_allowed and not r.world_membership_proven)
    f.params[1].IndividualId=id(2);assert(r.records[1].key==key(1))
    assert(read(f).matched==0)
end
do local f=fixture();f.params={};local r=read(f)
    assert(r.complete and r.matched==0 and r.requested==1)end
do local f=fixture();f.params[1].GetGroupId=function()return {A=9,B=2,C=3,D=4}end
    local r=read(f);assert(r.complete and r.observed==1 and r.matched==0 and not r.records[1].matches)end
for _,edit in ipairs({
    function(f)f.params=nil end,
    function(f)f.params[2]=f.params[1]end,
    function(f)f.params[3]=f.params[1];f.params[1]=nil end,
    function(f)f.params[1].IsValid=function()return false end end,
    function(f)f.params[1].IndividualId=nil end,
    function(f)f.params[1].GetGroupId=function()error('unavailable')end end,
    function(f)f.params[1].GetGroupId=function()return {A=0,B=0,C=0,D=0}end end,
    function(f)f.params[1].GetGroupId=function()return {A=0/0,B=2,C=3,D=4}end end,
    function(f)f.params[1].GetGroupId=function()f.params[1].IndividualId=id(9);return {A=1,B=2,C=3,D=4}end end,
    function(f)f.params[1].GetGroupId=function()f.params[1].GetAddress=function()return 999 end;return {A=1,B=2,C=3,D=4}end end,
    function(f)f.wanted[key(1)]=false end,
    function(f)f.wanted.slot1=true end,
})do local f=fixture();edit(f);local r=read(f);assert(not r.complete and #r.records==0 and r.matched==0)end
do -- A late malformed object must not publish an earlier successful match.
    local f=fixture();f.params[2]={IsValid=function()return false end}
    local r=read(f);assert(not r.complete and #r.records==0)end
do -- Caller-owned request mutation during enumeration cannot widen this read.
    local f=fixture();local r=R.read(function()f.wanted[key(2)]=true;return f.params end,f.api,group,f.wanted)
    assert(r.complete and r.requested==1)end
do -- No wrappers retained in scalar observations.
    local weak=setmetatable({}, {__mode='v'})
    local function run()local f=fixture();weak[1]=f.params[1];return read(f)end
    local r=run();collectgarbage('collect');collectgarbage('collect')
    assert(weak[1]==nil and r.complete)end
print('priority parameter roster: missing/foreign/duplicate/change rejection, no authorization or retained wrappers')

for _,word in ipairs({1.5,4294967296,-2147483649,0/0,math.huge,'1'})do
    for _,part in ipairs({'PlayerUId','InstanceId'})do
        local f=fixture();f.params[1].IndividualId[part].A=word
        assert(not read(f).complete)
    end
end
do local f=fixture();f.params[1].IndividualId=id(0);assert(not read(f).complete)end
do local f=fixture();local other={IndividualId=id(2),IsValid=function()return true end,
    GetGroupId=function()error('non-target group read')end}
    f.params[2]=other;assert(read(f).complete)end

do -- Resolver receives the original struct, and must return the same parameter.
    local f=fixture();local calls=0
    local r=R.read(function()return f.params end,f.api,group,f.wanted,function(v)
        calls=calls+1;assert(v==f.params[1].IndividualId);return f.params[1]
    end)
    assert(r.complete and r.records[1].world_resolved and calls==1 and not r.world_membership_proven)
end
for _,mode in ipairs({'nil','throw','other_address','other_id','other_group','mutate_source'})do
    local f=fixture()
    local r=R.read(function()return f.params end,f.api,group,f.wanted,function(v)
        if mode=='nil'then return nil end
        if mode=='throw'then error('unavailable')end
        local p={IndividualId=id(1),IsValid=function()return true end,GetAddress=function()return 123 end,
            GetGroupId=function()return {A=1,B=2,C=3,D=4}end}
        if mode=='other_address'then p.GetAddress=function()return 999 end end
        if mode=='other_id'then p.IndividualId=id(2)end
        if mode=='other_group'then p.GetGroupId=function()return {A=9,B=2,C=3,D=4}end end
        if mode=='mutate_source'then f.params[1].IndividualId=id(3)end
        return p
    end)
    assert(not r.complete and r.reason=='world_lookup_rejected' and #r.records==0,mode)
end
