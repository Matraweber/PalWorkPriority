local authority, pal, camp, component, assignment, job
local calls=0
local function live(t) t.IsValid=function() return true end; return t end
local function reset()
    authority=true; calls=0; camp={id='camp'}
    job=live({GetWorkId=function() return 'job' end,BaseCampIdBelongTo='camp'})
    assignment=live({AssignedIndividualId='pal',bFixed=false,State=2,HandleId={WorkId='job'},
        GetWork=function() return job end,GetWorkSuitability=function() return 8 end})
    local handle=live({GetIndividualID=function() return 'pal' end})
    component=live({IndividualHandle=handle,GetBaseCampId=function() return 'camp' end,
        IsAssignedToAnyWork=function() return true end,IsAssignedFixed=function() return false end,
        GetWorkAssign=function() return assignment end})
    local actor=live({CharacterParameterComponent=component})
    handle.TryGetIndividualActor=function() calls=calls+1; return actor end
    pal={key='pal',handle=handle}
end
package.loaded.palapi={has_authority=function() return authority end,
    camp_id=function(c) return c.id end,
    guid_key=function(s) if type(s)=='string' then return s end end,
    instance_key=function(s) if type(s)=='string' then return s end end,
    valid=function(o) return type(o)=='table' and o.IsValid and o:IsValid()==true end,
    prop=function(o,k) local ok,v=pcall(function() return o[k] end); if ok then return v end end}
FindAllOf=function() error('reader must not sweep objects') end
FindFirstOf=FindAllOf; StaticFindObject=FindAllOf
local reader=require('assignments')
local function read() return reader.read(pal,camp) end
local count=0
local function test(name,fn) reset();fn();count=count+1;print('assignments: '..name) end
local function uncertain() local a=read();assert(a.state=='unknown' and a.manual==nil) end
test('automatic occupied work',function()
    local a=read();assert(a.state=='occupied' and a.manual==false and a.id=='job' and a.value==8 and calls==1)
end)
test('authority gate prevents native reads',function()
    authority=false;uncertain();authority=nil;uncertain();assert(calls==0)
end)
test('unknown actor is not idle',function() pal.handle.TryGetIndividualActor=function() return nil end;uncertain() end)
test('unreadable flags are not false',function() component.IsAssignedFixed=function() return nil end;uncertain() end)
test('missing handle and temporary identity refuse',function()
    pal.handle=nil;uncertain();reset();pal.key='slot1';uncertain();assert(calls==0)
end)
test('component owner and camp must agree',function()
    component.GetBaseCampId=function() return 'other' end;uncertain();reset()
    component.IndividualHandle.GetIndividualID=function() return 'other' end;uncertain()
end)
test('assignment owner, camp and handle must agree',function()
    assignment.AssignedIndividualId='other';uncertain();reset()
    job.BaseCampIdBelongTo='other';uncertain();reset()
    assignment.HandleId.WorkId='other';uncertain()
end)
test('conflicting fixed flags refuse',function() assignment.bFixed=true;uncertain() end)
test('fixed reservation and leave preserve manual intent',function()
    assignment.bFixed=true;component.IsAssignedFixed=function() return true end
    assignment.State=1;local a=read();assert(a.manual==true and a.state=='ready')
    assignment.State=3;a=read();assert(a.manual==true and a.state=='unknown' and a.id=='job')
end)
test('explicit unassigned requires both flags and absent record',function()
    component.IsAssignedToAnyWork=function() return false end;uncertain()
    assignment=nil;local a=read();assert(a.state=='ready' and a.manual==false and a.id==nil)
    component.IsAssignedFixed=function() return true end;uncertain()
end)
test('failed GetWorkAssign does not mean idle',function()
    component.IsAssignedToAnyWork=function() return false end
    component.GetWorkAssign=function() error('native failed') end;uncertain()
end)
test('assigned without readable record refuses',function() assignment=nil;uncertain() end)
test('state and suitability strictly validated',function()
    for _,s in ipairs({0,2.5,4}) do assignment.State=s;uncertain() end
    assignment.State=2
    for _,v in ipairs({0,8.5,14,999}) do assignment.GetWorkSuitability=function() return v end;uncertain() end
end)
test('next call reads changed assignment afresh',function()
    assert(read().value==8);assignment.GetWorkSuitability=function() return 5 end;assert(read().value==5)
    component.GetWorkAssign=function() return nil end;uncertain()
end)
test('result is plain data only',function()
    for _,v in pairs(read()) do assert(type(v)=='string' or type(v)=='number' or type(v)=='boolean') end
end)
local allocator=require('scheduler_plan')
local function plan_read()
    local p={key=pal.key,assignment=read(),base={[8]=true,[5]=true},
        priorities={[8]=2,[5]=1},ranks={[8]=1,[5]=1},observed_on={[8]=true}}
    return allocator.plan({assignment_mode='fill',max_pals_per_work_type=1,leave_unordered_pals_to_game=false}, {p}, {[5]=1}, {}, 100)
end
test('native fixed leave protects assignment against higher-priority demand',function()
    assignment.bFixed=true;component.IsAssignedFixed=function() return true end
    assignment.State=3
    local plan,report=plan_read()
    assert(plan.pal[8] and not plan.pal[5])
    assert(report.manual_unavailable==0)
end)
test('explicit native idle permits priority allocation',function()
    component.IsAssignedToAnyWork=function() return false end;assignment=nil
    local plan,report=plan_read()
    assert(plan.pal[5] and not plan.pal[8])
    assert(report.assignment_unknown==0 and report.manual_unavailable==0)
end)
test('missing native actor preserves existing permissions',function()
    pal.handle.TryGetIndividualActor=function() return nil end
    local plan,report=plan_read()
    assert(plan.pal[8] and not plan.pal[5])
    assert(report.manual_unavailable==1)
end)
test('missing actor with no observed permissions does not acquire work',function()
    pal.handle.TryGetIndividualActor=function() return nil end
    local p={key=pal.key,assignment=read(),base={[5]=true},
        priorities={[5]=1},ranks={[5]=1},observed_on={}}
    local plan=allocator.plan({assignment_mode='fill',max_pals_per_work_type=1,leave_unordered_pals_to_game=false}, {p}, {[5]=1}, {}, 100)
    assert(next(plan.pal)==nil)
end)
print(count..' direct assignment reader cases passed')
