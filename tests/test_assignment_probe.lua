local calls, authority, camps, assignments, roster_error, scan_complete
local function obj(t)
    t.IsValid=function() return true end
    return t
end
local function reset()
    calls, authority, roster_error, scan_complete = 0, true, nil, true
    camps={{id='camp', pals={{key='pal', name='worker', param={current=8}}}}}
    local work=obj({GetWorkId=function() return 'job' end, BaseCampIdBelongTo='camp'})
    assignments={obj({AssignedIndividualId='pal', HandleId={WorkId='job'},
        State=2, bFixed=false, GetWork=function() return work end,
        GetWorkSuitability=function() return 8 end})}
end
reset()
local api={latch_authority=function() return authority end,
    has_authority=function() return authority end,
    valid=function(o) return type(o)=='table' and o.IsValid and o:IsValid() == true end,
    prop=function(o,k) local ok,v=pcall(function() return o[k] end); if ok then return v end end,
    guid_key=function(s) if type(s)=='string' then return s end end,
    instance_key=function(s) if type(s)=='string' then return s end end,
    camp_id=function(c) return c.id end,
    camp_pals=function(c) return c.pals,roster_error end,
    current_work_suitability=function(p) return p.current end}
api.base_camps=function() calls=calls+1; api.camps_available=scan_complete; return camps end
package.loaded.palapi=api
FindAllOf=function(class) assert(class=='PalWorkAssign'); calls=calls+1; return assignments end
local probe=require('assignment_probe')
local function read() return probe.read() end
local function evidence() return read().rows[1].evidence end
local tests=0
local function test(name,fn)
    reset(); fn(); tests=tests+1; print('assignment probe: '..name)
end
test('fresh authority required before any enumeration',function()
    authority=false; assert(not read().authoritative and calls==0)
    authority=nil; assert(not read().authoritative and calls==0)
end)
test('automatic occupied assignment with matching job and camp',function()
    local r=read(); local a=r.rows[1].evidence
    assert(r.complete and a.state=='occupied' and a.manual==false and a.value==8 and a.id=='job')
    assert(calls==2)
end)
test('explicit fixed true survives',function()
    assignments[1].bFixed=true; assert(evidence().manual==true)
end)
test('missing fixed flag is unknown, never false',function()
    assignments[1].bFixed=nil; assert(evidence().manual==nil and evidence().state=='unknown')
end)
test('no matching record is not proven idle',function()
    assignments={}; local r=read()
    assert(r.complete and r.rows[1].evidence.state=='unknown' and r.rows[1].evidence.manual==nil)
end)
test('documented nil enumeration means no records, not proven idle',function()
    assignments=nil
    local r=read()
    assert(r.complete and r.assignments==0 and r.reason==nil)
    assert(r.rows[1].evidence.state=='unknown' and r.rows[1].evidence.manual==nil)
    assert(r.rows[1].direct.state=='unknown')
end)

test('thrown or malformed enumeration is still unavailable',function()
    local original=FindAllOf
    FindAllOf=function() error('scan failed') end
    assert(not read().complete)
    FindAllOf=function() return false end
    assert(not read().complete)
    FindAllOf=original
end)

test('reserve and leave are not occupied or completed',function()
    assignments[1].State=1; assert(evidence().state=='reserved')
    assignments[1].State=3; assert(evidence().state=='unknown')
    assignments[1].State=0; assert(evidence().state=='unknown')
end)
test('mismatched and unavailable camp cannot verify',function()
    camps[1].id='elsewhere'; assert(evidence().state=='unknown')
    camps[1].id=nil; assert(not read().complete and evidence().state=='unknown')
end)
test('job identity must match assignment handle',function()
    assignments[1].HandleId.WorkId='another'; assert(evidence().state=='unknown')
    assignments[1].HandleId=nil; assert(evidence().state=='unknown')
end)
test('fractional and unsupported states/types are unavailable',function()
    assignments[1].State=2.5; assert(evidence().state=='unknown')
    assignments[1].State=2
    for _,v in ipairs({0,8.5,14,999}) do
        assignments[1].GetWorkSuitability=function() return v end
        assert(evidence().state=='unknown')
    end
end)
test('multiple records never choose an arbitrary assignment',function()
    assignments[2]=assignments[1]; assert(evidence().state=='unknown')
end)
test('duplicate roster identity never verifies',function()
    camps[2]={id='other',pals=camps[1].pals}
    local r=read(); assert(not r.complete)
    for _,row in ipairs(r.rows) do assert(row.evidence.state=='unknown') end
end)
test('failed and partial enumeration remain incomplete',function()
    roster_error='partial'; assert(not read().complete)
    roster_error=nil; scan_complete=false; assert(not read().complete and calls==3)
end)
test('native failure is unavailable and does not escape',function()
    assignments[1].GetWork=function() error('native unavailable') end
    local r=read(); assert(not r.complete and r.failures==1 and r.rows[1].evidence.state=='unknown')
end)
test('over-budget enumeration refuses rather than truncating to certainty',function()
    for i=2,4097 do assignments[i]=assignments[1] end
    local r=read(); assert(not r.complete and r.assignments==0 and r.reason:find('budget'))
end)
test('results contain no engine wrappers or functions',function()
    assignments[1].bFixed=obj({}); assignments[1].State=obj({})
    local function plain(t)
        for _,v in pairs(t) do
            assert(type(v)~='userdata' and type(v)~='function')
            if type(v)=='table' then assert(not v.IsValid); plain(v) end
        end
    end
    plain(read())
end)
test('format preserves false and labels scope of evidence',function()
    local text=probe.format(read())
    assert(text:find('fixed=false',1,true) and text:find('NOT scheduler verification',1,true))
end)
test('report never changes scheduler integration',function()
    local sentinel={assignment_reader=nil}; package.loaded.scheduler=sentinel
    read(); assert(sentinel.assignment_reader==nil)
end)
test('director observations are bounded scalars, never assignment evidence',function()
    assignments=nil
    camps[1].WorkerDirector=obj({BaseCampId='camp',State=1,bEnableWorkerPlayerTracking=false})
    local reads={};local original=api.prop
    api.prop=function(o,k) reads[k]=(reads[k] or 0)+1;return original(o,k) end
    local r=read();api.prop=original
    local d=assert(r.directors and r.directors[1],'missing director observation')
    assert(#r.directors==1 and d.camp=='camp' and d.state==1 and d.state_name=='WaitForLoadingAround')
    assert(d.tracking==false and d.available==true and calls==2)
    for _,key in ipairs({'WorkerDirector','BaseCampId','State','bEnableWorkerPlayerTracking'}) do
        assert(reads[key]==1,'director field must be read once per camp: '..key)
    end
    assert(r.complete and r.rows[1].evidence.state=='unknown' and r.rows[1].evidence.manual==nil)
    assert(r.rows[1].direct.state=='unknown')
    local text=probe.format(r)
    assert(text:find('director camp=camp state=1 (WaitForLoadingAround) player_tracking=false',1,true))
    camps[1].WorkerDirector.State=2;camps[1].WorkerDirector.bEnableWorkerPlayerTracking=true
    assert(d.state==1 and d.tracking==false,'report retained mutable native fields')
    r=read();assert(r.directors[1].state_name=='Active' and r.directors[1].tracking==true)
    assert(r.rows[1].evidence.state=='unknown','Active director fabricated an assignment')
end)
test('missing foreign malformed and throwing directors stay unavailable',function()
    assignments=nil
    local function unavailable()
        local r=read();assert(r.directors and not r.directors[1].available)
        assert(r.complete and r.rows[1].evidence.state=='unknown','diagnostic changed census semantics')
        return r.directors[1]
    end
    assert(unavailable().tracking==nil)
    camps[1].WorkerDirector=obj({BaseCampId='foreign',State=2,bEnableWorkerPlayerTracking=true})
    assert(unavailable().state==nil,'foreign director state was published')
    camps[1].WorkerDirector.BaseCampId='camp'
    for _,bad in ipairs({1.5,99,math.huge,{},'2'}) do
        camps[1].WorkerDirector.State=bad;unavailable()
    end
    camps[1].WorkerDirector.State=0
    for _,bad in ipairs({{},'false',0}) do
        camps[1].WorkerDirector.bEnableWorkerPlayerTracking=bad
        assert(unavailable().tracking==nil,'nonboolean tracking was coerced')
    end
    camps[1].WorkerDirector={IsValid=function()error('native unavailable')end}
    assert(unavailable().tracking==nil)
end)
test('authority and camp budget fence director observations',function()
    local original=api.prop;local reads=0
    api.prop=function(...) reads=reads+1;return original(...) end
    authority=false;assert(not read().authoritative and reads==0)
    authority=true;for i=2,33 do camps[i]=camps[1] end
    local r=read();api.prop=original
    assert(not r.complete and #r.directors==0 and reads==0,'over-budget census touched directors')
end)
print(tests..' assignment census regressions passed')
