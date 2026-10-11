local log=require('log')
local measure=require('measurement')
local success=measure.callback('hook:test',function() return nil,false,3 end)
local a,b,c=success()
assert(a==nil and b==false and c==3)
local row=log.snapshot().rows[1]
assert(row.calls==1 and row.timed_samples==0 and row.total_ms==nil)
log.set_perf(true)
a,b,c=success()
assert(a==nil and b==false and c==3)
local failure=measure.callback('hook:error',function() error('failed callback') end)
assert(not pcall(failure))
local seen={}
for _,r in ipairs(log.snapshot().rows) do seen[r.name]=r end
assert(seen['hook:test'].timed_samples==1 and seen['hook:error'].timed_samples==1)
local m={fn=success}
assert(not measure.bind(m,'fn','double'), 'callback was instrumented twice')
