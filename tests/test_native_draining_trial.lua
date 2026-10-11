local Trial=dofile(TEST_ROOT..'/experiments/native_draining_trial.lua')
local Wire=dofile(TEST_ROOT..'/experiments/save_native_backend.lua')
local function fixture(coalesce,mutate)
    local f={handles={},disk={},events={},calls={},writes=0,time=0}
    local function native(command,id,ticket,hex,n)
        assert(n==#hex)
        local raw=hex:gsub('..',function(b)return string.char(tonumber(b,16))end)
        local args=Wire.unpack(raw,command==1 and 5 or (command==4 or command==5) and 1 or 0)
        local h=f.handles[id];local result={1,'',10,1,2,1000}
        f.calls[#f.calls+1]=command
        if command==1 then
            id=#f.handles+1
            f.handles[id]={stream=args[3],scope='PWP-SCOPE-1:'..args[1]..':'..args[2]..':'..args[3],
                inc=args[4],accepted=0,committed=0,gen=0,phase='dormant',payloads={}}
            result[2]=Wire.pack({tostring(id)})
        elseif command==2 then h.phase='awaiting_validation'
        elseif command==3 then
            local d=f.disk[h.stream] or {}
            local a,b=d.A,d.B
            local gen=math.max(a and a.gen or 0,b and b.gen or 0)
            result[2]=Wire.pack({h.scope,h.inc,'1','recovered','1',tostring(gen),'0','token','0','0',
                a and 'valid' or 'missing',a and tostring(a.gen) or '0',a and a.payload or '',
                b and 'valid' or 'missing',b and tostring(b.gen) or '0',b and b.payload or ''})
        elseif command==4 then assert(args[1]=='initialize_missing');h.phase='ready'
        elseif command==5 then
            assert(h.phase=='ready');h.accepted=h.accepted+1;h.payloads[h.accepted]=args[1];f.writes=f.writes+1
            result[2]=Wire.pack({tostring(h.accepted)})
        elseif command==8 then
            if h.accepted>0 then
                assert(h.accepted==3)
                h.gen=coalesce and 2 or 3
                f.disk[h.stream]={A={gen=coalesce and 1 or 3,payload=h.payloads[coalesce and 1 or 3]},
                    B={gen=2,payload=h.payloads[coalesce and 3 or 2]}}
            end
            h.committed=h.accepted;h.phase='closed'
            result[2]=Wire.pack({h.scope,h.inc,'1',tostring(h.accepted),tostring(h.committed),h.phase,
                'none',tostring(h.gen),'0','updated','1','0',tostring(ticket),'8','0','accepted'})
        elseif command==9 then assert(h.phase=='closed');h.released=true
        else error('unexpected command') end
        if mutate then mutate(command,result,f,h) end
        return table.unpack(result)
    end
    f.trial=Trial.new{native=native,game_thread=10,boot='test',clock=function()return f.time end,
        report=function(e)f.events[#f.events+1]=e;if f.on_report then f.on_report(e) end end}
    function f:run()
        self.trial:start()
        for _=1,8 do if self.trial:status().state~='running' then break end;self.trial:poll() end
        return self.trial:status()
    end
    return f
end
for _,coalesce in ipairs({true,false}) do
    local f=fixture(coalesce);assert(f:run().state=='passed' and f.writes==6)
    assert(#f.handles==4);for _,h in ipairs(f.handles)do assert(h.released)end
    assert(f.events[#f.events].shutdown_route_verified==false)
end
for _,mutant in ipairs({
    function(c,r)if c==5 then r[1]=0 end end,
    function(c,r)if c==8 then local f=Wire.unpack(r[2],16);f[5]='2';r[2]=Wire.pack(f)end end,
    function(c,r)if c==8 then local f=Wire.unpack(r[2],16);f[6]='blocked';r[2]=Wire.pack(f)end end,
    function(c,r)if c==3 then local f=Wire.unpack(r[2],16);f[1]='foreign';r[2]=Wire.pack(f)end end,
    function(c,r)if c==3 then local f=Wire.unpack(r[2],16);f[11]='unreadable';r[2]=Wire.pack(f)end end,
    function(c,r)if c==3 then local f=Wire.unpack(r[2],16);if f[11]=='valid' then f[13]='corrupt' end;r[2]=Wire.pack(f)end end,
    function(c,r)if c==5 then error('lost reply after admission')end end,
    function(c,r)if c==8 then r[3]=20 end end,
}) do local f=fixture(true,mutant);assert(f:run().state=='failed');for _,e in ipairs(f.events)do assert(e.event~='passed')end end
do
    local f=fixture(true);f.on_report=function(e)if e.event=='bound' then f.trial:poll()end end
    assert(f:run().state=='failed' and f.writes==0)
    local g=fixture(true);assert(g.trial:start());g.time=121;g.trial:poll();assert(g.trial:status().state=='failed')
end
print('native draining trial: both physical schedules, exact typed recovery, wrong owner/thread, failed drain, uncertainty/reentry fail closed')
