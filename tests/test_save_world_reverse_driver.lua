local path=TEST_ROOT..'/experiments/ue4ss-save-world-reverse/Scripts/main.lua'
local f=assert(io.open(path));local code=f:read('*a');f:close()
local Probe=dofile(TEST_ROOT..'/experiments/save_world_identity_probe.lua')
local Identity=dofile(TEST_ROOT..'/experiments/save_identity_probe.lua')
local id=string.rep('a',32)
local host_id=string.rep('b',32)
local gameplay='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local title='World /Game/Pal/Maps/Title/PL_Title.PL_Title'
local function fixture(o)
    o=o or {}
    local s={now=0,control=o.control or 'PWP_WORLD_REVERSE_RUN fixture',logs={},reads=0,loads=0,cancels=0,forbidden=0,probes=0}
    local function object(fields)
        fields.IsValid=function() return true end
        return setmetatable({}, {__index=function(_,k)
            if fields[k]~=nil then return fields[k] end
            s.forbidden=s.forbidden+1;error('forbidden property: '..k)
        end,__newindex=function() s.forbidden=s.forbidden+1;error('native write') end})
    end
    s.directory=id;s.role=1;s.dedicated=true;s.selected=host_id;s.loaded=false
    s.world_name=gameplay
    local generation=0
    function s.replace()
        -- Every replacement has distinct native identities and a matching manager owner.
        generation=generation+1
        local base=generation*10
        local instance_fields={SelectedWorldSaveDirectoryName=s.selected,
            GetAddress=function() return base+2 end}
        local instance=object(instance_fields)
        instance_fields.SaveGameManager=object{AutoSaveWorldDefaultName='',bIsLoadedWorldSaveData=s.loaded,
            GetAddress=function() return base+3 end,GetOuter=function() return instance end}
        s.engine=object{GameViewport=object{World=object{
            GetFullName=function() return s.world_name end,GetAddress=function() return base+1 end,
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
        assert(name:match('/world%-reverse.log$') and mode=='a' and s.control=='DISABLED\n')
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
                if s.loaded_status then out.loaded_status=s.loaded_status end
                return out
            end}
        end
        assert(name:match('/save_world_identity_probe.lua$'))
        return {read=function(engine)
            s.probes=s.probes+1;if o.probe_failure then error('probe failed') end
            local result=Probe.read(engine)
            if o.unsupported then result.status=o.unsupported end
            if s.directory_status then result.directory_status=s.directory_status end
            if s.role_status then result.role_status=s.role_status end
            if s.dedicated_status then result.dedicated_status=s.dedicated_status end
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
    sample.replace()
    local after=Identity.read(sample.engine)
    assert(after.context_status=='context_agrees' and after.verified==false)
    for _,key in ipairs({'world_address','instance_address','manager_address'}) do
        assert(after[key]~=before[key],'replacement must refresh '..key)
    end
    assert(sample.forbidden==0)
end

for _,o in ipairs({{missing=true},{control='DISABLED\n'},{control='PWP_WORLD_REVERSE_RUN '},
    {control='PWP_WORLD_REVERSE_RUN fixture extra'},{control='PWP_WORLD_REVERSE_RUN '..string.rep('x',65)},
    {control='PWP_DESTINATION_RUN fixture'}}) do
    local s=fixture(o);assert(s.start());assert(not s.callback and s.loads==0 and #s.logs==0)
end
for _,fault in ipairs({'open_failure','write_failure','close_failure'}) do
    local s=fixture({[fault]=true});assert(not s.start())
    assert(not s.callback and s.loads==0 and #s.logs==0)
end
local function incomplete(s)
    assert(not s.has('TRANSITION_COMPLETE') and not s.has('HOST_OBSERVED'))
    assert(s.cancels==0 and s.forbidden==0 and not s.has('verified=true'))
end
local function client(s,start,role)
    start=start or 0
    s.world_name=gameplay;s.directory=id;s.role=role or 1;s.dedicated=true;s.loaded=false;s.replace()
    s.tick(start);s.tick(start+9);assert(not s.has('CLIENT_OBSERVED'))
    s.tick(start+10);assert(s.has('CLIENT_OBSERVED directory='..id));incomplete(s)
end
local function boundary(s,time)
    s.world_name=title;s.loaded=false;s.replace();s.tick(time)
    assert(s.has('TITLE_BOUNDARY'));incomplete(s)
end
local function host(s)
    s.world_name=gameplay;s.directory=host_id;s.role=3;s.dedicated=false;s.loaded=true;s.replace()
end
local function completed(s)
    assert(s.has('HOST_OBSERVED') and s.has('TRANSITION_COMPLETE observations only'))
    assert(s.cancels==1 and s.has('verified=false'));s.inert()
end
-- Both valid initial client roles, scalar comparison, and freshly replaced trees.
for _,role in ipairs({1,2}) do
    local s=fixture();assert(s.start());assert(s.loads==2 and s.reads==0)
    client(s,0,role);boundary(s,11);host(s)
    s.tick(20);s.tick(29);incomplete(s);s.tick(30);completed(s)
    assert(s.has('differs_from_client=true selected_matches_host=true verified=false'))
    assert(s.start() and s.loads==2)
end
-- Equality is merely reported; it must not turn observation into storage proof.
local s=fixture();assert(s.start());client(s);boundary(s,11);host(s)
s.directory=id;s.selected='';s.replace();s.tick(20);s.tick(30);completed(s)
assert(s.has('differs_from_client=false selected_matches_host=false verified=false'))
-- One visit never completes, even if it changes to host without observed Title.
s=fixture();assert(s.start());client(s);s.tick(100);incomplete(s)
host(s);s.tick(101);s.tick(120);incomplete(s)
assert(not s.has('TITLE_BOUNDARY'))
-- A Title before stable client cannot qualify; interrupted client dwell resets.
s=fixture();assert(s.start());s.tick(0);s.tick(9)
s.world_name=title;s.loaded=false;s.replace();s.tick(10)
assert(not s.has('CLIENT_OBSERVED') and not s.has('TITLE_BOUNDARY'))
client(s,20);host(s);s.tick(40);s.tick(60);incomplete(s)
assert(not s.has('TITLE_BOUNDARY'))
-- Exact client conditions, including read statuses, must all be present.
local cases={
    function(x) x.role=3 end, function(x) x.role=0 end,
    function(x) x.dedicated=false end, function(x) x.loaded=true end,
    function(x) x.directory='PRIVATE_PATH' end, function(x) x.mismatch=true end,
    function(x) x.world_name='World other' end,
    function(x) x.loaded_status='read_failed' end,
    function(x) x.role_status='unknown' end,
    function(x) x.dedicated_status='unavailable' end,
    function(x) x.directory_status='malformed' end
}
for _,change in ipairs(cases) do
    s=fixture();change(s);s.replace();assert(s.start());s.tick(0);s.tick(20)
    assert(not s.has('CLIENT_OBSERVED'));incomplete(s)
end
-- Login/non-Title maps, unreadable load flags, loaded Title and mismatched
-- observations do not establish the boundary.
for _,mode in ipairs({'login','loaded','unreadable','mismatch'}) do
    s=fixture();assert(s.start());client(s)
    s.world_name=title;s.loaded=false
    if mode=='login' then s.world_name='World /Game/Pal/Maps/Login/PL_Login.PL_Login'
    elseif mode=='loaded' then s.loaded=true
    elseif mode=='unreadable' then s.loaded_status='read_failed'
    else s.mismatch=true end
    s.replace();s.tick(11);assert(not s.has('TITLE_BOUNDARY'))
    s.loaded_status=nil;s.mismatch=false;host(s);s.tick(20);s.tick(40);incomplete(s)
end
-- Reject each incorrect host combination, then require ten fresh seconds.
for _,change in ipairs({
    function(x) x.role=1 end,function(x) x.role=2 end,
    function(x) x.dedicated=true end,function(x) x.loaded=false end,
    function(x) x.directory='PRIVATE_PATH' end,function(x) x.mismatch=true end,
    function(x) x.world_name='World other' end,
    function(x) x.loaded_status='read_failed' end,function(x) x.role_status='unknown' end,
    function(x) x.dedicated_status='unavailable' end,function(x) x.directory_status='malformed' end
}) do
    s=fixture();assert(s.start());client(s);boundary(s,11);host(s)
    s.tick(20);s.tick(29);change(s);s.replace();s.tick(30);s.tick(40);incomplete(s)
    s.mismatch=false;s.loaded_status=nil;s.role_status=nil;s.dedicated_status=nil;s.directory_status=nil
    host(s);s.tick(50);s.tick(59);incomplete(s);s.tick(60);completed(s)
end
-- Changing an otherwise valid candidate restarts the dwell on either visit.
for _,phase in ipairs({'client','host'}) do
    s=fixture();assert(s.start())
    if phase=='host' then client(s);boundary(s,11);host(s) end
    local start=phase=='host' and 20 or 0
    s.tick(start);s.tick(start+9)
    s.directory=string.rep('c',32);s.replace();s.tick(start+10);s.tick(start+19)
    if phase=='client' then assert(not s.has('CLIENT_OBSERVED')) else incomplete(s) end
    s.tick(start+20)
    if phase=='client' then assert(s.has('CLIENT_OBSERVED directory='..string.rep('c',32)))
    else completed(s) end
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
    s=fixture({[fault]=true});assert(s.start());client(s);boundary(s,11);host(s);s.tick(20);s.tick(30)
    completed(s);assert(s.has('timer_cancelled=false'))
end
for _,fault in ipairs({'open','write','close','print'}) do
    s=fixture({initial_sink=fault});assert(s.start());assert(not s.callback);s.inert()
    s=fixture();assert(s.start());s.sink=fault
    assert(pcall(s.tick,0));assert(s.cancels==1);s.inert()
end
s=fixture({unsupported='read_failed'});assert(s.start());s.tick(0)
assert(s.has('UNSUPPORTED read_failed') and s.cancels==1);s.inert()
s=fixture({slow_read=true});assert(s.start());s.tick(0)
assert(s.has('SLOW_READ') and s.cancels==1);s.inert()
-- Timeouts must explicitly distinguish incomplete transitions from completion.
for _,phase in ipairs({'client','title','host'}) do
    s=fixture();assert(s.start())
    if phase=='client' then s.directory='';s.replace()
    else client(s);if phase=='host' then boundary(s,11);host(s);s.tick(590) end end
    s.tick(599);incomplete(s);local reads=s.reads
    s.tick(600)
    assert(s.reads==reads and s.cancels==1 and not s.has('TRANSITION_COMPLETE'))
    assert(s.has('TIMEOUT'),'incomplete transition must be labelled TIMEOUT, not COMPLETE')
    s.inert()
end
for _,backwards in ipairs({false,true}) do
    s=fixture();s.directory='';s.replace();assert(s.start())
    for i=1,600 do s.tick(backwards and -i or 0) end
    assert(s.reads==600 and s.cancels==0)
    s.tick(backwards and -601 or 0)
    assert(s.reads==600 and s.cancels==1 and s.has('TIMEOUT') and not s.has('TRANSITION_COMPLETE'))
    s.inert()
end
print('world reverse: client/Title/host fences, dwell resets, unverified comparison, timeout and inert failures passed')
