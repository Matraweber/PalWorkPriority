-- Pure, one-shot synthetic typed trial. No IO, engine queries or production data.
-- Bootstrap calls native command 0 ONCE on the game thread, configuring the
-- bridge's fixed local-test-profile root. Pass that returned game_thread here.
-- Call start/poll on that same control thread. clock is monotonic SECONDS.
-- schedule/resume use the worker/control routes. Never automatically retry an
-- admission, publication, retire or release; failed/uncertain trials retain IDs.
-- recovery_only=true reads the existing synthetic A1/B2 pair after restart;
-- only two recovery workers, never initialization/update. Independent readback
-- must still compare both complete slot envelopes against passed.expected.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/native_settings_trial.lua$'))
local Adapter=dofile(root..'/save_native_backend.lua')
local Queue=dofile(root..'/save_journal_queue.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local Store,Caps=require('store'),require('caps')
local M={}
local W,G=string.rep('1',32),string.rep('2',32)
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function clone(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t) do out[k]=clone(v) end;return out
end
-- Deterministic bytes for independent readback: A=physical generation 1,
-- payloads[1]; B=physical generation 2, payloads[3]. Payload 2 is coalesced away.
function M.fixtures()
    local out={}
    for _,stream in ipairs({'priorities','limits'}) do
        local codec=Codec.new{storage=W,guild=G,stream=stream}
        local payloads={}
        for revision=1,3 do
            local body
            if stream=='priorities' then
                body=assert(Store.serialize_snapshot({['trial-pal']={
                    [1]=1,[2]=2,[3]=3,[4]=4,[5]=5,[6]=false,[7]=revision}},true))
            else
                body=assert(Caps.serialize_snapshot({[G]={Mining={Stone=false,Ore=100*revision}}}))
            end
            payloads[revision]=assert(codec.encode(body))
            assert(codec.decode(payloads[revision]),'fixture codec roundtrip')
        end
        out[stream]={storage=W,guild=G,payloads=payloads,
            slots={A={generation=1,payload=payloads[1]},B={generation=2,payload=payloads[3]}}}
    end
    return out
end
function M.new(o)
    assert(plain(o),'trial options')
    local native,schedule,resume,clock,report=o.native,o.schedule,o.resume,o.clock,o.report
    local game,boot=o.game_thread,o.boot
    local recovery_only=o.recovery_only==true -- captured once; default trial unchanged
    local worker_limit=recovery_only and 2 or 8
    for _,f in ipairs({native or false,schedule or false,resume or false,clock or false,report or false}) do
        assert(type(f)=='function','trial dependency')
    end
    assert(math.type(game)=='integer' and game>0 and game<2147483647,'game thread')
    assert(type(boot)=='string' and #boot>0 and #boot<=64 and boot:match('^[%w%-_]+$'),'boot label')
    local timeout,max_polls=o.timeout_seconds or 120,o.max_polls or 512
    assert(type(timeout)=='number' and timeout>0 and timeout<=300,'timeout seconds')
    assert(math.type(max_polls)=='integer' and max_polls>=1 and max_polls<=2048,'poll bound')
    local fixtures=M.fixtures() -- serializers only; construction never calls dependencies
    local state,phase,busy='idle','idle',false
    local fault,last_time,deadline,frequency
    local index,handle,queue,incarnation,epoch,polls=1,nil,nil,nil,nil,0
    local streams={'priorities','limits'}
    local telemetry,order,handles,completed,warnings={},{},{},{},{}
    local function emit(event) report(clone(event)) end -- control calls ONLY
    local function fail(why) state='failed';fault=fault or why end
    local function now()
        local n=clock()
        assert(type(n)=='number' and n==n and n>-math.huge and n<math.huge
            and (not last_time or n>=last_time),'nonmonotonic clock')
        last_time=n;return n
    end
    local function checked() assert(not fault,fault or 'trial failure') end
    local function key(h,t) return h..':'..t end
    local function wire(command,h,t,hex,length)
        assert(not recovery_only or command~=3,'recovery-only prohibits publication admission')
        local k=key(h,t)
        local entry=telemetry[k]
        if command==2 or command==3 then
            assert(not entry,'duplicate admission')
            entry={handle=h,ticket=t,stream=streams[index],done=false,attempts=0}
            telemetry[k]=entry;order[#order+1]=entry
            assert(#order<=worker_limit,'worker bound')
        elseif command==4 then
            if not entry then fault='unknown worker';error(fault) end
            entry.attempts=entry.attempts+1
            if entry.attempts~=1 then fault='duplicate worker';error(fault) end
        end
        local r=table.pack(pcall(native,command,h,t,hex,length))
        if not r[1] then fault='native exception';error(fault) end
        local shape=r.n==7 and math.type(r[2])=='integer' and type(r[3])=='string'
            and math.type(r[4])=='integer' and r[4]>0
            and math.type(r[5])=='integer' and math.type(r[6])=='integer'
            and r[5]>=0 and r[6]>=r[5] and math.type(r[7])=='integer' and r[7]>0
        if not shape then fault='native reply shape';error(fault) end
        if frequency and frequency~=r[7] then fault='native frequency changed';error(fault) end
        if command~=4 then
            if r[4]~=game then fault='wrong control thread';error(fault) end
            frequency=r[7]
            if command==2 or command==3 then entry.admitted_end=r[6] end
            if command==5 and entry and entry.done and r[5]<entry.finish then
                fault='completion clock order';error(fault)
            end
        else
            if r[2]~=1 or r[3]~='' or r[4]==game or not entry.admitted_end or r[5]<entry.admitted_end then
                fault='worker route/status/clock';error(fault)
            end
            entry.worker,entry.start,entry.finish,entry.frequency=r[4],r[5],r[6],r[7]
            entry.done=true -- owned scalar telemetry; no worker reports/logs
        end
        if r[2]~=1 and not (command==5 and r[2]==2 and r[3]=='') then
            fault='native rejection';error(fault)
        end
        return table.unpack(r,2,r.n)
    end
    local function control(command,h,t,fields)
        local r=Adapter.call(wire,command,h,t,fields)
        checked();assert(r[1]==1 and r[3]==game,'control result');return r[2]
    end
    local function collect()
        checked()
        for _,entry in ipairs(order) do
            if entry.done and not entry.reported then
                entry.reported=true
                emit{event='worker',stream=entry.stream,handle=entry.handle,ticket=entry.ticket,
                    worker=entry.worker,game=game,start=entry.start,finish=entry.finish,
                    frequency=entry.frequency,inclusive_ms=1000*(entry.finish-entry.start)/entry.frequency}
            end
        end
    end
    local function bind(reopening)
        local stream=streams[index]
        epoch=(index-1)*2+(reopening and 2 or 1)
        incarnation=boot..':'..stream..':'..epoch
        local bytes=control(1,1,0,{W,G,stream,incarnation,tostring(epoch)})
        local field=Adapter.unpack(bytes,1)[1]
        local id=tonumber(field)
        assert(math.type(id)=='integer' and id>=1 and id<=128 and tostring(id)==field and not handles[id],'binding ID')
        handle=id;handles[id]={stream=stream,released=false}
        local adapter=Adapter.new{enabled=true,native=wire,schedule=schedule,resume=resume,
            binding=handle,game_thread=game,storage=W,guild=G,stream=stream,incarnation=incarnation,epoch=epoch}
        queue=Queue.new{enabled=true,backend=adapter,storage=W,guild=G,stream=stream,
            incarnation=incarnation,epoch=epoch}
        phase=reopening and 'recover-latest' or 'recover-missing'
        assert(queue:recover()==true,'recovery admission');checked()
        emit{event='bound',stream=stream,handle=handle,reopening=reopening,synthetic=true}
    end
    local function release()
        assert(queue:can_shutdown(),'undrained release')
        collect()
        for _,entry in ipairs(order) do
            if entry.handle==handle then assert(entry.done and entry.reported,'missing worker telemetry') end
        end
        assert(control(7,handle,0,{})=='','retire reply')
        assert(control(8,handle,0,{})=='','release reply')
        handles[handle].released=true
        emit{event='released',stream=streams[index],handle=handle}
    end
    local function guarded(fn)
        if busy then fail('reentrant trial');return false end
        if state=='failed' or state=='passed' then return false end
        busy=true
        local ok,why=pcall(function() fn();checked() end)
        busy=false
        if not ok then
            fail(tostring(why))
            pcall(emit,{event='failed',phase=phase,reason=fault,automatic_retry=false})
            return false
        end
        return true
    end
    local api={}
    function api:start()
        if state~='idle' then return false end
        return guarded(function()
            state='running';deadline=now()+timeout
            bind(recovery_only)
        end)
    end
    function api:poll()
        if state~='running' then return false end
        return guarded(function()
            polls=polls+1;assert(polls<=max_polls and now()<deadline,'trial timeout/poll bound')
            collect()
            local saved_before=queue.saved
            local ok,payload=queue:poll()
            collect()
            if queue.saved>saved_before then
                local event={event='published',stream=streams[index],logical_revision=queue.saved,
                    physical_generation=queue.journal_generation,cleanup_error=queue.cleanup_error or 0}
                if event.cleanup_error~=0 then warnings[#warnings+1]=clone(event) end
                emit(event)
            end
            local fixture=fixtures[streams[index]]
            assert(not recovery_only or (phase=='recover-latest' and not queue:can_initialize()),
                'recovery-only requires existing latest generation')
            if phase=='recover-missing' then
                if queue:can_initialize() then
                    assert(ok==false and queue.journal_generation==0,'positive missing required')
                    phase='drain-edits'
                    assert(queue:initialize(fixture.payloads[1])==1,'initialize logical revision')
                    checked()
                    assert(queue:submit(fixture.payloads[2])==2 and queue:submit(fixture.payloads[3])==3,'coalesced revisions')
                    checked()
                else assert(queue.state~='saved' and ok~=true,'store must start positively missing') end
            elseif phase=='drain-edits' then
                if ok==true then assert(payload==fixture.payloads[1],'initialization payload changed') end
                if queue:can_shutdown() then
                    assert(queue.saved==3 and queue.generation==3 and queue.journal_generation==2,'logical/physical counters')
                    release();bind(true)
                end
            elseif phase=='recover-latest' and ok==true then
                assert(payload==fixture.payloads[3] and queue.journal_generation==2,'latest exact recovery')
                assert(Codec.new{storage=W,guild=G,stream=streams[index]}.decode(payload),'typed recovery')
                release();completed[#completed+1]=streams[index]
                if index==1 then index=2;bind(recovery_only)
                else
                    assert(#order==worker_limit,'exact worker count')
                    state,phase='passed','complete'
                    emit{event='passed',synthetic=true,storage=W,guild=G,namespace='local-test-profile',
                        completed=completed,expected=fixtures,workers=#order,cleanup_warnings=warnings,
                        recovery_only=recovery_only,
                        power_loss_verified=false}
                end
            end
            checked()
            assert(queue.state~='uncertain' and (queue.state~='error' or queue:can_initialize()),'queue failed/uncertain')
        end)
    end
    function api:status()
        return {state=state,phase=phase,reason=fault,polls=polls,completed=clone(completed),recovery_only=recovery_only,
            handles=clone(handles),cleanup_warnings=clone(warnings),
            expected=state=='passed' and clone(fixtures) or nil}
    end
    return api
end
return M
