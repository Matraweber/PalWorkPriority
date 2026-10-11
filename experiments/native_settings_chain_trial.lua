-- Isolated full-chain synthetic trial. Bootstrap configures frozen draining DLL
-- root (command0) on the control thread BEFORE construction/start. No loading,
-- installation, engine/file access, production settings mutation or exit hooks.
-- clock uses monotonic seconds; report receives copied bounded event tables.
-- start/poll/quit(4) stay on the original thread. quit preflights BOTH owners
-- before admission, then explicitly blocks in session:drain OUTSIDE DllMain.
-- No filesystem wall-time bound is possible during that explicit native join.
-- Failures retain every outstanding owner, never retry, and attempt only one
-- diagnostic command6 per known handle. Native acceptance is never called saved.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/native_settings_chain_trial.lua$'))
local Wire=dofile(root..'/save_native_backend.lua')
local Backend=dofile(root..'/save_draining_backend.lua')
local Settings=dofile(root..'/settings_session.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local Writer=require('settings_writer')
local Store,Caps=require('store'),require('caps')
local M={}
local W,G=string.rep('7',32),string.rep('8',32)
local streams={'priorities','limits'}
local function clone(t)
    if type(t)~='table' then return t end
    local r={};for k,v in pairs(t) do r[k]=clone(v) end;return r
end
local function integer(n,a,b) return math.type(n)=='integer' and n>=a and n<=b end
function M.fixtures()
    local out={}
    for _,stream in ipairs(streams) do
        local codec=Codec.new{storage=W,guild=G,stream=stream}
        local f={storage=W,guild=G,bodies={},payloads={}}
        for revision=1,5 do
            local body=stream=='priorities' and Store.serialize_snapshot({['trial-pal']={
                [1]=1,[2]=2,[3]=3,[4]=4,[5]=5,[6]=false,[7]=revision}},true)
                or Caps.serialize_snapshot({[G]={Mining={Stone=false,Ore=100*revision}}})
            f.bodies[revision]=assert(body);f.payloads[revision]=assert(codec.encode(body))
        end
        out[stream]=f
    end
    return out
end
function M.new(o)
    assert(type(o)=='table','trial options')
    local native,clock,report,game,boot=o.native,o.clock,o.report,o.game_thread,o.boot
    assert(type(native)=='function' and type(clock)=='function' and type(report)=='function','dependencies')
    assert(integer(game,1,4294967295) and type(boot)=='string' and #boot>0 and #boot<=64
        and boot:match('^[%w_-]+$'),'control thread/boot')
    assert(o.recovery_only==nil or type(o.recovery_only)=='boolean','recovery mode')
    local recovery_only=o.recovery_only==true
    local mode=recovery_only and 'recovery' or 'write'
    local fixtures=M.fixtures()
    local owners,by_handle={},{}
    local state,phase,busy='idle','idle',false
    local reason,fault,started,last_time,frequency
    local polls,calls,events=0,0,0
    local diagnosing=false
    local function check() assert(not fault,fault or 'failed trial') end
    local function emit(e)
        events=events+1;assert(events<=8192,'event bound')
        e.mode=mode;report(clone(e));if not diagnosing then check() end
    end
    local function now()
        local n=clock();check()
        assert(type(n)=='number' and n==n and n>=0 and n<math.huge and (not last_time or n>=last_time),'clock')
        last_time=n;return n
    end
    local function decoded_reply(command,result)
        if result[1]~=1 then return {} end
        local count=(command==1 or command==5) and 1 or (command==3 or command==6 or command==8) and 16 or 0
        return Wire.unpack(result[2],count)
    end
    local function validate_recovery(owner,f)
        assert(f[1]==owner.context.scope and f[2]==owner.context.incarnation and f[3]=='1'
            and f[4]=='recovered' and f[5]=='1' and f[7]=='0' and f[9]=='0','recovery identity/terminal')
        if not recovery_only then
            assert(f[6]=='0' and f[11]=='missing' and f[14]=='missing' and f[12]=='0' and f[15]=='0'
                and f[13]=='' and f[16]=='','write trial requires positive absence')
        else
            local best,latest=0,nil
            for _,i in ipairs({11,14}) do
                local gen=math.tointeger(tonumber(f[i+1]))
                assert(f[i]=='valid' and gen and gen>=1 and gen<=5 and tostring(gen)==f[i+1]
                    and owner.codec.decode(f[i+2]),'both recovered typed slots')
                local revision
                for n,payload in ipairs(fixtures[owner.stream].payloads) do if payload==f[i+2] then revision=n end end
                assert(revision,'unexpected synthetic payload')
                if gen>best then best,latest=gen,f[i+2] end
            end
            assert(best>=3 and tostring(best)==f[6] and latest==fixtures[owner.stream].payloads[5],
                'latest full-chain revision5 missing')
        end
    end
    local function wire(command,handle,ticket,hex,length)
        assert(not fault or diagnosing,'failed trial cannot call native')
        assert(not diagnosing or command==6,'diagnostic reads only')
        assert(command>=1 and command<=9,'bootstrap owns configure')
        assert(type(hex)=='string' and #hex==length and #hex<=1200000 and #hex%2==0
            and not hex:find('[^0-9a-f]'),'protected input')
        calls=calls+1;assert(calls<=4096,'native call bound')
        local sequence=calls
        local bytes=hex:gsub('..',function(s)return string.char(tonumber(s,16))end)
        local fields=Wire.unpack(bytes,command==1 and 5 or (command==4 or command==5) and 1 or 0)
        local owner=by_handle[handle]
        local stream=command==1 and fields[3] or owner and owner.stream
        if command==1 then assert(fields[1]==W and fields[2]==G and fixtures[stream] and handle==1 and ticket==0,'synthetic owner only')
        else assert(owner,'unknown handle') end
        if command==4 then assert(fields[1]==(recovery_only and 'existing' or 'initialize_missing'),'mode-specific approval') end
        local payload_revision
        if command==5 then
            assert(not recovery_only,'recovery trial cannot submit')
            payload_revision=owner.submissions+1
            assert(payload_revision<=5 and fields[1]==fixtures[stream].payloads[payload_revision],'exact ordered fixture submission')
            owner.submissions=payload_revision -- consume before call, including lost returns
        end
        local raw=table.pack(pcall(native,command,handle,ticket,hex,length))
        local result={};local count=raw[1] and raw.n-1 or 0
        if raw[1] then for i=1,count do result[i]=raw[i+1] end end
        local ok,output=pcall(decoded_reply,command,result)
        local event={event='call',sequence=sequence,command=command,handle=handle,ticket=ticket,stream=stream,
            fields=fields,count=count,status=result[1],thread=result[3],start=result[4],finish=result[5],frequency=result[6],
            result_fields=ok and output or {},decode_error=not ok,threw=not raw[1],diagnostic=diagnosing,
            payload_revision=payload_revision}
        emit(event)
        assert(raw[1] and count==6 and ok,'native reply unavailable/malformed')
        assert(result[3]==game and integer(result[4],0,math.maxinteger) and integer(result[5],result[4],math.maxinteger)
            and integer(result[6],1,math.maxinteger),'native route/clock')
        assert(not frequency or frequency==result[6],'QPC frequency changed');frequency=result[6]
        if owner and result[1]==1 and (command==6 or command==8) then owner.native_sequence=sequence end
        if command==3 and result[1]==1 then validate_recovery(owner,output) end
        return table.unpack(result,1,count)
    end
    local function diagnostic()
        diagnosing=true
        for _,owner in ipairs(owners) do
            if owner.handle then pcall(Wire.call,wire,6,owner.handle,0,{}) end
        end
        diagnosing=false
    end
    local function guarded(fn)
        if busy then fault='reentry';state='failed';return false end
        busy=true
        local ok,err=pcall(fn)
        if not ok or fault then
            state='failed';reason=fault or tostring(err):sub(1,512);fault=reason
            diagnostic()
            pcall(emit,{event='failed',reason=reason,phase=phase,owners_retained=true})
        end
        busy=false
        return ok and not fault
    end
    local function bind(stream)
        local context={scope='PWP-SCOPE-1:'..W..':'..G..':'..stream,storage=W,guild=G,stream=stream,
            incarnation=boot..'-'..stream,session=boot..'-'..stream,epoch=1,authority=true,camp='chain-trial'}
        local owner={stream=stream,context=context,submissions=0,lease={},stage='recovering',
            codec=Codec.new{storage=W,guild=G,stream=stream}}
        owners[#owners+1]=owner
        local r=Wire.call(wire,1,1,0,{W,G,stream,context.incarnation,'1'})
        assert(r[1]==1,'owner refused')
        local id=Wire.unpack(r[2],1)[1];local h=math.tointeger(tonumber(id))
        assert(h and h>=1 and h<=128 and tostring(h)==id and not by_handle[h],'invalid/reused handle')
        owner.handle=h;by_handle[h]=owner
        local function authorize(c)
            return not fault and state~='failed' and c.scope==context.scope and c.guild==G
                and c.incarnation==context.incarnation and c.epoch==1 and c.authority==true
        end
        owner.backend=Backend.new{enabled=true,native=wire,binding=h,game_thread=game,storage=W,guild=G,stream=stream,
            session=context.session,incarnation=context.incarnation,epoch=1,authorize=authorize}
        owner.session=Settings.new{enabled=true,storage=W,guild=G,stream=stream,session=context.session,
            incarnation=context.incarnation,epoch=1,backend_kind='PWP-DRAINING-DEV-1',backend=owner.backend,
            lease=owner.lease,clock=now,timeout=120,authorize=authorize}
        emit{event='bound',stream=stream,handle=h,scope=context.scope,incarnation=context.incarnation,
            session=context.session,epoch=1,boot=boot}
    end
    local function submit(owner,revision)
        local r=owner.writer:submit(fixtures[owner.stream].bodies[revision])
        check();assert(r.state=='pending' and r.receipt.revision==revision,'writer did not return pending receipt')
        emit{event='submitted',stream=owner.stream,revision=revision,state=r.state,
            body=r.body,payload=fixtures[owner.stream].payloads[revision]}
    end
    local function attach(owner,restored)
        local expected=recovery_only and 5 or 1
        local body=owner.stream=='priorities' and Store.serialize_snapshot(restored.settings.data,restored.settings.baseline)
            or Caps.serialize_snapshot(restored.settings.data)
        assert(body==fixtures[owner.stream].bodies[expected] and restored.revision==(recovery_only and 0 or 1),'recovered original body/revision')
        assert(owner.session:register_camp(owner.context,true),'camp baseline registration')
        owner.writer=assert(Writer.new{enabled=true,session=owner.session,context=owner.context,recovery=restored,
            body=body,recovery_body=body})
        emit{event='recovered',stream=owner.stream,revision=restored.revision,body=body,payload=fixtures[owner.stream].payloads[expected]}
        if not recovery_only then submit(owner,2);submit(owner,3) end
        owner.stage='saving'
    end
    local function saved(owner)
        local r=owner.writer:poll();check()
        assert(r.state=='saving' or r.state=='saved','writer save failed')
        if r.state~='saved' then return false end
        local revision=recovery_only and 0 or 3
        local expected=recovery_only and 5 or 3
        local b=owner.backend:inspect()
        assert(r.revision==revision and r.body==fixtures[owner.stream].bodies[expected]
            and b.accepted==revision and b.committed==revision and b.phase=='ready' and b.error=='none','saved snapshot/counters')
        emit{event='saved',stream=owner.stream,revision=revision,state=r.state,body=r.body,
            payload=fixtures[owner.stream].payloads[expected],accepted=b.accepted,committed=b.committed,
            generation=b.generation,native_sequence=owner.native_sequence}
        owner.stage='ready';return true
    end
    local function drain_all()
        for _,owner in ipairs(owners) do
            assert(owner.writer:close()==false,'writer close must not claim blocking cleanup')
            emit{event='closed',stream=owner.stream}
        end
        for _,owner in ipairs(owners) do
            assert(owner.session:drain(owner.context)==true,'explicit native drain/cleanup failed');check()
            local s=owner.backend:inspect();local count=recovery_only and 0 or 5
            assert(s.accepted==count and s.committed==count and s.phase=='closed' and s.cleaned==true
                and s.joined==true and s.error=='none' and owner.lease.holder==nil,'incomplete owner release')
            assert(owner.writer:drain()==true,'writer close acknowledgement')
            emit{event='drained',stream=owner.stream,accepted=s.accepted,committed=s.committed,
                generation=s.generation,phase=s.phase,cleanup_error=s.cleanup_error,cleaned=s.cleaned,
                native_sequence=owner.native_sequence}
        end
        state,phase='passed','complete'
        emit{event='passed',synthetic=true,completed=streams,explicit_drain=true,storage=W,guild=G,boot=boot}
    end
    local api={}
    function api:start()
        if state~='idle' then return false end
        return guarded(function()
            state,phase='running','opening';started=now()
            for _,stream in ipairs(streams) do bind(stream) end
            for _,owner in ipairs(owners) do assert(owner.session:open(owner.context),'session open') end
            phase='recovering'
        end)
    end
    function api:poll()
        if state~='running' and state~='ready' then return false end
        return guarded(function()
            assert(now()-started<=(state=='ready' and 1800 or 120),'trial timeout')
            if state=='ready' then return end
            polls=polls+1;assert(polls<=512,'poll bound')
            for _,owner in ipairs(owners) do
                if owner.stage=='recovering' or owner.stage=='initializing' then
                    local event=owner.session:poll(owner.context);check()
                    if event=='recovered' then attach(owner,assert(owner.session:take_recovered(owner.context)))
                    elseif owner.stage=='recovering' and event=='initialization_required' then
                        assert(not recovery_only,'recovery cannot initialize')
                        local r=assert(owner.session:initialize(owner.context,fixtures[owner.stream].bodies[1]))
                        check();assert(r.revision==1,'initial receipt');owner.stage='initializing'
                        emit{event='initialized',stream=owner.stream,revision=1}
                    else assert(event=='recovering' or event=='initializing' or event=='saving','recovery failed') end
                end
                if owner.stage=='saving' then saved(owner) end
            end
            local ready=true;for _,owner in ipairs(owners) do ready=ready and owner.stage=='ready' end
            if ready then
                if recovery_only then phase='draining';drain_all()
                else state,phase='ready','awaiting_quit';emit{event='ready',revision=3} end
            end
        end)
    end
    function api:quit(code)
        if state=='passed' or state=='failed' then return false end
        return guarded(function()
            assert(not recovery_only and state=='ready' and code==4,'quit4 requires write-ready trial')
            assert(now()-started<=1800,'quit deadline')
            phase='quit_preflight'
            for _,owner in ipairs(owners) do
                local r=Wire.call(wire,6,owner.handle,0,{})
                assert(r[1]==1,'quit control preflight')
                local f=Wire.unpack(r[2],16)
                assert(f[1]==owner.context.scope and f[2]==owner.context.incarnation and f[3]=='1'
                    and f[4]=='3' and f[5]=='3' and f[6]=='ready' and f[7]=='none','quit owner/counters')
            end
            emit{event='quit_preflight',code=4,reason=4,thread=game,game_thread=game};phase='quitting'
            for _,owner in ipairs(owners) do submit(owner,4);submit(owner,5) end
            phase='draining';drain_all()
        end)
    end
    function api:status()
        return {state=state,phase=phase,reason=reason or fault,mode=mode,polls=polls,calls=calls}
    end
    return api
end
return M
