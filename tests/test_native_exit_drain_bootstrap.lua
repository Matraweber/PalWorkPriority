local file=TEST_ROOT..'/experiments/native-exit-drain-live/main.lua'
local source=assert(io.open(file)):read('*a')
local function fixture(marker)
    local x={logs={},scheduled={},quits=0,reads=0,state='running',loads=0}
    local env=setmetatable({},{__index=_G})
    env.debug={getinfo=function()return {source='@fixture/main.lua'}end}
    env.package={path='',loadlib=function()x.loads=x.loads+1;return function()end end}
    env.io={open=function(path,mode)
        if mode=='r' then
            if marker==false then return end
            local n=0;return {read=function()n=n+1;if n==1 then return marker or 'PWP_EXIT_DRAIN_TRIAL fixture-1\n' end end,close=function()return true end}
        end
        return {write=function(_,s)
            if path:match('run.txt$') then x.disarmed=s else x.logs[#x.logs+1]=s end
            return true
        end,close=function()return true end}
    end}
    env.RegisterEndPlayPreHook=function(cb)x.callback=cb end
    env.ExecuteInGameThreadWithDelay=function(ms,cb)x.scheduled[#x.scheduled+1]={ms,cb}end
    env.dofile=function(path)
        if path:match('save_native_backend.lua$') then
            return {call=function()return {1,'root',7,1,2,1000}end,unpack=function()return {'1'}end}
        end
        assert(path:match('native_exit_drain_trial.lua$'))
        return {new=function(o)
            x.report=o.report
            return {start=function()return true end,poll=function()x.state='ready' end,
                status=function()return {state=x.state}end,
                quit=function(_,reason)assert(reason==4);x.quits=x.quits+1;x.state='passed' end}
        end}
    end
    assert(load(source,'@'..file,'t',env))()
    function x:fire(reason)
        self.callback(setmetatable({},{__index=function()error('actor accessed')end}),
            {get=function()self.reads=self.reads+1;return reason end})
    end
    function x:run()local q=table.remove(self.scheduled,1);assert(q);q[2]()end
    return x
end
do
    local x=fixture();assert(x.disarmed=='DISABLED\n' and #x.scheduled==1 and x.scheduled[1][1]==90000)
    x:fire(1);x:fire(0);assert(x.quits==0)
    x:run();x:run();assert(x.state=='ready' and #x.scheduled==0)
    x:fire(4);x:fire(4);assert(x.quits==1 and x.reads==3)
    assert(x.logs[#x.logs]:find('"state":"passed"',1,true))
end
do
    local x=fixture();x:fire(4);x:run();assert(x.loads==0 and x.quits==0)
    assert(x.logs[#x.logs]:find('bootstrap-failed',1,true))
end
for _,value in ipairs({false,'4',5,1.5})do
    local x=fixture();x:fire(value);x:run();assert(x.loads==0 and x.quits==0)
end
for _,marker in ipairs({false,'DISABLED\n','PWP_EXIT_DRAIN_TRIAL bad!\n'})do
    local x=fixture(marker);assert(not x.callback and #x.scheduled==0 and x.loads==0)
end
print('exit drain bootstrap: disarm, Quit one-shot, early/invalid callbacks, no actor retention passed')
