local session=require('session')
local n=0
session.begin('same-map')
session.enqueue(function() n=n+1 end,true)
local old=session.guard(function() n=n+100 end)
session.begin('same-map')
session.drain(); old()
assert(n==0,'same-name reconnect retained old callbacks')
session.enqueue(function() n=n+1 end,true)
session.invalidate_ui(); session.drain()
assert(n==0,'closed UI retained pending action')
session.enqueue(function() n=n+2 end,false)
session.drain()
assert(n==2)

-- The fast main beat must be able to inspect an empty queue without invoking it.
assert(not session.has_pending())
local events={}
session.enqueue(function()
    events[#events+1]='first'
    session.enqueue(function() events[#events+1]='next beat' end,true)
end,true)
session.enqueue(function() events[#events+1]='second' end,true)
assert(session.has_pending())
session.drain()
assert(table.concat(events,',')=='first,second' and session.has_pending(),
    'drain swallowed/reordered actions added during the snapshot')
session.drain()
assert(table.concat(events,',')=='first,second,next beat' and not session.has_pending())

session.enqueue(function() events[#events+1]='close'; session.invalidate_ui() end,true)
session.enqueue(function() error('cancelled UI action ran') end,true)
session.enqueue(function() events[#events+1]='maintenance' end,false)
session.drain(error)
assert(events[#events-1]=='close' and events[#events]=='maintenance' and not session.has_pending())

local errors=0
session.enqueue(function() error('expected action failure') end,true)
session.enqueue(function() events[#events+1]='survived' end,true)
session.drain(function() errors=errors+1 end)
assert(errors==1 and events[#events]=='survived' and not session.has_pending())

local count=0
for _=1,128 do assert(session.enqueue(function() count=count+1 end,true)) end
assert(not session.enqueue(function() count=count+1000 end,true),'bounded queue silently overflowed')
session.drain()
assert(count==128 and not session.has_pending(),'bounded FIFO lost accepted actions')

-- Slow edits yield between actions, retaining FIFO and the 128-action bound.
local now=0
os.clock=function() return now end
session.begin('budgeted')
events={}
session.enqueue(function()
    events[#events+1]='first'; now=now+.020
    session.enqueue(function() events[#events+1]='new' end,true)
end,true)
session.enqueue(function() events[#events+1]='second' end,true)
session.drain(error,8)
assert(table.concat(events,',')=='first' and session.has_pending(),'input burst still monopolizes one callback')
session.drain(error,8)
assert(table.concat(events,',')=='first,second,new','yield reordered accepted input')

session.enqueue(function() now=now+.020; session.invalidate_ui() end,true)
session.enqueue(function() error('old UI action survived budget yield') end,true)
session.drain(error,8); session.drain(error,8)
session.enqueue(function()
    now=now+.020; session.begin('new-world')
    session.enqueue(function() events[#events+1]='new-world' end,true)
end,true)
session.enqueue(function() error('old session action survived budget yield') end,true)
session.drain(error,8); session.drain(error,8)
assert(events[#events]=='new-world')

local accepted=0
session.enqueue(function()
    for _=1,200 do if session.enqueue(function() end,true) then accepted=accepted+1 end end
    now=now+.020
end,true)
for _=1,127 do session.enqueue(function() end,true) end
session.drain(error,8)
assert(accepted==1,'yielding drain let nested enqueues bypass the queue bound')
session.drain(error,8)
