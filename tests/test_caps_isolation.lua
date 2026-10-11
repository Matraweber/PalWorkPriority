package.loaded.log={warn=function() end,say=function() end,error=function() end}
local fs=require('memory_fs')()
require('datafile').fs=fs
fs.files.caps='guild-A|Mining|Stone|100\n'
local caps=require('caps')
assert(caps.load('caps')==1)
caps.set_role('authority',1)
assert(caps.apply_set('Mining','Stone',200,'guild-A'))
local durable=fs.files.caps
caps.set_role('client',2)
assert(next(caps.all({work_caps={Mining={Ore=999}}},'guild-A'))==nil)
assert(caps.replace_all({{work='Mining',item='Stone',amount=500}},2,'server-guild')==1)
assert(caps.all({},'server-guild').Mining.Stone==500)
assert(not caps.replace_all({{work='Mining',item='Stone',amount=600}},1,'server-guild'))
assert(not caps.save())
caps.set_role(nil,3)
assert(caps.view_status()=='unavailable','undecided session advertised saved local rules')
assert(not caps.set('Mining','Stone',700,'guild-A'))
caps.set_role('authority',3)
assert(caps.all({},'guild-A').Mining.Stone==200)
assert(caps.all({},'server-guild').Mining==nil)
assert(fs.files.caps==durable, 'remote snapshot touched durable local rules')
assert(not caps.apply_set('Mining','Ore',100,'guild-A'), 'unverified item limit became a group rule')
assert(caps.apply_clear('Mining','Stone','guild-A'))
