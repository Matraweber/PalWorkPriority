package.loaded.log={count=function() return {} end,warn=function() end,debug=function() end,say=function() end}
local api=require('palapi')
api.instance_key=function(id) return id end
local function live(t) t.IsValid=function() return true end; return t end
local checks,species_calls=0,0
local param={IsValid=function() checks=checks+1; return true end,
    SaveParameter={NickName='None'},
    -- Game 1.0.5: GetNickname wants an out parameter; calling it without one
    -- raises, and that raise cost 0.5 ms per pal (2026-10-19).
    GetNickname=function() error('UFunction expected 1 parameters, received 0') end,
    GetCharacterID=function() species_calls=species_calls+1; return 'Lamball' end}
local handle=live({GetIndividualID=function() return 'pal-one' end,TryGetIndividualParameter=function() return param end})
local slot=live({IsEmpty=function() return false end,Handle=handle})
local camp=live({WorkerDirector=live({CharacterContainer=live({SlotArray={slot}})})})
local pals,err=api.camp_pals(camp)
assert(not err and #pals==1 and pals[1].name=='Lamball' and pals[1].species=='Lamball')
assert(checks==1,'fresh successful parameter validity was checked twice')
assert(species_calls==1,'successful species lookup was repeated')
-- Missing handle parameter still validates the replicated fallback.
handle.TryGetIndividualParameter=function() return nil end
slot.ReplicateIndividualParameter=param
checks=0
pals,err=api.camp_pals(camp)
assert(not err and checks==1 and pals[1].param==param)
-- A failed first species lookup retains the prior second-attempt behavior.
species_calls=0
param.GetCharacterID=function() species_calls=species_calls+1; if species_calls==1 then error('temporarily unreadable') end; return 'Lamball' end
pals,err=api.camp_pals(camp)
assert(not err and pals[1].name=='<unnamed>' and pals[1].species=='Lamball' and species_calls==2,'failed species lookup did not retain its retry')
-- Replacement is read afresh; an old wrapper must never be consulted.
param.IsValid=function() error('stale wrapper') end
slot.ReplicateIndividualParameter=live({SaveParameter={NickName='New pal'},GetCharacterID=function() return 'Foxparks' end})
pals,err=api.camp_pals(camp)
assert(not err and pals[1].name=='New pal' and pals[1].species=='Foxparks')
slot.ReplicateIndividualParameter=nil
pals,err=api.camp_pals(camp)
assert(err and #pals==0,'unavailable occupied slot became empty success')
-- The nickname is a property read; GetNickname is never called, and an empty
-- NickName (an unnamed pal) falls back to the species.
local nick_calls=0
slot.ReplicateIndividualParameter=live({SaveParameter={NickName=''},
    GetNickname=function() nick_calls=nick_calls+1; error('UFunction expected 1 parameters, received 0') end,
    GetCharacterID=function() return 'Cattiva' end})
pals,err=api.camp_pals(camp)
assert(not err and pals[1].name=='Cattiva' and nick_calls==0,'roster called GetNickname or ignored the species fallback')
assert(api.pal_name(slot.ReplicateIndividualParameter)=='Cattiva' and nick_calls==0,'pal_name called GetNickname')
assert(api.pal_name(live({SaveParameter={NickName='Bob'},GetCharacterID=function() return 'Cattiva' end}))=='Bob','nickname property ignored')
