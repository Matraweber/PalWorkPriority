local path=TEST_ROOT..'/experiments/ue4ss-save-headless/Scripts/main.lua'
local f=assert(io.open(path));local code=f:read('*a');f:close()
local Probe=dofile(TEST_ROOT..'/experiments/save_headless_identity_probe.lua')
local root=path:match('^(.*)/Scripts/main.lua$')
local function fixture(o)
    o=o or {}
    local s={now=0,control=o.control or 'PWP_HEADLESS_IDENTITY_RUN fixture',logs={},
        reads=0,loads=0,cancels=0,probes=0,forbidden=0,lib_reads=0,state_reads=0}
    local next_id=0
    local function object(fields)
        next_id=next_id+1;local id=next_id
        fields.IsValid=function() return true end
        fields.GetAddress=function() return id end
        return setmetatable({}, {__index=function(_,key)
            if fields[key]~=nil then return fields[key] end
            s.forbidden=s.forbidden+1;error('unexpected property '..key)
        end,__newindex=function() s.forbidden=s.forbidden+1;error('native write') end})
    end
    s.instance=object{SelectedWorldSaveDirectoryName=string.rep('b',32)}
    s.directory=string.rep('a',32);s.role=3;s.dedicated=true;s.world_name='World fixture'
    function s.replace()
        local level
        s.state_fields={WorldSaveDirectoryName=s.directory,Role=s.role,bIsDedicatedServer=s.dedicated,
            GetLevel=function() return level end}
        s.state=object(s.state_fields)
        local world=object{GameState=s.state,OwningGameInstance=s.instance,
            GetFullName=function() return s.world_name end}
        level=object{OwningWorld=world}
        s.engine=object{GameInstance=s.instance}
    end
    s.replace()
    s.lib=object{
        GetGameState=function(_,context)
            assert(context==s.instance);s.state_reads=s.state_reads+1
            if o.getter_failure then error('PRIVATE getter') end
            return s.state
        end,
        GetGameInstance=function(_,context)
            assert(context==s.state);return s.foreign or s.instance
        end}
    local env=setmetatable({}, {__index=function(_,key)
        s.forbidden=s.forbidden+1;error('unexpected global '..key)
    end})
    for _,key in ipairs({'assert','debug','ipairs','pcall','table','tostring'}) do env[key]=_G[key] end
    local clocks=0
    env.os={time=function() return s.now end,date=function() return 'fixture-time ' end,
        clock=function() clocks=clocks+1;return clocks*(o.clock_step or (o.slow and 0.051 or 0)) end}
    env.print=function(line)
        if (s.sink or o.initial_sink)=='print' then error('PRIVATE print') end
        assert(not line:find('PRIVATE',1,true))
    end
    env.io={open=function(name,mode)
        if name==root..'/run.txt' then
            if mode=='r' then
                if o.missing then return end
                return {read=function(_,count) assert(count==128);return s.control:sub(1,count) end,
                    close=function() return true end}
            end
            assert(mode=='w');if o.open_failure then return end
            return {write=function(_,value)
                assert(value=='DISABLED\n');if o.write_failure then return end
                s.control=value;return true
            end,close=function() return not o.close_failure end}
        end
        assert(name==root..'/headless-identity.log' and mode=='a' and s.control=='DISABLED\n')
        local fault=s.sink or o.initial_sink
        if fault=='open' then return end
        return {write=function(_,value)
            if fault=='write' then return end
            assert(not value:find('PRIVATE',1,true));s.logs[#s.logs+1]=value;return true
        end,close=function() return fault~='close' end}
    end}
    env.dofile=function(name)
        assert(s.control=='DISABLED\n' and name==root..'/experiments/save_headless_identity_probe.lua')
        s.loads=s.loads+1
        if o.load_failure then error('PRIVATE load') end
        return {read=function(engine,get_state,get_instance)
            s.probes=s.probes+1
            if o.probe_failure then error('PRIVATE probe') end
            if o.cross_deadline then s.now=60 end
            return Probe.read(engine,get_state,get_instance)
        end}
    end
    env.FindFirstOf=function(class)
        assert(class=='GameEngine' and s.control=='DISABLED\n')
        s.reads=s.reads+1
        if o.discovery_failure then error('PRIVATE discovery') end
        return s.engine
    end
    env.StaticFindObject=function(name)
        assert(name=='/Script/Engine.Default__GameplayStatics' and s.control=='DISABLED\n')
        s.lib_reads=s.lib_reads+1
        if o.lib_missing then return end
        if o.lib_failure then error('PRIVATE CDO') end
        return s.lib
    end
    env.LoopInGameThreadWithDelay=function(ms,cb)
        assert(ms==1000 and not s.callback and s.control=='DISABLED\n')
        s.callback=cb
        if o.synchronous then cb() end
        if o.timer_throws then error('PRIVATE registration') end
        if o.timer_failure then return end
        return 73
    end
    env.CancelDelayedAction=function(handle)
        assert(handle==73);s.cancels=s.cancels+1
        if o.cancel_throws then error('PRIVATE cancellation') end
        return not o.cancel_failure
    end
    function s.start() return pcall(assert(load(code,'@'..path,'t',env))) end
    function s.tick(now) s.now=now;assert(s.callback)() end
    function s.has(value) return table.concat(s.logs):find(value,1,true)~=nil end
    function s.inert()
        local counts={#s.logs,s.reads,s.probes,s.cancels,s.lib_reads,s.state_reads}
        if s.callback then s.tick(s.now+1);s.tick(s.now+300) end
        assert(#s.logs==counts[1] and s.reads==counts[2] and s.probes==counts[3] and s.cancels==counts[4])
        assert(s.lib_reads==counts[5] and s.state_reads==counts[6])
        assert(s.forbidden==0 and not s.has('verified=true'))
    end
    return s
end
for _,o in ipairs({{missing=true},{control='DISABLED\n'},{control='PWP_HEADLESS_IDENTITY_RUN '},
    {control='PWP_HEADLESS_IDENTITY_RUN fixture extra'},{control='PWP_WORLD_IDENTITY_RUN fixture'},
    {control='PWP_HEADLESS_IDENTITY_RUN '..string.rep('x',65)},
    {control='PWP_HEADLESS_IDENTITY_RUN fixture'..string.rep(' ',128)..'extra'}}) do
    local s=fixture(o);assert(s.start());assert(not s.callback and s.loads==0 and #s.logs==0);s.inert()
end
for _,fault in ipairs({'open_failure','write_failure','close_failure','load_failure'}) do
    local s=fixture({[fault]=true});assert(not s.start())
    assert(not s.callback and #s.logs==0 and s.reads==0)
end
local s=fixture();assert(s.start());assert(s.loads==1 and s.reads==0)
s.tick(0);assert(s.has('current_world_status=context_agrees') and s.has('verified=false'))
assert(s.has('directory='..string.rep('a',32)) and s.has('role=3') and s.has('dedicated=true'))
local logs=#s.logs;s.tick(9);assert(#s.logs==logs and s.cancels==0)
s.tick(10);assert(s.reads==3 and s.cancels==1 and s.has('OBSERVATION_COMPLETE'))
assert(s.lib_reads==3 and s.state_reads==6);s.inert()
assert(s.start() and s.loads==1,'consumed arm restarted')
-- Missing roots are re-resolved each callback; successful observations dwell.
s=fixture();local engine=s.engine;s.engine=nil;assert(s.start())
s.tick(0);local logs=#s.logs;s.tick(10);assert(#s.logs==logs and s.reads==2)
s.engine=engine;s.tick(11);assert(s.reads==3 and s.cancels==0)
s.tick(21);assert(s.has('OBSERVATION_COMPLETE'));s.inert()
for _,backward in ipairs({false,true}) do
    s=fixture();s.engine=nil;assert(s.start())
    for i=1,59 do s.tick(backward and -i or 0) end
    assert(s.reads==59 and s.cancels==0)
    s.tick(backward and -60 or 0)
    assert(s.reads==60 and s.probes==60 and s.cancels==1 and s.has('SAMPLE_LIMIT'));s.inert()
end
s=fixture();s.engine=nil;assert(s.start());s.tick(59);assert(s.reads==1)
s.tick(60);assert(s.reads==1 and s.has('TIME_LIMIT') and s.cancels==1);s.inert()
s=fixture({cross_deadline=true});s.engine=nil;assert(s.start());s.tick(59)
assert(s.has('TIME_LIMIT') and s.reads==1);s.inert()
for _,fault in ipairs({'timer_failure','timer_throws'}) do
    s=fixture({[fault]=true});assert(s.start());assert(s.has('TIMER_UNAVAILABLE'));s.inert()
end
for _,fault in ipairs({'probe_failure','discovery_failure','lib_failure'}) do
    s=fixture({[fault]=true});assert(s.start());s.tick(0)
    assert(s.has('FAIL observation unavailable') and s.cancels==1);s.inert()
end
for _,fault in ipairs({'cancel_failure','cancel_throws'}) do
    s=fixture({[fault]=true});assert(s.start());s.tick(60)
    assert(s.has('timer_cancelled=false') and s.cancels==1);s.inert()
end
for _,fault in ipairs({'print','open','write','close'}) do
    s=fixture({initial_sink=fault});assert(s.start());assert(not s.callback);s.inert()
    s=fixture();assert(s.start());s.sink=fault;s.tick(0)
    assert(s.cancels==1);s.inert()
end
s=fixture({slow=true});s.engine=nil;assert(s.start());s.tick(0)
assert(s.has('SLOW_READ elapsed_ms=') and s.has('budget_ms=100') and s.cancels==1);s.inert()
-- 36ms discovery/read plus 36ms diagnostic work fits the inclusive 100ms cap;
-- timing changes are excluded from stability comparison.
s=fixture({clock_step=0.036});assert(s.start());s.tick(0);s.tick(10)
assert(s.has('OBSERVATION_COMPLETE') and not s.has('SLOW_READ'));s.inert()
s=fixture();s.engine=setmetatable({IsValid=function() return true end},
    {__index=function() error('PRIVATE field failure') end})
assert(s.start());s.tick(0);assert(s.has('UNSUPPORTED read_failed'));s.inert()
for _,o in ipairs({{synchronous=true},{synchronous=true,timer_throws=true},
    {synchronous=true,timer_failure=true}}) do
    o.lib_missing=true
    s=fixture(o);assert(s.start());assert(s.reads==1 and s.has('UNSUPPORTED'))
    assert(s.cancels==((o.timer_throws or o.timer_failure) and 0 or 1));s.inert()
end
-- Field changes and same-name/same-directory world replacement reset the dwell.
for _,field in ipairs({'directory','role','dedicated','world_name','same_map_world'}) do
    s=fixture();assert(s.start());s.tick(0);s.tick(9)
    if field=='directory' then s.directory=string.rep('c',32)
    elseif field=='role' then s.role=1
    elseif field=='dedicated' then s.dedicated=false
    elseif field=='world_name' then s.world_name='World other' end
    s.replace();s.tick(10);s.tick(19);assert(s.cancels==0)
    if field=='role' or field=='dedicated' then
        s.role=3;s.dedicated=true;s.replace();s.tick(20);s.tick(29);assert(s.cancels==0)
        s.tick(30)
    else s.tick(20) end
    assert(s.has('OBSERVATION_COMPLETE'));s.inert()
end
-- Nil state and foreign owner reset progress, and invalid fields cannot finish.
for _,gap in ipairs({'nil','foreign','malformed'}) do
    s=fixture();assert(s.start());s.tick(0);s.tick(9)
    local state=s.state
    if gap=='nil' then s.state=nil
    elseif gap=='foreign' then s.foreign={IsValid=function() return true end,GetAddress=function() return 999 end}
    else s.state_fields.WorldSaveDirectoryName='PRIVATE/path' end
    s.tick(10);s.tick(30);assert(s.cancels==0)
    s.state=state;s.foreign=nil;s.state_fields.WorldSaveDirectoryName=s.directory
    s.tick(31);s.tick(40);assert(s.cancels==0)
    s.tick(41);assert(s.has('OBSERVATION_COMPLETE'));s.inert()
end
s=fixture({lib_missing=true});assert(s.start());s.tick(0)
assert(s.has('UNSUPPORTED unsupported_getter'));s.inert()
s=fixture({getter_failure=true});assert(s.start());s.tick(0)
assert(s.has('UNSUPPORTED read_failed'));s.inert()
-- Limits take precedence even when an otherwise successful dwell matures.
s=fixture();assert(s.start());s.tick(50);s.tick(60)
assert(s.has('TIME_LIMIT') and not s.has('OBSERVATION_COMPLETE'));s.inert()
s=fixture();assert(s.start());s.tick(0);s.tick(-10);s.tick(-1)
assert(s.cancels==0);s.tick(0);assert(s.has('OBSERVATION_COMPLETE'));s.inert()
print('headless driver: real context getters, fresh roots/CDO, stable server dwell/reset, 60 bounds, failures and inert shutdown passed')
