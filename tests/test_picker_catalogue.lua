-- Execute the real picker selection functions with controlled catalogue
-- readiness. Incomplete search results must never become a cached empty list.
local f = assert(io.open(TEST_ROOT .. '/Scripts/panel.lua', 'r'))
local source = f:read('*a'); f:close()
local first = assert(source:find('local function drop_numbered_variants', 1, true))
local last = assert(source:find('local function draw_item_picker', first, true))
local state, prepares, searches, names, captures = 'pending', 0, 0, {}, 0
local ready_catalogue = {'Ore','Stone'}
local env = setmetatable({search_text='ore', show_all=false,
    looks_internal=function() return false end,
    items={
        prepare_picker=function(eligible, n, ms) assert(n==128 and ms==2); prepares=prepares+1
            assert(eligible('Ore') and not eligible('Decoration') and not eligible('Ore2'))
            return state=='ready' and ready_catalogue or nil, state end,
        catalogue_ids=function() captures=captures+1
            return state=='ready' and {'Decoration','Ore','Stone'} or nil, state end,
        search_picker=function(query,cap,accept) assert(state=='ready' and query=='ore' and cap==400)
            searches=searches+1; assert(not accept('Decoration') and accept('Ore')); return {'Ore'} end,
        real_name=function(id) names[id]=(names[id] or 0)+1; return id end,
    },
    icons={}, workdefs={work_for_item=function(id) if id~='Decoration' then return 'Mining' end end},
}, {__index=_G})
local pick = assert(load(source:sub(first,last-1)..'\nreturn picker_source', 'real picker', 't', env))()
local list, all, status = pick({})
assert(#list==0 and not all and status=='pending' and prepares==1 and searches==0)
assert(env.picker_key==nil, 'partial index committed a cache')
state='unavailable'; list,all,status=pick({})
assert(status=='unavailable' and env.picker_key==nil and searches==0)
local stock={}
state='ready'; list,all,status=pick(stock)
assert(status==nil and #list==1 and list[1]=='Ore' and searches==1)
assert(names.Decoration==nil, 'localized a non-job item before filtering')
assert(pick(stock)==list and searches==1, 'complete result was not reused')
-- The selected base and the set of ids in storage are the key (review B6,
-- 2026-10-28; round 2): another base is a new list, but a pass that only
-- publishes a new totals table with the same items is not. Keying on the
-- table re-sorted the tiles under the pointer on every pass.
local b=pick(stock,'camp-b')
assert(b~=list and searches==2, 'another base reused the first base list')
assert(pick({},'camp-b')==b and searches==2, 'a new totals table with the same items rebuilt the list')
assert(pick({Ore=1},'camp-b')~=b and searches==3, 'an item appearing did not rebuild the list')
assert(pick({Stone=1},'camp-b') and searches==4, 'a different item set of the same size reused the list')
-- World reset while the query is unchanged must gate even an old cache.
state='pending'; local pending=select(3,pick({})); assert(pending=='pending')
env.search_text,env.show_all='',true
state='unavailable'; assert(select(3,pick({}))=='unavailable')
state='ready'; local before=prepares
list,all,status=pick({})
assert(all and status==nil and #list==2 and prepares==before and captures==2)
assert(names.Decoration==nil and list[1]=='Ore' and list[2]=='Stone')
-- Stock-only mode never touches an unavailable catalogue.
env.show_all=false; state='unavailable'; before=prepares+captures
list,all,status=pick({Stone=3,Ore=1})
assert(not all and status==nil and list[1]=='Stone' and list[2]=='Ore')
assert(prepares+captures==before)
-- The next pass's totals: same items, new numbers, a new table. The order
-- holds still (round 2); only an item appearing or running out re-sorts.
local held=pick({Stone=1,Ore=5})
assert(held==list and held[1]=='Stone', 'tiles re-sorted under the pointer on a new pass')
held=pick({Stone=1,Ore=5,Wood=9})
assert(held~=list and held[1]=='Wood' and held[2]=='Ore', 'a new item did not re-sort the list')
print('real picker: bounded preparation, complete caches, IDs-only browsing, cheap rejection passed')
