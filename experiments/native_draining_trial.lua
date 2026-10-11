-- Disposable explicit-drain trial; no engine, filesystem, real settings or exit hooks.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/'):match('^(.*)/native_draining_trial.lua$'))
local Wire=dofile(root..'/save_native_backend.lua')
local Fixtures=dofile(root..'/native_settings_trial.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local M={}
function M.new(o)
    assert(type(o.native)=='function' and type(o.report)=='function' and type(o.clock)=='function')
    assert(math.type(o.game_thread)=='integer' and o.game_thread>0)
    assert(type(o.boot)=='string' and #o.boot>0 and #o.boot<=64 and o.boot:match('^[%w%-_]+$'))
    local native,report,clock,game,boot=o.native,o.report,o.clock,o.game_thread,o.boot
    local fixture=Fixtures.fixtures()
    local streams={'priorities','limits'}
    local state,phase,index,handle,ticket,polls='idle','idle',1,nil,0,0
    local started,reason,incarnation,scope,codec,busy,last_clock
    local completed,handles,drained_generations={},{},{}
    local function emit(event) report(event);assert(state~='failed','report reentry') end
    local function now()
        local n=clock();assert(type(n)=='number' and n==n and n<math.huge and n>=0)
        assert(not last_clock or n>=last_clock,'clock reversed');last_clock=n;return n
    end
    local function call(command,fields,mutation)
        assert(state=='running','trial no longer running')
        if mutation then ticket=ticket+1 end
        local r=Wire.call(native,command,handle,mutation and ticket or 0,fields or {})
        assert(r[3]==game,'wrong control thread')
        emit{event='call',command=command,handle=handle,ticket=mutation and ticket or 0,
            status=r[1],thread=r[3],start=r[4],finish=r[5],frequency=r[6]}
        return r
    end
    local function bind(reopening)
        local stream=streams[index];local f=fixture[stream]
        incarnation=boot..'-'..stream..(reopening and '-reopen' or '-first')
        scope='PWP-SCOPE-1:'..f.storage..':'..f.guild..':'..stream
        codec=Codec.new{storage=f.storage,guild=f.guild,stream=stream}
        handle=1;ticket=0
        local r=call(1,{f.storage,f.guild,stream,incarnation,'1'})
        assert(r[1]==1,'bind failed')
        local id=Wire.unpack(r[2],1)[1];handle=math.tointeger(tonumber(id))
        assert(handle and handle>0 and handle<=128 and tostring(handle)==id and not handles[handle],'bad/reused binding')
        handles[handle]=true
        emit{event='bound',handle=handle,stream=stream,reopening=reopening}
        assert(call(2,{},true)[1]==1,'recovery not started')
        phase=reopening and 'recover_again' or 'recover_first'
    end
    local function status(r)
        assert(r[1]==1,'status refused')
        local f=Wire.unpack(r[2],16)
        assert(f[1]==scope and f[2]==incarnation and f[3]=='1','wrong status owner')
        local accepted,committed,generation=math.tointeger(tonumber(f[4])),math.tointeger(tonumber(f[5])),math.tointeger(tonumber(f[8]))
        assert(accepted and committed and generation and committed<=accepted,'invalid counters')
        return f,accepted,committed,generation
    end
    local function guarded(fn)
        if busy then state,reason='failed','reentry';return false end
        busy=true
        local ok,err=pcall(fn);busy=false
        if not ok then
            state,reason='failed',tostring(err):sub(1,1000)
            pcall(emit,{event='failed',reason=reason,phase=phase,owners_retained=true})
        end
        return ok and state~='failed'
    end
    local api={}
    function api:start()
        if state~='idle' then return false end
        return guarded(function() started=now();state='running';bind(false) end)
    end
    function api:poll()
        if state~='running' then return false end
        return guarded(function()
            polls=polls+1;assert(polls<=512 and now()-started<=120,'trial timed out')
            local r=call(3)
            if r[1]==2 then return end
            assert(r[1]==1,'recovery refused')
            local f=Wire.unpack(r[2],16)
            assert(f[1]==scope and f[2]==incarnation and f[3]=='1' and f[4]=='recovered'
                and f[5]=='1' and f[9]=='0','bad recovery')
            local stream=streams[index];local expected=fixture[stream]
            if phase=='recover_first' then
                assert(f[11]=='missing' and f[14]=='missing' and f[6]=='0','not positively missing')
                assert(f[12]=='0' and f[13]=='' and f[15]=='0' and f[16]=='','missing slot contained data')
                assert(call(4,{'initialize_missing'},true)[1]==1,'initialization approval refused')
                for revision=1,3 do
                    assert(codec.decode(expected.payloads[revision]),'invalid trial typed payload')
                    local accepted=call(5,{expected.payloads[revision]},true)
                    assert(accepted[1]==1 and Wire.unpack(accepted[2],1)[1]==tostring(revision),'revision admission failed')
                end
                local s,a,c,g=status(call(8,{},true))
                assert(s[6]=='closed' and s[7]=='none' and a==3 and c==3 and (g==2 or g==3),'incomplete drain')
                drained_generations[stream]=g
                emit{event='drained',stream=stream,accepted=a,committed=c,generation=g,cleanup_error=s[9]}
                assert(call(9)[1]==1,'cleanup refused')
                emit{event='released',handle=handle,stream=stream}
                bind(true)
            else
                assert(phase=='recover_again','phase mismatch')
                local newest=-1;local newest_payload
                for _,offset in ipairs({11,14}) do
                    assert(f[offset]=='valid','both written slots must validate')
                    local gen=math.tointeger(tonumber(f[offset+1]));local payload=f[offset+2]
                    assert(gen and gen>=1 and gen<=3 and codec.decode(payload),'bad recovered typed record')
                    assert(offset==11 and gen%2==1 or offset==14 and gen==2,'wrong slot generation')
                    assert((gen==1 and payload==expected.payloads[1]) or
                        (gen==2 and (payload==expected.payloads[2] or payload==expected.payloads[3])) or
                        (gen==3 and payload==expected.payloads[3]),'unexpected recovered bytes')
                    if gen>newest then newest,newest_payload=gen,payload end
                    emit{event='slot',stream=stream,slot=offset==11 and 'A' or 'B',generation=gen,payload=payload}
                end
                assert(newest==drained_generations[stream] and f[6]==tostring(newest)
                    and newest_payload==expected.payloads[3],'latest edit missing')
                local s,a,c=status(call(8,{},true)) -- never approve a reopening for writes
                assert(s[6]=='closed' and s[7]=='none' and a==0 and c==0,'read-only reopen did not close')
                assert(call(9)[1]==1,'reopen cleanup refused')
                emit{event='released',handle=handle,stream=stream}
                completed[#completed+1]=stream
                index=index+1
                if index>#streams then
                    state,phase='passed','complete';emit{event='passed',synthetic=true,explicit_drain=true,
                        completed={'priorities','limits'},shutdown_route_verified=false}
                else bind(false) end
            end
        end)
    end
    function api:status() return {state=state,phase=phase,reason=reason,polls=polls} end
    return api
end
return M
