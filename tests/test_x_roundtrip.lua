local fs = require('memory_fs')()
io.open, os.rename, os.remove = fs.open, fs.rename, fs.remove
package.loaded.log = { debug=function() end, say=function() end, warn=function() end, error=function() end }
local store = require('store')
store.load('priorities')
store.decided = true
store.apply_set('123-456-789-012',1,false)
for value=2,6 do store.apply_set('123-456-789-012',value,value-1) end
assert(store.save())
store.load('priorities')
assert(store.get('123-456-789-012',1) == false, 'X disappeared after save/load')
store.apply_set('another-guid',1,3)
assert(store.save())
store.load('priorities')
assert(store.get('123-456-789-012',1) == false, 'unrelated edit removed X')
for value=2,6 do assert(store.get('123-456-789-012',value) == value-1) end
