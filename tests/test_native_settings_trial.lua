-- Actual runner/adapter/queue/typed serializers. Only native ABI and scheduling
-- are mocked; no fixture files, engine access or production globals are used.
package.loaded.datafile={read=function()error('unexpected IO')end,write=function()error('unexpected IO')end}
package.loaded.log={warn=function()error('unexpected log')end,error=function()error('unexpected log')end}
local Trial=dofile(TEST_ROOT..'/experiments/native_settings_trial.lua')
local Adapter=dofile(TEST_ROOT..'/experiments/save_native_backend.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local W,G=string.rep('1',32),string.rep('2',32)
local function fixture(fault,recovery_only)
    local s={thread=10,ticks=0,time=0,calls={},workers={},callbacks={},reports={},bindings={},disk={},writes=0,release_count=0}
    if recovery_only==true then
        for stream,f in pairs(Trial.fixtures()) do
            s.disk[stream]={{gen=1,payload=f.payloads[1]},{gen=2,payload=f.payloads[3]}}
        end
        if fault=='recovery_missing' then s.disk.priorities={} end
        if fault=='recovery_wrong_latest' then s.disk.priorities[2].payload=Trial.fixtures().priorities.payloads[2] end
        if fault=='recovery_wrong_generation' then s.disk.priorities[2].gen=3 end
        if fault=='recovery_missing_second' then s.disk.limits={} end
    end
    local function fields(hex,n)
        assert(#hex==n and n%2==0)
        return hex:gsub('..',function(v)return string.char(assert(tonumber(v,16)))end)
    end
    local function native(cmd,h,t,hex,n)
        assert(cmd~=0,'bootstrap owns command zero')
        assert(recovery_only~=true or cmd~=3,'recovery mode issued an update/init command')
        s.calls[#s.calls+1]={cmd=cmd,h=h,t=t}
        s.ticks=s.ticks+10;local start=s.ticks
        local function reply(status,data)
            if cmd==4 and fault=='bad_worker_clock' then return status,data or '',s.thread,start,start-1,10000000 end
            if cmd==4 and fault=='bad_frequency' then return status,data or '',s.thread,start,start+2,9 end
            return status,data or '',s.thread,start,start+2,10000000
        end
        if (cmd==4)==(s.thread==10) then return reply(0) end
        if cmd==1 then
            assert(h==1 and t==0)
            local f=Adapter.unpack(fields(hex,n),5)
            assert(f[1]==W and f[2]==G,'only fixed synthetic scope')
            assert(f[3]=='priorities' or f[3]=='limits')
            for _,b in pairs(s.bindings) do assert(b.released,'streams/rebind must be serial') end
            local id=#s.bindings+1
            s.bindings[id]={stream=f[3],incarnation=f[4],epoch=f[5],scope='PWP-SCOPE-1:'..W..':'..G..':'..f[3],high=0}
            s.disk[f[3]]=s.disk[f[3]] or {}
            if fault=='existing_store' then
                s.disk[f[3]][1]={gen=1,payload=Trial.fixtures()[f[3]].payloads[1]}
            end
            return reply(1,Adapter.pack({tostring(id)}))
        end
        local b=assert(s.bindings[h]);assert(not b.released)
        if cmd==2 or cmd==3 then
            assert(not b.pending and not b.retired and t>b.high)
            b.high=t;b.pending={kind=cmd==2 and 'recover' or 'update',ticket=t}
            if cmd==3 then
                local f=Adapter.unpack(fields(hex,n),5)
                assert(f[1]==b.token,'exact predecessor token')
                local p=b.pending;p.payload=f[2];p.gen=assert(tonumber(f[3]));p.revision=assert(tonumber(f[4]));p.init=f[5]=='1'
                local disk=s.disk[b.stream];local highest=0
                for _,r in pairs(disk) do highest=math.max(highest,r.gen) end
                assert(p.gen==highest+1 and p.init==(highest==0))
                assert(Codec.new{storage=W,guild=G,stream=b.stream}.decode(p.payload),'real typed payload')
            end
            if fault=='admission_exception' then error('lost admission reply') end
            return reply(1)
        end
        if cmd==4 then
            local p=assert(b.pending);assert(p.ticket==t and not p.ran);p.ran=true
            local disk=s.disk[b.stream]
            b.token=h..':'..t
            local result={b.scope,b.incarnation,b.epoch,p.kind=='recover' and 'recovered' or (p.init and 'initialized' or 'updated'),
                '1','0',tostring(p.revision or 0),b.token,'0','0','','','','','',''}
            if p.kind=='recover' then
                local highest=0
                for i=1,2 do
                    local r=disk[i];local at=i==1 and 11 or 14
                    result[at]=r and 'valid' or 'missing';result[at+1]=r and tostring(r.gen) or '0';result[at+2]=r and r.payload or ''
                    if r then highest=math.max(highest,r.gen) end
                end
                result[6]=tostring(highest)
                if fault=='wrong_recovery' and h==2 then result[13]=result[13]..'altered' end
            else
                s.writes=s.writes+1
                disk[p.gen%2==1 and 1 or 2]={gen=p.gen,payload=p.payload}
                result[6]=tostring(p.gen)
                if fault=='uncertain' then result[4]='uncertain';result[5]='0' end
                if fault=='cleanup_warning' then result[10]='5' end
            end
            b.result=Adapter.pack(result)
            if fault=='recovery_uncertain' then result[5]='0';b.result=Adapter.pack(result) end
            if fault=='worker_exception' then error('lost worker reply') end
            return reply(1)
        end
        if cmd==5 then
            assert(b.pending and b.pending.ticket==t)
            return reply(b.result and 1 or 2,b.result)
        end
        if cmd==6 then
            if b.consumed==t then return reply(1) end
            assert(b.result and Adapter.unpack(b.result,16)[5]=='1','never consume uncertain')
            b.pending=nil;b.result=nil;b.consumed=t
            if fault=='consume_exception' then error('lost consumed reply') end
            return reply(1)
        end
        if cmd==7 then assert(t==0 and not b.pending);b.retired=true;return reply(1) end
        if cmd==8 then
            assert(b.retired and not b.pending);b.released=true;s.release_count=s.release_count+1
            if fault=='release_exception' then error('lost release reply') end
            return reply(1)
        end
        error('unknown command')
    end
    local options={native=native,game_thread=10,boot='test-boot',clock=function()return s.time end,
        recovery_only=recovery_only,
        max_polls=fault=='poll_bound' and 2 or 128,timeout_seconds=30,
        schedule=function(fn)
            if fault=='schedule_exception' then error('route failed') end
            if fault=='schedule_refused' then return false end
            s.workers[#s.workers+1]=fn
        end,
        resume=function(fn) s.callbacks[#s.callbacks+1]=fn end,
        report=function(event)
            assert(s.thread==10,'report on worker')
            s.reports[#s.reports+1]=event
            if fault=='report_exception' then error('report failed') end
            if fault=='report_reentry' and s.runner then s.runner:poll() end
        end}
    s.runner=Trial.new(options)
    options.recovery_only=not recovery_only -- must not change the captured mode
    assert(#s.calls==0 and #s.reports==0 and #s.workers==0,'constructor must be inert')
    function s.step()
        if fault~='timeout' and fault~='poll_bound' then
            local workers=s.workers;s.workers={}
            s.thread=fault=='wrong_worker' and 10 or 11
            for _,fn in ipairs(workers) do fn();if fault=='duplicate_worker' then fn() end end
            s.thread=10
            local callbacks=s.callbacks;s.callbacks={}
            if fault~='lost_resume' then for _,fn in ipairs(callbacks) do fn() end end
        end
        s.time=s.time+(fault=='timeout' and 31 or 0.01)
        s.runner:poll()
    end
    function s.run()
        s.runner:start()
        for _=1,30 do if s.runner:status().state~='running' then break end;s.step() end
        return s.runner:status()
    end
    return s
end

for _,mode in ipairs({'normal','lost_resume','cleanup_warning'}) do
    local s=fixture(mode);local status=s.run()
    assert(status.state=='passed',status.reason)
    assert(#status.completed==2 and s.writes==4 and s.release_count==4)
    local telemetry=0
    for _,r in ipairs(s.reports) do if r.event=='worker' then telemetry=telemetry+1;assert(r.worker~=r.game) end end
    assert(telemetry==8)
    assert(#status.cleanup_warnings==(mode=='cleanup_warning' and 4 or 0))
    local expected=Trial.fixtures()
    for _,stream in ipairs({'priorities','limits'}) do
        assert(s.disk[stream][1].gen==1 and s.disk[stream][1].payload==expected[stream].payloads[1])
        assert(s.disk[stream][2].gen==2 and s.disk[stream][2].payload==expected[stream].payloads[3])
    end
    local decoded=assert(Codec.new{storage=W,guild=G,stream='priorities'}.decode(expected.priorities.payloads[3]))
    for i=1,5 do assert(decoded.data['trial-pal'][i]==i) end
    assert(decoded.data['trial-pal'][6]==false)
    status.expected.priorities.slots.A.payload='mutated'
    assert(s.runner:status().expected.priorities.slots.A.payload~= 'mutated')
    local count=#s.calls;assert(not s.runner:start() and not s.runner:poll() and #s.calls==count)
end
for _,mode in ipairs({'admission_exception','worker_exception','consume_exception','release_exception',
    'schedule_exception','schedule_refused','wrong_worker','duplicate_worker','uncertain','timeout','poll_bound',
    'wrong_recovery','report_exception','report_reentry','bad_worker_clock','bad_frequency','existing_store'}) do
    local s=fixture(mode);local status=s.run()
    assert(status.state=='failed',mode..': '..tostring(status.reason))
    local calls=#s.calls;s.runner:start();s.runner:poll();assert(#s.calls==calls,'failed trial retried')
    if mode~='release_exception' and mode~='wrong_recovery' then assert(s.release_count==0,mode..' released uncertain owner') end
    assert(s.writes<=2,mode..' continued publication')
end
print('typed trial: both streams, real serializers, logical3/physical2, exact recovery, eight worker receipts, fail-stop routes passed')

for _,mode in ipairs({'normal','lost_resume'}) do
    local s=fixture(mode,true)
    local before=Adapter.pack({s.disk.priorities[1].payload,s.disk.priorities[2].payload,
                              s.disk.limits[1].payload,s.disk.limits[2].payload})
    local status=s.run()
    assert(status.state=='passed' and status.recovery_only==true,status.reason)
    assert(#status.completed==2 and #s.bindings==2 and s.release_count==2 and s.writes==0)
    local workers,recoveries,passed=0,0,nil
    for _,c in ipairs(s.calls) do
        assert(c.cmd~=0 and c.cmd~=3)
        if c.cmd==4 then workers=workers+1 end
        if c.cmd==2 then recoveries=recoveries+1 end
    end
    assert(workers==2 and recoveries==2)
    for _,event in ipairs(s.reports) do
        assert(event.event~='published')
        if event.event=='bound' then assert(event.reopening==true) end
        if event.event=='passed' then passed=event end
    end
    assert(passed and passed.recovery_only==true and passed.workers==2)
    for stream,f in pairs(Trial.fixtures()) do
        assert(passed.expected[stream].slots.A.generation==1 and passed.expected[stream].slots.A.payload==f.payloads[1])
        assert(passed.expected[stream].slots.B.generation==2 and passed.expected[stream].slots.B.payload==f.payloads[3])
    end
    assert(before==Adapter.pack({s.disk.priorities[1].payload,s.disk.priorities[2].payload,
                                s.disk.limits[1].payload,s.disk.limits[2].payload}))
end
for _,mode in ipairs({'recovery_missing','recovery_missing_second','recovery_wrong_latest','recovery_wrong_generation',
    'recovery_uncertain','admission_exception','worker_exception','consume_exception','release_exception',
    'schedule_exception','schedule_refused','wrong_worker','duplicate_worker','timeout','poll_bound','bad_worker_clock'}) do
    local s=fixture(mode,true);local status=s.run()
    assert(status.state=='failed',mode)
    assert(s.writes==0 and #s.bindings<=2)
    for _,c in ipairs(s.calls) do assert(c.cmd~=3 and c.cmd~=0) end
    local calls=#s.calls;s.runner:poll();s.runner:start();assert(#s.calls==calls)
    if mode~='release_exception' and mode~='recovery_missing_second' then assert(s.release_count==0,mode) end
end
-- Only literal true opts into recovery. Explicit false follows the write trial.
local default=fixture('normal',false);assert(default.run().state=='passed' and default.writes==4)
print('restart recovery: two workers, exact latest generation/payload, zero writes/init, uncertainty retained, default unchanged passed')
