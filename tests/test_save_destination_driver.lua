local path=TEST_ROOT..'/experiments/ue4ss-save-destination/Scripts/main.lua'
local file=assert(io.open(path,'r'))
local code=file:read('*a');file:close()
local Probe=dofile(TEST_ROOT..'/experiments/save_identity_probe.lua')
local Destination=dofile(TEST_ROOT..'/experiments/save_destination_probe.lua')
local target='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local id=string.rep('a',32)

local function fixture(options)
    options=options or {}
    local s={now=0,control=options.control or 'PWP_DESTINATION_RUN fixture',
        logs={},cancels=0,reads=0,loads=0,forbidden=0,hooks=0,gets=0,classifications=0,prints={}}
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
        assert(p:match('/destination.log$') and mode=='a','unexpected file access')
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
        assert(name=='/Script/Pal.PalSaveGameManager:OnFinishedWorldAsyncSaveGameInternal')
        s.hooks=s.hooks+1;assert(s.hooks==1);s.hook=fn
        if options.hook_failure then error('hook registration failed after retaining callback') end
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
    function s.fire(slot,success,world)
        local ignored=setmetatable({}, {__index=function()
            s.forbidden=s.forbidden+1;error('unused callback argument accessed')
        end})
        local logs,reads,prints=#s.logs,s.reads,#s.prints
        s.in_hook=true
        local ok,err=pcall(s.hook,ignored,slot,ignored,success,world,ignored)
        s.in_hook=false;assert(ok,err)
        assert(#s.logs==logs and s.reads==reads and #s.prints==prints)
    end
    function s.start() return pcall(assert(load(code,'@'..path,'t',env))) end
    function s.tick(time) s.now=time;assert(s.callback)() end
    function s.log() return table.concat(s.logs) end
    function s.has(text) return s.log():find(text,1,true)~=nil end
    function s.quiet_after_stop()
        local count,reads,cancels=#s.logs,s.reads,s.cancels
        local gets,classified=s.gets,s.classifications
        s.fire(s.arg('PRIVATE'),s.arg(true),s.arg(id))
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


-- All filesystem writes are mocked and limited to disarm + diagnostic log.
for _,options in ipairs({{missing=true},{control='DISABLED\n'},
    {control='PWP_DESTINATION_RUN '},{control='PWP_DESTINATION_RUN fixture extra'},
    {control='PWP_DESTINATION_RUN '..string.rep('x',65)},
    {control='PWP_IDENTITY_RUN fixture'}}) do
    local s=fixture(options);assert(s.start())
    assert(s.hooks==0 and not s.callback and s.loads==0 and #s.logs==0)
end
for _,fault in ipairs({'open_failure','write_failure','close_failure'}) do
    local s=fixture({[fault]=true});assert(not s.start())
    assert(s.hooks==0 and not s.callback and s.loads==0 and #s.logs==0)
end
local s=fixture();assert(s.start())
assert(s.control=='DISABLED\n' and s.loads==2 and s.hooks==1 and s.reads==0)
s.tick(0);local count=#s.logs;s.tick(1);assert(#s.logs==count)
s.world(target);s.tick(2);assert(s.has('SAMPLE world='..target))
s.fire(s.arg('PRIVATE_PREFIX/'..id..'/Level'),s.arg(true),s.arg(id))
assert(not s.has('CALLBACK '));s.tick(3)
assert(s.has('successful_destination_candidate') and s.has('slot_candidate='..id))
assert(s.has('OBSERVATION_COMPLETE callback not session-verified'))
assert(s.has('timer_cancelled=true') and s.cancels==1)
assert(not s.has('PRIVATE_PREFIX') and not table.concat(s.prints):find('PRIVATE_PREFIX',1,true))
s.quiet_after_stop()
assert(s.start());assert(s.hooks==1 and s.loads==2)

-- Preserve false, deny nil/throwing getters; raw paths/errors are never logged.
for _,mode in ipairs({'false','nil','throw','direct','malformed','oversized','conversion'}) do
    s=fixture();assert(s.start())
    local slot,success,world=s.arg(id..'/Level'),s.arg(false),s.arg(id)
    local expected='failed_completion'
    if mode=='nil' then success=s.arg(nil);expected='unknown_completion'
    elseif mode=='throw' then success=s.arg(nil,true);expected='unknown_completion'
    elseif mode=='direct' then slot,success,world=id..'/Level',true,id;expected='successful_destination_candidate'
    elseif mode=='malformed' then slot,success,world=s.arg('C:/PRIVATE/path'),s.arg(true),s.arg('PRIVATE_WORLD');expected='unrecognized_destination'
    elseif mode=='oversized' then slot,success=s.arg(string.rep('x',1025)),s.arg(true);expected='unrecognized_destination'
    elseif mode=='conversion' then
        slot=s.arg({ToString=function() error('PRIVATE_CONVERSION') end})
        success=s.arg(true);expected='unrecognized_destination'
    end
    s.fire(slot,success,world);s.tick(1)
    assert(s.has('state='..expected) and s.has('verified=false'))
    assert(not s.has('PRIVATE') and not table.concat(s.prints):find('PRIVATE',1,true))
    if mode=='false' then assert(s.has('success=false')) end
    assert(s.cancels==1);s.quiet_after_stop()
end

-- Four events maximum, including when callbacks arrive before the first tick.
s=fixture();assert(s.start())
for i=1,4 do s.fire(s.arg(id..'/Level'),s.arg(true),s.arg(id)) end
local gets=s.gets
s.fire(s.arg('extra'),s.arg(true),s.arg(id))
assert(s.gets==gets and s.classifications==4)
s.tick(1);local _,events=s.log():gsub('CALLBACK ','');assert(events==4)
s.quiet_after_stop()

for _,fault in ipairs({'cancel_failure','cancel_throws'}) do
    s=fixture({[fault]=true});assert(s.start())
    s.fire(id..'/Level',true,id);s.tick(1)
    assert(s.cancels==1 and s.has('timer_cancelled=false'))
    assert(s.has('OBSERVATION_COMPLETE') and not s.has('FAIL '));s.quiet_after_stop()
end
s=fixture();assert(s.start());s.tick(299)
assert(not s.has('TIMEOUT') and s.cancels==0)
s.tick(300);assert(s.has('TIMEOUT no callback observed') and s.cancels==1)
assert(not s.has('OBSERVATION_COMPLETE'));s.quiet_after_stop()

-- Failed registration/scheduling can retain callbacks: they must remain inert.
for _,fault in ipairs({'hook_failure','timer_failure','timer_throws'}) do
    s=fixture({[fault]=true});assert(s.start())
    assert(s.has(fault=='hook_failure' and 'HOOK_UNAVAILABLE' or 'TIMER_UNAVAILABLE'))
    assert(s.cancels==0);s.quiet_after_stop()
end
s=fixture({engine_failure=true});assert(s.start());s.tick(1)
assert(s.has('FAIL observation unavailable') and s.cancels==1);s.quiet_after_stop()
s=fixture({classifier_failure=true});assert(s.start())
s.fire(id..'/Level',true,id);s.tick(1)
assert(s.has('classifier_failed') and not s.has('private classifier error'));s.quiet_after_stop()
-- A persistent output failure must never escape the engine timer callback.
for _,fault in ipairs({'open','write','close','print'}) do
    s=fixture();assert(s.start());s.output_failure=fault
    local ok=pcall(s.tick,1)
    assert(ok,'diagnostic '..fault..' failure escaped game-thread callback')
    assert(s.cancels==1)
    s.quiet_after_stop()
end
print('destination driver: disarm, bounded hook copies, timer, failure containment, privacy and no save writes passed')
