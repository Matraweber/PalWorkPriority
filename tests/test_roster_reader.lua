package.loaded.log={count=function() return {ms=0} end,warn=function() end,debug=function() end,say=function() end}
local api=require('palapi')
local function live(object) object.IsValid=function() return true end; return object end
local calls=0
local container=live({SlotArray={}})
local director=live({CharacterContainer=container,GetCharacterHandleSlots=function() calls=calls+1 end})
local camp=live({WorkerDirector=director})
local pals,err=api.camp_pals(camp)
assert(#pals==0 and err==nil and calls==0,'known zero invoked unsafe native out-table fallback')
container.SlotArray=nil
pals,err=api.camp_pals(camp)
assert(err and calls==0,'missing array became known empty')
local slot=live({IsEmpty=function() return nil end})
container.SlotArray={slot}
pals,err=api.camp_pals(camp)
assert(err,'unknown occupancy became an empty slot')
slot.IsEmpty=function() return false end
pals,err=api.camp_pals(camp)
assert(err,'occupied slot with missing Pal data disappeared from roster')
slot.IsEmpty=function() return true end
pals,err=api.camp_pals(camp)
assert(#pals==0 and err==nil)
container.SlotArray={slot,live({IsEmpty=function() error('unreadable') end})}
pals,err=api.camp_pals(camp)
assert(err,'partial roster was presented as complete')
