local Probe=dofile(TEST_ROOT..'/experiments/save_destination_probe.lua')
local id=string.rep('a',32)
local function check(slot,success,world,state)
    local out=Probe.read(slot,success,world)
    assert(out.state==state,out.state)
    assert(out.verified==false and out.ready==nil and out.storage==nil and out.key==nil)
    for _,v in pairs(out) do assert(type(v)=='boolean' or type(v)=='string') end
    return out
end
for _,slot in ipairs({id..'/Level', 'account/'..id:upper()..'/Level.sav',
    'account\\'..id..'\\Level'}) do
    local o=check(slot,true,id,'successful_destination_candidate')
    assert(o.slot_candidate==id and o.world_candidate==id)
end
check(id..'/Level',true,string.rep('b',32),'conflicting_candidates')
check(id..'/Level',false,id,'failed_completion')
check(id..'/Level',nil,id,'unknown_completion')
check(id..'/Level','true',id,'unknown_completion')
for _,slot in ipairs({'../'..id..'/Level','folder/./'..id..'/Level',
    '/'..id..'/Level','C:/'..id..'/Level',id..'/Level/',id..'//Level',
    id..'/Players',id..'/LevelMeta.sav',string.rep('0',32)..'/Level',
    id..'/Level\n',string.rep('x',1025),''}) do
    assert(check(slot,true,id,'unrecognized_destination').slot_candidate==nil)
end
local o=check(id..'/Level',true,'Private display name','successful_destination_candidate')
assert(o.world_candidate==nil and o.world_status=='unrecognized')
for _,v in pairs(o) do assert(v~='Private display name') end
check(nil,true,nil,'unrecognized_destination')
-- No native string conversion, methods, enumeration or writes permitted.
local hostile=setmetatable({}, {__index=function() error('native access') end,
    __tostring=function() error('native conversion') end})
check(hostile,true,hostile,'unrecognized_destination')
print('save destination: bounded copied arguments, failed/unknown completions, no native calls or authority')
