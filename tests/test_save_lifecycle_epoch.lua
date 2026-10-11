local Epoch = dofile(TEST_ROOT .. '/experiments/save_lifecycle_epoch.lua')
local Observer = dofile(TEST_ROOT .. '/experiments/save_lifecycle_epoch_observer.lua')
local names = {'RegisterLoadMapPreHook','RegisterLoadMapPostHook',
    'RegisterInitGameStatePreHook','RegisterInitGameStatePostHook'}
local function fixture(options, fail, missing)
    local f = {callbacks={}, registrations=0, api={}}
    for _,name in ipairs(names) do
        if name ~= missing then
            f.api[name] = function(cb)
                f.registrations = f.registrations + 1
                f.callbacks[name] = cb
                if name == fail then error('registration may already have retained callback') end
                -- Real pinned registrars return nil, not a hook ID or true.
            end
        end
    end
    options = options or {enabled=true}
    f.c = Epoch.new(options)
    f.installed = f.c:install(f.api)
    function f:event(index, ...)
        local result = table.pack(assert(self.callbacks[names[index]])(...))
        assert(result.n == 1 and result[1] == nil, 'hook must explicitly return nil')
    end
    function f:init() self:event(3); self:event(4) end
    function f:ready()
        local candidate = assert(self.c:candidate())
        assert(self.c:authorize(candidate, function(e) assert(e == candidate()); return true end))
        assert(self.c:admit() == candidate)
        return candidate
    end
    return f
end

-- No side effects on construction/disabled gate. Preflight all four functions.
do
    local f = fixture({enabled=false})
    assert(not f.installed and f.registrations == 0 and not f.c:admit())
    for _,name in ipairs(names) do
        local m = fixture(nil, nil, name)
        assert(not m.installed and m.registrations == 0 and m.c:status().terminal)
        assert(not m.c:install(f.api) and not m.c:candidate())
    end
    local c = Epoch.new{enabled=true}
    assert(not c:install(nil) and not c:admit())
end

-- Registration can throw AFTER installing a callback. Retained callbacks are
-- harmless and return nil; retries cannot duplicate a partially installed set.
for _,name in ipairs(names) do
    local f = fixture(nil, name)
    assert(not f.installed and f.c:status().terminal)
    for _,cb in pairs(f.callbacks) do assert(cb() == nil) end
    assert(not f.c:admit() and not f.c:candidate() and not f.c:install(f.api))
end
do
    local f = fixture()
    local c = Epoch.new{enabled=true}
    f.api[names[2]] = function() return false end
    assert(not c:install(f.api) and c:status().terminal)
end

-- Simulated A -> title -> B, including InitGameState nested inside LoadMap.
-- Callback ordering is synthetic; this does not establish live travel coverage.
do
    local f = fixture(); local c = f.c
    assert(f.installed and not c:admit() and not c:candidate())
    f:event(1); f:init()
    assert(not c:candidate(), 'outer LoadMap still running')
    f:event(2)
    assert(not c:admit(), 'post must never grant readiness')
    local a = f:ready(); local frozen = a()
    local status = c:status(); status.epoch = 99; status.ready = false; status.counters.load_pre = 99
    assert(c:accepts(a) and c:status().epoch == frozen and c:status().counters.load_pre == 1)
    assert(not pcall(function() a.epoch = 999 end), 'token is not a mutable table')
    f:event(1) -- leave A: close BEFORE title/post/next polling sample
    assert(not c:accepts(a) and not c:admit() and c:status().epoch > frozen)
    assert(a() == frozen, 'captured epoch must not track current epoch')
    f:event(2) -- title; no init evidence and no verification
    assert(not c:candidate())
    f:event(1); f:init(); f:event(2)
    local b = f:ready()
    assert(b ~= a and c:accepts(b) and not c:accepts(a))
    assert(not c:accepts(function() return b() end), 'numeric epoch is not a credential')
    local other = fixture(); other:init(); local foreign = other:ready()
    assert(not c:accepts(foreign) and not other.c:accepts(b))
    f:event(3) -- independent InitGameState path also invalidates
    assert(not c:accepts(b)); f:event(4); f:ready()
    c:revoke(); assert(not c:admit() and not c:candidate())
end

-- Pre invalidation is visible even within the diagnostic observer itself.
do
    local c, old, seen
    local f = fixture{enabled=true, observe=function(event, s)
        if old and event == 'load_pre' then
            assert(not s.ready and s.epoch > old() and not c:accepts(old)); seen = true
        end
    end}
    c = f.c; f:init(); old = f:ready(); f:event(1); assert(seen)
end

-- Fresh active-storage proof is separate from lifecycle/role evidence. Observed
-- new-world gameplay with role=3, a directory, nil selected and loaded=false
-- must not be promoted by init/post, nor classified as non-authority here.
do
    local f = fixture(); f:init()
    local e = {role=3, directory='D869...', selected=nil, loaded_world=false}
    assert(not f.c:authorize(f.c:candidate(), function()
        assert(e.role == 3)
        return e.selected ~= nil and e.loaded_world == true
    end))
    assert(not f.c:admit() and f.c:status().reason == 'verification_failed')
end

-- Missing/throwing/truthy-but-not-true proof closes; stale proof cannot arm B.
for _,mode in ipairs({'missing','throw','truthy','false'}) do
    local f = fixture(); f:init(); local candidate = f.c:candidate()
    local verify
    if mode ~= 'missing' then verify = function()
        if mode == 'throw' then error('unavailable') end
        return mode == 'truthy' and 1 or false
    end end
    assert(not f.c:authorize(candidate, verify) and not f.c:admit())
    assert(not f.c:authorize(candidate, function() return true end))
end
do
    local f = fixture(); f:init(); local a = f.c:candidate()
    assert(not f.c:authorize(a, function() f:init(); return true end))
    assert(not f.c:admit()); f:ready()
end
do
    local f = fixture(); f:init(); local a = f.c:candidate()
    assert(not f.c:authorize(a, function()
        assert(not f.c:authorize(a, function() return true end)); return true
    end))
    assert(not f.c:admit())
end

-- Unpaired posts invalidate; nested callbacks cannot re-open an outer transition.
do
    local f = fixture(); f:init(); local a = f:ready()
    f:event(2); assert(not f.c:accepts(a) and not f.c:candidate())
    f:event(4); assert(not f.c:candidate())
    f:event(1); f:event(1); f:event(3); f:event(3); f:event(4)
    assert(not f.c:candidate()); f:event(4); f:event(2)
    assert(not f.c:candidate()); f:event(2); f:ready()
end

-- Epoch never wraps/reuses; diagnostic counts saturate and nesting is bounded.
do
    local f = fixture{enabled=true, epoch_limit=2, counter_limit=2}
    f:init(); local a = f:ready(); f:init(); local b = f:ready()
    assert(b() == 2 and not f.c:accepts(a)); f:event(3)
    assert(f.c:status().terminal and f.c:status().reason == 'epoch_exhausted')
    for _=1,20 do f:event(3); f:event(4); f.c:accepts(b); f.c:revoke() end
    local s = f.c:status(); assert(s.epoch == 2 and not f.c:candidate())
    for _,v in pairs(s.counters) do assert(v <= 2) end
end
do
    local f = fixture{enabled=true, depth_limit=1}
    f:event(1); f:event(1)
    assert(f.c:status().terminal and f.c:status().reason == 'depth_exhausted')
    f:event(2); f:init(); assert(not f.c:admit())
end

-- Observer errors never escape callbacks; no wrapper is accessed or retained.
do
    local f = fixture{enabled=true, observe=function() error('logger failed') end}
    local weak = setmetatable({}, {__mode='v'})
    do
        local wrapper = setmetatable({}, {__index=function() error('wrapper access') end,
            __tostring=function() error('wrapper stringify') end})
        weak[1] = wrapper
        f:event(1, wrapper, wrapper, wrapper, wrapper, wrapper)
        f:event(3, wrapper); f:event(4, wrapper); f:event(2, wrapper)
    end
    collectgarbage('collect'); assert(weak[1] == nil)
    assert(f.c:status().counters.observer_errors == 4); f:ready()
end
do
    local f = fixture(); local lines = {}
    local driver = Observer.start(f.api, function(s)
        assert(type(s) == 'string'); lines[#lines+1] = s
    end, 2)
    assert(driver.installed and #lines == 1)
    f:event(1); f:event(3); f:event(4); f:event(2)
    assert(#lines == 3 and lines[2]:find('event=load_pre',1,true))
    assert(lines[3]:find('log_limit_reached',1,true) and not driver.status().ready)
    assert(driver.admit == nil and driver.authorize == nil)
end
print('save lifecycle epoch: isolated lifecycle, stale admission/completion and observer checks passed')
