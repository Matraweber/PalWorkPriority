local path=TEST_ROOT..'/experiments/ue4ss-save-identity/Scripts/main.lua'
local file=assert(io.open(path,'r'))
local code=file:read('*a');file:close()
local Probe=dofile(TEST_ROOT..'/experiments/save_identity_probe.lua')
local target='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local id=string.rep('a',32)

local function fixture(options)
    options=options or {}
    local s={now=0,control=options.control or 'PWP_IDENTITY_RUN fixture',
        logs={},cancels=0,reads=0,loads=0,forbidden=0}
    local env={}
    setmetatable(env,{__index=function(_,key)
        error('unexpected driver global: '..tostring(key))
    end})
    for _,key in ipairs({'assert','debug','ipairs','pcall','table','tostring'}) do env[key]=_G[key] end
    local function object(fields)
        fields.IsValid=function() return true end
        return setmetatable(fields,{__index=function(_,key)
            -- Count even accesses swallowed by the probe's pcall.
            s.forbidden=s.forbidden+1
            error('unexpected property or native getter: '..tostring(key))
        end})
    end
    function s.world(name,selected,autosave)
        -- Replace every wrapper, including the Engine, on each transition.
        local instance=object{SelectedWorldSaveDirectoryName=selected or id,
            GetAddress=function() return 102 end}
        instance.SaveGameManager=object{AutoSaveWorldDefaultName=autosave or id,
            bIsLoadedWorldSaveData=true,GetAddress=function() return 103 end,
            GetOuter=function() return instance end}
        s.engine=object{GameViewport=object{World=object{
            GetFullName=function() return name end,GetAddress=function() return 101 end,
            OwningGameInstance=instance
        }}}
    end
    s.world('World splash')
    env.os={time=function() return s.now end,date=function() return 'fixture-time ' end}
    env.print=function() end
    env.io={open=function(p,mode)
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
        assert(p:match('/identity.log$') and mode=='a','unexpected file access')
        assert(s.control=='DISABLED\n')
        return {write=function(_,text) s.logs[#s.logs+1]=text;return true end,
            close=function() return true end}
    end}
    env.dofile=function(p)
        assert(p:match('/experiments/save_identity_probe.lua$'))
        assert(s.control=='DISABLED\n')
        s.loads=s.loads+1
        return Probe
    end
    env.require=function(name)
        assert(name=='UEHelpers')
        return {GetEngine=function()
            s.reads=s.reads+1
            if options.engine_failure then error('fixture engine unavailable') end
            return s.engine
        end}
    end
    env.LoopInGameThreadWithDelay=function(ms,fn)
        assert(ms==1000 and not s.callback and s.control=='DISABLED\n')
        s.callback=fn;return 73
    end
    env.CancelDelayedAction=function(handle)
        assert(handle==73)
        s.cancels=s.cancels+1
        return not options.cancel_failure
    end
    function s.start() return pcall(assert(load(code,'@'..path,'t',env))) end
    function s.tick(time) s.now=time;assert(s.callback)() end
    function s.log() return table.concat(s.logs) end
    function s.has(text) return s.log():find(text,1,true)~=nil end
    function s.quiet_after_stop()
        local count,reads,cancels=#s.logs,s.reads,s.cancels
        s.tick(s.now+1);s.tick(s.now+300)
        assert(#s.logs==count and s.reads==reads and s.cancels==cancels)
        assert(s.forbidden==0,'unexpected native getter/property access')
    end
    return s
end

-- Invalid/missing arms never load the probe, schedule, or log.
for _,options in ipairs({{missing=true},{control='DISABLED\n'},
    {control='PWP_IDENTITY_RUN '..string.rep('x',65)},
    {control='PWP_IDENTITY_RUN fixture extra'}}) do
    local s=fixture(options);assert(s.start())
    assert(not s.callback and s.loads==0 and #s.logs==0)
end
for _,fault in ipairs({'open_failure','write_failure','close_failure'}) do
    local s=fixture({[fault]=true});assert(not s.start())
    assert(not s.callback and s.loads==0 and #s.logs==0)
end

local s=fixture();assert(s.start())
assert(s.control=='DISABLED\n' and s.loads==1 and s.reads==0)
s.tick(0);local count=#s.logs
s.tick(1);assert(#s.logs==count,'identical samples should be deduplicated')
s.world('World title');s.tick(20);s.tick(40)
assert(not s.has('FINAL ') and s.cancels==0,'title must not complete')
s.world(target);s.tick(50);s.tick(59)
assert(not s.has('FINAL ') and s.cancels==0,'must wait ten seconds after target arrival')
s.tick(60)
assert(s.has('FINAL ') and s.has('OBSERVATION_COMPLETE identity remains unverified'))
assert(s.has('verified=false') and s.has('timer_cancelled=true') and s.cancels==1)
s.quiet_after_stop()
-- The consumed arm prevents a second load from installing a timer.
local callback,loads=s.callback,s.loads
assert(s.start());assert(s.callback==callback and s.loads==loads)

-- Leaving the target resets the dwell interval; final data is freshly read.
s=fixture();assert(s.start());s.world(target);s.tick(1);s.tick(10)
s.world('World intermediate title');s.tick(11)
s.world(target,string.rep('b',32));s.tick(20);s.tick(29)
assert(not s.has('FINAL ') and s.cancels==0)
s.tick(30)
assert(s.has('FINAL world='..target..' | state=candidates_conflict'))
assert(s.has('selected='..string.rep('b',32)) and s.cancels==1)
s.quiet_after_stop()

-- Unavailable cancellation is reported truthfully, but late callbacks are inert.
s=fixture({cancel_failure=true});assert(s.start());s.world(target);s.tick(0);s.tick(10)
assert(s.cancels==1 and s.has('timer_cancelled=false'))
s.quiet_after_stop()

-- Timeout never emits completion and takes precedence over a late target dwell.
for _,late_target in ipairs({false,true}) do
    s=fixture();assert(s.start());s.tick(0)
    if late_target then s.world(target);s.tick(235) end
    s.tick(240);assert(s.cancels==0 and not s.has('TIMEOUT'))
    s.tick(241)
    assert(s.has('TIMEOUT observations incomplete') and s.cancels==1)
    assert(not s.has('FINAL ') and not s.has('OBSERVATION_COMPLETE'))
    s.quiet_after_stop()
end

s=fixture({engine_failure=true});assert(s.start());s.tick(0)
assert(s.has('FAIL ') and s.cancels==1 and not s.has('OBSERVATION_COMPLETE'))
s.quiet_after_stop()

-- Malformed identity text never enters the output, even on the final sample.
s=fixture();assert(s.start());s.world(target,'RAW_MALFORMED_SELECTED','RAW_MALFORMED_AUTOSAVE')
s.tick(0);s.tick(10)
assert(s.has('selected_status=malformed') and s.has('autosave_status=malformed'))
assert(not s.has('RAW_MALFORMED') and s.has('verified=false'))
s.quiet_after_stop()
print('identity driver: disarm, fresh real-probe reads, target dwell/reset, cancellation, timeout and redaction passed')
