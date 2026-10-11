-- Independent review: real Lua scheduling, mocked native timers, no game IO.
-- Run with: python tools/test_lua.py tests/test_clock_review.lua
-- Failures describe expected behavior, rather than blessing current regressions.
local output = print
local saved_io = {open=io.open, popen=io.popen}
local saved_os = {clock=os.clock, time=os.time, rename=os.rename,
    remove=os.remove, execute=os.execute}
local failures = {}
local function restore()
    for k,v in pairs(saved_io) do io[k]=v end
    for k,v in pairs(saved_os) do os[k]=v end
    print=output
end
local function test(name, fn)
    restore()
    local ok,why=xpcall(fn,debug.traceback)
    restore()
    output((ok and 'PASS ' or 'FAIL ')..name)
    if not ok then failures[#failures+1]=name..': '..tostring(why); output(why) end
end

local function fixture(mode)
    package.loaded.clock=nil
    local f={now=0, callbacks={}, warnings={}, events={}}
    os.clock=function() return f.now end
    package.loaded.log={say=function() end, count=function() end,
        begin=function() end, finish=function() end,
        warn=function(s) f.warnings[#f.warnings+1]=s end}
    package.loaded.palapi={pc_memo_begin=function() f.memo=true end,
        pc_memo_end=function() f.memo=false end}
    local function schedule(ms,fn)
        assert(ms==100); f.callbacks[#f.callbacks+1]=fn
    end
    LoopInGameThreadWithDelay=mode=='loop' and function(ms,fn)
        assert(ms==100); f.tick=fn
    end or nil
    ExecuteInGameThreadWithDelay=mode=='delayed' and schedule or nil
    ExecuteWithDelay=schedule
    ExecuteInGameThread=function(fn) fn() end
    f.clock=require('clock'); f.clock.start()
    function f:run()
        self.now=self.now+.1
        if self.tick then self.tick()
        else
            local pending=self.callbacks; self.callbacks={}
            for _,fn in ipairs(pending) do fn() end
        end
        assert(not self.memo,'controller memo survived dispatch')
    end
    return f
end

for _,mode in ipairs({'loop','delayed','fallback'}) do
    test(mode..': reset and ordinary error recovery',function()
        local f=fixture(mode)
        f.clock.defer('stale',function() error('stale job ran') end)
        f.clock.reset()
        local n=0
        f.clock.every('input',100,function() n=n+1 end)
        f.clock.defer('bad',function() error('ordinary failure') end)
        f.clock.defer('good',function() f.good=true end)
        for _=1,6 do f:run() end
        assert(n==6 and f.good and #f.warnings==1)
    end)
end

test('reset preserves deadlines of surviving one-shots',function()
    local f=fixture('loop')
    f.clock.once(500,function() f.events[#f.events+1]='old' end)
    for _=1,4 do f:run() end
    f.clock.reset()
    f.clock.once(500,function() f.events[#f.events+1]='new' end)
    f:run()
    local on_original_deadline=f.events[1]=='old'
    for _=1,4 do f:run() end
    output('Reset one-shots: original deadline fired='..tostring(on_original_deadline)..
        '; callbacks after new deadline='..table.concat(f.events,','))
    assert(on_original_deadline,
        'reset restarted a surviving timer; old startup callbacks now accumulate and align with new ones')
end)

test('callback error formatting cannot poison later due snapshots',function()
    local f=fixture('loop')
    local bad=setmetatable({}, {__tostring=function() error('error formatter failed') end})
    f.clock.every('bad',0,function()
        f.clock.cancel('bad') -- The failing entry itself cannot cause a repeat.
        error(bad)
    end)
    f.clock.once(0,function() f.good=true end)
    for _=1,3 do f:run() end
    assert(f.good,'valid one-shot was lost')
    local before=#f.warnings
    for _=1,5 do f:run() end
    local empty_failures=#f.warnings-before
    local input=0
    f.clock.every('input',100,function() input=input+1 end)
    for _=1,6 do f:run() end
    output('After exceptional callback: empty beat failures='..empty_failures..
        '; input callbacks in 6 beats='..input)
    assert(empty_failures==0 and input==6,
        'a caught batch exception left stale due entries; empty future beats keep failing')
end)

-- Reuse only the existing integration fixture, with its native/persistence
-- boundaries intact. Replace the CLOCK MOCK in memory; no existing file edits.
local function main_fixture()
    restore()
    local h=assert(io.open(TEST_ROOT..'/tests/test_main_integration.lua','rb'))
    local source=h:read('*a'); h:close()
    local boundary=assert(source:find('\nlocal function test(name,fn)',1,true))
    source=source:sub(1,boundary-1)
    local first=assert(source:find('    package.loaded.clock={',1,true))
    local last=assert(source:find('    local loaded,why=',first,true))
    source=source:sub(1,first-1)..[[
    package.loaded.clock=nil
    local real_clock=require('clock')
    local real_every=real_clock.every
    real_clock.every=function(name,ms,fn,background)
        state.timers[name]={ms=ms,fn=fn}
        return real_every(name,ms,fn,background)
    end
    local real_start=real_clock.start
    real_clock.start=function() state.clock_started=true; return real_start() end
    state.clock=real_clock
]]..source:sub(last)..'\nreturn boot'
    return assert(load(source,'@review-main-fixture','t',_G))()(true)
end

test('real main/clock: delayed refresh does not skip the next maintenance second',function()
    local s=main_fixture()
    s.timers.role.fn(); s.viewport=true
    local beat,painted=0,{}
    s.ui.refresh=function() painted[#painted+1]=beat end
    s.clock.every('review: transient input load',100,function()
        if beat==11 or beat==12 then s.now=s.now+.020 end
    end)
    for i=1,31 do
        beat=i; s.now=s.now+.1; s.loops[100]()
    end
    output('Observed grid refresh beats: '..table.concat(painted,','))
    assert(#painted>=3,
        'expected three one-second refresh opportunities; delayed first refresh caused the second to be skipped')
end)

test('real main/clock: stand and panel render on separate background beats',function()
    local s=main_fixture()
    s.timers.role.fn(); s.viewport=true; s.panel.open=true
    local beat,stand,panel=0,{},{}
    s.ui.refresh=function() stand[beat]=true; s.now=s.now+.012 end
    s.panel.refresh=function() panel[beat]=true; s.now=s.now+.007 end
    for i=1,45 do
        beat=i; s.now=s.now+.1; s.loops[100]()
        assert(not (stand[i] and panel[i]),'stand and panel still combine their native costs in one beat')
    end
    local sn,pn=0,0
    for _ in pairs(stand) do sn=sn+1 end
    for _ in pairs(panel) do pn=pn+1 end
    assert(sn>=3 and pn>=8,'separating redraws starved a visible UI')
    -- A pending render belongs to the old session, even if the world name matches.
    s.session.begin('same-world-name'); s.viewport=false
    beat=46; s.now=s.now+.1; s.loops[100]()
    assert(not stand[46] and not panel[46],'queued renderer survived a session/viewport change')
end)

test('real main/clock: storage job is budgeted separately and session guarded',function()
    local s=main_fixture()
    s.timers.role.fn()
    assert(s.timers['stock refresh check'],'main did not register stock refresh polling')
    local beat,scans,passes,needed=0,{}, {},false
    s.scheduler.stock_refresh_due=function() return needed end
    s.scheduler.refresh_stock=function() scans[beat]=true; needed=false; s.now=s.now+.022 end
    s.handler=function(_,scheduler)
        passes[beat]=true; s.now=s.now+.020; scheduler.pass_id=scheduler.pass_id+1
        return {camps=1,pals=1,failed=0}
    end
    for i=1,130 do
        beat=i; if i==98 then needed=true end
        s.now=s.now+.1; s.loops[100]()
        assert(not(scans[i] and passes[i]),'storage and scheduler combined on a main clock beat')
    end
    assert(next(scans) and next(passes),'integration never ran both jobs')
    needed=true; s.timers['stock refresh check'].fn()
    s.session.begin('same-world-name'); needed=false
    beat=131; s.now=s.now+.1; s.loops[100]()
    assert(not scans[131],'queued storage scan survived session transition')
end)

test('session: budget yield retains FIFO and bounded capacity',function()
    package.loaded.session=nil
    local s=require('session')
    local now,seen=0,{}
    os.clock=function() return now end
    for i=1,128 do
        assert(s.enqueue(function() seen[#seen+1]=i; now=now+.009 end,true))
    end
    assert(not s.enqueue(function() end,true))
    for i=1,128 do s.drain(error,8); assert(#seen==i and seen[i]==i) end
    assert(not s.has_pending())
end)

restore()
assert(#failures==0,table.concat(failures,'\n\n'))
