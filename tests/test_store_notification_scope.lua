local fs = require('memory_fs')()
package.loaded.log = {warn=function() end,error=function() end}
local file = require('datafile'); file.fs=fs
local store = require('store')
store.load('priorities'); store.set_role('authority')
local notifications={}
store.on_change=function(key) notifications[#notifications+1]={key=key} end
assert(store.apply_set('PAL-A',1,2))
assert(store.apply_set('PAL-A',2,false))
local saved,scope=store.flush(nil,true,true)
assert(saved and scope and scope.key=='PAL-A' and not scope.full)
assert(#notifications==0,'deferred save called the normal notifier')
local clean,empty=store.flush(nil,true,true)
assert(clean and empty==nil,'clean flush reused an old scope')
assert(store.apply_set('PAL-A',1,3))
assert(store.apply_set('PAL-B',1,4))
fs.fault=function(op) return op=='write' end
assert(not store.flush(nil,true,true))
assert(#notifications==0)
fs.fault=nil
assert(store.flush(nil,true))
assert(#notifications==1 and notifications[1].key==nil,'retry lost multi-Pal scope or retained deferral')
assert(store.apply_set('PAL-B',1,5))
assert(store.apply_clear('PAL-A',3)) -- no-op must not erase B's pending change
saved,scope=store.flush(nil,true,true)
assert(saved and scope.key=='PAL-B')
assert(store.apply_set('PAL-A',1,1))
store.on_change=function(key)
    assert(key=='PAL-A')
    assert(store.apply_set('PAL-B',1,2)) -- starts a new dirty generation
end
assert(store.flush(nil,true))
saved,scope=store.flush(nil,true,true)
assert(saved and scope.key=='PAL-B','notification erased reentrant mutation')
assert(store.apply_set('PAL-A',1,2))
assert(store.apply_set('PAL-B',1,3))
saved,scope=store.flush(nil,true,true)
assert(saved and scope.full==true and scope.key==nil,'deferred multi-key commit narrowed its scope')
store.on_change=function()
    assert(store.apply_set('PAL-B',1,4))
    error('notification failed after another edit')
end
assert(store.apply_set('PAL-A',1,3)); assert(store.flush(nil,true))
saved,scope=store.flush(nil,true,true)
assert(saved and scope.key=='PAL-B','throwing callback erased its pending edit')
store.on_change=function(key) notifications[#notifications+1]={key=key} end
assert(store.set('PAL-A',1,false))
assert(notifications[#notifications].key=='PAL-A','local save omitted the changed key')
store.load('other'); store.set_role('authority')
local ok,none=store.flush(nil,true,true)
assert(ok and none==nil,'load retained a previous scope')
