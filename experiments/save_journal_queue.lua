-- Isolated whole-journal queue. No production wiring, filesystem IO or SHA in Lua.
-- new{enabled=true,storage,guild,stream,incarnation,epoch,backend,max_payload_bytes}
-- constructs without IO. All calls are non-yielding on the game thread.
-- Backend contract PWP-JOURNAL-DEV-1 (copied tables, plain function calls):
-- recover(identity); update(identity + {preimages,payload,journal_generation,
-- covered_revision,initialize}); peek(identity); consume(identity).
-- Identity = scope,incarnation,epoch,ticket,kind,max_payload_bytes. Every terminal
-- echoes all fields and terminal=true,certain=boolean,status. Admission returns
-- true / false DEFINITELY not reserved or started / nil or throw UNKNOWN.
-- peek returns nil while pending. consume returns true only for that exact
-- certain terminal and is idempotent. No callback into Lua from a worker.
-- Recovery status 'recovered' includes slots={A,B}, each {status=...}; valid
-- slots additionally contain scope,generation,payload. Native has checked SHA.
-- Statuses: valid,missing,corrupt,unsupported,foreign,unreadable. preimages is a
-- bounded opaque token for BOTH exact native-held encoded preimages, including
-- corrupt/empty files; missing is positively observed, never inferred from nil.
-- Tokens are bound to this owner/destination. update checks that exact pair,
-- encodes SHA, and owns the WHOLE journal update; Lua never selects a slot.
-- The backend captures its root capability with the scope; these requests carry
-- no independent root/path and cannot redirect an admitted operation.
-- Successful update status initialized/updated echoes journal_generation and
-- covered_revision, plus a successor preimages token. cleanup_error is a warning.
-- Success MUST mean validated publication of this operation's exact immutable
-- payload: native SHA envelope validation, matching preimages/next generation,
-- checked full write, FlushFileBuffers, publication and closes. Dispatch success
-- or SaveOperation::run()==true alone is NOT publication success. No separate
-- payload readback is required by this contract; the backend attests the exact
-- published bytes and successor pair. This makes no power-loss guarantee.
-- Other certain terminals: conflict,io_error,cancelled-before-io. These require
-- reconciliation (inactive preimages may have changed); retry() only retries a
-- definitely rejected dispatch. Native uncertain terminals are never consumed.
--
-- generation/saved are session-local logical revisions (start at zero even when
-- recovery finds disk generation N). journal_generation is the physical counter.
-- submit returns a logical revision; save_session supplies scoped receipts and
-- take_committed ranges. Payloads are complete immutable CODEC envelopes.
-- poll returns true,payload for supported recovery OR consumed durable initial
-- publication (the exact initialization payload, never a newer coalesced value).
-- Two missing slots require initialize(payload), explicitly authorized by the
-- caller; can_initialize() reports that positive absence, not authorization.
-- Ordinary submit cannot initialize.
--
-- retire() revokes submissions but drains already accepted snapshots, including
-- coalesced work needing a NEW native reservation. It does NOT retire SaveOwner.
-- Caller must delay native retire/release until can_shutdown()==true. Calling
-- SaveOwner::retire early cancels/not-admits work; this queue cannot drain then.
-- save_session.close already revokes submissions and polls its original queue;
-- it need not call retire(). No new owner/lease may replace unresolved work.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/save_journal_queue.lua$'))
local Scope=dofile(root..'/save_scope.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local M={}
local LIMIT=2147483646
local function integer(n,lo,hi) return math.type(n)=='integer' and n>=lo and n<=hi end
local function text(s) return type(s)=='string' and #s>0 and #s<=256 end
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local identity_fields={'scope','incarnation','epoch','ticket','kind','max_payload_bytes'}
local function copy_identity(op)
    local t={};for _,k in ipairs(identity_fields) do t[k]=op[k] end;return t
end
local function matches(result,op)
    if not plain(result) then return false end
    for _,k in ipairs(identity_fields) do if result[k]~=op[k] then return false end end
    return true
end
function M.new(options)
    assert(plain(options) and options.enabled==true,'development opt-in required')
    local scope=Scope.new(options.storage,options.guild,options.stream).key
    local incarnation,epoch=options.incarnation,options.epoch
    assert(text(incarnation) and integer(epoch,1,LIMIT),'invalid binding')
    local max=options.max_payload_bytes
    if max==nil then max=65536 end
    local codec=Codec.new{storage=options.storage,guild=options.guild,stream=options.stream,max_payload_bytes=max}
    local backend=options.backend
    assert(plain(backend) and backend.contract=='PWP-JOURNAL-DEV-1'
        and backend.max_payload_bytes==max,'whole-journal capacity/contract required')
    local recover,update,peek,consume=backend.recover,backend.update,backend.peek,backend.consume
    assert(type(recover)=='function' and type(update)=='function'
        and type(peek)=='function' and type(consume)=='function','incomplete backend')
    local q={session=incarnation,generation=0,saved=0,journal_generation=0,
        ticket=0,state='unrecovered',max_payload_bytes=max}
    local flight,latest,preimages,recovered,missing,retired,busy,retryable
    local function supported(payload)
        return type(payload)=='string' and #payload<=max and codec.supported(payload)
    end
    local function fail(reason)
        q.state,q.error='error',reason
        return false
    end
    local function launch(kind)
        if q.ticket>=LIMIT then retryable=false;return fail('ticket exhausted') end
        q.ticket=q.ticket+1
        local op={scope=scope,incarnation=incarnation,epoch=epoch,ticket=q.ticket,
            kind=kind,max_payload_bytes=max}
        local request=copy_identity(op)
        if kind=='update' then
            if q.journal_generation>=LIMIT then retryable=false;return fail('journal generation exhausted') end
            op.payload,op.covered_revision=latest.payload,latest.revision
            op.journal_generation=q.journal_generation+1
            op.initialize=missing==true
            request.payload,request.covered_revision=op.payload,op.covered_revision
            request.journal_generation,request.initialize=op.journal_generation,op.initialize
            request.preimages=preimages
        end
        flight,retryable=op,false
        local ok,accepted=pcall(kind=='recover' and recover or update,request)
        if ok and accepted==false then
            flight=nil;retryable=kind=='update'
            return fail('dispatch rejected')
        end
        q.state,q.error=ok and accepted==true and (kind=='recover' and 'recovering' or 'saving') or 'uncertain',nil
        return ok and accepted==true and true or nil
    end
    local function issue() if not flight and latest then return launch('update') end end
    -- Copy/validate before consume: a failed consume can be retried without
    -- trusting a mutated mailbox, and cannot cause another publication.
    local function terminal(result,op)
        if result.terminal~=true or type(result.certain)~='boolean' then return end
        if not result.certain then return {uncertain=true} end
        if result.status=='conflict' or result.status=='io_error' or result.status=='cancelled-before-io' then
            return {error=result.status..': reconciliation required'}
        end
        if op.kind=='recover' then
            if result.status~='recovered' or not plain(result.slots) or not text(result.preimages) then return end
            local best,missing_count=nil,0
            for i=1,2 do
                local r=result.slots[i]
                if not plain(r) then return end
                if r.status=='valid' then
                    if r.scope~=scope or not integer(r.generation,1,LIMIT) or not supported(r.payload) then
                        return {error='unsupported recovery'}
                    end
                    if best and r.generation==best.generation and r.payload~=best.payload then
                        return {error='conflicting generations'}
                    end
                    if not best or r.generation>best.generation then best=r end
                elseif r.status=='missing' or r.status=='corrupt' then
                    if r.payload~=nil or r.generation~=nil or r.scope~=nil then return {error='contradictory recovery'} end
                    if r.status=='missing' then missing_count=missing_count+1 end
                elseif r.status=='unsupported' or r.status=='foreign' or r.status=='unreadable' then
                    return {error='blocked recovery: '..r.status}
                else return end
            end
            if not best and missing_count~=2 then return {error='no recovery candidate'} end
            return {payload=best and best.payload,generation=best and best.generation or 0,
                missing=missing_count==2,preimages=result.preimages}
        end
        if result.status~=(op.initialize and 'initialized' or 'updated')
            or result.journal_generation~=op.journal_generation
            or result.covered_revision~=op.covered_revision or not text(result.preimages)
            or (result.cleanup_error~=nil and not integer(result.cleanup_error,0,4294967295)) then return end
        return {generation=op.journal_generation,revision=op.covered_revision,
            preimages=result.preimages,cleanup_error=result.cleanup_error}
    end
    local function poll()
        local op=flight
        if not op then return end
        if not op.result then
            local result=peek(copy_identity(op))
            if result==nil or not matches(result,op) then return end
            local value=terminal(result,op)
            if not value then q.state='uncertain';return end
            op.result=value
        end
        local value=op.result
        if value.uncertain then q.state='uncertain';return end
        if consume(copy_identity(op))~=true then return end
        flight=nil
        if value.error then return fail(value.error) end
        preimages=value.preimages
        if op.kind=='recover' then
            q.journal_generation=value.generation
            missing,recovered=value.missing,not value.missing
            q.recovered_payload=value.payload
            if missing then return fail('explicit initialization required') end
            q.state,q.error='saved',nil
            return true,value.payload
        end
        q.journal_generation,q.saved=value.generation,value.revision
        q.cleanup_error=value.cleanup_error
        missing,recovered=false,true
        if latest and latest.revision==q.saved then latest=nil end
        q.state,q.error=latest and 'dirty' or 'saved',nil
        issue()
        if op.initialize then
            q.recovered_payload=op.payload
            return true,op.payload
        end
    end
    -- Reentry cannot consume or submit while a dispatch/receipt is being copied.
    local function guarded(fn)
        return function(self,...)
            assert(self==q,'wrong queue')
            if busy then return nil,'busy' end
            busy=true
            local out=table.pack(pcall(fn,...))
            busy=false
            if not out[1] then error(out[2],0) end
            return table.unpack(out,2,out.n)
        end
    end
    q.recover=guarded(function()
        assert(not retired and q.state=='unrecovered','recovery is once per queue')
        return launch('recover')
    end)
    local function submit(payload,initializing)
        assert(not retired and supported(payload),'retired or unsupported snapshot')
        assert(not initializing and recovered and q.state~='error' and q.state~='uncertain'
            or initializing and missing and not flight and not latest,'recovery/initialization unavailable')
        assert(q.generation<LIMIT and q.journal_generation<LIMIT,'generation exhausted')
        q.generation=q.generation+1
        if initializing then recovered=true end -- permits coalescing after explicit admission, not an ACK
        latest={payload=payload,revision=q.generation}
        issue()
        return q.generation -- accepted snapshot, not durable success
    end
    q.submit=guarded(function(payload) return submit(payload,false) end)
    q.initialize=guarded(function(payload) return submit(payload,true) end)
    q.poll=guarded(function()
        local ok,a,b=pcall(poll)
        if not ok then q.state='uncertain';return end
        return a,b
    end)
    q.retry=guarded(function()
        if not flight and latest and retryable and q.state=='error' then return issue() end
        return false
    end)
    q.timeout=guarded(function()
        if flight then q.state='uncertain';return true end
        return false
    end)
    q.retire=guarded(function() retired=true;return not flight and not latest end)
    function q:can_initialize()
        return not busy and not retired and missing==true and not flight and not latest
    end
    function q:can_shutdown() return not busy and not flight and not latest end
    return q
end
return M
