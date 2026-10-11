local file=TEST_ROOT..'/experiments/native-settings-chain-live/main.lua'
local source=assert(io.open(file)):read('*a')
local function fixture(marker, faults)
    faults=faults or {}
    local x={logs={},scheduled={},quits=0,reads=0,state='running',loads=0,native_calls=0,starts=0,polls=0,hits={}}
    local function inject(point)
        x.hits[point]=(x.hits[point] or 0)+1
        local f=faults[point]
        if f and x.hits[point]==(f.at or 1) then
            if f.throw then error('injected '..point) end
            return false
        end
        return true
    end
    local env=setmetatable({},{__index=_G})
    env.debug={getinfo=function()return {source='@fixture/main.lua'}end}
    env.package={path='',loadlib=function()x.loads=x.loads+1;return function()end end}
    env.io={open=function(path,mode)
        if mode=='r' then
            if marker==false then return end
            local n=0;return {read=function()n=n+1;if n==1 then return marker or 'PWP_SETTINGS_CHAIN WRITE fixture-1\n' end end,close=function()return inject('marker_read_close') end}
        end
        local point=path:match('run.txt$') and 'marker' or 'report'
        if not inject(point..'_open') then return nil end
        return {write=function(_,s)
            if not inject(point..'_write') then return nil end
            if point=='marker' then x.disarmed=s else x.logs[#x.logs+1]=s end
            return true
        end,close=function()return inject(point..'_close') end}
    end}
    env.RegisterEndPlayPreHook=function(cb)x.callback=cb;if not inject('hook') then return false end end
    env.ExecuteInGameThreadWithDelay=function(ms,cb)
        -- A throwing registration may already have queued the callback. Prove
        -- that stale queued work is inert, not merely that no callback exists.
        x.scheduled[#x.scheduled+1]={ms,cb}
        if not inject('schedule') then return false end
    end
    env.dofile=function(path)
        if path:match('save_native_backend.lua$') then
            return {call=function()x.native_calls=x.native_calls+1;return {1,'root',7,1,2,1000}end,unpack=function()return {'1'}end}
        end
        assert(path:match('native_settings_chain_trial.lua$'))
        return {new=function(o)
            x.report=o.report;x.recovery_only=o.recovery_only
            return {start=function()x.starts=x.starts+1;return true end,poll=function()x.polls=x.polls+1;x.state=faults.keep_running and 'running' or (o.recovery_only and 'passed' or 'ready') end,
                status=function()return {state=x.state}end,
                quit=function(_,reason)assert(reason==4);x.quits=x.quits+1;x.state='passed' end}
        end}
    end
    x.boot_ok,x.boot_error=pcall(assert(load(source,'@'..file,'t',env)))
    if not next(faults) then assert(x.boot_ok,x.boot_error) end
    function x:fire(reason)
        self.callback(setmetatable({},{__index=function()error('actor accessed')end}),
            {get=function()self.reads=self.reads+1;return reason end})
    end
    function x:run()local q=table.remove(self.scheduled,1);assert(q);q[2]()end
    return x
end
do
    local x=fixture();assert(x.disarmed=='DISABLED\n' and #x.scheduled==1 and x.scheduled[1][1]==90000)
    x:fire(1);x:fire(0);assert(x.quits==0)
    x:run();x:run();assert(x.state=='ready' and #x.scheduled==0)
    x:fire(4);x:fire(4);assert(x.quits==1 and x.reads==3)
    assert(x.logs[#x.logs]:find('"state":"passed"',1,true))
end
do
    local x=fixture();x:fire(4);x:run();assert(x.loads==0 and x.quits==0)
    assert(x.logs[#x.logs]:find('bootstrap-failed',1,true))
end
for _,value in ipairs({false,'4',5,1.5})do
    local x=fixture();x:fire(value);x:run();assert(x.loads==0 and x.quits==0)
end
for _,marker in ipairs({false,'DISABLED\n','PWP_SETTINGS_CHAIN WRITE bad!\n'})do
    local x=fixture(marker);assert(not x.callback and #x.scheduled==0 and x.loads==0)
end
do
    local x=fixture('PWP_SETTINGS_CHAIN RECOVER recovery-1\n');x:run();x:run()
    assert(x.recovery_only and x.state=='passed' and #x.scheduled==0)
    x:fire(4);assert(x.quits==0)
end
local function inert(x)
    local before={x.loads,x.native_calls,x.starts,x.polls,x.quits}
    local pending=#x.scheduled
    for _=1,pending do x:run() end
    if x.callback then x:fire(4);x:fire(4) end
    assert(#x.scheduled==0,'failed bootstrap scheduled new work')
    for i,n in ipairs({x.loads,x.native_calls,x.starts,x.polls,x.quits}) do
        assert(n==before[i],'failed bootstrap allowed later native/trial work')
    end
end
local negative_count=0
for _,point in ipairs({'marker_read_close','marker_open','marker_write','marker_close','hook',
    'report_open','report_write','report_close','schedule'}) do
    for _,throws in ipairs({false,true}) do
        local x=fixture(nil,{[point]={throw=throws}})
        assert(x.loads==0 and x.native_calls==0 and x.starts==0,'boot fault admitted native')
        inert(x);negative_count=negative_count+1
    end
end
-- Failure after root configuration but before trial construction must retain
-- that configuration and never continue to start/recover on a later callback.
for _,point in ipairs({'report_open','report_write','report_close'}) do
    for _,throws in ipairs({false,true}) do
        local x=fixture(nil,{[point]={at=2,throw=throws}})
        x:run();assert(x.native_calls==1 and x.starts==0)
        inert(x);negative_count=negative_count+1
    end
end
-- Poll scheduling may fail after trial start. Already accepted owners are left
-- to the trial/native retention contract; no retry or implicit Quit is allowed.
for _,throws in ipairs({false,true}) do
    local x=fixture(nil,{schedule={at=2,throw=throws}})
    x:run();assert(x.starts==1 and x.polls==0)
    inert(x);negative_count=negative_count+1
end
-- A report failure following Quit must not replay its mutations or schedule IO.
for _,point in ipairs({'report_open','report_write','report_close'}) do
    for _,throws in ipairs({false,true}) do
        local x=fixture(nil,{[point]={at=3,throw=throws}})
        x:run();x:run();x:fire(4);assert(x.quits==1)
        inert(x);negative_count=negative_count+1
    end
end
-- Repeated poll scheduling uses the same fail-stop rule.
for _,throws in ipairs({false,true}) do
    local x=fixture(nil,{keep_running=true,schedule={at=3,throw=throws}})
    x:run();x:run();assert(x.polls==1)
    inert(x);negative_count=negative_count+1
end
-- RECOVER completes without Quit; even a lost final log must stay stopped.
for _,point in ipairs({'report_open','report_write','report_close'}) do
    for _,throws in ipairs({false,true}) do
        local x=fixture('PWP_SETTINGS_CHAIN RECOVER recovery-1\n',{[point]={at=3,throw=throws}})
        x:run();x:run();assert(x.state=='passed' and x.quits==0)
        inert(x);negative_count=negative_count+1
    end
end
assert(negative_count==40)
print('settings chain bootstrap: 40 injected failure cases passed')
print('settings chain bootstrap: disarm, Quit one-shot, early/invalid callbacks, no actor retention passed')
