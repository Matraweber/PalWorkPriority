package.loaded.log={count=function() return {ms=0} end,warn=function() end,debug=function() end,say=function() end}
local api=require('palapi')
local function live(t) t.IsValid=function() return true end; return t end
FindFirstOf=function(cls) assert(cls=='PalGameMode'); return live({}) end
assert(api.latch_authority()==true)
local zero={A=0,B=0,C=0,D=0}
local base={A=1,B=2,C=3,D=4}
local target_reads=0
local function model(cls, guid, amount, identity)
    local container=live({GetFullName=function() return identity or cls end,
        ItemSlotArray={{ItemId={StaticId={ToString=function() return 'Stone' end}},StackCount=amount}}})
    local module=live(setmetatable({}, {__index=function(_,k)
        assert(k=='TargetContainer'); target_reads=target_reads+1; return container
    end}))
    return live({GetFullName=function() return cls .. ' instance' end,
        GetItemContainerModule=function() return module end,
        GetBaseCampIdBelongTo=function() return guid end})
end
local kinds={'PalMapObjectTreasureBoxModel','BP_MapObjectTreasureBoxModel_C',
    'PalMapObjectPickupItemOnLevelModel','PalMapObjectPalEggModel','PalMapObjectDropItemModel'}
for _,cls in ipairs(kinds) do
    local ambient=model(cls,zero,999,'outside')
    local owned=model(cls,base,7,'base')
    FindAllOf=function() return {ambient,owned} end
    local before=target_reads
    local by,counts,e=api.chest_totals_by_camp({exclude={}})
    assert(e.complete and e.unknown_scope==0, 'known no-base world loot invalidated scoped storage: '..cls)
    assert(e.outside_camp_loot==1 and api.last_storage_scan.outside_camp_loot==1)
    assert(by['1-2-3-4'].Stone==7 and counts['1-2-3-4']==1, 'in-base loot was lost or outside loot was counted')
    assert(target_reads==before+1, 'outside contents were scanned unnecessarily')
    local totals,_,camp=api.camp_item_totals('1-2-3-4',{exclude={}})
    assert(camp.complete and camp.outside_camp_loot==1 and totals.Stone==7)
    -- Neither missing/malformed scope nor failed reads are a positive absence.
    for _,guid in ipairs({false,{A=0,B=0,C=0},{A='bad',B=0,C=0,D=0},{A=0.5,B=0,C=0,D=0}}) do
        FindAllOf=function() return {model(cls,guid,999)} end
        assert(not select(3,api.chest_totals_by_camp({exclude={}})).complete)
    end
    ambient.GetBaseCampIdBelongTo=function() error('no scope') end
    FindAllOf=function() return {ambient} end
    assert(not select(3,api.chest_totals_by_camp({exclude={}})).complete)
    ambient.GetBaseCampIdBelongTo=function() return nil end
    assert(not select(3,api.chest_totals_by_camp({exclude={}})).complete)
    ambient.GetBaseCampIdBelongTo=function() return setmetatable({}, {__index=function() error('bad guid') end}) end
    assert(not select(3,api.chest_totals_by_camp({exclude={}})).complete)
    ambient.GetBaseCampIdBelongTo=function() return zero end
    ambient.GetFullName=function() return nil end
    assert(not select(3,api.chest_totals_by_camp({exclude={}})).complete)
end
local changing=model('PalMapObjectDropItemModel',zero,9,'changes')
FindAllOf=function() return {changing} end
for _,guid in ipairs({zero,base,zero}) do
    changing.GetBaseCampIdBelongTo=function() return guid end
    local by,_,e=api.chest_totals_by_camp({exclude={}})
    assert(e.complete and (by['1-2-3-4']~=nil)==(guid==base), 'scope classification was cached')
end
api.reset()
assert(not select(3,api.chest_totals_by_camp({exclude={}})).complete, 'undecided session excluded loot')
api.local_player_controller=function() return {Role=2} end
assert(api.latch_authority()==false)
assert(not select(3,api.chest_totals_by_camp({exclude={}})).complete, 'client replication was treated as absence')
api.local_player_controller=function() return nil end
assert(api.latch_authority()==true)
for _,cls in ipairs({'PalMapObjectItemChestModel','PalMapObjectGuildChestModel',
    'PalMapObjectConvertItemModel','PalMapObjectProductItemModel','PalMapObjectPalFoodBoxModel',
    'BP_UnverifiedDropItemModel_C','BP_UnverifiedTreasureBoxModel_C'}) do
    FindAllOf=function() return {model(cls,zero,999)} end
    local _,_,e=api.chest_totals_by_camp({exclude={}})
    assert(not e.complete and e.unknown_scope==1 and e.reasons.scope_zero_guid==1,cls..' was guessed outside scope')
end
-- A configured filter remains independent from the scope decision.
FindAllOf=function() return {model(kinds[1],zero,999),model('PalMapObjectItemChestModel',base,8)} end
local by,_,e=api.chest_totals_by_camp({include={'PalMapObjectItemChestModel'}})
assert(e.complete and by['1-2-3-4'].Stone==8 and e.outside_camp_loot==0)
-- Unscoped all-world diagnostics retain their existing literal meaning.
local all=api.all_chest_totals({exclude={}})
assert(all.Stone==1007)
