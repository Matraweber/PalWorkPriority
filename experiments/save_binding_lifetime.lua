-- Pure, opt-in game-thread coordinator. No engine, IO, scheduling or retries.
-- track(id, context) immediately after native bind, BEFORE returning its ID to
-- save_local_binding. attach(id, drain) before opening/admitting a Lua session.
-- Wire binder.discard = lifetime.discard (dot call). true acknowledges Lua
-- invalidation ONLY, not native retirement. Poll discarded IDs explicitly.
-- Every settings_session authorize callback MUST also call current(id, context),
-- alongside fresh binder/authority checks; current alone grants no authority.
-- This fence revokes submission/activation/ACK even during reentrant discard.
-- Drain callbacks close/poll/drained receive a fresh copy of the ORIGINAL context.
-- close returns boolean (false means accepted tail still draining); poll's result
-- is discarded; drained returns true ONLY after all accepted/coalesced snapshots
-- and native mailbox reservations are resolved. Never infer this from idle worker.
-- close may return nil,'busy' ONLY for a definite non-execution; defer that call.
-- M.settings(session) adapts the actual settings_session close/poll/status API.
-- Raw queue users supply close=retire, poll=poll, drained=can_shutdown wrappers.
-- Native retire(id, context)/release(id, context) return literal true only after
-- validated bridge command 7/8 success. Those commands are NOT retry-idempotent.
-- We call each once, memoize success, and retain uncertainty without retry. A
-- failed drain stays owned; explicit recovery/retry belongs to the old session.
-- Track inert IDs even if binder's postcheck fails. Unknown bind-return IDs cannot
-- be rescued here. All callbacks are trusted synchronous/non-yielding adapters.
-- Integration gap: save_local_binding requires bind to be inert/no owner claim;
-- bridge command 1 already claims SaveOwner. Directly wiring those two still needs
-- an inert registry stage or an explicit binder contract reconciliation. This
-- coordinator manages captured native IDs; it does not change bind semantics or
-- authenticate IDs. Reserve tracking capacity before native allocation; a failed
-- track must never be followed by session admission or returning an active ID.
local M={}
local fields={'scope','storage','guild','stream','session','incarnation','epoch','camp','authority'}
local identity={'scope','guild','stream','session','incarnation','epoch'}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function copy(c) local r={};for _,k in ipairs(fields) do r[k]=c[k] end;return r end
local function context(c)
    if not plain(c) or c.authority~=true or math.type(c.epoch)~='integer'
        or c.epoch<1 or c.epoch>2147483646 then return end
    for _,k in ipairs({'scope','guild','stream','session','incarnation','camp'}) do
        if type(c[k])~='string' or #c[k]==0 or #c[k]>256 then return end
    end
    if c.storage~=nil and (type(c.storage)~='string' or #c.storage>256) then return end
    return copy(c)
end
function M.settings(session)
    local close,poll,status=session.close,session.poll,session.status
    assert(type(close)=='function' and type(poll)=='function' and type(status)=='function')
    return {
        close=function(c) return close(session,c) end,
        poll=function(c) return poll(session,c) end,
        drained=function(c)
            local s,why=status(session,c)
            if s==nil and why=='busy' then return false end
            assert(plain(s) and type(s.drain_state)=='string','drain status unavailable')
            -- Session 'unavailable' means no queue was opened (construction is
            -- IO-free). An attached-but-never-opened session is still inert.
            return s.drain_state=='closed' or s.drain_state=='unavailable'
        end}
end
function M.new(o)
    assert(plain(o) and o.enabled==true,'isolated opt-in required')
    local retire,release=o.retire,o.release
    local limit=o.limit or 128 -- bridge IDs are burned, never reused
    assert(type(retire)=='function' and type(release)=='function')
    assert(math.type(limit)=='integer' and limit>=1 and limit<=128)
    local entries,count,busy={},0,false
    local api={}
    function api.track(id,c)
        if busy or math.type(id)~='integer' or id<1 or id>128 or entries[id] or count>=limit then return false end
        local captured=context(c);if not captured then return false end
        entries[id]={context=captured,state='active'};count=count+1;return true
    end
    function api.attach(id,drain)
        local e=entries[id]
        if busy or not e or e.state~='active' or e.drain or not plain(drain) then return false end
        for _,k in ipairs({'close','poll','drained'}) do if type(drain[k])~='function' then return false end end
        e.drain={close=drain.close,poll=drain.poll,drained=drain.drained};return true
    end
    function api.current(id,c)
        local e=entries[id]
        if not e or e.state~='active' or not plain(c) or c.authority~=true then return false end
        for _,k in ipairs(identity) do if c[k]~=e.context[k] then return false end end
        if c.storage~=nil and c.storage~=e.context.storage then return false end
        return true -- shared guild stream may authorize multiple camps
    end
    function api.discard(id)
        local e=entries[id];if not e then return false end
        if e.state=='active' then e.state='draining' end -- no callbacks, reentry safe
        return true
    end
    function api.status(id)
        local e=entries[id]
        return {state=e and e.state or 'unknown',reason=e and e.reason,
            retired=e and e.retired==true or false,released=e and e.state=='released' or false}
    end
    function api.poll(id)
        local e=entries[id]
        if busy then return false,'busy' end
        if not e then return false,'unknown' end
        if e.state=='released' then return true end
        if e.state~='draining' then return false,e.state end
        busy=true
        local phase='drain'
        local ok,done=pcall(function()
            if e.drain then
                if not e.closed then
                    local closed,why=e.drain.close(copy(e.context))
                    if closed==nil and why=='busy' then return false end
                    assert(type(closed)=='boolean','close outcome unknown')
                    e.closed=true -- close revokes; false is NOT a drain failure
                end
                e.drain.poll(copy(e.context)) -- never deliver recovery/ACK to new world
                local drained=e.drain.drained(copy(e.context))
                assert(type(drained)=='boolean','drain outcome unknown')
                if not drained then return false end
            end
            phase='retire';e.state='retiring'
            assert(retire(id,copy(e.context))==true,'retire outcome unknown')
            e.retired=true
            phase='release';e.state='releasing'
            assert(release(id,copy(e.context))==true,'release outcome unknown')
            e.state='released';e.context=nil;e.drain=nil
            return true
        end)
        busy=false
        if not ok then e.state='uncertain';e.reason=phase..'_uncertain';return false,e.reason end
        return done,e.state
    end
    return api
end
return M
