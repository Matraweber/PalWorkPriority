package.loaded.log = { debug=function() end, say=function() end, warn=function() end, error=function() end }
local file = require('datafile')
local create_fs = require('memory_fs')
local decode = function(s) if s == 'old' or s == 'new' then return s end return nil,'invalid' end
for _, fault in ipairs({'open','write','close','rename_old','rename_new','remove_backup'}) do
    local fs = create_fs()
    file.fs = fs
    assert(file.write('save','old',0))
    fs.files['save.bak'] = 'old'
    fs.fault = function(op,path)
        return (fault==op and path=='save.tmp')
            or (fault=='rename_old' and op=='rename' and path=='save>save.bak')
            or (fault=='rename_new' and op=='rename' and path=='save.tmp>save')
            or (fault=='remove_backup' and op=='remove' and path=='save.bak')
    end
    assert(file.write('save','new',1) == false, fault .. ' reported success')
    fs.fault = nil
    local value = file.read('save',decode)
    assert(value=='old' or value=='new', fault .. ' lost every valid generation')
    assert(fs.files.save or fs.files['save.bak'], fault .. ' destroyed previous generation')
end
-- Crash after verified temporary write and rotation: recover without truncation.
local fs = create_fs(); file.fs = fs
assert(file.write('save','old',0))
fs.fault=function(op,path) return op=='rename' and path=='save.tmp>save' end
assert(not file.write('save','new',1))
fs.fault=nil
local value,meta = file.read('save',decode)
assert(value=='new' and meta.recovered)
fs.files['save.tmp']=fs.files['save.tmp']:sub(1,-2)
assert(file.read('save',decode)=='old', 'truncated temporary generation was accepted')
fs.files['bad']='not a priority row'
assert(file.read('bad',decode)==nil, 'corrupt save was treated as empty')
local store=require('store')
store.load('priorities'); store.set_role('authority')
assert(not store.set('slot3',1,2), 'temporary Pal identity persisted')
assert(not store.set('guid',1,1.5), 'fraction accepted')
assert(store.set('guid',1,false)); assert(store.flush(nil,true))
fs.fault=function(op,path) return op=='write' and path=='priorities.tmp' end
assert(not store.set('guid',2,3)); assert(not store.flush(nil,true))
assert(store.state=='error')
fs.fault=nil
assert(store.flush(nil,true)); assert(store.state=='saved')
store.set_role('client')
assert(not store.apply_set('guid',1,4)); assert(not store.save())
store.set_role(nil)
assert(not store.set('guid',1,4))
