-- Opt-in facade for save_session. Every accepted snapshot already belongs to
-- the native worker; no Lua-only coalesced tail. Construction performs no IO.
-- close_admission is nonblocking. shutdown_drain is explicitly blocking and
-- must NEVER run in DLL teardown. A released lease requires confirmed cleanup.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/'):match('^(.*)/save_draining_queue.lua$'))
local Scope=dofile(root..'/save_scope.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local M={}
function M.new(o)
    assert(type(o)=='table' and o.enabled==true,'development opt-in required')
    local scope=Scope.new(o.storage,o.guild,o.stream)
    local max=o.max_payload_bytes or 65536
    local codec=Codec.new{storage=o.storage,guild=o.guild,stream=o.stream,max_payload_bytes=max}
    local backend=o.backend
    assert(type(backend)=='table' and backend.contract=='PWP-DRAINING-DEV-1'
        and backend.max_payload_bytes==max,'native draining backend required')
    local methods={}
    for _,k in ipairs({'start','poll','recovery','approve','submit','close','drain','cleanup','inspect'})do
        assert(type(backend[k])=='function','missing backend method');methods[k]=backend[k]
    end
    local context={scope=scope.key,storage=o.storage,guild=o.guild,stream=o.stream,
        session=o.session,incarnation=o.incarnation,epoch=o.epoch,authority=true,camp=o.camp}
    assert(type(context.session)=='string' and type(context.incarnation)=='string'
        and math.type(context.epoch)=='integer','immutable context required')
    local q={session=o.session,generation=0,saved=0,journal_generation=0,ticket=0,
        state='unrecovered',max_payload_bytes=max}
    local busy,retired,closed,cleaned,poison=false,false,false,false,false
    local close_attempted,drain_attempted=false,false
    local draining_call=false
    local missing,ready,delivered,initial,payload=false,false,false,nil,nil
    local function call(k,...)
        local c={};for key,value in pairs(context)do c[key]=value end
        local out=table.pack(methods[k](backend,c,...))
        assert(draining_call or not poison,'reentrant/uncertain operation')
        return table.unpack(out,1,out.n)
    end
    local function fail(why,uncertain)
        q.error=why;poison=poison or uncertain==true;q.state=poison and 'uncertain' or 'error'
    end
    local function sync(s)
        assert(type(s)=='table' and s.scope==scope.key and s.session==context.session,'backend identity')
        q.ticket=s.ticket or q.ticket
        if s.state=='uncertain' or s.uncertain then fail('native uncertainty',true)
        elseif s.state=='error' or s.revoked then fail(s.reason or 'backend unavailable',false) end
        local g=s.generation or 0
        assert(math.type(g)=='integer' and g>=q.journal_generation,'physical generation regressed')
        q.journal_generation=g
        if not poison and s.committed~=nil then
            assert(math.type(s.committed)=='integer' and s.committed>=q.saved
                and s.committed<=q.generation,'invalid committed revision')
            q.saved=s.committed
        end
        if not poison and q.state~='error' and ready then q.state=q.saved<q.generation and 'saving' or 'saved' end
        return s
    end
    local function guarded(fn,drain_only)
        return function(self,...)
            assert(self==q,'wrong queue')
            if busy then fail('reentry',true);return nil,'busy' end
            busy=true;draining_call=drain_only==true
            local out=table.pack(pcall(fn,...));busy=false;draining_call=false
            if not out[1] then fail('operation failed',true);return nil,'uncertain' end
            if poison then q.state='uncertain';return nil,'uncertain' end
            return table.unpack(out,2,out.n)
        end
    end
    local function body(p)
        assert(codec.decode(p),'unsupported typed snapshot')
        return assert(p:match('^[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*\n%d+\n(.*)$'))
    end
    local function submit(p)
        assert(not retired and not poison and q.state~='error','admission unavailable')
        local receipt,why=call('submit',body(p))
        if receipt==false then fail(why or 'refused',false);return nil end
        if type(receipt)~='table' or receipt.scope~=scope.key or receipt.session~=context.session
            or math.type(receipt.revision)~='integer' or receipt.revision~=q.generation+1 then
            fail('uncertain admission',true);return nil
        end
        q.generation=receipt.revision;q.state='saving'
        q.ticket=methods.inspect(backend).ticket
        return receipt.revision
    end
    q.recover=guarded(function()
        assert(q.state=='unrecovered' and not retired,'one recovery only')
        local yes,why=call('start');q.ticket=methods.inspect(backend).ticket
        if yes~=true then fail(why or 'recovery refused',yes~=false);return yes end
        q.state='recovering';return true
    end)
    q.poll=guarded(function()
        if cleaned then return end
        local s=call('poll');if type(s)~='table' then fail('status unavailable',true);return end
        sync(s)
        if retired or poison or q.state=='error' then return end
        if not ready and not missing and s.state=='awaiting_validation' then
            local r=call('recovery');assert(type(r)=='table' and r.scope==scope.key and r.session==context.session,'recovery identity')
            if r.kind=='missing' then missing=true;q.state='error';q.error='explicit initialization required';return end
            assert(r.kind=='existing' and codec.decode(r.payload),'unsupported recovery')
            payload=r.payload
            local yes=call('approve','existing');assert(yes==true,'recovery approval failed')
            ready=true;q.state='saved'
        end
        if not delivered and (ready or initial and q.saved>=1) then
            ready,delivered=true,true
            q.recovered_payload=initial or payload
            return true,q.recovered_payload
        end
    end)
    q.initialize=guarded(function(p)
        assert(missing and not initial and not retired and not poison,'initialization unavailable')
        body(p) -- validate before approval
        local yes=call('approve','initialize_missing');assert(yes==true,'initialization approval failed')
        q.state,q.error='initializing',nil
        local revision=submit(p)
        if revision then initial=p;missing=false end
        return revision
    end)
    q.submit=guarded(function(p)assert(ready and delivered,'recovery incomplete');return submit(p)end)
    q.close_admission=guarded(function()
        retired=true
        if closed then return true end
        if close_attempted then return false end
        close_attempted=true
        local yes=call('close');closed=yes==true
        if not closed then fail('close uncertain',yes~=false) end
        return closed
    end,true)
    q.shutdown_drain=guarded(function()
        retired=true
        if cleaned then return true end
        if not closed then
            if close_attempted then return false end
            close_attempted=true
            local yes=call('close');closed=yes==true
            if not closed then fail('close unavailable',yes~=false);return false end
        end
        if drain_attempted then return false end
        drain_attempted=true
        local s=call('drain');if type(s)~='table' then fail('drain unavailable',true);return false end
        sync(s)
        if poison or s.phase~='closed' or s.uncertain or s.committed~=q.generation then return false end
        cleaned=call('cleanup')==true
        return cleaned
    end,true)
    q.timeout=guarded(function()if q.saved<q.generation or not delivered then fail('timeout',true);return true end;return false end)
    q.retry=guarded(function()return false end) -- uncertain/refused native mutations are never replayed
    q.retire=q.close_admission
    function q:can_initialize()return not busy and missing and not retired and not poison end
    function q:can_shutdown()return not busy and cleaned end
    return q
end
return M
