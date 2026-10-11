-- Execute the actual main, observer, epoch and property probes in an isolated
-- Lua environment. Only filesystem, scheduling and engine boundaries are faked.
local path = TEST_ROOT .. '/experiments/ue4ss-save-lifecycle/Scripts/main.lua'
local root = TEST_ROOT .. '/experiments/ue4ss-save-lifecycle'
local hook_names = {'RegisterLoadMapPreHook','RegisterLoadMapPostHook',
    'RegisterInitGameStatePreHook','RegisterInitGameStatePostHook'}
local checks = 0
local function trial(options)
    options = options or {}
    local f = {arm=options.arm == nil and 'PWP_LIFECYCLE fixture-01\n' or options.arm,
        now=100, logs={}, console={}, callbacks={}, registrations=0, loads=0,
        writes=0, closes=0, queries=0, timers=0, cancels=0, weak=setmetatable({}, {__mode='v'})}
    local env = setmetatable({}, {__index=_G}); env._G = env
    env.print = function(s) f.console[#f.console+1] = s end
    env.os = {time=function() if f.clock_error then error('clock') end; return f.now end,
        date=function() return '2026-10-04T00:00:00Z' end}
    env.io = {open=function(p, mode)
        assert(p == root .. '/run.txt' or p == root .. '/lifecycle.log', 'unapproved file')
        if mode == 'r' then
            assert(p == root .. '/run.txt')
            if options.read_open_error then error('arm open') end
            if f.arm == false then return nil end
            local cursor = 1
            return {read=function(_,n)
                if options.read_error then error('arm read') end
                if cursor > #f.arm then return nil end
                local text = f.arm:sub(cursor,cursor+n-1); cursor = cursor+n; return text
            end, close=function() f.closes=f.closes+1; return not options.read_close_error end}
        end
        if mode == 'w' then
            assert(p == root .. '/run.txt'); f.writes=f.writes+1
            if options.disarm_open_error then return nil end
            f.arm = ''
            return {write=function(_,text)
                if options.disarm_throw then error('write failed') end
                if options.disarm_write_error then return nil end
                f.arm = text; return true
            end, close=function() f.closes=f.closes+1; return not options.disarm_close_error end}
        end
        assert(mode == 'a' and p == root .. '/lifecycle.log' and f.arm == 'DISABLED\n')
        if options.log_open_error or f.log_open_error then return nil end
        return {write=function(_,text)
            if options.log_throw then error('log write failed') end
            if options.log_write_error then return nil end
            f.logs[#f.logs+1] = text; return true
        end, close=function() f.closes=f.closes+1; return not options.log_close_error end}
    end}
    local allowed = {['save_lifecycle_epoch_observer.lua']=true, ['save_lifecycle_epoch.lua']=true,
        ['save_world_identity_probe.lua']=true, ['save_identity_probe.lua']=true}
    env.dofile = function(p)
        assert(f.arm == 'DISABLED\n', 'module loaded before disarm')
        f.loads=f.loads+1
        local name = p:match('/experiments/([^/]+)$')
        assert(allowed[name], 'unexpected module: ' .. p)
        if options.module_error then error('missing module') end
        return assert(loadfile(TEST_ROOT .. '/experiments/' .. name, 't', env))()
    end
    local function object(fields, address)
        fields.IsValid=function() return true end
        fields.GetAddress=function() return address end
        local proxy = setmetatable({}, {__index=fields,
            __newindex=function() error('engine write forbidden') end,
            __tostring=function() error('wrapper stringification forbidden') end})
        f.weak[#f.weak+1] = proxy
        return proxy
    end
    local function engine()
        assert(f.arm == 'DISABLED\n'); f.queries=f.queries+1
        if f.query_error then error('query failed') end
        local base = f.address or 100
        local id = string.rep(f.world_id or 'a',32)
        local title, new = f.mode == 'title', f.mode == 'new'
        local name = title and 'World /Game/Pal/Maps/Title/PL_Title.PL_Title' or 'World same map'
        local instance_fields = {SelectedWorldSaveDirectoryName=not new and id or nil}
        local instance = object(instance_fields,base+2)
        local manager = object({AutoSaveWorldDefaultName='', bIsLoadedWorldSaveData=not title and not new,
            GetOuter=function() return f.bad_owner and object({},999) or instance end},base+3)
        instance_fields.SaveGameManager=manager
        local state=object({WorldSaveDirectoryName=id,Role=3,bIsDedicatedServer=false},base+4)
        local world=object({GameState=state,OwningGameInstance=instance,
            GetFullName=function() return name end},base+1)
        return object({GameViewport=object({World=world},base+5)},base+6)
    end
    env.require = function(name)
        assert(name == 'UEHelpers' and f.arm == 'DISABLED\n')
        if options.require_error then error('helper unavailable') end
        return {GetEngine=engine}
    end
    for _,name in ipairs(hook_names) do
        if options.missing_hook ~= name then env[name] = function(cb)
            assert(f.arm == 'DISABLED\n'); f.registrations=f.registrations+1
            f.callbacks[name]=cb
            if options.throw_hook == name then error('retained before throwing') end
            if options.false_hook == name then return false end
            -- Pinned UE4SS success returns no values.
        end end
    end
    if not options.no_timer then env.LoopInGameThreadWithDelay = function(delay, cb)
        assert(delay == 1000 and f.arm == 'DISABLED\n'); f.timers=f.timers+1; f.timer=cb
        if options.inline_timer then f.query_error=true; cb() end
        if options.timer_throw then error('scheduled but handle unavailable') end
        if options.timer_nil then return nil end
        return 37
    end end
    if not options.no_cancel then env.CancelDelayedAction = function(h)
        assert(h == 37); f.cancels=f.cancels+1
        if options.cancel_throw then error('cancel failed') end
        return not options.cancel_false
    end end
    function f:run() assert(loadfile(path,'t',env))() end
    function f:text() return table.concat(self.logs) end
    function f:event(n, ...)
        local r=table.pack(assert(self.callbacks[hook_names[n]])(...))
        assert(r.n == 1 and r[1] == nil, 'callback override/non-nil return')
    end
    function f:tick() assert(self.timer)() end
    function f:stopped()
        local logs, queries, cancels = #self.logs, self.queries, self.cancels
        if self.timer then for _=1,3 do self:tick() end end
        for _,cb in pairs(self.callbacks) do assert(cb() == nil) end
        assert(#self.logs == logs and self.queries == queries and self.cancels == cancels,
            'callbacks must be inert after stop')
    end
    f:run(); checks=checks+1
    return f
end

for _,arm in ipairs({false,'','DISABLED\n','PWP_WRONG fixture','PWP_LIFECYCLE ',
    'PWP_LIFECYCLE bad_nonce','PWP_LIFECYCLE ' .. string.rep('x',65),
    'PWP_LIFECYCLE ok\nPWP_LIFECYCLE twice','PWP_LIFECYCLE ok' .. string.rep(' ',130)}) do
    local f=trial{arm=arm}
    assert(f.writes == 0 and f.loads == 0 and f.registrations == 0 and f.timers == 0 and #f.logs == 0)
end
for _,key in ipairs({'read_open_error','read_error','read_close_error','disarm_open_error',
    'disarm_write_error','disarm_throw','disarm_close_error'}) do
    local f=trial{[key]=true}
    assert(f.loads == 0 and f.registrations == 0 and f.timers == 0 and #f.console == 1)
end

-- Actual modules register nil-returning hooks; samples expose scalar correlation
-- fields from the real current-chain probe. None of these observations grants.
do
    local f=trial()
    assert(f.arm == 'DISABLED\n' and f.loads == 4 and f.registrations == 4 and f.timers == 1)
    assert(f.queries == 0, 'no engine access while installing')
    f:run(); assert(f.registrations == 4 and f.timers == 1, 'self-disarmed reload')
    f.arm='PWP_LIFECYCLE rearm\n'; f:run()
    assert(f.arm == 'DISABLED\n' and f.registrations == 4, 'one install per environment')
    for _,n in ipairs({1,3,4,2}) do f:event(n) end
    assert(f.queries == 0, 'hooks must not query world wrappers')
    f:tick()
    local text=f:text()
    assert(text:find('world.role=3',1,true) and text:find('identity.context_status=context_agrees',1,true))
    assert(text:find('identity.world_address=101',1,true) and text:find('identity.instance_address=102',1,true)
        and text:find('identity.manager_address=103',1,true))
    local count=#f.logs; f:tick(); assert(#f.logs == count, 'unchanged sample should not log')
    f.address=200; f:tick(); assert(#f.logs == count+1, 'address-only change must log')
    f.mode='title'; f:tick()
    f.mode='new'; f.world_id='b'; f:tick()
    assert(f.logs[#f.logs]:find('world.role=3',1,true)
        and f.logs[#f.logs]:find('identity.selected=nil',1,true)
        and f.logs[#f.logs]:find('identity.loaded_world=false',1,true))
    f.mode='host'; f:tick() -- normal reload B now selected+loaded true
    assert(f.logs[#f.logs]:find('identity.selected=' .. string.rep('b',32),1,true)
        and f.logs[#f.logs]:find('identity.loaded_world=true',1,true))
    f.bad_owner=true; f:tick()
    assert(f.logs[#f.logs]:find('identity.context_status=owner_unestablished',1,true)
        and f.logs[#f.logs]:find('identity.world_address=nil',1,true))
    for _,line in ipairs(f.logs) do
        assert(line:find('verified=false storage_grant=false',1,true) and not line:find('ready=true',1,true))
    end
    -- Both sampled and hook-supplied wrappers can be collected with callbacks alive.
    do
        local wrapper=setmetatable({}, {__tostring=function() error('stringify') end,
            __index=function() error('wrapper access') end})
        f.weak[#f.weak+1]=wrapper
        f:event(1,wrapper,wrapper,wrapper,wrapper,wrapper)
    end
    collectgarbage('collect'); assert(next(f.weak) == nil, 'engine wrappers retained')
    f.now=1900; f:tick()
    assert(f:text():find('TIMEOUT timer_cancelled=true',1,true) and f.cancels == 1)
    f:stopped()
end

for _,name in ipairs(hook_names) do
    for _,failure in ipairs({'missing_hook','throw_hook','false_hook'}) do
        local f=trial{[failure]=name}
        assert(f.timers == 0 and f:text():find('FAIL hooks_unavailable',1,true))
        if failure == 'missing_hook' then assert(f.registrations == 0) end
        f:stopped()
    end
end
for _,key in ipairs({'module_error','require_error','no_timer','no_cancel'}) do
    local f=trial{[key]=true}
    assert(f.arm == 'DISABLED\n' and f.registrations == 0 and f.timers == 0)
    assert(f:text():find('FAIL setup',1,true)); f:stopped()
end
for _,key in ipairs({'log_open_error','log_write_error','log_throw','log_close_error'}) do
    local f=trial{[key]=true}
    assert(f.registrations == 0 and f.timers == 0 and #f.console == 1); f:stopped()
end
for _,key in ipairs({'timer_throw','timer_nil'}) do
    local f=trial{[key]=true}
    assert(f:text():find('FAIL timer_registration timer_cancelled=no_handle',1,true))
    f:stopped()
end
do
    local f=trial{inline_timer=true}
    assert(f.cancels == 1 and table.concat(f.console):find('late_handle timer_cancelled=true',1,true))
    f:stopped()
end
for _,key in ipairs({'query_error','clock_error','log_open_error'}) do
    local f=trial(); f[key]=true; f:tick()
    assert(f.cancels == 1); f:stopped()
end
for _,key in ipairs({'cancel_throw','cancel_false'}) do
    local f=trial{[key]=true}; f.now=1900; f:event(1)
    assert(f:text():find('TIMEOUT timer_cancelled=false',1,true) and f.cancels == 1)
    f:stopped() -- failed native cancellation cannot reactivate local work
end
do
    local f=trial(); f.now=99; f:tick()
    assert(f:text():find('CLOCK_REVERSED timer_cancelled=true',1,true)); f:stopped()
end
do
    local f=trial()
    for _=1,1800 do f:tick() end -- frozen wall clock still bounded by callback count
    assert(f.queries == 1799 and f.cancels == 1 and f:text():find('TICK_LIMIT',1,true))
    f:stopped()
end
do
    local f=trial()
    for _=1,5000 do f:event(2) end
    assert(#f.logs == 4096 and f.cancels == 1 and f.logs[4096]:find('LINE_LIMIT',1,true))
    f:stopped()
end
print('save lifecycle driver: ' .. checks .. ' actual-entry fixtures passed; no live travel claim')
