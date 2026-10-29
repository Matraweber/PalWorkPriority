-- Real items and picker functions, with native calls modelled in memory.
-- A throwing sentinel records the call BEFORE throwing: pcall cannot hide it.
local now, epoch, stale = 0, 0, 0
local ids, names, calls = {}, {}, {}
local missing, name_cost, scalar_cost = false, 0, 0
local captures, examined = 0, 0
local old_clock = os.clock
os.clock = function() return now end
local wrappers = setmetatable({}, {__mode='k'})
local function native(fields)
    local born = epoch
    local w = setmetatable({}, {__index=function(_, key)
        if born ~= epoch then stale=stale+1; error('expired native wrapper') end
        return fields[key]
    end})
    wrappers[w] = true
    return w
end
package.loaded.log = {perf=false, count=function() end, debug=function() end, warn=function() end}
package.loaded.palapi = {
    valid=function(w) return w and w:IsValid() end,
    player_controller=function() return native({IsValid=function() return true end}) end,
    cdo=function(path)
        if path:find('DataTableFunctionLibrary',1,true) then
            return native({GetDataTableRowNames=function(_, tbl, out)
                assert(tbl:IsValid())
                for _, id in ipairs(ids) do
                    out[#out+1]=native({get=function()
                        return native({ToString=function() return id end})
                    end})
                end
            end})
        end
        return native({GetItemName=function(_, pc, id, out)
            assert(pc:IsValid() and id.tag=='FName')
            local key = id.value
            calls[key]=(calls[key] or 0)+1
            now=now+name_cost
            if key=='NPC_CrashSentinel' then error('native resolver sentinel') end
            out.outName=native({ToString=function() return names[key] or key end})
        end})
    end,
}
StaticFindObject=function()
    captures=captures+1
    now=now+0.030 -- indivisible capture must not also start localization
    if not missing then return native({IsValid=function() return true end}) end
end
FName=function(id) return native({tag='FName',value=id}) end
local items=require('items')
assert(type(items.prepare_picker)=='function', 'missing filtered picker preparation')
assert(type(items.search_picker)=='function', 'missing filtered picker search')

local file=assert(io.open(TEST_ROOT..'/Scripts/panel.lua','r'))
local source=file:read('*a'); file:close()
local first=assert(source:find('local INTERNAL =',1,true))
local last=assert(source:find('local function draw_item_picker',first,true))
local rejected_icons={}
local env=setmetatable({RB={}, items=items, search_text='wood', show_all=false,
    icons={gave_up_n=0, gave_up=function(id) return rejected_icons[id] end},
    workdefs={work_for_item=function(id)
        if id:find('Decoration',1,true) then return nil end
        return 'Mining'
    end},
}, {__index=_G})
local pick, eligible, accept=assert(load(source:sub(first,last-1)..
    '\nreturn picker_source, picker_eligible, producible','real picker search','t',env))()
assert(type(eligible)=='function', 'missing scalar picker predicate')
local function counted(id)
    examined=examined+1; now=now+scalar_cost
    return eligible(id)
end
local function fresh(next_ids)
    items.reset(); ids=next_ids; epoch=epoch+1
end
local function step(limit,budget)
    epoch=epoch+1
    local result,status=items.prepare_picker(counted,limit,budget)
    assert(stale==0, 'pcall hid a stale wrapper access')
    collectgarbage('collect')
    assert(next(wrappers)==nil, 'picker retained native wrappers')
    if status~='ready' then
        local matches,state=items.search_picker('wood',400)
        assert(matches==nil and state==status, 'partial/unavailable index leaked')
    end
    return result,status
end
local function finish()
    for _=1,1000 do
        local result,status=step()
        if status=='ready' then return result end
        assert(status=='pending')
    end
    error('picker never completed')
end
local function same(actual,expected)
    assert(table.concat(actual,'|')==table.concat(expected,'|'),
        table.concat(actual,'|')..' ~= '..table.concat(expected,'|'))
end

ids={'NPC_CrashSentinel','Decoration','Wood2','Wood9','Wood001','Wood_01',
    'Debug_Wood','Wood','Wood0','Wood1','Wood_Prefix','Birch','Zebra','Oak','Literal%Wood'}
names.Birch='Wood'; names.Zebra='Wood beam'; names.Oak='Refined wood'
local result,status=step()
assert(result==nil and status=='pending' and examined==0 and next(calls)==nil)
result,status=step(2,100)
assert(result==nil and status=='pending' and examined==2)
local filtered=finish()
assert(items.ids==nil and items.lower==nil and items.disp==nil, 'picker published generic index')
for _,id in ipairs({'NPC_CrashSentinel','Decoration','Wood2','Wood9','Wood001','Wood_01','Debug_Wood'}) do
    assert(calls[id]==nil, 'localized excluded item '..id)
end
assert(#filtered==8 and captures==1)
local ranked={'Birch','Wood','Wood_Prefix','Wood0','Wood1','Zebra','Literal%Wood','Oak'}
for _,cap in ipairs({0,1,2,5,8,9,400}) do
    local expected={}
    for i=1,math.min(cap,#ranked) do expected[i]=ranked[i] end
    same(items.search_picker('WOOD',cap),expected)
end
same(items.search_picker('wood beam',40),{'Zebra'})
-- The picker matches the name a player reads, never the id (UX crowding
-- P3-6: "ore" listed Lily Hat and Paloxite through their ids). Birch's id
-- is not its name ("Wood").
same(items.search_picker('Birch',40),{})
same(items.search_picker('irc',40),{})
same(items.search_picker('%',40),{'Literal%Wood'})
same(items.search_picker('no such item',40),{})
same(items.search_picker('',2),{filtered[1],filtered[2]})
local before=examined
assert(step()==filtered and examined==before, 'warm index rebuilt')
-- Generic callers retain the full catalogue and still invoke the sentinel.
assert(items.search('NPC_CrashSentinel',1)[1]=='NPC_CrashSentinel')
assert(calls.NPC_CrashSentinel==1 and #items.ids==#ids)
assert(items.search('Birch',1)[1]=='Birch', 'the debug search lost the id')
same(items.search_picker('wood',400),ranked)

-- Count rejected IDs as work even with a coarse clock or slow scalar filter.
local excluded={}
for i=1,300 do excluded[i]='NPC_Excluded'..i end
fresh(excluded); step(); before=examined
assert(step()==nil and examined-before==128, 'excluded IDs escaped count budget')
scalar_cost=0.0011; before=examined
assert(step(100,2)==nil and examined-before==2, 'scalar filtering escaped time budget')
scalar_cost=0; result=finish(); assert(#result==0)
local empty,state=items.search_picker('wood',400)
assert(#empty==0 and state=='ready', 'known empty index is not ready')

-- A single native name may overrun; no following name may compound it.
fresh({'BudgetA','BudgetB','BudgetC','BudgetD'}); step()
name_cost=0.010; before=examined
assert(step(100,2)==nil and examined-before==1)
name_cost=0.0011; before=examined
assert(step(100,2)==nil and examined-before==2)
name_cost=0; before=examined
assert(#step(100,0)==4 and examined-before==1, 'zero budget failed to make bounded progress')

-- Generic and picker preparation share capture/memo facts, not partial indexes.
fresh({'DecorationInterleaved','InterleavedA','InterleavedB'})
assert(select(2,items.prepare(1,100))=='pending')
assert(items.prepare(1,100)==nil and calls.DecorationInterleaved==1)
before=captures
assert(step()==nil and captures==before, 'picker recaptured the generic catalogue')
assert(step(1,100)==nil)
same(finish(),{'InterleavedA','InterleavedB'})
assert(items.ids==nil, 'picker completed the generic partial index')
same(items.load(),{'DecorationInterleaved','InterleavedA','InterleavedB'})
-- A reset also abandons both kinds of pending work.
fresh({'AbandonedGenericA','AbandonedGenericB'})
items.prepare(1,100); items.prepare(1,100); step(); step(1,100)
fresh({'BothReplacement'})
same(items.load(),{'BothReplacement'})
same(finish(),{'BothReplacement'})

-- Reset pending and complete indexes, including unchanged-query panel caches.
fresh({'AbandonedA','AbandonedB'}); step(); step(1,100)
fresh({'Replacement'}); assert(step()==nil)
same(finish(),{'Replacement'})
env.search_text='replacement'
local list=pick({}); same(list,{'Replacement'})
fresh({'ReplacementNew'})
list,_,status=pick({}); assert(#list==0 and status=='pending')
finish()
list=pick({}); same(list,{'ReplacementNew'})
assert(items.ids==nil, 'reset did not clear generic index')

-- Missing and empty catalogues are unavailable; recovery attempts stay bounded.
fresh({'Recovered'}); missing=true; before=captures
assert(select(2,step())=='unavailable')
assert(select(2,step())=='unavailable' and captures==before+1)
missing=false; now=now+5.1; assert(select(2,step())=='pending')
same(finish(),{'Recovered'})
fresh({}); before=captures
for attempt=1,3 do
    assert(select(2,step())=='unavailable' and captures==before+attempt)
    now=now+5.1
end
assert(select(2,step())=='unavailable' and captures==before+3)

-- More than 400 excluded matches cannot starve eligible matches. Native-name
-- and icon exclusions also happen before the result cap, without index rebuild.
local many={'ZWoodExact','ZWoodPrefix','ZContainsWood','AUnnamedWood','AIconWood'}
for i=1,405 do many[#many+1]='NPC_Wood'..i end
for i=1,405 do many[#many+1]='ZWoodMatch'..string.char(65+math.floor((i-1)/26))..string.char(65+(i-1)%26) end
names.ZWoodExact='wood'; names.ZWoodPrefix='wood plank'
names.AUnnamedWood='en Text'; names.AIconWood='wood'
rejected_icons.AIconWood=true
fresh(many); env.search_text='wood'; finish()
for _,cap in ipairs({399,400,401}) do
    local matches,state=items.search_picker('wood',cap,accept)
    assert(state=='ready' and #matches==cap)
    assert(matches[1]=='ZWoodExact' and matches[2]=='ZWoodPrefix')
    for _,id in ipairs(matches) do
        assert(not id:find('NPC_',1,true) and id~='AUnnamedWood' and id~='AIconWood')
    end
end
list=pick({})
assert(#list==400 and list[1]=='ZWoodExact' and list[2]=='ZWoodPrefix')
for _,id in ipairs(list) do
    assert(not id:find('NPC_',1,true) and id~='AUnnamedWood' and id~='AIconWood')
end
rejected_icons.ZWoodExact=true; env.icons.gave_up_n=1
list=pick({}); assert(#list==400 and list[1]=='ZWoodPrefix')
assert(calls.NPC_Wood1==nil and stale==0)
os.clock=old_clock
print('Picker search: excluded sentinel, ranking, post-eligibility cap, budgets, reset, unavailable and wrapper lifetime passed')
