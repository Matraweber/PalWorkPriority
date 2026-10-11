package.loaded.log={warn=function()end,error=function()end,say=function()end}
local Gate=require('settings_gate')
local Data=require('datafile')
local Store,Caps=require('store'),require('caps')
local fs=require('memory_fs')();Data.fs=fs
assert(Data.write('priorities',assert(Store.serialize_snapshot({pal={[1]=false,[2]=3}},true)),0))
assert(Data.write('caps',assert(Caps.serialize_snapshot({guild={Mining={Stone=100}}})),0))
Store.load('priorities');Caps.load('caps');Store.set_role('authority');Caps.set_role('authority','session')
local before_p,before_c,io=Store.serialize(),Caps.serialize(),#fs.operations
local sends,notices=0,0
Store.submit=function()sends=sends+1 end;Caps.submit=Store.submit
Store.on_change=function()notices=notices+1 end;Caps.on_change=Store.on_change
assert(not Gate.blocked() and not Gate.release(nil))
local owner=assert(Gate.acquire());assert(Gate.held(owner) and Gate.blocked())
assert(not Gate.acquire() and not Gate.release(function()end))
for _,call in ipairs({
    function()return Store.save()end,function()return Store.flush(nil,true)end,
    function()return Store.poll_persistence()end,function()return Caps.poll_persistence()end,
    function()return Store.set('pal',1,4)end,function()return Store.clear('pal',1)end,
    function()return Store.apply_set('pal',1,4)end,function()return Store.apply_clear('pal',1)end,
    function()return Store.capture_baseline('new',{[1]=true},{})end,
    function()return Caps.save()end,function()return Caps.flush()end,
    function()return Caps.set('Mining','Stone',200,'guild')end,
    function()return Caps.clear('Mining','Stone','guild')end,
    function()return Caps.apply_set('Mining','Stone',200,'guild')end,
    function()return Caps.apply_clear('Mining','Stone','guild')end,
})do local yes,why=call();assert(yes==false and why=='settings_recovering')end
local n,why=Store.load('wrong');assert(n==0 and why=='settings_recovering')
n,why=Caps.load('wrong');assert(n==0 and why=='settings_recovering')
n,why=Caps.adopt_wildcard('guild');assert(n==0 and why=='settings_recovering')
assert(Store.serialize()==before_p and Caps.serialize()==before_c and #fs.operations==io and sends==0 and notices==0)
assert(Caps.view_status()=='unavailable')
-- The scheduler must refuse before any engine operation or settings flush.
package.loaded.palapi=setmetatable({},{__index=function(_,name)error('unexpected engine API '..name)end})
local scheduler=require('scheduler')
local stats=scheduler.run_pass({});assert(stats.blocked and stats.blocked_reason=='settings recovery is in progress')
stats=scheduler.restore({});assert(stats.blocked and stats.blocked_reason=='settings recovery is in progress')
assert(#fs.operations==io)
assert(Gate.release(owner) and not Gate.blocked())
Store.submit,Caps.submit=nil,nil
assert(Store.set('pal',1,4));assert(Caps.apply_set('Mining','Stone',200,'guild'))
assert(Gate.status()=='ready')
local replacement=assert(Gate.acquire());assert(not Gate.release(owner) and Gate.held(replacement))
assert(Gate.status()=='recovering')
assert(not Gate.require_restart(owner) and Gate.status()=='recovering')
assert(Gate.require_restart(replacement) and Gate.status()=='restart_required')
local status,detail=Caps.view_status()
assert(status=='unavailable' and detail:find('Restart the game',1,true),
    'terminal fence must explain restart, not promise ongoing recovery')
local _,_,panel_detail=require('panel_status').save(Caps)
assert(panel_detail==detail,'limits panel must preserve the terminal reason')
stats=scheduler.run_pass({});assert(stats.blocked and stats.blocked_reason=='settings locked; restart the game')
stats=scheduler.restore({});assert(stats.blocked and stats.blocked_reason=='settings locked; restart the game')
assert(Gate.blocked() and not Gate.release(owner))
assert(Gate.release(replacement) and Gate.status()=='ready')
print('settings fence: both writers/mutators/loaders and scheduler blocked, no IO or sends, exact-owner release and unchanged dormant behavior passed')
