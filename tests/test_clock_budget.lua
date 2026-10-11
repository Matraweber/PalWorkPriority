-- Real heartbeat under a deterministic runtime clock. No engine objects.
local function fixture()
    package.loaded.clock=nil
    local f={now=0,events={},warnings={}}
    os.clock=function() return f.now end
    package.loaded.log={say=function() end,count=function() end,
        begin=function() end,finish=function() end,
        warn=function(s) f.warnings[#f.warnings+1]=s end}
    package.loaded.palapi={pc_memo_begin=function() f.memo=true end,
        pc_memo_end=function() f.memo=false end}
    LoopInGameThreadWithDelay=function(ms,fn) assert(ms==100); f.tick=fn end
    ExecuteInGameThreadWithDelay=nil
    local clock=require('clock'); f.clock=clock
    clock.start()
    function f:run() self.now=self.now+.1; self.tick(); assert(not self.memo) end
    function f:job(name,cost)
        return function() self.events[#self.events+1]=name; self.now=self.now+(cost or 0)/1000 end
    end
    return f
end

local f=fixture()
f.clock.every('pass',100,f:job('pass',45),true)
f.clock.every('stand',100,f:job('stand',24),true)
f.clock.every('input',100,f:job('input'))
f:run()
assert(table.concat(f.events,',')=='input,pass','expensive jobs still share a beat')
f:run()
assert(table.concat(f.events,',')=='input,pass,input,stand','deferred stand starved or input waited')

f=fixture()
f.clock.every('input',100,f:job('input',20))
f.clock.defer('work',f:job('old'))
for _=1,2 do f:run(); f.clock.defer('work',f:job('latest')) end
assert(#f.events==2,'background job exceeded input budget early')
f:run()
assert(table.concat(f.events,',')=='input,input,input,latest','coalesced work starved or stale callback ran')

f=fixture()
f.clock.defer('repeat',function()
    f.events[#f.events+1]='first'
    f.clock.defer('repeat',f:job('second'))
end)
f:run(); f:run()
assert(table.concat(f.events,',')=='first,second','one-shot removal erased re-armed work')

f=fixture()
f.clock.every('reset',100,function() f.clock.reset() end)
f.clock.defer('old world',f:job('stale'))
f:run(); assert(#f.events==0,'world reset executed old due callback')
f.clock.cancel('reset'); f:run(); assert(#f.events==0,'world reset retained deferred callback')

f=fixture()
f.clock.every('replace',100,function()
    f.clock.every('target',100,f:job('new'),true)
    f.clock.cancel('replace')
end)
f.clock.every('target',100,f:job('old'),true)
f:run(); assert(#f.events==0,'replacement ran from old due snapshot')
f:run(); assert(f.events[1]=='new')

f=fixture()
f.clock.defer('bad',function() error('expected') end)
f.clock.defer('good',f:job('survived'))
f:run(); f:run()
assert(#f.warnings==1 and f.events[1]=='survived','error stopped scheduling or bypassed background limit')
print('PASS clock budgeting: collision, fairness, coalescing, reset, replacement and error recovery')
