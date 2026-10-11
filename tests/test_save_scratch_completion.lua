local M=dofile(TEST_ROOT..'/experiments/ue4ss-save-scratch-v3/Scripts/completion.lua')
local function fixture()
    local record={Generation=1,Session='scope',Payload='1|X',Checksum='abc',IsValid=function() return true end}
    local actor={TrialTag='incarnation',CompletedGeneration=1,Done=true,Busy=false,Success=true,
        LoadedSave=record,StartedSeconds=1,SaveFinishedSeconds=2,ReadStartedSeconds=2,CompletedSeconds=3,
        IsValid=function() return true end,GetFullName=function() return 'Class /World.Bridge' end}
    local box=M.new('incarnation');box:bind('/World.Bridge');box:arm(1)
    return box,actor,record,{get=function() return actor end}
end
do
    local box,actor,record,ctx=fixture()
    box:receive(ctx)
    record.Payload='changed';actor.CompletedGeneration=999;actor.Success=false
    box:receive(ctx) -- duplicate cannot overwrite the first copied result
    local copy=box:take(1)
    assert(copy.Success and copy.CompletedGeneration==1 and copy.LoadedSave.Payload=='1|X')
    local function scalar_tree(t)
        for _,v in pairs(t) do
            if type(v)=='table' then assert(getmetatable(v)==nil);scalar_tree(v)
            else assert(type(v)=='number' or type(v)=='boolean' or type(v)=='string') end
        end
    end
    scalar_tree(copy)
    box:arm(2);box:receive(ctx);assert(box:take(2)==nil)
end
for _,field in ipairs({'TrialTag','CompletedGeneration','GetFullName'}) do
    local box,actor,_,ctx=fixture()
    local original=actor[field]
    actor[field]=field=='TrialTag' and 'foreign' or field=='CompletedGeneration' and 42
        or function() return 'Class /Other.Bridge' end
    box:receive(ctx);assert(box:take(1)==nil)
    actor[field]=original;box:receive(ctx);assert(box:take(1).Success)
end
for _,field in ipairs({'Done','Busy','Success'}) do
    local box,actor,_,ctx=fixture()
    actor[field]=field=='Busy' and true or field=='Done' and false or 'unknown'
    box:receive(ctx);assert(box:take(1).error)
end
do
    local box,actor,_,ctx=fixture();actor.Success=false;actor.LoadedSave=nil
    box:receive(ctx);local r=box:take(1);assert(r.Success==false and not r.LoadedSave)
end
do
    local box,_,record,ctx=fixture();record.Payload=string.rep('x',65537)
    box:receive(ctx);assert(box:take(1).error)
end
do
    local box=fixture();assert(not pcall(box.arm,box,2));assert(not pcall(box.take,box,2))
    box:receive({get=function() error('expired context') end});assert(box:take(1).error)
    box:close();box:receive({get=function() error('closed inbox read an engine object') end})
    assert(not pcall(box.arm,box,3))
end
print('completion inbox: copied values, ownership, duplicate, inline failure, malformed and late-event guards passed')
