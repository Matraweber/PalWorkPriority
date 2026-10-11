-- Actual writer/session/queue/backend/wire chain. Only DLL behavior is modeled.
package.loaded.log={warn=function()end,error=function()end}
package.loaded.datafile={read=function()error('unexpected IO')end,write=function()error('unexpected IO')end}
local Trial=dofile(TEST_ROOT..'/experiments/native_settings_chain_trial.lua')
local Wire=dofile(TEST_ROOT..'/experiments/save_native_backend.lua')
local Store,Caps=require('store'),require('caps')
local before_store,before_caps=Store.data,Caps.data
local function copy(t)if type(t)~='table'then return t end;local r={};for k,v in pairs(t)do r[k]=copy(v)end;return r end
local function fixture(coalesce,recovery,disk,mutate)
    local f={events={},calls={},owners={},disk=copy(disk or {}),time=0,thread=10,submits=0,updates=0}
    local fixtures=Trial.fixtures()
    local function status(h)
        return {h.scope,h.inc,'1',tostring(h.a),tostring(h.c),h.phase,h.error,tostring(h.gen),'0',
            h.terminal,h.certain,h.terr,tostring(h.ticket),tostring(h.command),tostring(h.revision),h.outcome}
    end
    local function publish(h,revision)
        assert(revision>h.c)
        h.gen=h.gen+1;h.c=revision
        local slots=f.disk[h.stream] or {};f.disk[h.stream]=slots
        slots[h.gen%2==1 and 1 or 2]={gen=h.gen,payload=h.payloads[revision]}
        h.terminal=h.initial and 'initialized' or 'updated';h.certain='1';h.terr='0';h.initial=false
        f.updates=f.updates+1
    end
    local function advance(h)
        if h.phase=='recovering' then
            local d=f.disk[h.stream] or {}
            h.gen=math.max(d[1] and d[1].gen or 0,d[2] and d[2].gen or 0)
            h.phase='awaiting_validation';h.terminal='recovered';h.certain='1';h.terr='0'
        elseif (h.phase=='ready' or h.phase=='closing') and h.a>h.c then
            if h.initial then publish(h,1) end
            if h.a>h.c then publish(h,h.a) end
        end
    end
    local function native(cmd,id,ticket,hex,length)
        assert(#hex==length)
        local raw=hex:gsub('..',function(s)return string.char(tonumber(s,16))end)
        local fields=Wire.unpack(raw,cmd==1 and 5 or (cmd==4 or cmd==5) and 1 or 0)
        f.calls[#f.calls+1]={command=cmd,handle=id,ticket=ticket,fields=copy(fields)}
        local r={1,'',f.thread,20,21,1000};local h=f.owners[id]
        -- Frozen DLL preflights control thread BEFORE backend action.
        if f.thread~=10 then r[1]=0
        elseif cmd==1 then
            assert(fields[1]==string.rep('7',32) and fields[2]==string.rep('8',32))
            id=#f.owners+1
            h={scope='PWP-SCOPE-1:'..fields[1]..':'..fields[2]..':'..fields[3],stream=fields[3],inc=fields[4],
                a=0,c=0,gen=0,phase='dormant',error='none',terminal='',certain='',terr='',
                ticket=0,command=0,revision=0,outcome='none',payloads={}}
            f.owners[id]=h;r[2]=Wire.pack({tostring(id)})
        elseif cmd==6 then
            if not f.hold then advance(h) end;r[2]=Wire.pack(status(h))
        elseif cmd==3 then
            assert(h.phase=='awaiting_validation')
            local d=f.disk[h.stream] or {};local a,b=d[1],d[2]
            r[2]=Wire.pack({h.scope,h.inc,'1','recovered','1',tostring(h.gen),'0','pair-1','0','0',
                a and 'valid' or 'missing',a and tostring(a.gen) or '0',a and a.payload or '',
                b and 'valid' or 'missing',b and tostring(b.gen) or '0',b and b.payload or ''})
        elseif cmd==9 then assert(h.phase=='closed');h.cleaned=true
        else
            assert(h and not h.cleaned and ticket>h.ticket,'immutable monotonic ticket')
            h.ticket,h.command,h.revision,h.outcome=ticket,cmd,0,'accepted'
            if cmd==2 then assert(h.phase=='dormant');h.phase='recovering'
            elseif cmd==4 then
                assert(h.phase=='awaiting_validation')
                if recovery then assert(fields[1]=='existing' and h.gen>=3)
                else assert(fields[1]=='initialize_missing' and h.gen==0) end
                h.phase='ready';h.initial=not recovery
            elseif cmd==5 then
                assert(not recovery and h.phase=='ready')
                h.a=h.a+1;h.revision=h.a;h.payloads[h.a]=fields[1]
                assert(fields[1]==fixtures[h.stream].payloads[h.a],'exact fixture bytes through full chain')
                f.submits=f.submits+1;r[2]=Wire.pack({tostring(h.a)})
                local inline=not coalesce
                if type(coalesce)=='table' then inline=h.a<=3 and not coalesce.before or h.a>3 and not coalesce.after end
                if inline then publish(h,h.a) end
            elseif cmd==7 then h.phase='closing'
            elseif cmd==8 then
                advance(h);h.phase='closed';r[2]=Wire.pack(status(h));h.drained=true
            else error('unexpected command') end
        end
        if mutate then mutate(cmd,r,f,h,fields) end
        return table.unpack(r)
    end
    f.options={native=native,game_thread=10,boot='chain-test',clock=function()return f.time end,
        recovery_only=recovery,report=function(e)
            f.events[#f.events+1]=copy(e)
            if f.on_report then f.on_report(e) end
        end}
    f.trial=Trial.new(f.options)
    function f:run()
        assert(self.trial:start())
        for _=1,16 do if self.trial:status().state~='running'then break end;self.trial:poll() end
        return self.trial:status().state
    end
    return f
end
local function event_count(f,name)
    local count=0;for _,e in ipairs(f.events)do if e.event==name then count=count+1 end end;return count
end
local final_disks={}
for _,coalesce in ipairs({true,false}) do
    local f=fixture(coalesce,false)
    assert(#f.calls==0 and #f.events==0,'construction inert')
    assert(f:run()=='ready' and f.submits==6 and event_count(f,'saved')==2)
    for _,h in ipairs(f.owners)do assert(h.a==3 and h.c==3 and not h.cleaned)end
    assert(f.trial:quit(4) and f.trial:status().state=='passed' and f.submits==10)
    for _,h in ipairs(f.owners)do assert(h.a==5 and h.c==5 and h.drained and h.cleaned and h.gen==(coalesce and 3 or 5))end
    assert(event_count(f,'quit_preflight')==1 and event_count(f,'drained')==2 and event_count(f,'passed')==1)
    local n=#f.calls;assert(not f.trial:quit(4) and not f.trial:poll() and #f.calls==n,'one-shot')
    local calls,saved,preflight={},0,false
    for _,e in ipairs(f.events)do
        if e.event=='call' then
            calls[e.sequence]=e
            assert(e.count==6 and e.thread==10 and not e.threw and not e.decode_error)
            if e.command==5 and e.payload_revision>=4 then assert(preflight,'preflight before any Quit edit')end
        elseif e.event=='saved' then
            saved=saved+1
            assert(e.revision==3 and e.accepted==3 and e.committed==3 and e.state=='saved')
            local raw=calls[e.native_sequence];assert(raw.command==6 and raw.result_fields[4]=='3' and raw.result_fields[5]=='3')
        elseif e.event=='ready' then assert(saved==2)
        elseif e.event=='quit_preflight' then assert(e.reason==4 and e.game_thread==10);preflight=true
        elseif e.event=='drained' then
            local raw=calls[e.native_sequence];assert(raw.command==8 and raw.result_fields[4]=='5' and raw.result_fields[5]=='5' and e.cleaned)
        end
    end
    final_disks[#final_disks+1]=copy(f.disk)
    local r=fixture(coalesce,true,f.disk)
    assert(r:run()=='passed' and r.submits==0 and r.updates==0)
    assert(event_count(r,'initialized')==0 and event_count(r,'submitted')==0 and event_count(r,'ready')==0)
    for _,e in ipairs(r.events)do
        if e.event=='saved'then assert(e.revision==0 and e.accepted==0 and e.committed==0)end
        if e.event=='recovered'then assert(e.revision==0 and e.body==Trial.fixtures()[e.stream].bodies[5])end
    end
    for _,h in ipairs(r.owners)do assert(h.drained and h.cleaned)end
end
-- The two mixed schedules both end at generation4 with different older slots.
for _,schedule in ipairs({{before=true,after=false},{before=false,after=true}})do
    local f=fixture(schedule,false);assert(f:run()=='ready')
    assert(f.trial:quit(4) and f.trial:status().state=='passed')
    for _,h in ipairs(f.owners)do assert(h.gen==4 and h.cleaned)end
    local r=fixture(true,true,f.disk);assert(r:run()=='passed' and r.updates==0)
end
-- Both native scheduling outcomes preserve explicit marker values without
-- touching mutable production module tables or paths.
assert(Store.data==before_store and Caps.data==before_caps)
do
    local a=Trial.fixtures();a.priorities.bodies[1]='changed'
    assert(Trial.fixtures().priorities.bodies[1]~='changed')
    assert(Trial.fixtures().priorities.bodies[5]:find('trial%-pal|6|X'))
    assert(Trial.fixtures().limits.bodies[5]:find('|Stone|OFF',1,true))
end
-- Failures after acceptance retain, never retry; diagnostic command6 only after
-- the first failure. Test ready Quit failures separately from startup failures.
for _,failure in ipairs({'lost_init','bad_owner','bad_thread','bad_count','bad_payload','drain_count','drain_phase','cleanup','quit_lost'})do
    local f=fixture(true,false,nil,function(cmd,r,s,h)
        if failure=='lost_init' and cmd==5 and h.a==1 then error('lost init reply')end
        if failure=='bad_owner' and cmd==3 then local a=Wire.unpack(r[2],16);a[1]='foreign';r[2]=Wire.pack(a)end
        if failure=='bad_thread' and cmd==3 then r[3]=20 end
        if failure=='bad_count' and cmd==5 then r[7]='extra' end
        if failure=='bad_payload' and cmd==3 then local a=Wire.unpack(r[2],16);a[13]='unexpected';r[2]=Wire.pack(a)end
        if failure=='drain_count' and cmd==8 then local a=Wire.unpack(r[2],16);a[5]='4';r[2]=Wire.pack(a)end
        if failure=='drain_phase' and cmd==8 then local a=Wire.unpack(r[2],16);a[6]='blocked';a[7]='uncertain';r[2]=Wire.pack(a)end
        if failure=='cleanup' and cmd==9 then error('lost cleanup return')end
        if failure=='quit_lost' and cmd==5 and h.a==4 then error('lost Quit submit reply')end
    end)
    f.trial:start()
    for _=1,16 do if f.trial:status().state~='running'then break end;f.trial:poll()end
    if f.trial:status().state=='ready'then f.trial:quit(4)end
    assert(f.trial:status().state=='failed' and event_count(f,'passed')==0,failure)
    assert(event_count(f,'failed')==1,failure)
    local n=#f.calls;assert(not f.trial:poll() and not f.trial:quit(4) and #f.calls==n)
    for _,e in ipairs(f.events)do if e.event=='call' and e.diagnostic then assert(e.command==6)end end
end
do
    local f=fixture(true,false);assert(f:run()=='ready');f.thread=20
    assert(not f.trial:quit(4) and f.submits==6,'wrong Quit thread no admissions')
    f=fixture(true,false);assert(f:run()=='ready');assert(not f.trial:quit(3) and f.submits==6)
end
for _,event in ipairs({'bound','initialized','recovered','submitted','saved','ready','quit_preflight','drained'})do
    local f=fixture(true,false)
    f.on_report=function(e)if e.event==event then f.trial:poll()end end
    f.trial:start()
    for _=1,16 do if f.trial:status().state~='running'then break end;f.trial:poll()end
    if f.trial:status().state=='ready'then f.trial:quit(4)end
    assert(f.trial:status().state=='failed' and event_count(f,'passed')==0,'report reentry '..event)
end
do
    local f=fixture(true,false);f.hold=true;assert(f.trial:start());f.time=121
    assert(not f.trial:poll() and f.submits==0,'startup timeout')
    f=fixture(true,false);assert(f:run()=='ready');f.time=1801
    assert(not f.trial:quit(4) and f.submits==6,'Quit timeout')
    f=fixture(true,false);assert(f.trial:start());f.time=-1;assert(not f.trial:poll())
    f=fixture(true,false);f.hold=true;assert(f.trial:start())
    for _=1,512 do assert(f.trial:poll() and f.trial:status().state=='running')end
    assert(not f.trial:poll() and f.trial:status().state=='failed' and f.submits==0,
        'stalled native worker terminates at finite poll cap even with frozen clock')
    local count=#f.calls;assert(not f.trial:poll() and #f.calls==count,'failed harness stops polling native')
end
for _,mode in ipairs({'empty','missing_slot','unsupported_older','not_latest5','write_on_existing'})do
    local disk=copy(final_disks[1]);local recovery=true
    if mode=='empty'then disk={}
    elseif mode=='missing_slot'then disk.priorities[2]=nil
    elseif mode=='unsupported_older'then disk.priorities[2].payload='unsupported'
    elseif mode=='not_latest5'then disk.priorities[1].payload=Trial.fixtures().priorities.payloads[4]
    else recovery=false end
    local f=fixture(true,recovery,disk);f.trial:start()
    for _=1,8 do if f.trial:status().state~='running'then break end;f.trial:poll()end
    assert(f.trial:status().state=='failed' and f.submits==0 and f.updates==0,mode)
end
print('native settings full chain: both schedules, ready3/Quit5, fresh typed recovery, native tracing, failure retention and control preflight passed')
