package.loaded.log={warn=function() end,say=function() end,error=function() end}
local fs=require('memory_fs')()
require('datafile').fs=fs
fs.files.caps='*|Mining|Stone|100\nguild-A|Mining|Stone|200\n'
local caps=require('caps')
local cfg={work_caps={EmitFlame={Food=30}}}
caps.configure(cfg)
assert(caps.load('caps')==2)
caps.set_role('authority',1)
assert(caps.apply_clear('Mining','Stone','guild-A'))
assert(caps.all(cfg,'guild-A').Mining==nil, 'clear exposed the shared ceiling')
assert(caps.all(cfg,'guild-B').Mining.Stone==100, 'clear changed another guild')
assert(caps.apply_clear('EmitFlame','Food','guild-A'))
assert(caps.all(cfg,'guild-A').EmitFlame==nil, 'config ceiling was not cleared for requester')
caps.load('caps'); caps.set_role('authority',2)
assert(caps.all(cfg,'guild-A').Mining==nil and caps.all(cfg,'guild-A').EmitFlame==nil)
assert(caps.all(cfg,'guild-B').EmitFlame.Food==30)
assert(caps.apply_set('Mining','Stone',300,'guild-A'))
assert(caps.all(cfg,'guild-A').Mining.Stone==300, 'existing legacy mask cannot be edited')
assert(not caps.apply_clear('Mining','Stone','*'), 'unscoped clear was authorized')
