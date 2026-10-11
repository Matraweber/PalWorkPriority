-- Default-off, pure bridge to an injected, already recovered settings_session.
-- No imports, IO, native setup, timers, migration, or implicit retries.
-- new requires the exact take_recovered envelope and a registered/ready camp;
-- caller proves canonical recovery_body equals its entire current body. Session
-- methods are trusted, captured once, and receive fresh scalar context copies.
-- submit returns pending only for a matching memory-acceptance receipt. A nil,
-- thrown or malformed submit result is ambiguous: retain bytes, block admission
-- and never announce saved. Only literal false means definitely refused.
-- close revokes activation; the owner must continue drain() until true before
-- releasing the underlying session/native binding. No implicit native retirement.
local M={}
-- VM-local monotonically allocated identity, retained across module reloads.
-- Receipts are trusted internal values, never wire input or persistent tokens.
-- The registry holds one scalar, no writer, callback or engine wrapper.
local registry
if type(debug)=='table' and type(debug.getregistry)=='function' then
    local ok,value=pcall(debug.getregistry)
    if ok and type(value)=='table' then registry=value end
end
local attachment_key='PalWorkPriority.settings_writer.attachment_serial.v1'
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function text(s,n) return type(s)=='string' and #s>0 and #s<=n and not s:find('%c') end
local function integer(n) return math.type(n)=='integer' and n>=0 and n<=2147483646 end
local function guid(s) return type(s)=='string' and #s==32 and s:match('^[0-9a-f]+$') and s~=string.rep('0',32) end
local function copy(t) local r={};for k,v in pairs(t) do r[k]=v end;return r end
function M.new(o)
    if not plain(o) or o.enabled~=true or not plain(o.context) or not plain(o.recovery)
        or not plain(o.session) then return nil,'invalid_attachment' end
    if not registry then return nil,'attachment_identity_unavailable' end
    local c={}
    for _,k in ipairs({'scope','session','incarnation','guild','stream','camp'}) do
        if not text(o.context[k],256) then return nil,'invalid_context' end;c[k]=o.context[k]
    end
    c.epoch,c.authority=o.context.epoch,o.context.authority
    if c.authority~=true or not integer(c.epoch) or c.epoch==0 or not guid(c.guild)
        or (c.stream~='priorities' and c.stream~='limits') then return nil,'invalid_context' end
    local world=c.scope:match('^PWP%-SCOPE%-1:([0-9a-f]+):')
    if not guid(world) or c.scope~='PWP-SCOPE-1:'..world..':'..c.guild..':'..c.stream then return nil,'invalid_scope' end
    local recovery=copy(o.recovery)
    local initial_body=o.body
    if recovery.scope~=c.scope or recovery.session~=c.session or not integer(recovery.revision)
        or type(o.body)~='string' or #o.body>262144 or o.body~=o.recovery_body then return nil,'recovery_mismatch' end
    local session=o.session
    local calls={}
    for _,k in ipairs({'stage','submit','poll','status','ready','close'}) do
        if type(session[k])~='function' then return nil,'missing_session_method' end;calls[k]=session[k]
    end
    local function call(k,...) return calls[k](session,copy(c),...) end
    local function status()
        local s=call('status')
        if not plain(s) then return end
        if not plain(s.barrier) or s.recovered~=true or s.activation_taken~=true or s.blocked_commit then
            return nil,nil,s.state
        end
        local b=s.barrier
        if not integer(b.stream_required) or not integer(b.durable) or not integer(b.stream_unsubmitted)
            or b.durable>b.stream_required then return end
        return s,b
    end
    local ok,initial=pcall(function()
        local s,b=status()
        return s and s.state=='saved' and b.stream_required==recovery.revision and b.durable==recovery.revision
            and b.stream_unsubmitted==0 and call('ready')==true
    end)
    if not ok or not initial then return nil,'recovery_not_ready' end
    local previous=rawget(registry,attachment_key)
    if previous==nil then previous=0 end
    if math.type(previous)~='integer' or previous<0 or previous>=2147483646 then
        return nil,'attachment_limit'
    end
    local attachment=previous+1
    rawset(registry,attachment_key,attachment)
    local issued={}
    local body,revision=initial_body,recovery.revision
    local uncertain_body,receipt,busy,poison,closed,closing_done=nil,nil,false,false,false,false
    local uncertain,reason,count=false,nil,0
    local closing_busy=false
    local w={}
    local function view(state)
        return {state=state,body=body,revision=revision,receipt=receipt and copy(receipt),reason=reason}
    end
    local function close_session()
        if closing_done then return true end
        if closing_busy then return false end
        closing_busy=true
        local yes,value=pcall(call,'close');closing_done=yes and value==true
        closing_busy=false
        return closing_done
    end
    local function guard(fn)
        if busy then poison=true;return view('uncertain') end
        if closed then return view('stale') end
        busy,poison=true,false
        local yes,result=pcall(fn)
        if not yes or poison then uncertain=true;reason=poison and 'reentrant' or 'session_exception';result=view('uncertain') end
        busy=false
        if closed then close_session();return view('stale') end
        return result
    end
    function w:submit(candidate,baseline)
        return guard(function()
            if uncertain then return view('uncertain') end
            if type(candidate)~='string' or #candidate>262144 or count>=256 then return view('rejected') end
            local s,b=status()
            if not s or (s.state~='saved' and s.state~='saving') or b.stream_required~=revision
                or b.stream_unsubmitted~=0 then reason='session_not_admitting';return view('rejected') end
            if closed or poison then return view('stale') end
            -- Retain BEFORE crossing either callback: its result may be lost.
            uncertain_body=candidate;count=count+1
            local ticket=call('stage',{baseline=baseline==true})
            if closed or poison then return view('stale') end
            if ticket==nil or ticket==false then uncertain_body=nil;return view('rejected') end
            if not integer(ticket) or ticket==0 then uncertain=true;reason='invalid_stage';return view('uncertain') end
            local r=call('submit',ticket,candidate)
            if closed or poison then return view('stale') end
            if r==false then
                -- No cancellation API exists for a staged entry. Close this
                -- attachment rather than leaving an unsubmitted barrier open.
                uncertain_body=nil;closed=true;reason='admission_rejected';close_session();return view('rejected')
            end
            if not plain(r) or r.scope~=c.scope or r.session~=c.session or not integer(r.revision)
                or r.revision~=revision+1 then uncertain=true;reason='submission_uncertain';return view('uncertain') end
            body,revision=candidate,r.revision
            receipt={scope=c.scope,session=c.session,incarnation=c.incarnation,epoch=c.epoch,
                revision=revision,attachment=attachment}
            issued[revision]=true
            uncertain_body=nil
            return view('pending') -- never reports durable completion inline
        end)
    end
    local function poll()
            call('poll')
            if closed or poison then return view('stale') end
            if uncertain then return view('uncertain') end
            local s,b,underlying=status()
            if not s or b.stream_required~=revision then
                reason=underlying or 'session_mismatch'
                if underlying=='uncertain' then uncertain=true;return view('uncertain') end
                return view('error')
            end
            if s.state=='error' or s.state=='uncertain' then
                reason=s.state;uncertain=s.state=='uncertain';return view(s.state)
            end
            if s.state=='saved' and b.durable==revision and b.stream_unsubmitted==0 and call('ready')==true then
                return view('saved')
            end
            return view('saving')
    end
    function w:poll()
        return guard(poll)
    end
    -- A saved result covers the requested revision with the returned CURRENT
    -- durable body/revision. It does not promise an older superseded value is
    -- still present. Callers must bind the exact transmitted snapshot separately.
    -- No legacy IO, retry, network ACK or role grant occurs here.
    function w:receipt_status(request)
        return guard(function()
            if not plain(request) then return {state='invalid_receipt'} end
            local wanted={scope=request.scope,session=request.session,incarnation=request.incarnation,
                epoch=request.epoch,revision=request.revision,attachment=request.attachment}
            for k in next,request do
                if wanted[k]==nil then return {state='invalid_receipt'} end
            end
            if wanted.scope~=c.scope or wanted.session~=c.session
                or wanted.incarnation~=c.incarnation or wanted.epoch~=c.epoch
                or wanted.attachment~=attachment or not integer(wanted.revision)
                or not issued[wanted.revision] then return {state='invalid_receipt'} end
            local result=poll()
            if not plain(request) then return {state='invalid_receipt'} end
            for k,v in pairs(wanted) do
                if request[k]~=v then return {state='invalid_receipt'} end
            end
            for k,v in pairs(request) do
                if wanted[k]~=v then return {state='invalid_receipt'} end
            end
            result.request_revision=wanted.revision
            return result
        end)
    end
    function w:close()
        closed=true
        if busy then return false end
        return close_session()
    end
    function w:drain()
        if not closed then return false end
        if busy then return false end
        busy=true
        local yes=pcall(call,'poll')
        busy=false
        return yes and close_session()
    end
    function w:matches(candidate) return not closed and not uncertain and body==candidate end
    function w:identity() return copy(c) end
    function w:status()
        return {closed=closed,uncertain=uncertain,reason=reason,revision=revision,
            candidate_retained=uncertain_body~=nil,submissions=count,drained=closing_done}
    end
    return w
end
return M
