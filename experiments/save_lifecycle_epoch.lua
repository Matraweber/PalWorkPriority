-- Development experiment only. No production imports, engine queries or IO.
-- All calls must be serialized on the game thread; verifier/observer must not
-- yield. Tokens stay in Lua on that thread (never send a Lua closure to native
-- workers). Capture at admission, then check accepts() before applying a reply.
-- This is a lifecycle fence, NOT active-storage/authority proof or IO cancellation.
-- LuaMod.cpp (pinned 2281fa31), 6437-6540: LoadMap receives five arguments,
-- requests one nil/bool return; bool overrides the result. InitGameState receives
-- one wrapper and requests zero returns. Every callback below explicitly returns
-- nil and discards arguments without inspecting or retaining engine wrappers.
local M = {}
local hooks = {
    {'RegisterLoadMapPreHook', 'load_pre', 'load', true},
    {'RegisterLoadMapPostHook', 'load_post', 'load', false},
    {'RegisterInitGameStatePreHook', 'init_pre', 'init', true},
    {'RegisterInitGameStatePostHook', 'init_post', 'init', false},
}
local function bound(n, default)
    if n == nil then return default end
    assert(math.type(n) == 'integer' and n >= 1 and n <= 2147483647, 'invalid bound')
    return n
end
function M.new(options)
    options = options or {}
    local epoch_limit = bound(options.epoch_limit, 2147483647)
    local counter_limit = bound(options.counter_limit, 2147483647)
    local depth_limit = bound(options.depth_limit, 64)
    local observer = type(options.observe) == 'function' and options.observe or nil
    local enabled = options.enabled == true
    local epoch, token, ready, initialized = 0, nil, false, false
    local attempted, installed, terminal, busy = false, false, false, false
    local reason = enabled and 'uninstalled' or 'disabled'
    local depth = {load = 0, init = 0}
    local counts = {load_pre=0, load_post=0, init_pre=0, init_post=0,
        invalidations=0, rejected=0, observer_errors=0}
    local c = {}
    local function count(k) counts[k] = math.min(counter_limit, counts[k] + 1) end
    local function stop(why)
        ready, initialized, token, terminal, reason = false, false, nil, true, why
    end
    local function invalidate(why)
        ready, initialized, token, reason = false, false, nil, why
        count('invalidations')
        if terminal then return end
        if epoch >= epoch_limit then stop('epoch_exhausted'); return end
        epoch = epoch + 1
        local immutable_epoch = epoch
        -- Function identity is the credential; numeric epoch alone is never one.
        -- Captured value cannot be reassigned through ordinary Lua table writes.
        token = function() return immutable_epoch end
    end
    local function eligible()
        return installed and not terminal and initialized and depth.load == 0 and depth.init == 0
    end
    function c:status()
        local copy = {}
        for k,v in pairs(counts) do copy[k] = v end
        return {epoch=epoch, ready=ready, installed=installed, terminal=terminal,
            reason=reason, load_depth=depth.load, init_depth=depth.init, counters=copy}
    end
    local function observe(event)
        if observer then
            local ok = pcall(observer, event, c:status())
            if not ok then count('observer_errors') end
        end
    end
    local function callback(event, kind, pre)
        return function()
            count(event)
            if enabled and not terminal then
                if pre then
                    -- Fence first, including before any diagnostic/user callback.
                    invalidate(event)
                    if depth[kind] >= depth_limit then stop('depth_exhausted')
                    else depth[kind] = depth[kind] + 1 end
                elseif depth[kind] == 0 then
                    -- A post without its pre cannot establish a session.
                    invalidate('unmatched_' .. event)
                else
                    depth[kind] = depth[kind] - 1
                    if kind == 'init' and depth.init == 0 then initialized = true end
                    -- LoadMap post supplies no success result. Never infer ready.
                end
            end
            observe(event)
            return nil
        end
    end
    function c:install(api)
        if attempted or not enabled or terminal then return false end
        attempted = true
        if type(api) ~= 'table' then stop('hooks_unavailable'); return false end
        local registrars = {}
        for i,h in ipairs(hooks) do
            registrars[i] = rawget(api, h[1])
            if type(registrars[i]) ~= 'function' then
                stop('missing_' .. h[1]); return false
            end
        end
        for i,h in ipairs(hooks) do
            local ok, result = pcall(registrars[i], callback(h[2], h[3], h[4]))
            -- Pinned registration returns no Lua values: nil IS success.
            -- Explicit false is treated as failure for alternate adapters.
            if not ok or result == false then
                stop('registration_failed_' .. h[1]); return false
            end
            if terminal then return false end
        end
        installed = true
        reason = 'awaiting_lifecycle'
        return true
    end
    -- Candidate for a fresh synchronous authority/active-storage verification.
    -- Late attachment without an observed InitGameState pair stays closed.
    function c:candidate()
        if eligible() and not busy then return token end
    end
    function c:authorize(candidate, verify)
        if busy then invalidate('reentrant_verification'); return false end
        if not eligible() or candidate == nil or candidate ~= token or ready then return false end
        if type(verify) ~= 'function' then invalidate('verification_unavailable'); return false end
        busy = true
        local ok, proof = pcall(verify, epoch)
        busy = false
        if not ok or proof ~= true then invalidate('verification_failed'); return false end
        if not eligible() or token ~= candidate then return false end
        ready, reason = true, 'ready'
        return true
    end
    function c:admit()
        if ready and eligible() and not busy then return token end
        count('rejected')
        return nil
    end
    function c:accepts(captured)
        local ok = ready and eligible() and not busy and captured ~= nil and captured == token
        if not ok then count('rejected') end
        return ok == true
    end
    function c:revoke()
        invalidate('explicit_revoke')
    end
    return c
end
return M
