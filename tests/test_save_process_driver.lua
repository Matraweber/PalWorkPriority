local path=TEST_ROOT..'/experiments/ue4ss-save-process/Scripts/main.lua'
local f=assert(io.open(path));local code=f:read('*a');f:close()
local Probe=dofile(TEST_ROOT..'/experiments/save_process_probe.lua')
local Identity=dofile(TEST_ROOT..'/experiments/save_identity_probe.lua')
local id=string.rep('a',32)
local function fixture(o)
    o=o or {}
    local s={now=0,control=o.control or 'PWP_PROCESS_RUN fixture',logs={},reads=0,loads=0,cancels=0,forbidden=0,probes=0}
    local function object(fields)
        fields.IsValid=function() return true end
        return setmetatable({}, {__index=function(_,k)
            if fields[k]~=nil then return fields[k] end
            s.forbidden=s.forbidden+1;error('forbidden property: '..k)
        end,__newindex=function() s.forbidden=s.forbidden+1;error('native write') end})
    end
    s.state=2
    local map=setmetatable({}, {__len=function() return 1 end,__index=function(_,k)
        if k=='type' then return function() return 'TMap' end end
        assert(k=='ForEach')
        return function(_,cb)
            local result=cb({get=function() return 'PRIVATE_PREFIX/'..id..'/Level' end},
                {get=function() return object{State=s.state,bPreDelegateSuccess=false} end})
            assert(result==true)
        end
    end})
    -- Model the native identity/ownership contract without allowing arbitrary getters.
    local instance_fields={SelectedWorldSaveDirectoryName=id,GetAddress=function() return 102 end}
    local instance=object(instance_fields)
    local manager=object{WorldSaveProcess=object{ProcessMap=map},AutoSaveWorldDefaultName='',
        bIsLoadedWorldSaveData=true,GetAddress=function() return 103 end,
        GetOuter=function() return instance end}
    instance_fields.SaveGameManager=manager
    s.engine=object{GameViewport=object{World=object{GetFullName=function() return 'World fixture' end,
        GetAddress=function() return 101 end,OwningGameInstance=instance}}}
    local env=setmetatable({}, {__index=function(_,k) s.forbidden=s.forbidden+1;error('unexpected global '..k) end})
    for _,k in ipairs({'assert','debug','ipairs','pcall','table','tostring'}) do env[k]=_G[k] end
    local clock_calls=0
    env.os={time=function() return s.now end,date=function() return 'fixture-time ' end,
        clock=function() clock_calls=clock_calls+1;return clock_calls*(o.slow_read and 0.011 or 0) end}
    env.print=function(line)
        if s.sink=='print' or o.initial_sink=='print' then error('console failed') end
        assert(not line:find('PRIVATE',1,true))
    end
    env.io={open=function(name,mode)
        if name:match('/run.txt$') then
            if mode=='r' then
                if o.missing then return end
                return {read=function() return s.control end,close=function() return true end}
            end
            assert(mode=='w');if o.open_failure then return end
            return {write=function(_,value)
                assert(value=='DISABLED\n');if o.write_failure then return end
                s.control=value;return true
            end,close=function() return not o.close_failure end}
        end
        assert(name:match('/process.log$') and mode=='a' and s.control=='DISABLED\n')
        local fail=s.sink or o.initial_sink
        if fail=='open' then return end
        return {write=function(_,value)
            if fail=='write' then return end
            assert(not value:find('PRIVATE',1,true));s.logs[#s.logs+1]=value;return true
        end,close=function() return fail~='close' end}
    end}
    env.dofile=function(name)
        assert(s.control=='DISABLED\n');s.loads=s.loads+1
        if name:match('/save_identity_probe.lua$') then return Identity end
        assert(name:match('/save_process_probe.lua$'))
        return {read=function(engine)
            s.probes=s.probes+1;if o.probe_failure then error('probe failed') end
            local result=Probe.read(engine)
            if o.unsupported then result.status=o.unsupported end
            return result
        end}
    end
    env.require=function(name)
        assert(name=='UEHelpers')
        return {GetEngine=function()
            s.reads=s.reads+1;if o.engine_failure then error('no engine') end;return s.engine
        end}
    end
    env.LoopInGameThreadWithDelay=function(ms,cb)
        assert(ms==1000 and not s.callback and s.control=='DISABLED\n');s.callback=cb
        if o.timer_throws then error('timer failed after registration') end
        if o.timer_failure then return end
        return 73
    end
    env.CancelDelayedAction=function(handle)
        assert(handle==73);s.cancels=s.cancels+1
        if o.cancel_throws then error('cancel failure') end
        return not o.cancel_failure
    end
    function s.start() return pcall(assert(load(code,'@'..path,'t',env))) end
    function s.tick(n) s.now=n;assert(s.callback)() end
    function s.has(text) return table.concat(s.logs):find(text,1,true)~=nil end
    function s.inert()
        local logs,reads,probes,cancels=#s.logs,s.reads,s.probes,s.cancels
        if s.callback then s.tick(s.now+1);s.tick(s.now+300) end
        assert(#s.logs==logs and s.reads==reads and s.probes==probes and s.cancels==cancels)
        assert(s.forbidden==0 and not s.has('verified=true'))
    end
    return s
end

-- Fixture identities must satisfy the real collector while remaining unverified.
do
    local sample=fixture()
    local before=Identity.read(sample.engine)
    assert(before.context_status=='context_agrees' and before.verified==false)
    assert(before.world_address and before.instance_address and before.manager_address)
    assert(sample.forbidden==0)
end

for _,o in ipairs({{missing=true},{control='DISABLED\n'},{control='PWP_PROCESS_RUN '},
    {control='PWP_PROCESS_RUN fixture extra'},{control='PWP_PROCESS_RUN '..string.rep('x',65)},
    {control='PWP_DESTINATION_RUN fixture'}}) do
    local s=fixture(o);assert(s.start());assert(not s.callback and s.loads==0 and #s.logs==0)
end
for _,fault in ipairs({'open_failure','write_failure','close_failure'}) do
    local s=fixture({[fault]=true});assert(not s.start())
    assert(not s.callback and s.loads==0 and #s.logs==0)
end
local s=fixture();assert(s.start());assert(s.loads==2 and s.reads==0)
s.tick(0);assert(s.has('candidate='..id) and s.has('state=2') and s.has('pre_success=false'))
local logs=#s.logs;s.tick(1);assert(#s.logs==logs and s.reads==2)
s.state=3;s.tick(2);assert(#s.logs==logs+1 and s.has('state=3'))
s.tick(239);assert(s.cancels==0);local reads=s.reads
s.tick(240);assert(s.cancels==1 and s.reads==reads and s.has('COMPLETE'));s.inert()
assert(s.start() and s.loads==2)
-- Frozen/backward wall time still cannot cause more than 240 property samples.
for _,backwards in ipairs({false,true}) do
    s=fixture();assert(s.start())
    for i=1,240 do s.tick(backwards and -i or 0) end
    assert(s.reads==240 and s.probes==240 and s.cancels==0)
    s.tick(backwards and -241 or 0)
    assert(s.reads==240 and s.cancels==1 and s.has('samples=240'));s.inert()
end
for _,fault in ipairs({'timer_failure','timer_throws'}) do
    s=fixture({[fault]=true});assert(s.start())
    assert(s.has('TIMER_UNAVAILABLE') and s.cancels==0);s.inert()
end
for _,fault in ipairs({'engine_failure','probe_failure'}) do
    s=fixture({[fault]=true});assert(s.start());s.tick(0)
    assert(s.has('FAIL observation unavailable') and s.cancels==1);s.inert()
end
for _,fault in ipairs({'cancel_failure','cancel_throws'}) do
    s=fixture({[fault]=true});assert(s.start());s.tick(240)
    assert(s.has('timer_cancelled=false') and s.cancels==1);s.inert()
end
for _,fault in ipairs({'open','write','close','print'}) do
    s=fixture({initial_sink=fault});assert(s.start());assert(not s.callback);s.inert()
    s=fixture();assert(s.start());s.sink=fault
    assert(pcall(s.tick,0));assert(s.cancels==1);s.inert()
end
for _,status in ipairs({'read_failed','invalid_count','oversize'}) do
    s=fixture({unsupported=status});assert(s.start());s.tick(0)
    assert(s.has('UNSUPPORTED '..status) and s.cancels==1);s.inert()
end
s=fixture({slow_read=true});assert(s.start());s.tick(0)
assert(s.has('SLOW_READ') and s.cancels==1);s.inert()
print('save process driver: real probes, disarm, no hooks/writes, change logs, time/sample caps and inert failure shutdown passed')
