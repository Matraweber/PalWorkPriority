-- Offline only: real panel + remote adapters, synthetic file/clock/thread queue.
dofile(TEST_ROOT .. '/tests/test_panel_render.lua')
local panel, session = require('panel'), require('session')
package.loaded.reload={now=function() end}
local messages={}
package.loaded.log={say=function(s) messages[#messages+1]=s end,
    warn=function(s) messages[#messages+1]='WARN '..s end}
local now, contents = 0, 'initial\nopen\n'
local real_clock,real_open=os.clock,io.open
os.clock=function() return now end
io.open=function() return {read=function() return contents end,close=function() return true end} end
package.loaded.remote=nil
local remote=require('remote'); remote.path='synthetic-not-a-file'
panel.close()
local queued={}
ExecuteInGameThread=function(fn) queued[#queued+1]=fn end
local function poll(text)
    now=now+2
    contents=tostring(now)..'\n'..text..'\n'
    remote.poll()
end
now=2; remote.poll(); remote.drain()
assert(not panel.open, 'startup replayed stale control instructions')
poll('open\nopen')
assert(not panel.open, 'poll performed panel mutation outside drain')
for _,line in ipairs(messages) do
    assert(not line:find('panel is now',1,true), 'request logged completion before execution')
end
remote.drain()
assert(panel.open and #queued==0, 'drain did not finish the explicit open request on its game thread')
local generation=require('overlay').generation
poll('open');remote.drain()
assert(panel.open and require('overlay').generation==generation, 'repeated open toggled/recreated panel')
poll('close\nopen\nclose');remote.drain()
assert(not panel.open and #queued==0, 'latest desired state did not win within the batch')
poll('open');session.begin('different test world');remote.drain()
assert(not panel.open, 'old-world open request followed the player into another world')
assert(messages[#messages]:find('session changed',1,true), 'cancelled request had no diagnostic')
local overlay=require('overlay');local show=overlay.show
overlay.show=function() return false end
poll('open');remote.drain()
assert(not panel.open, 'failed opening was reported as open')
assert(messages[#messages]:find('could not open',1,true), 'failed open lacked failure report')
overlay.show=function() error('native creation failed') end
poll('open');remote.drain()
assert(not panel.open and not overlay.open, 'throwing opening left a phantom panel')
assert(messages[#messages]:find('could not open',1,true))
overlay.show=show
poll('open');remote.drain()
assert(panel.open, 'a failed opening poisoned the next request')
local hide=overlay.hide
overlay.hide=function() overlay.open=false;overlay.phase='close_failed';return false end
poll('close');remote.drain()
assert(messages[#messages]:find('could not close',1,true), 'failed detach claimed complete close')
overlay.hide=function() hide();overlay.phase='closed';return true end
poll('close');remote.drain()
assert(messages[#messages]=='panel is now closed' and overlay.phase=='closed',
    'repeated close failed to retry incomplete native cleanup')
overlay.hide=hide
-- The last explicit desired state also supersedes older queued toggles.
panel.toggle()
assert(not panel.open and #queued>0)
poll('close');remote.drain()
for _,fn in ipairs(queued) do fn() end
queued={}
assert(not panel.open, 'older queued toggle undid a confirmed closed state')
poll('open\nmode item');remote.drain()
for _,fn in ipairs(queued) do fn() end
queued={}
assert(panel.open and panel.command({},'state'):find('screen=item',1,true),
    'combined open/mode request lost its screen change')
panel.close()
poll('open');remote.drain()
for _,fn in ipairs(queued) do fn() end
queued={}
assert(panel.open, 'older queued close undid a confirmed open state')
poll('mode rubbish')
assert(messages[#messages]:find('no such screen',1,true), 'invalid mode was reported as queued success')
poll('mode item')
assert(messages[#messages]:find('requested',1,true), 'queued screen change claimed completion')
remote.drain()
assert(panel.command({},'state'):find('screen=item',1,true))
local _,_,fresh=overlay.host()
fresh.cancel_requested=true
poll('mode list');remote.drain()
assert(not panel.open, 'screen request ignored an earlier native Cancel')
assert(messages[#messages]:find('could not change screen',1,true), 'cancelled screen request claimed completion')
local previous_in_action
for i=1,100 do
 local name,value=debug.getupvalue(panel.refresh,i)
 if name=='RB' then previous_in_action=value.runtime.in_action;break end
end
assert(previous_in_action~=true, 'synchronous control left the action guard set')

-- Failed console dispatch is not successful execution, and old-session
-- pending console text cannot run after a world transition.
local api=require('palapi');local calls=0
api.player_controller=function() return {} end;api.valid=function() return true end
local cdo=api.cdo
api.cdo=function(path)
 if path:find('KismetSystemLibrary',1,true) then
  return {ExecuteConsoleCommand=function() calls=calls+1;error('adapter refused') end}
 end
 return cdo(path)
end
poll('cmd stat unit');remote.drain()
assert(calls==1 and messages[#messages]:find('failed',1,true), 'failed console call claimed success')
poll('cmd stat unit');session.begin('next world');remote.drain()
assert(calls==1, 'old-session console command executed')
os.clock,io.open=real_clock,real_open
ExecuteInGameThread=nil
