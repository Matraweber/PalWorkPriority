local time=1
local writes={}
local mode
local trace=require('frame_trace').new({clock=function() return time end,limit=2,seconds=5,
    open=function(path)
        if mode=='open' then return nil,'denied' end
        return {write=function(_,text)
            if mode=='write' then return nil,'full' end
            writes[path]=text; time=time+.001; return true
        end,close=function() if mode=='close' then return nil,'failed' end; return true end}
    end})
trace:record('disabled',1,2); assert(#trace.events==0)
trace:start()
trace:record('tiny',1,1.001); assert(#trace.events==0)
trace:record('parent',1,1.020)
trace:record('child',1.002,1.012)
trace:record('bounded',1,1.010)
assert(#trace.events==2 and trace.dropped==1 and trace.events[2].first==1.002)
assert(trace:anchor('marker','start_1'))
assert(trace.anchors[1].first==1 and trace.anchors[1].last==1.001)
assert(writes.marker=='start_1\n')
assert(not trace:anchor('marker','start_1'))
assert(not trace:anchor('marker','../invalid'))
for _,failure in ipairs({'open','write','close'}) do mode=failure; assert(not trace:anchor('marker','failed_'..failure)) end
mode=nil
assert(#trace.anchors==1)
local failed_content=writes.marker
assert(not trace:anchor('marker','failed_close'))
assert(writes.marker==failed_content,'failed publication nonce was reused')
trace:record('expired',6,7); assert(not trace.enabled and trace.expired)
assert(trace:export('result')); assert(writes.result:find('#dropped\t1',1,true))
assert(writes.result:find('event\tparent\t1.000000000\t1.020000000',1,true))
time=10; trace:start(); assert(#trace.events==0 and #trace.anchors==0 and not trace.expired)
assert(not trace:anchor('marker','start_1'),'nonce reused across traces')
trace:record('old session',1,2); trace:record('rollback',12,11); trace:record('nan',10,0/0)
assert(#trace.events==0)
trace:stop(); trace:record('off',10,11); assert(#trace.events==0)
local observed={}
local perf=require('perf').new({clock=function() return time end,wall_clock=function() return time end,
    resolution_ms=1,on_finish=function(name,a,b) observed[#observed+1]={name,a,b} end})
perf:set_enabled(true)
local token=perf:begin('real interval'); time=10.02; perf:finish(token); perf:finish(token)
assert(#observed==1 and observed[1][1]=='real interval' and observed[1][2]==10 and observed[1][3]==10.02)
local stale=perf:begin('stale'); perf:reset(); perf:finish(stale); assert(#observed==1)
perf:observe('duration only',20); assert(#observed==1,'invented start for duration-only counter')
print('Frame trace: bounded intervals, commands-only writes, anchor failures and actual scope timestamps passed')
