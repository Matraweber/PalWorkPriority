package.loaded.log={count=function() return {ms=0} end,warn=function() end,debug=function() end,say=function() end}
local api=require('palapi')
local function live(object)
    object.IsValid=function() return true end
    return object
end
local slot={ItemId={StaticId={ToString=function() return 'Stone' end}},StackCount=50}
local container=live({ItemSlotArray={slot},GetFullName=function() return 'PalItemContainer shared' end})
local module=live({TargetContainer=container})
local function model(camp)
    return live({GetItemContainerModule=function() return module end,
        GetBaseCampIdBelongTo=function() return camp end,
        GetFullName=function() return 'PalMapObjectItemChestModel chest' end})
end
local guildcamp={A=1,B=2,C=3,D=4}
local one,two=model(guildcamp),model(guildcamp)
FindAllOf=function() return {one,two} end
local totals,count,evidence=api.camp_item_totals('1-2-3-4',{exclude={}})
assert(totals.Stone==50 and count==1,'same backing container was counted twice')
assert(evidence.complete and evidence.deduplicated)
slot.StackCount=nil
totals,count,evidence=api.camp_item_totals('1-2-3-4',{exclude={}})
assert(not evidence.complete,'unreadable quantity became a known empty container')
slot.StackCount=50
FindAllOf=function() return {model({A=0,B=0,C=0,D=0})} end
totals,count,evidence=api.chest_totals_by_camp({exclude={}})
assert(not evidence.complete and evidence.unknown_scope==1)
FindAllOf=function() return nil end
totals,count,evidence=api.chest_totals_by_camp({exclude={}})
assert(not evidence.complete)
assert(api.base_camps() and api.camps_available==false)

-- Diagnostics describe this existing scan, without replaying native getters.
local calls={walk=0,module=0,scope=0,class=0,identity=0,item=0}
local amount=50
local counted_slot={ItemId={StaticId={ToString=function()
    calls.item=calls.item+1; return 'Stone'
end}}}
setmetatable(counted_slot,{__index=function(_,key)
    if key=='StackCount' then return amount end
end})
local counted_container=live({ItemSlotArray={counted_slot},GetFullName=function()
    calls.identity=calls.identity+1; return 'PalItemContainer counted'
end})
local counted_module=live({TargetContainer=counted_container})
local counted_model=live({GetItemContainerModule=function()
    calls.module=calls.module+1; return counted_module
end,GetBaseCampIdBelongTo=function()
    calls.scope=calls.scope+1; return guildcamp
end,GetFullName=function()
    calls.class=calls.class+1; return 'PalMapObjectItemChestModel counted'
end})
FindAllOf=function() calls.walk=calls.walk+1; return {counted_model} end
amount=nil
totals,count,evidence=api.chest_totals_by_camp({exclude={}})
assert(evidence.failed_reads==1 and not evidence.complete and evidence.deduplicated)
assert(evidence.reasons and evidence.reasons.quantity==1,'quantity failure has no existing-read diagnostic')
local diagnostic=assert(api.last_storage_scan,'existing scan did not publish its diagnostic')
assert(diagnostic.reader=='by_camp' and diagnostic.complete==false and diagnostic.deduplicated)
assert(diagnostic.unknown_scope==0 and diagnostic.failed_reads==1 and diagnostic.reasons.quantity==1)
for name,n in pairs(calls) do assert(n==1,'diagnostics repeated '..name..' reads') end
evidence.reasons.quantity=999
assert(diagnostic.reasons.quantity==1,'cached diagnostic aliases the returned evidence')
local function plain(value)
    if type(value)=='table' then
        assert(getmetatable(value)==nil,'diagnostic retained a metatable')
        for key,child in pairs(value) do assert(type(key)=='string'); plain(child) end
    else
        assert(type(value)=='string' or type(value)=='number' or type(value)=='boolean',
            'diagnostic retained something other than plain data')
    end
end
plain(diagnostic)
amount=50
totals,count,evidence=api.chest_totals_by_camp({exclude={}})
assert(totals['1-2-3-4'].Stone==50 and evidence.complete)
assert(api.last_storage_scan.complete and api.last_storage_scan.failed_reads==0
    and next(api.last_storage_scan.reasons)==nil,'successful scan retained old failures')
for name,n in pairs(calls) do assert(n==2,'second scan repeated '..name..' reads') end

local function failure(reason, models, change)
    if change then change() end
    local walks=0
    FindAllOf=function() walks=walks+1; return models end
    local _,_,observed=api.chest_totals_by_camp({exclude={}})
    assert(walks==1 and not observed.complete and observed.reasons[reason]==1,
        'wrong diagnostic for '..reason)
    assert(api.last_storage_scan.reasons[reason]==1)
    plain(api.last_storage_scan)
end
failure('enumeration',nil)
failure('model_validity',{{IsValid=function() return false end}})
failure('container_module',{live({GetItemContainerModule=function() error('unique native error text') end})})
failure('scope_zero_guid',{model({A=0,B=0,C=0,D=0})})
assert(api.last_storage_scan.unknown_scope==1 and not api.last_storage_scan.complete,
    'an empty GUID was reclassified as known out-of-camp storage')
failure('scope_missing_guid',{model(nil)})
failure('scope_guid_fields',{model({A=1,B=2,C=3})})
failure('scope_guid_read',{model(setmetatable({}, {__index=function() error('unreadable GUID') end}))})
local scope_call_model=model(guildcamp)
scope_call_model.GetBaseCampIdBelongTo=function() error('scope method unavailable') end
failure('scope_call',{scope_call_model})
local guid_reads=0
local counted_guid=setmetatable({}, {__index=function(_,field)
    guid_reads=guid_reads+1
    return ({A=0,B=0,C=0,D=0})[field]
end})
failure('scope_zero_guid',{model(counted_guid)})
assert(guid_reads==4,'diagnostics repeated GUID field reads')
assert(select('#',api.guid_key(nil))==1 and select('#',api.guid_key({A=0,B=0,C=0,D=0}))==1,
    'private scope reasons changed the public GUID return arity')
FindAllOf=function() return {model({A=9,B=8,C=7,D=6})} end
local _,_,outside=api.camp_item_totals('1-2-3-4',{exclude={}})
assert(outside.complete and outside.unknown_scope==0,'a verified other-camp GUID was no longer excluded')
failure('item_identity',{one},function() slot.ItemId.StaticId.ToString=function() return nil end end)
slot.ItemId.StaticId.ToString=function() return 'Stone' end
failure('slot_array',{one},function() container.ItemSlotArray=nil end)
container.ItemSlotArray={slot}
failure('duplicate_scope',{one,model({A=9,B=8,C=7,D=6})})
assert(api.last_storage_scan.unknown_scope==1 and not api.last_storage_scan.deduplicated)

local broken={}
for i=1,64 do
    broken[i]=live({GetItemContainerModule=function() error('native object '..i) end})
end
FindAllOf=function() return broken end
api.chest_totals_by_camp({exclude={}})
local labels=0
for _ in pairs(api.last_storage_scan.reasons) do labels=labels+1 end
assert(labels==1 and api.last_storage_scan.reasons.container_module==64,
    'native error strings created unbounded diagnostic labels')
api.reset()
assert(api.last_storage_scan==nil,'previous session storage diagnostic survived reset')
