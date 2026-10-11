-- Development-only integration boundary. Never required by production Scripts.
-- Factory must only construct an isolated, scope-bound queue/adapter (no IO).
-- submit takes a COMPLETE immutable settings snapshot, not an edit delta.
-- initialize is optional: only a queue reporting positive missing may admit it.
-- Acceptance remains recovering until its durable, original-payload event.
-- All methods run on the game thread. No engine wrapper belongs in this module.
local M = {}
local function key(s) return type(s)=='string' and #s>0 and #s<=256 end
local function finite(n) return type(n)=='number' and n==n and n>=0 and n<math.huge end
local function capacity(n)
    if n==nil then return 65536 end
    assert(math.type(n)=='integer' and n>=65536 and n<=262144,'unsupported payload capacity')
    return n
end
function M.new(options)
    assert(type(options)=='table')
    if options.enabled~=true then
        return {status=function() return {state='disabled'} end,
            open=function() return false,'disabled' end}
    end
    assert(type(options.factory)=='function' and type(options.clock)=='function')
    local max_payload_bytes=capacity(options.max_payload_bytes)
    -- Every controller targeting the same native backend MUST share this lease.
    -- Native adapters must additionally enforce ownership across module reloads.
    assert(type(options.lease)=='table','shared backend lease required')
    local lease,claim=options.lease,{}
    local timeout=options.timeout or 10
    assert(finite(timeout) and timeout>0)
    local q, scope, session, active, recovering, deadline, ticket, delivered, last_now, opening
    local initializing,admitting_init=false,false
    lease.seen=lease.seen or {}; lease.sessions=lease.sessions or 0
    assert(type(lease.seen)=='table' and math.type(lease.sessions)=='integer')
    local seen=lease.seen -- shared across replacement controllers for this backend
    local c={}
    -- Trusted integration callback must freshly verify scope, incarnation,
    -- authority and storage readiness. A selected save ID alone is insufficient.
    -- Missing/throwing/ambiguous evidence denies access. Callback must not yield
    -- or reenter this controller. Retired accepted data still drains its owner.
    local function authorized(owner, token)
        if type(options.authorize)~='function' then return false end
        local ok,value=pcall(options.authorize,owner,token)
        return ok and value==true
    end
    local function refresh_authority()
        if active and not authorized(scope,session) then
            active=false
            if type(q.close_admission)=='function' then q:close_admission() end
            if q:can_shutdown() and lease.holder==claim then lease.holder=nil end
        end
    end
    local function now()
        local n=options.clock()
        assert(finite(n) and (not last_now or n>=last_now),'invalid/nonmonotonic save clock')
        last_now=n; return n
    end
    local function track(n)
        if ticket~=q.ticket then ticket=q.ticket; deadline=n+timeout end
    end
    local function matches(token) return q and active and token==session end
    function c:open(owner, token)
        if opening or admitting_init then return false,'opening in progress' end
        if not key(owner) or not key(token) then return false,'invalid owner/session' end
        refresh_authority()
        if not authorized(owner,token) then return false,'authority/storage unavailable' end
        -- Never replace a queue with unresolved IO or accepted dirty snapshots.
        if q and (active or not q:can_shutdown()) then return false,'previous owner not closed' end
        if lease.holder and lease.holder~=claim then return false,'backend owned by another controller' end
        if seen[token] then return false,'new incarnation required' end
        if lease.sessions>=256 then return false,'session capacity reached' end
        local n=now()
        lease.holder=claim
        opening=true
        -- Third factory argument is additive; legacy factories may ignore it.
        -- Construction must remain IO-free until all capacities agree.
        local built,nextq=pcall(function()
            local candidate=options.factory(owner,token,max_payload_bytes)
            assert(type(candidate)=='table'
                and capacity(candidate.max_payload_bytes)==max_payload_bytes,'queue payload capacity mismatch')
            return candidate
        end)
        opening=false
        if not built then
            -- Factory contract forbids IO, so construction failure is definite.
            if lease.holder==claim then lease.holder=nil end
            return false,'queue construction failed'
        end
        if lease.holder~=claim then return false,'backend reservation lost' end
        if not authorized(owner,token) then
            lease.holder=nil
            return false,'authority/storage changed during construction'
        end
        seen[token]=true; lease.sessions=lease.sessions+1
        q,scope,session,active,recovering=nextq,owner,token,true,true
        delivered,ticket,deadline=0,nil,nil
        initializing=false
        local origin=q
        local accepted=origin:recover()
        if q~=origin or session~=token then return false,'session changed during recovery' end
        track(n)
        return accepted, accepted==false and 'recovery rejected' or 'recovering'
    end
    function c:submit(token,payload)
        if admitting_init then return nil,'initialization admission in progress' end
        refresh_authority()
        if not matches(token) then return nil,'inactive session' end
        if recovering then return nil,'recovery incomplete' end
        if type(payload)~='string' or #payload>max_payload_bytes then return nil,'invalid snapshot' end
        -- Unknown/error state requires resolution or an explicit retry. Do not
        -- turn another click into an implicit retry of a failing storage path.
        if q.state=='uncertain' or q.state=='error' then return nil,q.state end
        local n=now()
        local origin,owner,incarnation=q,scope,session
        local revision=origin:submit(payload)
        if q==origin and session==incarnation then track(n) end
        -- Dispatch may complete inline and replace this controller's session.
        -- Return the original acceptance identity; status will mark it stale.
        return {session=incarnation,scope=owner,revision=revision}
    end
    -- Optional queue capability: positive missing recovery is not itself a write
    -- grant. Initialization uses fresh authorization and stays in recovery until
    -- the queue emits the consumed durable publication's original payload.
    function c:initialize(token,payload)
        if opening or admitting_init then return nil,'busy' end
        refresh_authority()
        if not matches(token) then return nil,'inactive session' end
        if not recovering or initializing or type(q.can_initialize)~='function'
            or type(q.initialize)~='function' or q:can_initialize()~=true then
            return nil,'initialization unavailable'
        end
        if type(payload)~='string' or #payload>max_payload_bytes then return nil,'invalid snapshot' end
        local origin,owner,incarnation=q,scope,session
        local n=now()
        refresh_authority() -- clock/provider callbacks cannot carry an old grant into IO
        if q~=origin or not matches(incarnation) or origin:can_initialize()~=true then
            return nil,'authority/session unavailable'
        end
        admitting_init=true
        local ok,revision=pcall(origin.initialize,origin,payload)
        admitting_init=false
        if not ok then return nil,'invalid initialization' end
        if math.type(revision)~='integer' or revision<1 then return nil,'initialization unavailable' end
        if q==origin and session==incarnation then initializing=true;track(n) end
        refresh_authority()
        return {session=incarnation,scope=owner,revision=revision} -- acceptance only
    end
    function c:poll()
        if opening or admitting_init then return end
        if not q then return end
        refresh_authority()
        local n=now()
        local origin,incarnation=q,session
        local ok,payload=origin:poll()
        if q~=origin or session~=incarnation then return end
        refresh_authority()
        track(n)
        if recovering and ok==true then
            recovering,initializing=false,false; delivered=q.saved
            -- Caller may install recovered settings only into this incarnation.
            if active then return {session=session,scope=scope,payload=payload,revision=q.saved} end
            if q:can_shutdown() and lease.holder==claim then lease.holder=nil end
        end
        if deadline and n>=deadline then q:timeout() end
        if not active and q:can_shutdown() and lease.holder==claim then lease.holder=nil end
    end
    function c:status(receipt)
        if not opening then refresh_authority() end
        if not q then return {state='unavailable'} end
        if receipt and (type(receipt)~='table' or not active or receipt.session~=session or receipt.scope~=scope
            or math.type(receipt.revision)~='integer' or receipt.revision<1
            or receipt.revision>q.generation) then return {state='stale'} end
        if receipt and receipt.revision<=q.saved then return {state='saved'} end
        local state=not active and (q:can_shutdown() and 'closed' or 'closing')
            or recovering and not initializing and type(q.can_initialize)=='function'
                and q:can_initialize()==true and 'initialization_required'
            or q.state=='uncertain' and 'uncertain' or q.state=='error' and 'error'
            or initializing and 'initializing' or recovering and 'recovering'
            or q.saved<q.generation and 'saving' or 'saved'
        return {state=state,session=session,scope=scope,accepted=q.generation,saved=q.saved}
    end
    function c:take_committed(token)
        refresh_authority()
        if not matches(token) or recovering or q.saved<=delivered then return end
        local event={session=session,scope=scope,first=delivered+1,last=q.saved}
        delivered=q.saved
        return event -- caller consumes once, then routes with the session fence
    end
    function c:retry(token)
        if opening or admitting_init then return false end
        -- Closing revokes new edits/replies, not ownership of accepted data.
        -- A definite failure may be explicitly retried for the retired owner,
        -- including accepted initialization. Unaccepted recovery is never retried.
        if not q or token~=session or (recovering and not initializing) or q.state~='error' then return false end
        local n=now(); local origin=q
        origin:retry()
        if q~=origin or session~=token then return false end
        track(n)
        return origin.state=='saving'
    end
    function c:close(token)
        if opening then return false end
        if not q or token~=session then return false end
        active=false -- revoke replies before any subsequent completion
        if type(q.close_admission)=='function' then q:close_admission() end
        local drained=q:can_shutdown()
        if drained and lease.holder==claim then lease.holder=nil end
        return drained
    end
    function c:drain(token)
        if opening or admitting_init or not q or token~=session or type(q.shutdown_drain)~='function' then return false end
        active=false
        q:close_admission()
        local drained=q:shutdown_drain()==true and q:can_shutdown()
        if drained and lease.holder==claim then lease.holder=nil end
        return drained
    end
    return c
end
return M
