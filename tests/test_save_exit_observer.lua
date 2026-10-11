local Observer=dofile(TEST_ROOT..'/experiments/save_exit_observer.lua')
local function wrapper(value) return {get=function()return value end,set=function()error('must not write reason')end} end
local function fixture(overrides)
    local f={events={},registrations=0,reads=0}
    local options={enabled=true,register=function(cb)f.registrations=f.registrations+1;f.callback=cb end,
        report=function(e)f.events[#f.events+1]=e end,clock=function()return 12.5 end}
    for k,v in pairs(overrides or {}) do options[k]=v end
    f.observer=Observer.new(options)
    function f:emit(value)
        local result=table.pack(self.callback(setmetatable({}, {__index=function()error('actor touched')end}),wrapper(value)))
        assert(result.n==1 and result[1]==nil)
    end
    return f
end
do
    local f=fixture();assert(f.registrations==0 and #f.events==0)
    assert(f.observer:install() and not f.observer:install() and f.registrations==1)
    for _,reason in ipairs({0,2,3})do f:emit(reason)end
    assert(#f.events==0)
    f:emit(1);for _=1,1000 do f:emit(1)end
    assert(#f.events==1 and f.events[1].reason_name=='LevelTransition')
    f:emit(4);for _=1,1000 do f:emit(4)end
    assert(#f.events==2 and f.events[2].reason_name=='Quit' and f.events[2].sequence==2)
    assert(f.observer:status().reason=='complete')
    for _,e in ipairs(f.events)do
        assert(e.clock==12.5 and not e.scope_verified and not e.drain_performed)
        for _,v in pairs(e)do assert(type(v)=='string' or type(v)=='boolean' or type(v)=='number')end
    end
    local s=f.observer:status();s.quit_seen=false;f.events[1].reason=99
    assert(f.observer:status().quit_seen)
end
do
    local f=fixture({enabled=false});assert(not f.observer:install() and f.registrations==0)
    f=fixture({register=false});assert(not f.observer:install() and f.observer:status().reason=='hook_unavailable')
end
for _,mode in ipairs({'throw','false'})do
    local retained
    local f=fixture({register=function(cb)retained=cb;cb(nil,wrapper(4));if mode=='throw'then error('retained before failure')end;return false end})
    assert(not f.observer:install() and not f.observer:install())
    assert(retained(nil,wrapper(4))==nil and #f.events==0)
end
do
    local f
    f=fixture({register=function()f.observer:stop()end})
    assert(not f.observer:install() and not f.observer:status().installed)
end
for _,value in ipairs({-1,5,1.5,'4',false,math.huge,0/0,{}})do
    local f=fixture();assert(f.observer:install());f:emit(value)
    f:emit(4);assert(#f.events==0 and f.observer:status().reason=='reason_unavailable')
end
do
    local f=fixture();assert(f.observer:install())
    assert(f.callback(nil,{get=function()error('invalid ephemeral param')end})==nil)
    assert(f.observer:status().reason=='reason_unavailable')
    f=fixture();assert(f.observer:install());assert(f.callback(nil,nil)==nil)
    assert(f.observer:status().terminal)
end
for _,report in ipairs({function()error('sink')end,function()return false end})do
    local f=fixture({report=report});assert(f.observer:install());f:emit(4);f:emit(1)
    assert(f.observer:status().report_attempts==1 and f.observer:status().reason=='report_failed')
end
for _,clock in ipairs({function()error('clock')end,function()return {}end,function()return math.huge end})do
    local f=fixture({clock=clock});assert(f.observer:install());f:emit(1)
    assert(#f.events==0 and f.observer:status().reason=='clock_unavailable')
end
do
    local f
    f=fixture({report=function()f:emit(1)end});assert(f.observer:install());f:emit(4)
    assert(f.observer:status().reason=='reentrant_callback' and f.observer:status().report_attempts==1)
    f=fixture({clock=function()f:emit(1);return 1 end});assert(f.observer:install());f:emit(4)
    assert(f.observer:status().reason=='reentrant_callback' and #f.events==0)
    f=fixture();assert(f.observer:install());f.observer:stop();f:emit(4);assert(#f.events==0)
end
-- Engine actor/reason objects are collectible immediately after the callback;
-- reporter sees only scalar fields and cannot retain either through the event.
do
    local f=fixture();assert(f.observer:install())
    local weak=setmetatable({}, {__mode='v'})
    do
        local actor=setmetatable({}, {__index=function()error('actor inspected')end})
        local param=wrapper(4);weak[1]=actor;weak[2]=param
        assert(f.callback(actor,param)==nil)
    end
    collectgarbage('collect');collectgarbage('collect')
    assert(weak[1]==nil and weak[2]==nil and #f.events==1)
    f:emit(1);assert(f.observer:status().reason=='complete')
end
print('exit observer: pinned wrapper semantics, Quit4/LevelTransition1, bounded one-shot reports, inert failures, reentry and no actor/param retention passed')
