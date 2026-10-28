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
-- 2026-10-27: new limits are group limits again; Ore joins the Mining group.
assert(caps.support('Mining','Ore','guild-A')==true, 'new group limit refused')
local offer=picker.describe(caps,caps.all({},'guild-A'),'Mining','Ore','guild-A',{item_limits_on_rocks=false})
assert(offer.state=='create' and offer.label=='Add group limit' and offer.group=='Stone'
    and offer.detail:find('stops once every one is reached',1,true), 'joining a group not explained')
-- 2026-10-28: by default a Mining limit is per item on rocks (item_sources).
local rocks=picker.describe(caps,caps.all({},'guild-A'),'Mining','Ore','guild-A')
assert(rocks.state=='create' and rocks.label=='Add item limit'
    and rocks.detail:find('rocks that mainly give this item',1,true), 'per-item Mining limit not explained')
assert(picker.describe(caps,caps.all({},'guild-A'),'Deforest','Wood','guild-A').label=='Add group limit',
    'a non-Mining limit claimed to be per item')
local before=fs.files.caps
assert(caps.support('NotAWork','Ore','guild-A')==false and caps.support('Mining','bad id!','guild-A')==false)
assert(not caps.apply_set('NotAWork','Ore',200,'guild-A') and fs.files.caps==before, 'invalid rule written')
assert(caps.apply_set('Mining','Ore',200,'guild-A') and caps.all({},'guild-A').Mining.Ore==200)
assert(caps.apply_clear('Mining','Ore','guild-A'))
assert(caps.support('Mining','Stone','guild-A')==true)
assert(caps.apply_set('Mining','Stone',200,'guild-A'))
assert(caps.all({},'guild-A').Mining.Stone==200)
assert(caps.all({},'guild-B').Mining==nil, 'another guild inherited the rule')
assert(caps.apply_clear('Mining','Stone','guild-A'))
caps.set_role('client',2)
assert(caps.replace_all({{work='Mining',item='Stone',amount=200}},2,'guild-A')==1)
assert(caps.support('Mining','Ore','guild-A')==true)
assert(caps.support('Mining','Stone','guild-A')==true)
assert(picker.describe(caps,caps.all({},'guild-A'),'Mining','Stone','guild-A').state=='existing')
