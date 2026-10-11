local function live(t) t.IsValid=function() return true end; return t end
package.loaded.palapi={CONTAINER_BASE_CLASS='models',valid=function(t) return t and t.IsValid and t:IsValid() end,
    guid_key=function(g) return g ~= 'zero' and g or nil end}
local p=require('storage_probe')
local function model(guid, name, slots, identity)
    local target=live({ItemSlotArray=slots,GetFullName=function() return identity or name end})
    local module=live({TargetContainer=target})
    return live({GetBaseCampIdBelongTo=function() return guid end,
        GetFullName=function() return name end, GetItemContainerModule=function() return module end})
end
local item={ItemId={StaticId={ToString=function() return 'Stone' end}},StackCount=7}
local models={model('zero','Chest unowned',{},'empty'),model('a','Chest owned',{item},'shared'),
    model('zero','Chest alias',{item},'shared'),model('zero','Chest broken',nil)}
FindAllOf=function() return models end
local r=p.read()
assert(r.models==4 and r.holders==4 and r.failures==0 and not r.truncated)
assert(r.groups['Chest | unknown | empty']==1 and r.groups['Chest | unknown | nonempty']==1)
assert(r.groups['Chest | unknown | unreadable']==1 and r.shared_scope_aliases==1)
assert(r.distinct_targets==3 and r.zero_only_targets==2 and r.conflicting_targets==0)
models[#models+1]=model('b','Chest conflict',{item},'shared')
assert(p.read().conflicting_targets==1)
item.IsValid=function() return false end
assert(p.read().groups['Chest | scoped | unreadable']==2)
item.IsValid=nil
local len_reads=0
local changing=setmetatable({}, {__len=function() len_reads=len_reads+1; return len_reads==1 and 1 or 0 end,
    __index=function() error('shrunk array must not be indexed') end})
models={model('zero','Shrinking container',changing)}
local shrinking=p.read()
assert(shrinking.slot_reads==0 and shrinking.groups['Shrinking | unknown | unreadable']==1)
local many=setmetatable({}, {__len=function() return 4096 end, __index=function() return item end})
models={}
for i=1,10 do models[i]=model('a','Large '..i,many) end
local bounded=p.read()
assert(bounded.truncated and bounded.slot_reads==32768 and bounded.models==8)
local function plain(v)
    if type(v)=='table' then for k,x in pairs(v) do assert(type(k)=='number' or type(k)=='string'); plain(x) end
    else assert(type(v)=='number' or type(v)=='boolean' or type(v)=='string') end
end
plain(r)
assert(p.format(r):find('Stone=7',1,true))
models={model('a','Chest base',{item},'shared'),model('a','Chest alias',{item},'shared'),
    model('zero','Chest unknown',{item})}
local api=package.loaded.palapi
api.has_authority=function() return true end
local fresh={a={Stone=7}}
local production_evidence={complete=true,deduplicated=true,outside_camp_loot=1}
api.chest_totals_by_camp=function(opts)
    assert(next(opts.exclude)==nil)
    return fresh,{a=1},production_evidence
end
local compared=p.read()
assert(compared.comparison=='MATCH' and compared.projection.a.Stone==7 and compared.projection_counts.a==1)
assert(compared.production_complete and compared.production_exclusions==1)
plain(compared)
fresh.a.Stone=8
assert(p.read().comparison=='MISMATCH', 'changed amount escaped independent comparison')
fresh={a={Stone=7,Ore=3}}
assert(p.read().comparison=='MISMATCH', 'unexpected item escaped reverse comparison')
fresh={b={Stone=7}}
assert(p.read().comparison=='MISMATCH', 'wrong camp escaped comparison')
fresh={a={Stone=7}}
production_evidence.complete=false
assert(p.read().comparison=='INCOMPLETE', 'equal partial counts passed')
production_evidence.complete=true
production_evidence.unknown_scope=1
assert(p.read().comparison=='INCOMPLETE', 'unknown scope passed')
production_evidence.unknown_scope=0
api.chest_totals_by_camp=function() error('scan failure') end
assert(p.read().comparison=='unavailable (production read)', 'failed scan destroyed census')
api.chest_totals_by_camp=function() return nil,{},{} end
assert(p.read().comparison=='unavailable (production read)')
api.has_authority=function() return false end
assert(p.read().comparison=='unavailable', 'client attempted authority inventory comparison')
FindAllOf=function() return nil end
assert(p.read().failures==1)
