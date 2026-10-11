package.loaded.log={warn=function() end,say=function() end,error=function() end}
local fs=require('memory_fs')()
require('datafile').fs=fs
fs.files.caps='guild-A|Mining|Stone|100\n'
local caps=require('caps')
local producers=require('producers')
local picker=require('picker_presentation')
assert(caps.load('caps')==1)
caps.set_role('authority',1)
assert(producers.register('mock', {supports=function() return true end,
    admit=function() error('capability check invoked control') end,
    evidence='offline mock only',max_inflight=0}))
assert(producers.support('Mining','Ore')==true)
assert(caps.support('Mining','Ore','guild-A')==false,
    'adapter registration advertised an unavailable item-rule path')
assert(picker.describe(caps,caps.all({},'guild-A'),'Mining','Ore','guild-A').state=='unavailable')
local before=fs.files.caps
local ok,why=caps.apply_set('Mining','Ore',200,'guild-A')
assert(not ok and why=='unsupported_limit' and fs.files.caps==before)
assert(caps.support('Mining','Stone','guild-A')==true)
assert(caps.apply_set('Mining','Stone',200,'guild-A'))
assert(caps.all({},'guild-A').Mining.Stone==200)
assert(caps.support('Mining','Stone','guild-B')==false, 'another guild inherited capability')
assert(caps.apply_clear('Mining','Stone','guild-A'))
caps.set_role('client',2)
assert(caps.replace_all({{work='Mining',item='Stone',amount=200}},2,'guild-A')==1)
assert(caps.support('Mining','Ore','guild-A')==false)
assert(caps.support('Mining','Stone','guild-A')==true)
assert(picker.describe(caps,caps.all({},'guild-A'),'Mining','Stone','guild-A').state=='existing')
