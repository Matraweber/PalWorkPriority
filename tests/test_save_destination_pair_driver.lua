local path=TEST_ROOT..'/experiments/ue4ss-save-destination-pair/Scripts/main.lua'
local file=assert(io.open(path,'r'))
local code=file:read('*a');file:close()
local Probe=dofile(TEST_ROOT..'/experiments/save_identity_probe.lua')
local Destination=dofile(TEST_ROOT..'/experiments/save_destination_probe.lua')
local target='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local id=string.rep('a',32)

local function fixture(options)
    options=options or {}
    local s={now=0,control=options.control or 'PWP_DESTINATION_PAIR_RUN fixture',
        logs={},cancels=0,reads=0,loads=0,forbidden=0,hooks=0,lanes={},gets=0,classifications=0,prints={}}
    local env={}
    setmetatable(env,{__index=function(_,key)
        s.forbidden=s.forbidden+1
        error('unexpected driver global: '..tostring(key))
    end})
    for _,key in ipairs({'assert','debug','ipairs','pcall','table','tostring','type'}) do env[key]=_G[key] end
    local function object(fields)
        fields.IsValid=function() return true end
        return setmetatable({},{__newindex=function() s.forbidden=s.forbidden+1;error('game write') end, __index=function(_,key)
            if fields[key]~=nil then return fields[key] end
            -- Count even accesses swallowed by the probe's pcall.
            s.forbidden=s.forbidden+1
            error('unexpected property or native getter: '..tostring(key))
        end})
    end
    local generation=0
    function s.world(name,selected,autosave)
        -- Fresh native identities and owner links accompany replacement wrappers.
        generation=generation+1
        local base=generation*10
        local instance_fields={SelectedWorldSaveDirectoryName=selected or id,
            GetAddress=function() return base+2 end}
        local instance=object(instance_fields)
        instance_fields.SaveGameManager=object{
            AutoSaveWorldDefaultName=autosave or id,bIsLoadedWorldSaveData=true,
            GetAddress=function() return base+3 end,GetOuter=function() return instance end}
        s.engine=object{GameViewport=object{World=object{
            GetFullName=function() return name end,GetAddress=function() return base+1 end,
            OwningGameInstance=instance
        }}}
    end
    s.world('World splash')
    env.os={time=function() return s.now end,date=function() return 'fixture-time ' end}
    env.print=function(line)
        assert(not s.in_hook)
        if s.output_failure=='print' then error('console unavailable') end
        s.prints[#s.prints+1]=line
        if s.on_print then s.on_print(line) end
    end
    env.io={open=function(p,mode)
        if s.in_hook then s.forbidden=s.forbidden+1;error("hook IO") end
        if p:match('/run.txt$') then
            if mode=='r' then
                if options.missing then return nil end
                return {read=function() return s.control end,close=function() return true end}
            end
            assert(mode=='w')
            if options.open_failure then return nil end
            return {write=function(_,text)
                assert(text=='DISABLED\n')
                if options.write_failure then return nil end
                s.control=text;return true
            end,close=function() return not options.close_failure end}
        end
        assert(p:match('/destination%-pair.log$') and mode=='a','unexpected file access')
        assert(s.control=='DISABLED\n')
        if s.output_failure=='open' then return nil end
        return {write=function(_,text)
            if s.output_failure=='write' then return nil end
            s.logs[#s.logs+1]=text;return true
        end,close=function() return s.output_failure~='close' end}
    end}
    env.dofile=function(p)
        assert(s.control=='DISABLED\n')
        s.loads=s.loads+1
        if p:match('/experiments/save_identity_probe.lua$') then return Probe end
        assert(p:match('/experiments/save_destination_probe.lua$'))
        return {read=function(slot,success,world)
            s.classifications=s.classifications+1
            assert(slot==nil or type(slot)=='string')
            assert(success==nil or type(success)=='boolean')
            assert(world==nil or type(world)=='string')
            if options.classifier_failure then error('private classifier error') end
            return Destination.read(slot,success,world)
        end}
    end
    env.RegisterHook=function(name,fn)
        assert(s.control=='DISABLED\n')
        local lane
        if name=='/Script/Pal.PalSaveGameManager:OnFinishedWorldAsyncSaveGamePreInternal' then lane='destination'
        elseif name=='/Script/Pal.PalStaticLogCollector:OnEndedWorldAutoSave' then lane='notification'
        else error('unexpected hook: '..name) end
        assert(not s.lanes[lane]);s.hooks=s.hooks+1;s.lanes[lane]=fn
        if s.hooks==2 then s.output_failure=options.registration_output_failure end
        if options[lane..'_failure'] then error('registration failed after retaining callback') end
        return 11,12
    end
    env.require=function(name)
        assert(name=='UEHelpers')
        return {GetEngine=function()
            if s.in_hook then s.forbidden=s.forbidden+1;error('hook engine access') end
            s.reads=s.reads+1
            if options.engine_failure then error('fixture engine unavailable') end
            return s.engine
        end}
    end
    env.LoopInGameThreadWithDelay=function(ms,fn)
        assert(ms==1000 and not s.callback and s.control=='DISABLED\n')
        s.callback=fn
        if options.timer_throws then error('timer failed after retaining callback') end
        if options.timer_failure then return nil end
        return 73
    end
    env.CancelDelayedAction=function(handle)
        assert(handle==73)
        s.cancels=s.cancels+1
        if options.cancel_throws then error('cancel failed') end
        return not options.cancel_failure
    end
    function s.arg(value,throws)
        return {get=function()
            s.gets=s.gets+1
            if throws then error('PRIVATE_ARGUMENT_ERROR') end
            return value
        end}
    end
    function s.fire(lane,slot,success,world)
        local ignored=setmetatable({}, {__index=function()
            s.forbidden=s.forbidden+1;error('unused callback argument accessed')
        end})
        local logs,reads,prints=#s.logs,s.reads,#s.prints
        s.in_hook=true
        local result
        if lane=='destination' then
            result=table.pack(pcall(s.lanes[lane],ignored,slot,ignored,success,world,ignored))
        else result=table.pack(pcall(s.lanes[lane],ignored,success)) end
        s.in_hook=false;assert(result[1],result[2])
        for i=2,result.n do assert(result[i]==nil,'hook must not override native return') end
        assert(#s.logs==logs and s.reads==reads and #s.prints==prints)
    end
    function s.event(lane)
        s.fire(lane,s.arg('PRIVATE_PREFIX/'..id..'/Level'),s.arg(true),s.arg(id))
    end
    function s.start() return pcall(assert(load(code,'@'..path,'t',env))) end
    function s.tick(time) s.now=time;assert(s.callback)() end
    function s.log() return table.concat(s.logs) end
    function s.has(text) return s.log():find(text,1,true)~=nil end
    function s.quiet_after_stop()
        local count,reads,cancels=#s.logs,s.reads,s.cancels
        local gets,classified=s.gets,s.classifications
        for lane in pairs(s.lanes) do s.event(lane) end
        if s.callback then s.tick(s.now+1);s.tick(s.now+300) end
        assert(s.gets==gets and s.classifications==classified)
        assert(#s.logs==count and s.reads==reads and s.cancels==cancels)
        assert(s.forbidden==0,'unexpected native getter/property access')
    end
    return s
end

-- Fixture identities must satisfy the real collector while remaining unverified.
do
    local sample=fixture()
    local before=Probe.read(sample.engine)
    assert(before.context_status=='context_agrees' and before.verified==false)
    assert(before.world_address and before.instance_address and before.manager_address)
    sample.world(target)
    local after=Probe.read(sample.engine)
    assert(after.context_status=='context_agrees' and after.verified==false)
    for _,key in ipairs({'world_address','instance_address','manager_address'}) do
        assert(after[key]~=before[key],'replacement must refresh '..key)
    end
    assert(sample.forbidden==0)
end


-- All file IO is mocked: only the arm and diagnostic sink are allowed.
for _,options in ipairs({{missing=true},{control='DISABLED\n'},
    {control='PWP_DESTINATION_PAIR_RUN '},{control='PWP_DESTINATION_PAIR_RUN extra words'},
    {control='PWP_DESTINATION_PAIR_RUN '..string.rep('x',65)},
    {control='PWP_DESTINATION_RUN old-arm'}}) do
    local s=fixture(options);assert(s.start())
    assert(s.hooks==0 and not s.callback and s.loads==0 and #s.logs==0)
end
for _,fault in ipairs({'open_failure','write_failure','close_failure'}) do
    local s=fixture({[fault]=true});assert(not s.start())
    assert(s.hooks==0 and not s.callback and s.loads==0 and #s.logs==0)
end
local function incomplete(s)
    assert(not s.has('OBSERVATION_COMPLETE') and s.cancels==0)
    assert(s.forbidden==0)
end
local function completed(s)
    assert(s.has('OBSERVATION_COMPLETE both lanes observed; not correlated or session-verified'))
    assert(s.cancels==1 and not s.has('verified=true'))
    assert(not s.has('PRIVATE') and not table.concat(s.prints):find('PRIVATE',1,true))
    s.quiet_after_stop()
end

-- Each lane alone stays active; the second lane completes, in either order.
for _,first in ipairs({'destination','notification'}) do
    local s=fixture();assert(s.start())
    assert(s.hooks==2 and s.loads==2 and s.reads==0 and s.control=='DISABLED\n')
    s.tick(0);local logs=#s.logs;s.tick(1);assert(#s.logs==logs)
    s.event(first);assert(not s.has('CALLBACK '));s.tick(2);incomplete(s)
    assert(s.has('CALLBACK lane='..first))
    logs=#s.logs;s.tick(3);assert(#s.logs==logs,'events must not be emitted twice')
    s.event(first=='destination' and 'notification' or 'destination')
    s.tick(4);completed(s)
    assert(s.has('timer_cancelled=true'))
    assert(s.start());assert(s.hooks==2 and s.loads==2)
end

-- Counts are lifetime caps, not buffer sizes; draining a lane cannot reset its cap.
for _,first in ipairs({'destination','notification'}) do
    local s=fixture();assert(s.start())
    for i=1,4 do s.event(first);s.tick(i);incomplete(s) end
    local gets,classified=s.gets,s.classifications
    for i=1,6 do s.event(first) end
    assert(s.gets==gets and s.classifications==classified)
    local second=first=='destination' and 'notification' or 'destination'
    for i=1,4 do s.event(second) end
    gets=s.gets;s.event(second);assert(s.gets==gets)
    s.tick(5);completed(s)
    local _,count=s.log():gsub('CALLBACK lane=','');assert(count==8)
end

-- Both callback signatures preserve false/nil/get errors and never return a Boolean.
for _,lane in ipairs({'destination','notification'}) do
    for _,mode in ipairs({'false','nil','throw','direct'}) do
        local s=fixture();assert(s.start())
        local success=s.arg(false)
        if mode=='nil' then success=s.arg(nil)
        elseif mode=='throw' then success=s.arg(nil,true)
        elseif mode=='direct' then success=true end
        s.fire(lane,id..'/Level',success,id);s.tick(1);incomplete(s)
        local status=(mode=='false' or mode=='direct') and 'read' or 'unavailable'
        assert(s.has('success_status='..status))
        if mode=='false' then assert(s.has('success=false')) end
        if lane=='destination' then
            assert(s.has('state='..(mode=='false' and 'failed_completion' or
                mode=='direct' and 'successful_destination_candidate' or 'unknown_completion')))
        else assert(s.has('state=notification_only')) end
        s.event(lane=='destination' and 'notification' or 'destination');s.tick(2);completed(s)
    end
end
for _,mode in ipairs({'path','oversized','slot_get','world_get','conversion','classifier'}) do
    local s=fixture({classifier_failure=mode=='classifier'});assert(s.start())
    local slot,world=s.arg('C:/PRIVATE/path'),s.arg('PRIVATE_WORLD')
    if mode=='oversized' then slot=s.arg(string.rep('x',1025))
    elseif mode=='slot_get' then slot=s.arg(nil,true)
    elseif mode=='world_get' then slot=s.arg(id..'/Level');world=s.arg(nil,true)
    elseif mode=='conversion' then slot=s.arg({ToString=function() error('PRIVATE_CONVERSION') end}) end
    s.fire('destination',slot,s.arg(true),world);s.event('notification');s.tick(1)
    completed(s)
    if mode=='classifier' then assert(s.has('state=classifier_failed')) end
end

-- Timeout is exactly 420 seconds, including either partial lane.
for _,lane in ipairs({'none','destination','notification'}) do
    local s=fixture();assert(s.start())
    if lane~='none' then s.event(lane) end
    s.tick(419);incomplete(s);assert(not s.has('TIMEOUT'))
    s.tick(420)
    assert(s.has('TIMEOUT destination='..(lane=='destination' and '1' or '0')..
        ' notification='..(lane=='notification' and '1' or '0')))
    assert(s.cancels==1 and not s.has('OBSERVATION_COMPLETE'));s.quiet_after_stop()
end

-- Independent registration: a retained failed-lane callback stays inert even
-- while its successful peer continues to collect and eventually times out.
for _,failed in ipairs({'destination','notification','both'}) do
    local s=fixture({destination_failure=failed~='notification',notification_failure=failed~='destination'})
    assert(s.start());assert(s.hooks==2)
    if failed=='both' then
        assert(s.has('HOOKS_UNAVAILABLE') and not s.callback and s.cancels==0)
    else
        local gets=s.gets;s.event(failed);assert(s.gets==gets and s.classifications==0)
        local other=failed=='destination' and 'notification' or 'destination'
        s.event(other);s.tick(1);incomplete(s)
        assert(s.has('CALLBACK lane='..other) and not s.has('CALLBACK lane='..failed))
        s.tick(420);assert(s.has('TIMEOUT') and s.cancels==1)
    end
    s.quiet_after_stop()
end
for _,fault in ipairs({'timer_failure','timer_throws'}) do
    local s=fixture({[fault]=true});assert(s.start())
    assert(s.has('TIMER_UNAVAILABLE') and s.cancels==0);s.quiet_after_stop()
end
for _,fault in ipairs({'cancel_failure','cancel_throws'}) do
    local s=fixture({[fault]=true});assert(s.start())
    s.event('destination');s.event('notification');s.tick(1);completed(s)
    assert(s.has('timer_cancelled=false') and not s.has('FAIL '))
end
local s=fixture({engine_failure=true});assert(s.start());s.tick(1)
assert(s.has('FAIL observation unavailable') and s.cancels==1);s.quiet_after_stop()
for _,fault in ipairs({'open','write','close','print'}) do
    s=fixture();assert(s.start());s.output_failure=fault
    assert(pcall(s.tick,1),'sink failure escaped timer');assert(s.cancels==1)
    s.quiet_after_stop()
end
-- A sink failure after registering both hooks must retire their callbacks
-- even though timer creation has not yet happened.
for _,fault in ipairs({'open','write','close','print'}) do
    s=fixture({registration_output_failure=fault})
    assert(s.start(),'registration sink failure escaped initialization')
    assert(s.hooks==2 and not s.callback and s.cancels==0)
    s.quiet_after_stop()
end
-- A hook reentering while a pending event is logged must survive to the next
-- tick, and completion must wait for that new event to be emitted.
s=fixture();assert(s.start());s.event('destination')
s.on_print=function(line)
    if line:find('CALLBACK lane=destination',1,true) then
        s.on_print=nil;s.event('notification')
    end
end
s.tick(1);incomplete(s)
assert(s.has('CALLBACK lane=destination') and not s.has('CALLBACK lane=notification'))
s.tick(2);completed(s)
local _,emitted=s.log():gsub('CALLBACK lane=','');assert(emitted==2)
print('destination pair driver: independent lanes, caps, nil returns, failure containment, privacy and shutdown passed')
