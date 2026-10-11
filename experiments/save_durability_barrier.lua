-- Isolated pure model; no IO, native authorization, scheduling or network sends.
-- ONE ledger per save_session scope/stream + authority session/guild/incarnation.
-- All camps sharing that stream MUST register every submission in this ledger.
-- Camp routes, required generations and baseline coverage belong to entries;
-- accepted/durable generations are shared. Never instantiate a ledger per camp.
-- Permission readiness conservatively waits for the whole stream: a guild-wide
-- rule edited from one camp may affect others. Per-camp required counters are
-- diagnostic; per-camp baseline coverage and ACK routes remain independent.
-- Caller supplies fresh context on EVERY decision; retire the stream on authority
-- or session replacement, not when merely switching between its registered camps.
-- Use a fresh save_session token for replacement incarnations, never relabel an
-- old event with a new context. Ready is an observation, not a transferable
-- permit: check again after callbacks and immediately before each native write.
-- Before mutating settings: stage(). Before releasing a committed event:
-- accept() the exact save_session receipt. A bare enqueue=true proves nothing.
-- commit() accepts ONLY save_session.take_committed events, after native/readback
-- validation. It cannot authenticate caller-fabricated evidence itself.
-- recover() first installs a validated stream generation, then registers each
-- additional camp against that SAME original recovery event without resetting
-- accepted/durable progress. Unknown camps remain closed until registered.
-- Recovery installs no edit ACKs. Baseline
-- coverage must be established from decoded data; stage missing Pal captures
-- before any in-memory insertion. Coalesced ACKs mean a durable snapshot covers
-- the accepted prefix, NOT that each intermediate edit value was written.
-- ACKs are retained copied envelopes. Revalidate peer/client and fresh context
-- immediately before sending; consume only after the caller owns delivery/replay.
local M={}
local LIMIT=2147483646
local context_fields={'scope','session','guild','incarnation','stream'}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function text(s,max) return type(s)=='string' and #s>0 and #s<=(max or 256) end
local function integer(n,lo,hi) return math.type(n)=='integer' and n>=lo and n<=hi end
local function clone(t)
    local out={};for k,v in pairs(t) do out[k]=v end;return out
end
local function context(c)
    if not plain(c) or c.authority~=true or not text(c.camp) then return end
    local out={}
    for _,k in ipairs(context_fields) do if not text(c[k]) then return end;out[k]=c[k] end
    if out.stream~='priorities' and out.stream~='limits' then return end
    return out
end
function M.new(options)
    assert(plain(options) and options.enabled==true,'isolated development opt-in required')
    local bound=assert(context(options.context),'complete authoritative context required')
    local max_pending=options.max_pending
    local max_peers=options.max_peers
    local max_camps=options.max_camps
    if max_pending==nil then max_pending=128 end
    if max_peers==nil then max_peers=32 end
    if max_camps==nil then max_camps=128 end
    assert(integer(max_pending,1,1024) and integer(max_peers,1,128)
        and integer(max_camps,1,1024),'invalid bounds')
    local entries,peers,camps={},{},{}
    local camp_count=0
    local count,serial,unstaged=0,0,0
    local accepted,durable,recovery_revision=0,0,nil
    local recovered,retired=false,false
    local m={}
    local function current(c,registering)
        if retired or not plain(c) or c.authority~=true or not text(c.camp) then return false end
        for _,k in ipairs(context_fields) do if c[k]~=bound[k] then return false end end
        return registering==true or camps[c.camp]~=nil
    end
    local function receipt(r)
        return plain(r) and r.scope==bound.scope and r.session==bound.session
            and integer(r.revision,1,LIMIT)
    end
    local function remove(ticket)
        entries[ticket]=nil;count=count-1
    end
    function m:recover(c,event,baseline_covered)
        if not current(c,true) or camps[c.camp] or camp_count>=max_camps or not plain(event)
            or event.scope~=bound.scope or event.session~=bound.session
            or not integer(event.revision,0,LIMIT) or type(baseline_covered)~='boolean' then return false end
        if recovered then
            if event.revision~=recovery_revision then return false end
        else
            accepted,durable,recovery_revision=event.revision,event.revision,event.revision
            recovered=true
        end
        camps[c.camp]={required=recovery_revision,unsubmitted=0,baseline=baseline_covered,
            baseline_required=recovery_revision}
        camp_count=camp_count+1
        return true
    end
    function m:stage(c,metadata)
        if not current(c) or not recovered or not plain(metadata)
            or (metadata.baseline~=nil and type(metadata.baseline)~='boolean') then return nil,'unavailable' end
        local request,peer=metadata.request
        if request~=nil then
            if not plain(request) or not text(request.peer) or not text(request.client)
                or not integer(request.id,1,LIMIT) or not text(request.command,2048) then
                return nil,'invalid request'
            end
            for _,p in ipairs(peers) do
                if p.peer==request.peer and p.client==request.client then peer=p;break end
            end
            for ticket,e in pairs(entries) do
                local r=e.request
                if r and r.peer==request.peer and r.client==request.client and r.id==request.id then
                    if e.camp~=c.camp or r.command~=request.command or e.baseline~=(metadata.baseline==true) then
                        return nil,'request reused'
                    end
                    return ticket,'duplicate' -- no second mutation or submission
                end
            end
            if peer and request.id<=peer.high then return nil,'stale request' end
            if not peer and #peers>=max_peers then return nil,'peer capacity' end
        end
        -- Never evict uncommitted work or retained ACKs to admit another edit.
        if count>=max_pending or serial>=LIMIT or accepted>=LIMIT then return nil,'capacity' end
        if request then
            if not peer then
                peer={peer=request.peer,client=request.client,high=0};peers[#peers+1]=peer
            end
            peer.high=request.id
            request={peer=request.peer,client=request.client,id=request.id,command=request.command}
        end
        serial=serial+1;count=count+1;unstaged=unstaged+1
        camps[c.camp].unsubmitted=camps[c.camp].unsubmitted+1
        entries[serial]={camp=c.camp,request=request,baseline=metadata.baseline==true,state='staged'}
        return serial,'staged'
    end
    function m:accept(c,ticket,r)
        local e=entries[ticket]
        if not current(c) or not recovered or not e or e.camp~=c.camp or not receipt(r) then return false end
        if e.revision then return e.revision==r.revision end
        if r.revision~=accepted+1 then return false end
        accepted=r.revision;unstaged=unstaged-1
        local camp=camps[e.camp]
        camp.required=r.revision;camp.unsubmitted=camp.unsubmitted-1
        e.revision=r.revision;e.state='saving'
        if e.baseline then camp.baseline_required=r.revision end
        return true
    end
    function m:failed(c,r,state)
        if not current(c) or not receipt(r) or r.revision<=durable or r.revision>accepted
            or (state~='error' and state~='uncertain') then return false end
        -- A stream failure affects every still-undurable accepted edit.
        for _,e in pairs(entries) do if e.revision and e.revision>durable then e.state=state end end
        return true -- retains required generations, baselines and ACK routes
    end
    function m:commit(c,event)
        if not current(c) or not recovered or not plain(event)
            or event.scope~=bound.scope or event.session~=bound.session
            or not integer(event.first,1,LIMIT) or not integer(event.last,event.first,LIMIT)
            or event.last>accepted or event.first>durable+1 then return false end
        if event.last<=durable then return true end -- replay cannot create new ACKs
        durable=event.last
        for ticket,e in pairs(entries) do
            if e.revision and e.revision<=durable then
                e.state='durable'
                if e.baseline then camps[e.camp].baseline=true end
                if not e.request then remove(ticket) end
            end
        end
        return true
    end
    function m:ready(c)
        if not current(c) or not recovered then return false end
        local camp=camps[c.camp]
        return unstaged==0 and durable>=accepted
            and camp.baseline and durable>=camp.baseline_required
    end
    function m:status(c,ticket)
        if not current(c) then return {state='stale'} end
        local e=ticket and entries[ticket]
        if e and e.camp~=c.camp then return {state='stale'} end
        local camp=camps[c.camp]
        return {state=ticket and (e and e.state or 'unknown') or (self:ready(c) and 'ready' or 'blocked'),
            required=camp.required,durable=durable,unsubmitted=camp.unsubmitted,pending=count,peers=#peers,
            stream_required=accepted,stream_unsubmitted=unstaged,camps=camp_count,
            baseline_required=camp.baseline_required,
            baseline_durable=camp.baseline and durable>=camp.baseline_required}
    end
    function m:peek_ack(c,ticket,route)
        local e=entries[ticket]
        if not current(c) or not e or e.camp~=c.camp or e.state~='durable' or not e.request or not plain(route)
            or route.peer~=e.request.peer or route.client~=e.request.client then return end
        local out=clone(bound)
        out.camp=e.camp
        out.peer,out.client,out.id=e.request.peer,e.request.client,e.request.id
        out.revision,out.durable_revision,out.status=e.revision,durable,'durable_prefix'
        return out -- copied scalar envelope; never returns the mutable entry
    end
    function m:consume_ack(c,ticket,route)
        if not self:peek_ack(c,ticket,route) then return false end
        remove(ticket);return true
    end
    function m:retire()
        retired=true;entries={};peers={};camps={};camp_count=0;count=0;unstaged=0
        -- Revokes policy/ACK access only. The save_session still owns IO/drain.
    end
    return m
end
return M
