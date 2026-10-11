local path = TEST_ROOT .. '/experiments/native-lua-handoff-probe/warm.lua'
local function fixture(mode)
    local f = {now=0, queue={}, loads=0, runs={}, logs={}, driverloads=0}
    local files = {['/probe/warm-run.txt']='PWP_HANDOFF_WARM test-nonce\n'}
    local env = setmetatable({}, {__index=_G}); env._G=env
    env.debug={getinfo=function() return {source='@/probe/warm.lua'} end}
    env.print=function() end
    env.io={open=function(name, access)
        if access=='r' and not files[name] then return nil end
        if access=='w' then files[name]='' end
        local pos=1
        return {read=function(_, count)
            local data=files[name]
            if pos>#data then return nil end
            local result=data:sub(pos,pos+count-1); pos=pos+#result; return result
        end, write=function(_, value)
            files[name]=(files[name] or '')..value
            if name=='/probe/warm.log' then f.logs[#f.logs+1]=value end
            return true
        end, close=function() return true end}
    end}
    local sequence=0
    local function enqueue(ms, fn)
        assert(ms>=0 and ms<=90000)
        sequence=sequence+1
        f.queue[#f.queue+1]={at=f.now+ms,seq=sequence,fn=fn}
    end
    env.ExecuteInGameThreadWithDelay=function(ms,fn)
        if mode=='scheduler throws' then error('scheduler throws') end
        enqueue(ms,fn)
    end
    env.ExecuteInGameThread=function(fn) enqueue(0,fn) end
    env.ExecuteAsync=function(fn) enqueue(0,fn) end
    local native=function() end
    env.package={loadlib=function(name, symbol)
        assert(f.now>=90000 and files['/probe/warm-run.txt']=='DISABLED\n')
        assert(name=='/probe/pwp_handoff_probe_v2.dll' and symbol=='luaopen_pwp_handoff_probe')
        f.loads=f.loads+1
        if mode=='loader throws' then error('loader throws') end
        return native
    end}
    env.dofile=function(name)
        assert(name=='/probe/driver.lua' and f.now>=90000)
        f.driverloads=f.driverloads+1
        return {run=function(d,g,input)
            f.runs[#f.runs+1]=f.now
            assert(d.native==native and g.active and #input==512*1024)
            if mode=='driver throws' then error('driver throws') end
            d.delay(200,function() d.async(function()
                if mode=='callback throws' then error('callback throws') end
                d.game(function()
                    d.diagnostic('raw evidence')
                    if mode=='stale in flight' then g.active=false end
                    if mode=='fail' then d.report(false,'injected failure')
                    else d.report(true,'synthetic pass') end
                    d.report(true,'duplicate must not schedule')
                end)
            end) end)
        end}
    end
    f.env, f.files=env,files
    function f:load() assert(loadfile(path,'t',env))() end
    function f:pump(until_ms)
        local steps=0
        while true do
            table.sort(self.queue,function(a,b) return a.at==b.at and a.seq<b.seq or a.at<b.at end)
            local next=self.queue[1]
            if not next or next.at>until_ms then break end
            table.remove(self.queue,1); self.now=next.at; next.fn()
            steps=steps+1; assert(steps<100,'unbounded callbacks')
        end
        self.now=until_ms
    end
    function f:count(kind)
        local n=0
        for _,line in ipairs(self.logs) do
            assert(line:find('test-nonce trial=',1,true))
            if line:find(' '..kind..' ',1,true) then n=n+1 end
        end
        return n
    end
    return f
end
local f=fixture('pass'); f:load(); f:load()
assert(f.files['/probe/warm-run.txt']=='DISABLED\n' and f:count('ARMED')==1)
f:pump(89999)
assert(f.loads==0 and f.driverloads==0 and #f.runs==0,'loaded/ran before warm delay')
f:pump(90000); assert(#f.runs==1)
f:pump(100199); assert(#f.runs==1)
f:pump(100200); assert(#f.runs==2)
f:pump(200000)
assert(#f.runs==3 and f.runs[3]==110400 and #f.queue==0)
assert(f.loads==1 and f.driverloads==1 and f:count('PASS')==3 and f:count('DIAG')==3
    and f:count('START')==3 and f:count('FAIL')==0)
for _,mode in ipairs({'fail','loader throws','driver throws','callback throws','scheduler throws','stale in flight'}) do
    f=fixture(mode); f:load(); f:pump(200000)
    assert(f:count('FAIL')==1 and f:count('PASS')==0 and #f.runs<=1,'failure did not stop: '..mode)
end
f=fixture('pass'); f:load(); f.env.PWP_HANDOFF_WARM_GENERATION.active=false; f:pump(200000)
assert(f:count('FAIL')==1 and f.loads==0 and #f.runs==0,'stale queued run executed')
f=fixture('pass'); f:load(); f:pump(90200)
f.env.PWP_HANDOFF_WARM_GENERATION={active=true}; f:pump(200000)
assert(f:count('FAIL')==1 and #f.runs==1,'replaced generation continued')
print('warm adapter: delayed load, 3 sequential trials, retained native, disarm, failures, stale generations and throws passed')
