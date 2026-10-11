local path=TEST_ROOT..'/experiments/ue4ss-save-world-identity/Scripts/main.lua'
local f=assert(io.open(path));local code=f:read('*a');f:close()
local Probe=dofile(TEST_ROOT..'/experiments/save_world_identity_probe.lua')
local Identity=dofile(TEST_ROOT..'/experiments/save_identity_probe.lua')
local id=string.rep('a',32)
local function fixture(o)
    o=o or {}
    local s={now=0,control=o.control or 'PWP_WORLD_IDENTITY_RUN fixture',logs={},reads=0,loads=0,cancels=0,forbidden=0,probes=0}
    local function object(fields)
        fields.IsValid=function() return true end
        return setmetatable({}, {__index=function(_,k)
            if fields[k]~=nil then return fields[k] end
            s.forbidden=s.forbidden+1;error('forbidden property: '..k)
        end,__newindex=function() s.forbidden=s.forbidden+1;error('native write') end})
    end
    s.directory=id;s.role=3;s.dedicated=false;s.selected=id;s.loaded=true
    s.world_name='World fixture'
    function s.replace()
        local instance_fields={SelectedWorldSaveDirectoryName=s.selected,
            GetAddress=function() return 102 end}
        local instance=object(instance_fields)
        local manager=object{AutoSaveWorldDefaultName='',bIsLoadedWorldSaveData=s.loaded,
            GetAddress=function() return 103 end,GetOuter=function() return instance end}
        instance_fields.SaveGameManager=manager
        s.engine=object{GameViewport=object{World=object{
            GetFullName=function() return s.world_name end,GetAddress=function() return 101 end,
            GameState=object{WorldSaveDirectoryName=s.directory,Role=s.role,bIsDedicatedServer=s.dedicated},
            OwningGameInstance=instance}}}
    end
    s.replace()
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
        assert(name:match('/world%-identity.log$') and mode=='a' and s.control=='DISABLED\n')
        local fail=s.sink or o.initial_sink
        if fail=='open' then return end
        return {write=function(_,value)
            if fail=='write' then return end
            assert(not value:find('PRIVATE',1,true));s.logs[#s.logs+1]=value;return true
        end,close=function() return fail~='close' end}
    end}
    env.dofile=function(name)
        assert(s.control=='DISABLED\n');s.loads=s.loads+1
        if name:match('/save_identity_probe.lua$') then
            return {read=function(engine)
                local out=Identity.read(engine)
                if s.mismatch then out.world='World other' end
                return out
            end}
        end
        assert(name:match('/save_world_identity_probe.lua$'))
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
for _,o in ipairs({{missing=true},{control='DISABLED\n'},{control='PWP_WORLD_IDENTITY_RUN '},
    {control='PWP_WORLD_IDENTITY_RUN fixture extra'},{control='PWP_WORLD_IDENTITY_RUN '..string.rep('x',65)},
    {control='PWP_DESTINATION_RUN fixture'}}) do
    local s=fixture(o);assert(s.start());assert(not s.callback and s.loads==0 and #s.logs==0)
end
for _,fault in ipairs({'open_failure','write_failure','close_failure'}) do
    local s=fixture({[fault]=true});assert(not s.start())
    assert(not s.callback and s.loads==0 and #s.logs==0)
end
local s=fixture();assert(s.start());assert(s.loads==2 and s.reads==0)
s.tick(0);assert(s.has('directory='..id) and s.has('role=3') and s.has('dedicated=false'))
local logs=#s.logs;s.tick(9);assert(#s.logs==logs and s.cancels==0)
s.tick(10);assert(s.has('OBSERVATION_COMPLETE identity remains unverified') and s.cancels==1);s.inert()
assert(s.start() and s.loads==2)
-- A client observation can finish but never becomes authority or storage proof.
s=fixture();s.directory=string.rep('b',32);s.role=1;s.dedicated=true;s.loaded=false;s.replace()
assert(s.start());s.tick(0);s.tick(10)
assert(s.has('directory='..string.rep('b',32)) and s.has('instance_selected='..id))
assert(s.has('instance_loaded_world=false') and s.has('OBSERVATION_COMPLETE'));s.inert()
-- Any scalar change resets stability, including fresh directory/role/world reads.
for _,field in ipairs({'directory','role','world_name','loaded'}) do
    s=fixture();assert(s.start());s.tick(0);s.tick(9)
    if field=='directory' then s.directory=string.rep('b',32)
    elseif field=='role' then s.role=1
    elseif field=='world_name' then s.world_name='World next'
    else s.loaded=false end
    s.replace();s.tick(10);s.tick(19);assert(s.cancels==0)
    s.tick(20);assert(s.has('OBSERVATION_COMPLETE') and s.cancels==1);s.inert()
end
for _,gap in ipairs({'malformed','role','mismatch'}) do
    s=fixture();assert(s.start());s.tick(0);s.tick(9)
    if gap=='malformed' then s.directory='PRIVATE_PATH'
    elseif gap=='role' then s.role=4 else s.mismatch=true end
    s.replace();s.tick(10);s.tick(30);assert(s.cancels==0)
    s.directory=id;s.role=3;s.mismatch=false;s.replace()
    s.tick(31);s.tick(40);assert(s.cancels==0)
    s.tick(41);assert(s.has('OBSERVATION_COMPLETE'));s.inert()
end
-- Deadline takes precedence over a ten-second dwell maturing at 180.
s=fixture();s.directory='';s.replace();assert(s.start());s.tick(169)
s.directory=id;s.replace();s.tick(170);s.tick(179);assert(s.cancels==0)
local reads=s.reads;s.tick(180)
assert(s.cancels==1 and s.reads==reads and not s.has('OBSERVATION_COMPLETE'));s.inert()
-- No valid observations still terminates, including a frozen/backward clock.
for _,backwards in ipairs({false,true}) do
    s=fixture();s.directory='';s.replace();assert(s.start())
    for i=1,180 do s.tick(backwards and -i or 0) end
    assert(s.reads==180 and s.probes==180 and s.cancels==0)
    s.tick(backwards and -181 or 0)
    assert(s.reads==180 and s.cancels==1 and s.has('samples=180'));s.inert()
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
    s=fixture({[fault]=true});assert(s.start());s.tick(180)
    assert(s.has('timer_cancelled=false') and s.cancels==1);s.inert()
end
for _,fault in ipairs({'open','write','close','print'}) do
    s=fixture({initial_sink=fault});assert(s.start());assert(not s.callback);s.inert()
    s=fixture();assert(s.start());s.sink=fault
    assert(pcall(s.tick,0));assert(s.cancels==1);s.inert()
end
for _,status in ipairs({'read_failed'}) do
    s=fixture({unsupported=status});assert(s.start());s.tick(0)
    assert(s.has('UNSUPPORTED '..status) and s.cancels==1);s.inert()
end
s=fixture({slow_read=true});assert(s.start());s.tick(0)
assert(s.has('SLOW_READ') and s.cancels==1);s.inert()
print('world identity driver: real probes, stale client contrast, stable dwell/reset, privacy, deadlines and inert shutdown passed')
