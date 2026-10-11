-- Isolated composition only. No production installation, settings mutation,
-- native authorization proof, migration or network sends.
-- ONE instance/shared lease per guild stream, covering EVERY camp submission.
-- authorize(copied_context) MUST freshly prove external authority/storage/role;
-- absent, thrown or nonliteral-true authorization permanently revokes admission,
-- activation and replies once opened. Original-owner poll/retry may still drain
-- already accepted data. Caller must authenticate peer routes before ACK delivery.
-- Workflow: open/poll -> take_recovered (typed decoded copy, once) -> register
-- camps with proven baseline coverage -> stage BEFORE mutable settings changes
-- -> submit canonical full body -> poll -> generation-scoped ACK/ready checks.
-- register_camp's boolean is supplied by trusted integration after inspecting
-- decoded settings and actual Pal coverage, never inferred from a header alone.
-- Default backend remains PWP-SCOPED-DEV-1. Explicit backend_kind=
-- PWP-JOURNAL-DEV-1 enables the whole-journal queue and initialize(context,body)
-- after positive missing recovery + fresh authorization. No automatic import.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/settings_session.lua$'))
local Scope=dofile(root..'/save_scope.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local Transport=dofile(root..'/save_transport.lua')
local Queue=dofile(root..'/save_scratch.lua')
local JournalQueue=dofile(root..'/save_journal_queue.lua')
local DrainingQueue=dofile(root..'/save_draining_queue.lua')
local Session=dofile(root..'/save_session.lua')
local Barrier=dofile(root..'/save_durability_barrier.lua')
local M={}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function text(v) return type(v)=='string' and #v>0 and #v<=256 end
local function copy(t) local r={};for k,v in pairs(t) do r[k]=v end;return r end
function M.new(options)
    assert(plain(options) and options.enabled==true,'isolated development opt-in required')
    local scope=Scope.new(options.storage,options.guild,options.stream)
    local token,incarnation=options.session,options.incarnation
    assert(text(token) and text(incarnation),'immutable session/incarnation required')
    local kind=options.backend_kind
    if kind==nil then kind='PWP-SCOPED-DEV-1' end
    assert(kind=='PWP-SCOPED-DEV-1' or kind=='PWP-JOURNAL-DEV-1' or kind=='PWP-DRAINING-DEV-1','unknown backend kind')
    local draining=kind=='PWP-DRAINING-DEV-1'
    local draining_backend=draining and options.backend or nil
    local journal=kind=='PWP-JOURNAL-DEV-1' or draining
    local epoch=options.epoch
    if journal then assert(math.type(epoch)=='integer' and epoch>=1 and epoch<=2147483646,'journal epoch required') end
    local max=options.max_payload_bytes
    if max==nil then max=65536 end
    local codec=Codec.new{storage=scope.storage,guild=scope.guild,stream=scope.stream,max_payload_bytes=max}
    local supported,decode,encode=codec.supported,codec.decode,codec.encode
    assert(type(supported)=='function','mandatory typed semantic policy')
    local authorize=options.authorize -- captured, never upgraded via options mutation
    assert(authorize==nil or type(authorize)=='function')
    local max_pending,max_peers,max_camps=options.max_pending,options.max_peers,options.max_camps
    -- Construct/validate transport capability without dispatching IO.
    local adapter,journal_queue
    if journal and not draining then
        journal_queue=JournalQueue.new{enabled=true,storage=scope.storage,guild=scope.guild,
            stream=scope.stream,incarnation=incarnation,epoch=epoch,backend=options.backend,max_payload_bytes=max}
    elseif not draining then
        adapter=Transport.new{enabled=true,storage=scope.storage,guild=scope.guild,
            stream=scope.stream,incarnation=token,backend=options.backend,max_payload_bytes=max}
    end
    local busy,opened,stopped=false,false,false
    local call_context,ledger,ledger_context,recovery,pending_commit,last_receipt
    local pending,activation_taken={},false
    local reason
    local function matches(c)
        return plain(c) and c.authority==true and text(c.camp) and c.scope==scope.key
            and c.guild==scope.guild and c.stream==scope.stream and c.session==token
            and c.incarnation==incarnation
            and (not journal or c.epoch==epoch)
    end
    local function context_copy(c)
        -- Allowlist scalar identity fields; never retain caller extras/wrappers.
        return {scope=scope.key,storage=scope.storage,session=token,incarnation=incarnation,epoch=journal and epoch or nil,
            guild=scope.guild,stream=scope.stream,camp=c.camp,authority=true}
    end
    local function fresh()
        if stopped or not call_context or type(authorize)~='function' then return false end
        local ok,yes=pcall(authorize,copy(call_context))
        return ok and yes==true
    end
    local controller=Session.new{enabled=true,lease=options.lease,clock=options.clock,
        timeout=options.timeout,max_payload_bytes=max,
        authorize=function(owner,session) return owner==scope.key and session==token and fresh() end,
        factory=function(owner,session,capacity)
            assert(owner==scope.key and session==token and capacity==max)
            if draining then
                return DrainingQueue.new{enabled=true,storage=scope.storage,guild=scope.guild,stream=scope.stream,
                    session=token,incarnation=incarnation,epoch=epoch,camp=call_context.camp,
                    backend=draining_backend,max_payload_bytes=max}
            end
            if journal then return journal_queue end
            return Queue.new(adapter,owner,session,{max_payload_bytes=max,validate_payload=supported})
        end}
    local function retire(why)
        stopped=true;reason=why or 'retired';pending={}
        if ledger then ledger:retire() end
        if opened then controller:close(token) end
    end
    local function allowed()
        if fresh() then
            local state=opened and controller:status().state
            if state~='closed' and state~='closing' then return true end
        end
        if opened then retire('authority/session unavailable') end
        return false
    end
    -- Reentry from authorize/backend/clock cannot poll or drain committed events
    -- while submission is still registering its receipt. No raw internals escape.
    local function guarded(fn)
        return function(_,c,...)
            if busy then return nil,'busy' end
            if not matches(c) then return nil,'context mismatch' end
            busy=true;call_context=context_copy(c)
            local result=table.pack(pcall(fn,c,...))
            call_context=nil;busy=false
            if not result[1] then
                retire('operation failed')
                return nil,'operation failed' -- no arbitrary callback/error text escapes
            end
            return table.unpack(result,2,result.n)
        end
    end
    local m={}
    m.open=guarded(function(c)
        if opened or stopped then return false,'already opened/retired' end
        if not allowed() then return false,'authority/storage unavailable' end
        ledger=Barrier.new{enabled=true,context=c,max_pending=max_pending,max_peers=max_peers,max_camps=max_camps}
        opened=true
        local ok,why=controller:open(scope.key,token)
        if not allowed() then return false,reason end
        return ok,why
    end)
    m.poll=guarded(function(c)
        if not opened then return nil,'not opened' end
        if not stopped then allowed() end
        -- Retired owners still drain through the original session, without ACKs.
        local event=controller:poll()
        if stopped or not allowed() then return nil,reason end
        if event then
            if event.payload==nil then retire('first initialization required');return nil,reason end
            local decoded=decode(event.payload)
            if not decoded then retire('unsupported recovery');return nil,reason end
            if not allowed() then return nil,reason end
            recovery={scope=event.scope,session=event.session,revision=event.revision,payload=event.payload}
        end
        if ledger_context then
            if not pending_commit then
                local committed=controller:take_committed(token)
                if committed then pending_commit=copy(committed) end
            end
            if not allowed() then return nil,reason end
            if pending_commit then
                if not ledger:commit(ledger_context,pending_commit) then
                    reason='commit registration mismatch';return nil,reason
                end
                pending_commit=nil
            end
            local status=controller:status()
            if last_receipt and (status.state=='error' or status.state=='uncertain') then
                ledger:failed(ledger_context,last_receipt,status.state)
            end
        end
        return event and 'recovered' or controller:status().state
    end)
    m.initialize=guarded(function(c,body)
        if not journal or not opened or recovery or not allowed() then return nil,'initialization unavailable' end
        local payload,why=encode(body)
        if not payload then return nil,why end
        local receipt,err=controller:initialize(token,payload)
        if not allowed() then return nil,reason end
        return receipt,err -- no activation, baseline coverage or ACK until durable recovery
    end)
    m.take_recovered=guarded(function()
        if not allowed() or not recovery or activation_taken then return nil,'unavailable' end
        local decoded=decode(recovery.payload)
        if not decoded or not allowed() then return nil,'unavailable' end
        activation_taken=true
        return {scope=scope.key,session=token,revision=recovery.revision,settings=decoded}
    end)
    m.register_camp=guarded(function(c,baseline_covered)
        if not allowed() or not recovery or not activation_taken then return false,'recovery not activated' end
        local ok=ledger:recover(c,recovery,baseline_covered)
        if ok and not ledger_context then ledger_context=context_copy(c) end
        return ok
    end)
    m.stage=guarded(function(c,metadata)
        if not allowed() or not recovery or not activation_taken or pending_commit then return nil,'unavailable' end
        local ticket,why=ledger:stage(c,metadata)
        if ticket and why~='duplicate' then pending[ticket]={camp=c.camp} end
        return ticket,why
    end)
    m.submit=guarded(function(c,ticket,body)
        if not allowed() or pending_commit then return nil,'unavailable' end
        local entry=pending[ticket]
        if not entry or entry.camp~=c.camp then return nil,'unregistered stage' end
        local payload,why=encode(body)
        if not payload then return nil,why end -- stage remains closed; caller may correct body
        local receipt,err=controller:submit(token,payload)
        if not receipt then return nil,err end
        -- No wrapper poll can run until this acceptance has been registered.
        if not allowed() then return nil,reason end
        if not ledger:accept(c,ticket,receipt) then retire('receipt mismatch');return nil,reason end
        pending[ticket]=nil;last_receipt=copy(receipt)
        return copy(receipt) -- memory acceptance only; never durable permission
    end)
    m.ready=guarded(function(c)
        return allowed() and recovery~=nil and activation_taken and not pending_commit
            and ledger:ready(c) or false
    end)
    m.peek_ack=guarded(function(c,ticket,route)
        if not allowed() or pending_commit or not ledger then return end
        local ack=ledger:peek_ack(c,ticket,route)
        if not allowed() then return end
        return ack
    end)
    m.consume_ack=guarded(function(c,ticket,route)
        return allowed() and not pending_commit and ledger and ledger:consume_ack(c,ticket,route) or false
    end)
    m.retry=guarded(function()
        if not opened then return false end
        -- Retirement revokes new edits/replies, not accepted-data ownership.
        -- guarded() still requires the ORIGINAL scope/session/incarnation context;
        -- its authority flag identifies that original binding, not fresh authority.
        -- Session.retry admits only a definite error with accepted dirty data,
        -- including accepted initialization, never unaccepted recovery,
        -- pending/uncertain IO, or a replacement owner's token.
        -- One explicit call makes at most one dispatch; there is no retry loop.
        if not stopped then allowed() end
        local ok=controller:retry(token)
        if not stopped then allowed() end
        return ok -- retry admission only; never permission or a durable ACK
    end)
    m.status=guarded(function(c,ticket)
        if not stopped then allowed() end
        local status=controller:status()
        local barrier=ledger and ledger:status(c,ticket)
        return {state=stopped and reason or status.state,barrier=barrier,
            drain_state=status.state,
            recovered=recovery~=nil,activation_taken=activation_taken,blocked_commit=pending_commit~=nil}
    end)
    m.close=guarded(function()
        retire('retired')
        return controller:close(token)
    end)
    -- Explicit blocking boundary for the native-owned tail. Never call from
    -- a worker or DLL teardown. Revokes edits/activation/ACKs before draining.
    m.drain=guarded(function()
        if not draining or not opened then return false end
        retire('retired')
        return controller:drain(token)
    end)
    return m
end
return M
