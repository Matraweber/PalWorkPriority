-- Real items.lua: native wrappers expire between prepare calls, including
-- IsValid. Only complete scalar indexes may be published to the picker.
local epoch, now, stale = 0, 0, 0
local row_calls, name_calls, table_calls = 0, 0, 0
local missing_table, missing_util = false, false
local name_cost = 0.0001
local counts = {}
local original_clock = os.clock
os.clock = function() return now end
package.loaded.log = {perf=false, debug=function() end, warn=function() end,
    count=function(label) counts[label]=(counts[label] or 0)+1 end,
    around=function() error('timing enabled unexpectedly') end}
package.loaded.measurement = nil
local wrappers = setmetatable({}, {__mode='k'})
local function native(fields)
    local born=epoch
    local function check()
        if born~=epoch then stale=stale+1; error('expired native wrapper') end
    end
    local w=setmetatable({}, {__index=function(_,key) check(); return fields[key] end})
    wrappers[w]=true
    return w
end
local ids={'Wood','wood','Wood_Refined','CopperOre','Pal_crystal_S','Unnamed','EmptyName','NPC_Debug2'}
for i=1,2458 do ids[#ids+1]=('Item_%04d'):format(i) end
assert(#ids==2466)
local localized={Wood='Wood',wood='wood',Wood_Refined='Refined Wood',
    CopperOre='Ore',Pal_crystal_S='Paldium Fragment',Unnamed='en Text',EmptyName='',NPC_Debug2='Debug Weapon'}
local function text_for(id) return localized[id] or 'Product '..id:sub(6) end
local function name_library()
    return native({GetItemName=function(_,pc,id,out)
        assert(pc:IsValid() and id.tag=='FName','native name argument was not FName')
        name_calls=name_calls+1; now=now+name_cost
        out.outName=native({ToString=function() return text_for(id.value) end})
    end})
end
package.loaded.palapi = {
    cdo=function(path)
        if path:find('DataTableFunctionLibrary',1,true) then
            return native({GetDataTableRowNames=function(_,tbl,out)
                assert(tbl:IsValid()); row_calls=row_calls+1
                for i,id in ipairs(ids) do
                    out[i]=native({get=function()
                        return native({ToString=function() return id end})
                    end})
                end
                -- Existing inclusion policy ignores these invalid row names.
                out[#ids+1]=native({get=function() return native({ToString=function() return 'None' end}) end})
                out[#ids+2]=native({get=function() error('unreadable row name') end})
            end})
        end
        if not missing_util then return name_library() end
    end,
    valid=function(w) return w~=nil and w:IsValid() end,
    player_controller=function() return native({IsValid=function() return true end}) end,
}
StaticFindObject=function(path)
    assert(path=='/Game/Pal/DataTable/Item/DT_ItemDataTable.DT_ItemDataTable')
    table_calls=table_calls+1
    -- Indivisible native lookup can exceed a slice; it must not then start
    -- thousands of localized-name calls in that same callback.
    now=now+0.030
    if not missing_table then return native({IsValid=function() return true end}) end
end
FName=function(id) return native({tag='FName',value=id}) end
local items=require('items')
assert(type(items.prepare)=='function','missing bounded catalogue preparation')
epoch=epoch+1
local catalogue,status=items.catalogue_ids()
assert(status=='ready' and #catalogue==2466 and name_calls==0,
    'IDs-only route performed eager catalogue localization')
assert(items.ids==nil and items.lower==nil and items.disp==nil)
local repeated=items.catalogue_ids()
assert(repeated==catalogue and row_calls==1,'IDs-only route repeated native capture')
local function step(limit,budget)
    epoch=epoch+1
    local before=name_calls
    local result,status=items.prepare(limit,budget)
    assert(status==(result and 'ready' or (missing_table and 'unavailable' or 'pending')),
        'preparation returned an incorrect state')
    assert(stale==0,'preparation touched a cross-callback wrapper')
    if not result then
        assert(items.ids==nil and items.lower==nil and items.disp==nil,'published partial index')
    end
    collectgarbage('collect')
    assert(next(wrappers)==nil,'catalogue retained a native wrapper after returning')
    return result,name_calls-before
end
assert(step()==nil and name_calls==0 and row_calls==1,'capture performed eager catalogue localization')
local result, used=step(5,100)
assert(result==nil and used==5,'name-count limit ignored')
name_cost=0.0011
result,used=step(100,2)
assert(result==nil and used==2,'soft time budget ignored')
name_cost=0.010
result,used=step(100,2)
assert(result==nil and used==1,'indivisible name call was followed after deadline')
name_cost=0.0001
local slices=0
repeat
    result,used=step()
    assert(used<=128,'default slice exceeded name count')
    slices=slices+1; assert(slices<200,'preparation did not finish')
until result
assert(row_calls==1 and table_calls==1 and name_calls==#ids)
assert(#result==2466 and #items.lower==2466 and #items.disp==2466)
local expected={table.unpack(ids)}
table.sort(expected,function(a,b)
    local ak,bk=a:lower():gsub('_',' '),b:lower():gsub('_',' ')
    return ak==bk and a<b or ak~=bk and ak<bk
end)
for i,id in ipairs(expected) do
    assert(result[i]==id,'catalogue inclusion/order changed')
    assert(items.lower[i]==id:lower())
    local displayed=text_for(id)
    if id=='Unnamed' then displayed='Unnamed' end
    if id=='EmptyName' then displayed='Empty Name' end
    assert(items.disp[i]==displayed:lower(),'display-name index changed for '..id)
end
local function reference_search(query,limit)
    local groups={{},{},{}}
    if query=='' then
        local out={}; for i=1,math.min(limit,#expected) do out[i]=expected[i] end; return out
    end
    local want=query:lower()
    for i,id in ipairs(expected) do
        local raw,shown=id:lower(),items.disp[i]
        local rank
        if raw==want or shown==want then rank=1
        elseif raw:sub(1,#want)==want or shown:sub(1,#want)==want then rank=2
        elseif raw:find(want,1,true) or shown:find(want,1,true) then rank=3 end
        if rank then groups[rank][#groups[rank]+1]=id end
    end
    local out={}
    for _,group in ipairs(groups) do for _,id in ipairs(group) do
        if #out==limit then return out end; out[#out+1]=id
    end end
    return out
end
for _,q in ipairs({'','wood','WOOD','Ore','Paldium Fragment','product 00','Item_0001','%','Empty Name'}) do
    for _,limit in ipairs({1,40,400}) do
        local actual,want=items.search(q,limit),reference_search(q,limit)
        assert(table.concat(actual,'|')==table.concat(want,'|'),'search/rank changed for '..q)
    end
end
local before=name_calls
assert(step()==result and items.load()==result and name_calls==before,'warm catalogue rebuilt')
assert(counts['items: table lookup']==1 and counts['items: native row names']==1
    and counts['items: row strings']==1 and counts['items: scalar sort']==1)
assert(counts['items: name index slice']>1)

-- Reset cancels a pending snapshot as well as every published parallel index.
items.reset(); ids={'Abandoned'}; assert(step()==nil)
items.reset(); ids={'Replacement'}
assert(items.ids==nil and items.lower==nil and items.disp==nil)
assert(step()==nil)
result=step(); assert(#result==1 and result[1]=='Replacement')

-- load/search stay synchronous. Explicit unavailable never means known empty;
-- three attempts / five-second cooldown bound recovery until the next reset.
items.reset(); ids={'CopperOre','Wood'}
assert(table.concat(items.load(),'|')=='CopperOre|Wood')
assert(items.search('Ore')[1]=='CopperOre')
items.reset(); missing_table=true
before=table_calls
assert(step()==nil and step()==nil and table_calls==before+1)
assert(#items.load()==0 and #items.search('anything')==0 and table_calls==before+1)
for i=2,3 do now=now+5.1; assert(step()==nil and table_calls==before+i) end
now=now+30; assert(step()==nil and table_calls==before+3,'retry cap ignored')
local _, unavailable=items.catalogue_ids(); assert(unavailable=='unavailable')
missing_table=false
assert(items.catalogue_ids()==nil and table_calls==before+3,'exhausted failure retried')
items.reset(); assert(step()==nil)
-- Recovery during the cooldown, before exhausting retries.
items.reset(); missing_table=true; assert(step()==nil)
missing_table=false
local absent, state=items.prepare(); assert(absent==nil and state=='unavailable')
now=now+5.1; assert(step()==nil); assert(#step()==2)

-- A missing localization utility never becomes a memoized native answer.
items.reset(); ids={'LateName'}; localized.LateName='Late localized name'
missing_util=true
assert(step()==nil); assert(#step()==1)
missing_util=false
assert(items.real_name('LateName')=='Late localized name')
assert(stale==0)
os.clock=original_clock
print('Catalogue: 2466 IDs preserved, atomic index, bounded name slices, fresh native wrappers')
