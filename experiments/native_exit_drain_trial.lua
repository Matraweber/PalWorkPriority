-- Isolated synthetic Quit-boundary trial. No hooks, IO, scheduling or engine.
-- Bootstrap configures frozen bridge command0 and calls start/poll on its control
-- thread. Call quit with a scalar reason extracted synchronously by bootstrap.
-- No current-player/settings authority: fixed synthetic storage3/guild4 only.
-- Ready retains TWO native owners with revision1 committed. Only Quit=4 can
-- admit revisions2/3. Command6 validates BOTH original handles/control routes
-- before any quit mutation. Lost replies never retry or release unresolved work.
-- Native drain may block the callback on filesystem IO; no timeout cancels it.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/native_exit_drain_trial.lua$'))
local Wire=dofile(root..'/save_native_backend.lua')
local Original=dofile(root..'/native_settings_trial.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local Store,Caps=require('store'),require('caps')
local M={}
local function fixture_scope(version)
    assert(version==nil or version==1 or version==2,'unsupported fixture version')
    return string.rep(version==2 and '5' or '3',32),string.rep(version==2 and '6' or '4',32)
end
local streams={'priorities','limits'}
local function copy(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t)do out[k]=copy(v)end;return out
end
function M.fixtures(version)
    local W,G=fixture_scope(version)
    local original=Original.fixtures();local out={}
    for _,stream in ipairs(streams)do
        local f=original[stream]
        local old=Codec.new{storage=f.storage,guild=f.guild,stream=stream}
        local new=Codec.new{storage=W,guild=G,stream=stream}
        local payloads={}
        for revision=1,3 do
            local decoded=assert(old.decode(f.payloads[revision]))
            local body
            if stream=='priorities' then body=assert(Store.serialize_snapshot(decoded.data,decoded.baseline))
            else body=assert(Caps.serialize_snapshot({[G]=assert(decoded.data[f.guild])}))end
            payloads[revision]=assert(new.encode(body))
        end
        out[stream]={storage=W,guild=G,payloads=payloads}
    end
    return out
end
local function number(s)
    assert(type(s)=='string','decimal field')
    local n=math.tointeger(tonumber(s));assert(n and n>=0 and n<2147483647 and tostring(n)==s,'invalid decimal')
    return n
end
function M.new(o)
    assert(type(o)=='table' and getmetatable(o)==nil)
    local native,clock,report,game,boot=o.native,o.clock,o.report,o.game_thread,o.boot
    assert(type(native)=='function' and type(clock)=='function' and type(report)=='function')
    assert(math.type(game)=='integer' and game>0 and game<2147483647)
    assert(type(boot)=='string' and #boot>0 and #boot<=64 and boot:match('^[%w%-_]+$'))
    local W,G=fixture_scope(o.fixture_version)
    local fixtures=M.fixtures(o.fixture_version)
    local state,phase,busy,reason='idle','idle',false,nil
    local bindings,used={},{}
    local index,polls,started,last_clock,frequency,last_finish=1,0,nil,nil,nil,nil
    local quit_attempted=false
    local function fail(why)state='failed';reason=reason or why end
    local function check()assert(state~='failed',reason or 'failed')end
    local function emit(e)assert(report(copy(e))~=false,'report refused');check()end
    local function now()
        local n=clock();check()
        assert(type(n)=='number' and n==n and n>=0 and n<math.huge and (not last_clock or n>=last_clock),'bad clock')
        last_clock=n;return n
    end
    local function event(kind,b,extra)
        local e={event=kind,stream=b.stream,scope=b.scope,incarnation=b.incarnation,handle=b.handle}
        for k,v in pairs(extra or {})do e[k]=v end
        return e
    end
    local function call(command,b,fields,mutation)
        check()
        if mutation then b.ticket=b.ticket+1;b.command=command;b.revision=command==5 and b.revision+1 or 0 end
        -- revision of last submit is tracked separately because non-submit commands
        -- reset the bridge's returned last-operation revision to zero.
        local ticket=mutation and b.ticket or 0
        local r=Wire.call(native,command,b.handle,ticket,fields or {})
        check()
        assert(r[3]==game,'wrong control thread')
        assert(type(r[6])=='number' and r[6]>0 and (not frequency or frequency==r[6]),'frequency changed')
        assert(type(r[4])=='number' and type(r[5])=='number' and r[4]>=0 and r[5]>=r[4]
            and (not last_finish or r[4]>=last_finish),'call clock reversed')
        frequency,last_finish=r[6],r[5]
        local count=(command==3 or command==6 or command==8) and r[1]==1 and 16
            or (command==1 or command==5) and r[1]==1 and 1 or 0
        local fields_out=Wire.unpack(r[2],count)
        emit(event('call',b,{command=command,ticket=ticket,status=r[1],thread=r[3],start=r[4],finish=r[5],frequency=r[6],fields=fields_out}))
        assert(r[1]==1 or command==3 and r[1]==2,'native refusal')
        return r
    end
    local function status(r,b)
        assert(r[1]==1,'status unavailable')
        local f=Wire.unpack(r[2],16)
        assert(f[1]==b.scope and f[2]==b.incarnation and f[3]=='1','stale status owner')
        local a,c,g=number(f[4]),number(f[5]),number(f[8])
        assert(c<=a and a==b.accepted and f[7]=='none' and f[9]=='0','bad counters/error/cleanup')
        assert(number(f[13])==b.ticket and number(f[14])==b.command and number(f[15])==b.revision
            and f[16]=='accepted','stale operation receipt')
        assert(f[11]=='1' and f[12]=='0','uncertain terminal')
        assert(f[10]=='initialized' or f[10]=='updated','not a published terminal')
        return f,a,c,g
    end
    local function bind(stream)
        local b={stream=stream,scope='PWP-SCOPE-1:'..W..':'..G..':'..stream,
            incarnation=boot..'-exit-'..stream,handle=1,ticket=0,command=0,revision=0,accepted=0}
        local r=call(1,b,{W,G,stream,b.incarnation,'1'})
        local id=number(Wire.unpack(r[2],1)[1]);assert(id>0 and id<=128 and not used[id],'bad/reused handle')
        b.handle=id;used[id]=true;bindings[stream]=b
        emit(event('bound',b,{synthetic=true}))
        assert(call(2,b,{},true)[2]=='','unexpected start reply')
        phase='recover'
    end
    local function submit(b,revision)
        -- Maintain bridge last-operation revision and logical accepted independently.
        b.revision=revision-1
        local r=call(5,b,{fixtures[b.stream].payloads[revision]},true)
        assert(number(Wire.unpack(r[2],1)[1])==revision,'wrong admitted revision')
        b.accepted=revision
    end
    local function guarded(fn)
        if busy then fail('reentry');return false end
        busy=true
        local ok,err=pcall(fn);busy=false
        if not ok then
            fail(tostring(err):sub(1,700))
            -- Preserve one failure report; reporter reentry cannot start new work.
            pcall(report,{event='failed',phase=phase,reason=reason,owners_retained=true})
            -- Read-only terminal capture after a failure; never replay admission,
            -- retire, drain or release. The native entry still enforces its thread.
            for _,stream in ipairs(streams)do
                local b=bindings[stream]
                if b then pcall(function()
                    local r=Wire.call(native,6,b.handle,0,{})
                    report(event('failure-status',b,{status=r[1],thread=r[3],
                        fields=r[1]==1 and Wire.unpack(r[2],16) or {}}))
                end) end
            end
        end
        return ok and state~='failed'
    end
    local api={}
    function api:start()
        if busy then fail('reentry');return false end
        if state~='idle' then return false end
        return guarded(function()state='starting';started=now();bind('priorities')end)
    end
    function api:poll()
        if busy then fail('reentry');return false end
        if state~='starting' then return false end
        return guarded(function()
            polls=polls+1;assert(polls<=512 and now()-started<=120,'startup timed out')
            local b=bindings[streams[index]]
            if phase=='recover' then
                local r=call(3,b)
                if r[1]==2 then assert(r[2]=='','pending data');return end
                local f=Wire.unpack(r[2],16)
                assert(f[1]==b.scope and f[2]==b.incarnation and f[3]=='1' and f[4]=='recovered'
                    and f[5]=='1' and f[6]=='0' and f[7]=='0' and f[8]~='' and f[9]=='0' and f[10]=='0','bad recovery')
                assert(f[11]=='missing' and f[12]=='0' and f[13]=='' and f[14]=='missing' and f[15]=='0' and f[16]=='','not positive missing pair')
                assert(call(4,b,{'initialize_missing'},true)[2]=='','approval reply')
                submit(b,1);phase='initializing'
            else
                assert(phase=='initializing','phase')
                local r=call(6,b);local f=Wire.unpack(r[2],16)
                -- During the first write the most recent terminal is still recovery.
                -- Validate identity/counters/last admission even before publication.
                assert(f[1]==b.scope and f[2]==b.incarnation and f[3]=='1' and f[4]=='1'
                    and f[6]=='ready' and f[7]=='none' and f[9]=='0'
                    and number(f[13])==b.ticket and f[14]=='5' and f[15]=='1' and f[16]=='accepted','invalid initialization status')
                if f[5]=='0' then
                    -- Worker publishes its terminal before consuming it and
                    -- advancing committed/gen. Either certain terminal is valid
                    -- in this interval; neither makes committed0 a durable ACK.
                    assert(f[8]=='0' and (f[10]=='recovered' or f[10]=='initialized')
                        and f[11]=='1' and f[12]=='0','invalid pending initialization');return
                end
                local _,a,c,g=status(r,b);assert(a==1 and c==1 and g==1 and f[10]=='initialized','initialization incomplete')
                emit(event('initialized',b,{accepted=a,committed=c,generation=g,cleanup_error=f[9]}))
                index=index+1
                if index<=#streams then bind(streams[index])
                else state='ready';phase='awaiting_quit';emit{event='ready',synthetic=true,storage=W,guild=G,owners_retained=2}end
            end
        end)
    end
    function api:quit(value)
        if busy then fail('reentry');return false end
        if value~=4 then return false end
        if quit_attempted or state=='passed' or state=='failed' then return false end
        quit_attempted=true
        return guarded(function()
            assert(state=='ready','Quit before ready');phase='quit_preflight'
            -- Query BOTH before the first submit. Wrong-thread entry is rejected
            -- by the frozen bridge before touching any native backend state.
            for _,stream in ipairs(streams)do
                local b=bindings[stream];local f,a,c,g=status(call(6,b),b)
                assert(f[6]=='ready' and a==1 and c==1 and g==1,'changed ready owner')
            end
            state='quitting';emit{event='quit-observed',reason=4,game_thread=game,synthetic=true,scope_verified=false}
            for _,stream in ipairs(streams)do
                local b=bindings[stream];phase='submit_tail';submit(b,2);submit(b,3)
                local f,a,c,g=status(call(6,b),b)
                assert(f[6]=='ready' and a==3 and c>=1 and c<=3 and g>=1 and g<=3,'tail status')
                emit(event('pending-observation',b,{accepted=a,committed=c,generation=g,pending_observed=c<a}))
            end
            for _,stream in ipairs(streams)do
                local b=bindings[stream];phase='drain'
                local f,a,c,g=status(call(8,b,{},true),b)
                assert(f[6]=='closed' and a==3 and c==3 and (g==2 or g==3),'drain incomplete')
                emit(event('drained',b,{accepted=a,committed=c,generation=g,cleanup_error=f[9]}))
            end
            -- Cleanup only after BOTH drains validated; no cleanup on ambiguity.
            for _,stream in ipairs(streams)do
                local b=bindings[stream];phase='cleanup';assert(call(9,b)[2]=='','cleanup reply')
                emit(event('released',b))
            end
            phase='complete';state='passed'
            emit{event='passed',synthetic=true,explicit_drain=true,quit_reason=4,storage=W,guild=G,
                completed={'priorities','limits'},shutdown_route_verified=false,worker_thread_independently_observed=false}
        end)
    end
    function api:status()return {state=state,phase=phase,reason=reason,polls=polls,quit_attempted=quit_attempted}end
    return api
end
return M
