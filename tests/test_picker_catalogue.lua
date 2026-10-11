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
state='ready'; list,all,status=pick({})
assert(status==nil and #list==1 and list[1]=='Ore' and searches==1)
assert(names.Decoration==nil, 'localized a non-job item before filtering')
assert(pick({})==list and searches==1, 'complete result was not reused')
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
print('real picker: bounded preparation, complete caches, IDs-only browsing, cheap rejection passed')
