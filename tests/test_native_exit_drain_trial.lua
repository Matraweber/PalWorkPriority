local Trial=dofile(TEST_ROOT..'/experiments/native_exit_drain_trial.lua')
local Wire=dofile(TEST_ROOT..'/experiments/save_native_backend.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local W,G=string.rep('3',32),string.rep('4',32)
do
    local v2=Trial.fixtures(2)
    for _,stream in ipairs({'priorities','limits'})do
        local f=v2[stream]
        assert(f.storage==string.rep('5',32) and f.guild==string.rep('6',32))
        local codec=Codec.new{storage=f.storage,guild=f.guild,stream=stream}
        for _,p in ipairs(f.payloads)do assert(codec.decode(p))end
    end
    assert(not pcall(Trial.fixtures,3))
end
local function fixture(coalesce,pending,mutate)
    local f={handles={},events={},calls={},time=0,tick=0,thread=10,updates=0,releases=0}
    local function native(command,id,ticket,hex,n)
        assert(#hex==n)
        local raw=hex:gsub('..',function(b)return string.char(tonumber(b,16))end)
        local args=Wire.unpack(raw,command==1 and 5 or (command==4 or command==5) and 1 or 0)
        f.tick=f.tick+2
        f.calls[#f.calls+1]={command=command,id=id,ticket=ticket}
        local result={1,'',f.thread,f.tick,f.tick+1,1000}
        if f.thread~=10 then result[1]=0;return table.unpack(result)end -- actual bridge route first
        local h=f.handles[id]
        if command==1 then
            assert(args[1]==W and args[2]==G and id==1 and ticket==0)
            id=#f.handles+1
            h={stream=args[3],scope='PWP-SCOPE-1:'..W..':'..G..':'..args[3],inc=args[4],
                accepted=0,committed=0,gen=0,phase='dormant',ticket=0,command=0,revision=0,
                payloads={},polls=0,terminal='recovered'}
            f.handles[id]=h;result[2]=Wire.pack({tostring(id)})
        else
            assert(h and not h.released)
            if command==2 or command==4 or command==5 or command==8 then
                assert(ticket==h.ticket+1);h.ticket=ticket;h.command=command;h.revision=0
            else assert(ticket==0)end
            if command==2 then h.phase='awaiting_validation'
            elseif command==3 then
                result[2]=Wire.pack({h.scope,h.inc,'1','recovered','1','0','0','token','0','0',
                    'missing','0','','missing','0',''})
            elseif command==4 then assert(args[1]=='initialize_missing');h.phase='ready'
            elseif command==5 then
                assert(h.phase=='ready');h.accepted=h.accepted+1;h.revision=h.accepted
                h.payloads[h.accepted]=args[1];f.updates=f.updates+1
                assert(Codec.new{storage=W,guild=G,stream=h.stream}.decode(args[1]))
                result[2]=Wire.pack({tostring(h.accepted)})
            elseif command==6 or command==8 then
                if h.accepted==1 then
                    h.polls=h.polls+1
                    if h.polls>=2 then h.committed=1;h.gen=1;h.terminal='initialized'end
                elseif h.accepted==3 and (command==8 or not pending)then
                    h.committed=3;h.gen=coalesce and 2 or 3;h.terminal='updated'
                end
                if command==8 then h.phase='closed'end
                result[2]=Wire.pack({h.scope,h.inc,'1',tostring(h.accepted),tostring(h.committed),h.phase,'none',
                    tostring(h.gen),'0',h.terminal,'1','0',tostring(h.ticket),tostring(h.command),tostring(h.revision),'accepted'})
            elseif command==9 then assert(h.phase=='closed');h.released=true;f.releases=f.releases+1
            else error('unexpected command')end
        end
        if mutate then mutate(command,result,f,h)end
        return table.unpack(result)
    end
    f.trial=Trial.new{native=native,clock=function()return f.time end,game_thread=10,boot='test',
        report=function(e)f.events[#f.events+1]=e;if f.on_report then f.on_report(e)end end}
    function f:ready()
        self.trial:start()
        for _=1,12 do if self.trial:status().state~='starting'then break end;self.trial:poll()end
        return self.trial:status().state
    end
    return f
end
local expected=Trial.fixtures()
for _,stream in ipairs({'priorities','limits'})do
    local codec=Codec.new{storage=W,guild=G,stream=stream}
    for i=1,3 do
        local decoded=assert(codec.decode(expected[stream].payloads[i]))
        if stream=='limits'then assert(decoded.data[G].Mining.Stone==false and decoded.data[G].Mining.Ore==100*i and not decoded.data[string.rep('2',32)])end
    end
end
for _,coalesce in ipairs({true,false})do for _,pending in ipairs({true,false})do
    local f=fixture(coalesce,pending)
    assert(#f.calls==0 and f:ready()=='ready' and f.updates==2 and f.releases==0)
    for _,h in ipairs(f.handles)do assert(h.accepted==1 and h.committed==1 and h.gen==1 and not h.released)end
    local before=#f.calls;assert(not f.trial:quit(1) and not f.trial:quit('4') and #f.calls==before)
    assert(f.trial:quit(4) and f.trial:status().state=='passed' and f.updates==6 and f.releases==2)
    assert(f.calls[before+1].command==6 and f.calls[before+2].command==6,'both route checks precede mutations')
    local observations=0
    for _,e in ipairs(f.events)do
        if e.event=='pending-observation'then observations=observations+1;assert(e.pending_observed==pending)end
        if e.event=='call'then assert(type(e.fields)=='table' and e.scope:find(W,1,true) and e.incarnation:find('-exit-',1,true))end
    end
    assert(observations==2 and f.events[#f.events].shutdown_route_verified==false)
    for _,h in ipairs(f.handles)do
        assert(h.gen==(coalesce and 2 or 3) and h.committed==3 and h.released)
        for i=1,3 do assert(h.payloads[i]==expected[h.stream].payloads[i])end
    end
    before=#f.calls;assert(not f.trial:quit(4) and not f.trial:start() and not f.trial:poll() and #f.calls==before)
end end
do
    local f=fixture(true,true);assert(f:ready()=='ready');local before=f.updates
    f.thread=20;assert(not f.trial:quit(4) and f.trial:status().state=='failed')
    assert(f.updates==before and f.releases==0 and f.calls[#f.calls].command==6)
    local calls=#f.calls;f.thread=10;assert(not f.trial:quit(4) and #f.calls==calls)
    for _,e in ipairs(f.events)do assert(e.event~='quit-observed' and e.event~='passed')end
    f=fixture(true,true);assert(not f.trial:quit(4) and f.trial:status().state=='failed' and #f.calls==0)
    f=fixture(true,true);assert(f.trial:start());assert(not f.trial:quit(4) and f.updates==0 and f.releases==0)
end
local failures=0
do
    local f=fixture(true,true,function(c,r,_,h)
        if c==6 and h.committed==0 then
            local s=Wire.unpack(r[2],16);s[10]='initialized';r[2]=Wire.pack(s)
        end
    end)
    assert(f:ready()=='ready' and f.trial:quit(4),'terminal-before-consume race is not a premature ACK or false failure')
end
local function bad(mutant,quit)
    local f=fixture(true,true,mutant)
    f:ready();if quit and f.trial:status().state=='ready'then f.trial:quit(4)end
    assert(f.trial:status().state=='failed' and f.releases==0)
    local calls=#f.calls;assert(not f.trial:quit(4) and not f.trial:poll() and #f.calls==calls)
    for _,e in ipairs(f.events)do assert(e.event~='passed')end
    failures=failures+1
end
for _,field in ipairs({1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16})do
    bad(function(c,r,_,h)if c==6 and h.committed==1 then local s=Wire.unpack(r[2],16);s[field]='invalid';r[2]=Wire.pack(s)end end)
end
for _,field in ipairs({1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16})do
    bad(function(c,r)if c==3 then local s=Wire.unpack(r[2],16);s[field]=field==8 and '' or 'invalid';r[2]=Wire.pack(s)end end)
end
for _,field in ipairs({1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16})do
    bad(function(c,r)if c==8 then local s=Wire.unpack(r[2],16);s[field]='invalid';r[2]=Wire.pack(s)end end,true)
end
for _,command in ipairs({1,2,4,5,8})do
    bad(function(c)if c==command then error('lost reply after native effect')end end,command==8)
end
bad(function(c,r,_,h)if c==5 and h.accepted==2 then error('lost accepted tail reply')end end,true)
bad(function(c,r,_,h)if c==5 and h.accepted==3 then r[2]=Wire.pack({'2'})end end,true)
bad(function(c,r,_,h)if c==6 and h.accepted==3 then r[3]=11 end end,true)
do
    local armed=false
    local f=fixture(true,true,function(c,r,_,h)
        if armed and c==6 and h.stream=='limits'then r[3]=20 end
    end)
    assert(f:ready()=='ready');armed=true
    assert(not f.trial:quit(4) and f.updates==2 and f.releases==0,'second owner route check also precedes all tail mutations')
    f=fixture(true,true,function(c)if c==9 then error('lost cleanup reply')end end)
    assert(f:ready()=='ready' and not f.trial:quit(4) and f.trial:status().state=='failed')
    assert(f.releases==1,'first known closed cleanup may have happened, never repeat it')
    local n=#f.calls;assert(not f.trial:quit(4) and #f.calls==n)
end
do
    local f=fixture(true,true);assert(f:ready()=='ready')
    f.on_report=function(e)if e.event=='quit-observed'then f.trial:quit(4)end end
    assert(not f.trial:quit(4) and f.updates==2 and f.releases==0 and f.trial:status().state=='failed')
    f=fixture(true,true);f.on_report=function(e)if e.event=='bound'then f.trial:poll()end end
    assert(f:ready()=='failed' and f.updates==0)
    f=fixture(true,true);assert(f.trial:start());f.time=121;assert(not f.trial:poll() and f.trial:status().state=='failed')
    f=fixture(true,true);assert(f:ready()=='ready');f.on_report=function(e)if e.event=='pending-observation'then error('sink failure')end end
    assert(not f.trial:quit(4) and f.releases==0)
end
print('exit drain trial: scope3/guild4 real codecs, retained ready owners, Quit4 thread gate, both schedules/pending observations, '..failures..' fail-stop regressions passed')
