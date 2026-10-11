-- Default-off facade for frozen native-draining-bridge, NOT settings_session.
-- new{enabled=true,native,binding,game_thread,storage,guild,stream,session,
--     incarnation,epoch,authorize,max_payload_bytes=65536} performs no IO.
-- binding must be an EXCLUSIVELY owned command1 handle, still dormant. Configure
-- and owner creation are external. No path, engine, scheduler, worker callback,
-- production activation, native load, or automatic mutation/retry occurs here.
-- All methods except inspect require the original scalar context (scope, guild,
-- stream, session, incarnation, epoch, authority=true; optional scalar camp).
-- start -> poll -> recovery -> approve('existing'/'initialize_missing') -> submit
-- canonical BODY strings. Submit returns scoped receipt,'pending' (not saved),
-- false,reason for definite refusal, nil,reason for an ambiguous/lost result.
-- poll/status expose validated native counters; take_committed emits monotonic
-- scoped prefixes only while freshly authorized, never after uncertainty/revoke.
-- Missing approval is explicit first-write authorization; it is not recovery.
-- close fences admission; drain BLOCKS explicitly outside loader lock/DllMain;
-- cleanup requires a positively returned closed drain and no ambiguous outcome.
-- Lost mutations consume local tickets forever. Status can show native outcome
-- but NEVER clears uncertainty or automatically restores activation/admission.
-- Original-owner close/drain may run after revocation/uncertainty; no ACK escapes.
--
-- Integration: settings_session currently builds JournalQueue/Session/Barrier.
-- This is deliberately NOT PWP-JOURNAL-DEV-1 recover/update/peek/consume: native
-- owns coalescing and logical revisions. A future explicit branch must preserve
-- stage-before-mutation and receipt registration before poll, feed committed
-- prefixes to Barrier, retain first initialization bytes until durable activation,
-- and separate nonblocking close from explicit blocking shutdown drain. Existing
-- take_recovered/register_camp/ACK/retry APIs are NOT implemented or simulated.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/save_draining_backend.lua$'))
local Wire=dofile(root..'/save_native_backend.lua')
local Scope=dofile(root..'/save_scope.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local M={}
local LIMIT=2147483646
local function plain(v) return type(v)=='table' and getmetatable(v)==nil end
local function integer(v,lo,hi) return math.type(v)=='integer' and v>=lo and v<=hi end
local function text(v,n) return type(v)=='string' and #v>0 and #v<=n and not v:find('%c') end
local function num(v,hi)
    assert(type(v)=='string' and v:match('^%d+$'),'decimal')
    local n=math.tointeger(tonumber(v));assert(n and n>=0 and n<=hi and tostring(n)==v,'integer');return n
end
local function copy(t) local r={};for k,v in pairs(t) do r[k]=v end;return r end
local phases={dormant=true,recovering=true,awaiting_validation=true,ready=true,closing=true,closed=true,blocked=true}
local errors={none=true,recovery=true,admission=true,publication=true,uncertain=true,consume=true,release=true,exception=true}
local outcomes={none=true,unknown=true,accepted=true,refused=true}
local terminals={recovered=true,initialized=true,updated=true,conflict=true,io_error=true,
    uncertain=true,['cancelled-before-io']=true}
function M.new(o)
    assert(plain(o) and o.enabled==true,'development opt-in required')
    local scope=Scope.new(o.storage,o.guild,o.stream)
    local native,authorize,handle,game=o.native,o.authorize,o.binding,o.game_thread
    assert(type(native)=='function' and type(authorize)=='function','trusted native/authorization required')
    assert(integer(handle,1,128) and integer(game,1,4294967295),'handle/thread')
    assert(text(o.session,256) and text(o.incarnation,128) and not o.incarnation:find('[^!-~]')
        and integer(o.epoch,1,LIMIT),'session/incarnation/epoch')
    local identity={scope=scope.key,storage=scope.storage,guild=scope.guild,stream=scope.stream,
        session=o.session,incarnation=o.incarnation,epoch=o.epoch,authority=true}
    local max=o.max_payload_bytes or 65536
    local codec=Codec.new{storage=scope.storage,guild=scope.guild,stream=scope.stream,max_payload_bytes=max}
    local ticket,accepted,committed,reported,generation=0,0,0,0,0
    local busy,uncertain,revoked,closing,joined,cleaned=false,false,false,false,false,false
    local verified,started,approved=false,false,false
    local reason,failed,last,flight,ambiguous,recovered,snapshot
    local function matches(c)
        if not plain(c) then return false end
        for _,k in ipairs({'scope','guild','stream','session','incarnation','epoch','authority'}) do
            if c[k]~=identity[k] then return false end
        end
        return c.camp==nil or text(c.camp,256)
    end
    local function fail(why)
        if not uncertain then ambiguous=flight or last end
        uncertain=true;reason=why
    end
    local function fresh(c)
        if revoked then return false end
        local proof=copy(identity);proof.camp=c.camp
        local ok,yes=pcall(authorize,proof)
        if not ok or yes~=true then revoked=true;reason='authority unavailable';return false end
        return not uncertain
    end
    local function receipt(revision)
        return {scope=identity.scope,session=identity.session,incarnation=identity.incarnation,
            epoch=identity.epoch,revision=revision}
    end
    local function call(command,fields,t)
        local r=Wire.call(native,command,handle,t or 0,fields or {})
        if r[3]~=game then verified=false;error('wrong control thread') end
        assert(r[1]==0 or r[1]==1 or (command==3 and r[1]==2),'native status')
        if r[1]~=1 then assert(r[2]=='','refused/pending data') end
        return r
    end
    local function check_identity(f)
        if f[1]~=identity.scope or f[2]~=identity.incarnation or f[3]~=tostring(identity.epoch) then
            verified=false;error('native owner mismatch')
        end
    end
    local function read_status(r)
        assert(r[1]==1,'status refused')
        local f=Wire.unpack(r[2],16);check_identity(f)
        local a,c,g=num(f[4],LIMIT),num(f[5],LIMIT),num(f[8],LIMIT)
        local lt,lc,lr=num(f[13],LIMIT),num(f[14],8),num(f[15],LIMIT)
        assert(phases[f[6]] and errors[f[7]] and outcomes[f[16]],'status enum')
        local ceiling=accepted
        if ambiguous and ambiguous.command==5 then ceiling=math.max(ceiling,ambiguous.before+1) end
        assert(a>=accepted and (not snapshot or a>=snapshot.accepted) and a<=ceiling
            and c>=committed and c<=a and g>=generation,'counter mismatch')
        assert(lt==(last and last.ticket or 0) and lc==(last and last.command or 0),'mutation correlation')
        if last and last.outcome then
            assert(f[16]==last.outcome and lr==last.revision,'mutation outcome mismatch')
        elseif last then
            assert(lr==0 or (last.command==5 and lr==last.before+1),'unknown revision')
        else assert(f[16]=='none' and lr==0,'unowned active handle') end
        assert(f[11]=='' or f[11]=='0' or f[11]=='1','terminal certainty')
        assert(terminals[f[10]] or f[10]=='','terminal status')
        local terminal_error
        if f[12]~='' then terminal_error=num(f[12],4294967295) end
        if f[10]=='' then assert(f[11]=='' and f[12]=='','empty terminal')
        else assert(f[11]~='' and terminal_error~=nil,'terminal fields') end
        local publication=f[10]=='initialized' or f[10]=='updated'
        local terminal_failure=f[10]~='' and f[10]~='recovered' and not publication
        local native_failure=f[7]~='none' or terminal_failure or (terminal_error and terminal_error~=0)
            or (f[10]~='' and f[11]=='0')
        -- The terminal can advance BEFORE committed/generation (native consumes
        -- between these locks), but a successful committed prefix cannot precede
        -- its certain publication terminal or physical generation increment.
        if c>0 and not native_failure then
            assert(publication and f[11]=='1' and terminal_error==0 and g>0,'unpublished committed prefix')
        end
        if c>committed then assert(g>generation,'commit without physical advance') end
        if recovered then
            assert(g>=recovered.generation and g<=recovered.generation+c,'physical generation bounds')
            if c==0 then assert(g==recovered.generation,'generation without commit') end
            if c==committed then assert(g==generation,'generation advanced without prefix') end
            if f[10]=='initialized' then
                assert(recovered.kind=='missing' and c<=1 and g<=1,'initialization terminal mismatch')
            end
            if recovered.kind=='missing' and c>1 then assert(g>=2,'initial snapshot was not preserved') end
        end
        if f[6]=='closed' then assert(f[7]=='none' and a==c,'incomplete closed') end
        if f[6]=='blocked' then assert(f[7]~='none','blocked without error') end
        snapshot={phase=f[6],error=f[7],accepted=a,committed=c,generation=g,
            cleanup_error=num(f[9],4294967295),terminal_status=f[10],terminal_certain=f[11]=='1',
            terminal_error=terminal_error,last_ticket=lt,last_command=lc,last_revision=lr,last_outcome=f[16]}
        committed,generation=c,g
        if f[7]~='none' then failed=f[7] end
        if f[10]=='uncertain' or (f[10]~='' and f[11]=='0') or f[7]=='uncertain' then fail('native uncertain')
        elseif f[10]~='' and f[10]~='recovered' and f[10]~='initialized' and f[10]~='updated' then failed=f[10]
        elseif terminal_error and terminal_error~=0 then failed='native terminal error' end
        return snapshot
    end
    local function mutate(command,fields,payload)
        assert(ticket<LIMIT,'ticket exhausted')
        ticket=ticket+1
        last={ticket=ticket,command=command,before=accepted,payload=payload};flight=last
        local r=call(command,fields,ticket)
        if r[1]==0 then
            last.outcome,last.revision,last.payload='refused',0,nil;flight=nil
            failed='native refused';return false,'native refused'
        end
        local revision=0
        if command==5 then
            revision=num(Wire.unpack(r[2],1)[1],LIMIT)
            assert(revision==accepted+1,'unexpected logical revision')
            accepted=revision
        elseif command~=8 then assert(r[2]=='','unexpected mutation data') end
        last.outcome,last.revision='accepted',revision;flight=nil
        if not uncertain then last.payload=nil end -- only native owns accepted tail
        return r,revision
    end
    local function state()
        if cleaned then return 'closed' end
        if uncertain then return 'uncertain' end
        if revoked then return 'revoked' end
        if failed then return 'error' end
        if closing then return snapshot and snapshot.phase=='closed' and 'closed' or 'closing' end
        if not started then return 'unrecovered' end
        if not approved then return recovered and 'awaiting_validation' or 'recovering' end
        if recovered.kind=='missing' and accepted==0 then return 'initialization_required' end
        return snapshot and snapshot.phase=='ready' and committed==accepted and 'saved' or 'saving'
    end
    local function view()
        local r=snapshot and copy(snapshot) or {}
        r.state,r.reason,r.uncertain,r.revoked=state(),reason or failed,uncertain,revoked
        r.scope,r.session,r.incarnation,r.epoch=identity.scope,identity.session,identity.incarnation,identity.epoch
        r.known_accepted,r.ticket,r.joined,r.cleaned=accepted,ticket,joined,cleaned
        r.candidate_retained=ambiguous~=nil and ambiguous.payload~=nil
        return r
    end
    local function guard(fn,admission)
        return function(_,c,...)
            if busy then fail('reentry');return nil,'uncertain' end
            if not matches(c) then return false,'context mismatch' end
            busy=true
            local r=table.pack(pcall(fn,c,...));busy=false
            if not r[1] then fail('operation failed');flight=nil;return nil,'uncertain' end
            if admission and uncertain then return nil,'uncertain' end
            return table.unpack(r,2,r.n)
        end
    end
    local function admitting(c)
        return not closing and not cleaned and not failed and not uncertain and fresh(c)
    end
    local function read_recovery()
        local r=call(3)
        if r[1]==2 then return end
        assert(r[1]==1,'recovery refused')
        local f=Wire.unpack(r[2],16);check_identity(f)
        assert(f[4]=='recovered' and f[5]=='1' and f[7]=='0' and f[9]=='0','recovery terminal')
        assert(text(f[8],256),'preimages')
        local best,slots,missing=nil,{},0
        for _,i in ipairs({11,14}) do
            local s={status=f[i],generation=num(f[i+1],LIMIT),payload=f[i+2]}
            if s.status=='valid' then
                assert(s.generation>0 and codec.decode(s.payload),'both typed slots must validate')
                assert(not best or best.generation~=s.generation or best.payload==s.payload,'conflicting generation')
                if not best or s.generation>best.generation then best=s end
            else
                assert((s.status=='missing' or s.status=='corrupt') and s.generation==0 and s.payload=='','unsafe recovery slot')
                if s.status=='missing' then missing=missing+1 end
            end
            slots[#slots+1]=s
        end
        assert(best or missing==2,'not positively missing')
        local g=num(f[6],LIMIT);assert(g==(best and best.generation or 0),'selected generation')
        assert(snapshot and snapshot.generation==g,'recovery/status disagreement')
        recovered={kind=best and 'existing' or 'missing',generation=g,payload=best and best.payload,
            slots=slots,cleanup_error=num(f[10],4294967295)}
    end
    local function verify_owner()
        if verified then return true end
        if uncertain then return false end
        local s=read_status(call(6))
        assert(s.phase=='dormant' and s.accepted==0 and s.committed==0 and s.generation==0,'requires virgin owner')
        verified=true;return true
    end
    local api={contract='PWP-DRAINING-DEV-1',max_payload_bytes=max}
    api.start=guard(function(c)
        if started or not admitting(c) then return false,'unavailable' end
        if not verify_owner() then return false,'unavailable' end
        if not admitting(c) then return false,'unavailable' end
        started=true
        local r=mutate(2,{})
        if not r then return false,'native refused' end
        if not fresh(c) then return nil,'revoked after start' end
        return true
    end,true)
    api.poll=guard(function(c)
        if not started or cleaned then return false,'unavailable' end
        if not revoked and not uncertain then fresh(c) end
        local s=read_status(call(6))
        if not uncertain and not revoked and not closing and not failed and not recovered and s.phase=='awaiting_validation' then
            read_recovery()
        end
        return view()
    end)
    api.status=api.poll
    api.recovery=guard(function(c)
        if not recovered or not admitting(c) then return false,'unavailable' end
        local r=receipt(0);r.kind,r.generation,r.payload=recovered.kind,recovered.generation,recovered.payload
        r.slots={};for i,s in ipairs(recovered.slots) do r.slots[i]=copy(s) end
        r.settings=r.payload and assert(codec.decode(r.payload)) or nil
        return r
    end,true)
    api.approve=guard(function(c,mode)
        if approved or not recovered or not admitting(c) then return false,'unavailable' end
        if mode~=(recovered.kind=='existing' and 'existing' or 'initialize_missing') then return false,'approval mismatch' end
        local r=mutate(4,{mode});if not r then return false,'native refused' end
        approved=true
        if not fresh(c) then return nil,'revoked after approval' end
        return true
    end,true)
    api.submit=guard(function(c,body)
        if not approved or not admitting(c) then return false,'unavailable' end
        local payload,why=codec.encode(body);if not payload then return false,why end
        local r,revision=mutate(5,{payload},payload)
        if not r then return false,'native refused' end
        if not fresh(c) then return nil,'revoked after admission' end
        return receipt(revision),'pending'
    end,true)
    api.take_committed=guard(function(c)
        if closing or not approved or not admitting(c) or committed<=reported then return end
        reported=committed;return receipt(reported)
    end,true)
    api.close=guard(function()
        closing=true
        if cleaned or not verify_owner() then return false,'unavailable' end
        local r=mutate(7,{});return r and true or false
    end)
    api.drain=guard(function()
        closing=true
        if cleaned or not verify_owner() then return false,'unavailable' end
        local r=mutate(8,{});if not r then return false,'native refused' end
        local s=read_status(r);joined=s.phase=='closed'
        return view() -- never a Boolean durable ACK
    end)
    api.cleanup=guard(function()
        if not joined or uncertain or failed or not verified then return false,'unavailable' end
        if cleaned then return true end
        local r=call(9);assert(r[2]=='','cleanup data')
        if r[1]~=1 then return false,'native refused' end
        cleaned=true;return true
    end)
    function api:inspect() return view() end -- local copied scalars, no native call
    return api
end
return M
