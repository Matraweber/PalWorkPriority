-- The picker page that never finished filling (perf, 2026-10-29).
--
-- Measured in game with Show all open: "panel: incremental fill" ran a full
-- refresh every 16ms for as long as the picker stayed open (324 in 10s),
-- and the page showed 20 of its 27 tiles with the pager under row 7.
--
-- The model: a tile already showing its item still costs the draw a little
-- Lua (0.41ms here, about what 20 settled tiles in a 12ms refresh leave),
-- and a tile shown for the first time costs its widget constructions. The
-- tile loop's slice check is the thing under test, so the clock moves only
-- through those two costs.
-- Real renderer against the small UMG model of test_panel_render.lua.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
local now=100
os.clock=function() return now end
for _,meta in pairs(scheduler.last_storage_by_camp) do meta.sampled_at=now end
local function up(fn,name)
    for i=1,200 do
        local n,v=debug.getupvalue(fn,i)
        if n==nil then break end
        if n==name then return v end
    end
end
local rb=assert(up(panel.refresh,'RB'))
rb.SLICE=0.008
-- A catalogue of 190 job items, as "Everything a base can make, 190 items".
local cat={}
for i=0,189 do
    cat[#cat+1]='Stone'..string.char(65+i//26)..string.char(65+i%26)
end
table.sort(cat)
local items=package.loaded.items
items.catalogue_ids=function() return cat, 'ready' end
items.prepare_picker=function() return {}, 'ready' end
items.search_picker=function() return {} end
-- Costs. Constructing a widget is the expensive part of a fresh tile.
local construct=StaticConstructObject
StaticConstructObject=function(...) now=now+0.001 return construct(...) end
local describe=rb.picker.describe
rb.picker.describe=function(...) now=now+0.00041 return describe(...) end

local function tiles()
    local n=0
    for k in pairs(rb.filled) do if k:match('^pick%d+$') then n=n+1 end end
    return n
end
local function caption()
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts.Caption and type(w.text)=='string' then return w.text end
    end
    return ''
end
-- The game's two loops: maintenance refreshes about every 200ms, the fast
-- loop calls fill_tick every 16ms. Answers how many fill refreshes ran.
local function play(seconds)
    local fills, last_maint=0, now
    local stop=now+seconds
    while now<stop do
        now=now+0.016
        if panel.fill_tick() then fills=fills+1 end
        if now-last_maint>=0.2 then
            last_maint=now
            -- The scheduler's passes keep the storage count fresh.
            for _,meta in pairs(scheduler.last_storage_by_camp) do meta.sampled_at=now end
            panel.refresh(cfg)
        end
    end
    return fills
end

rules(1)
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
assert(panel.open)
panel.set_screen('item'); panel.refresh(cfg)
assert(panel.apply(cfg,{kind='toggle_all'},-1,true)); panel.refresh(cfg)

-- 1: Show all settles. Every tile on page 1, and then no more fill work.
play(3)
assert(caption():find('Everything a base can make, 190 items',1,true), 'not the Show all list: '..caption())
assert(tiles()==27, 'Show all page stopped at '..tiles()..' of 27 tiles')
assert(not rb.pending, 'a full page still asks for fill frames')
local idle=play(10)
assert(idle==0, 'a settled page kept filling: '..idle..' refreshes in 10s')
local hosts=0
for i=0,8 do
    local h=rb.hosts['ItemList:'..i]
    local box=h and rb.runtime.objects[h.box]
    if box and box.visibility==0 then hosts=hosts+1 end
end
assert(hosts==9, 'only '..hosts..' of 9 grid rows shown')

-- 1b: an item the game has no name for is an answer, not a name it cannot
-- read yet, so the Show all list is still kept between draws. Rebuilt on
-- every draw, it walked the whole catalogue before the first tile.
local function cached()
    for i=1,200 do
        local n,v=debug.getupvalue(rb.clear_widgets,i)
        if n==nil then break end
        if n=='picker_key' then return v~=nil, i end
    end
end
local _, key_at=cached()
debug.setupvalue(rb.clear_widgets, key_at, nil)
local real_name=items.real_name
items.real_name=function(id) if id=='StoneAA' then return nil, 'unnamed' end return id end
panel.refresh(cfg)
assert(caption():find('189 items',1,true), 'the unnamed item was shown: '..caption())
assert(cached(), 'a list with an unnamed item was not kept')
items.real_name=function(id) if id=='StoneAA' then return nil end return id end
debug.setupvalue(rb.clear_widgets, key_at, nil)
panel.refresh(cfg)
assert(not cached(), 'a list built while a name was unreadable was kept')
items.real_name=real_name
debug.setupvalue(rb.clear_widgets, key_at, nil)
panel.refresh(cfg); play(3)

-- 2: a page turn fills the next page the same way.
assert(panel.apply(cfg,{kind='page',by=1},-1,true))
play(3)
assert(tiles()==27 and not rb.pending, 'page 2 stopped at '..tiles())

-- 3: the default list (what storage holds) with enough items to fill a page.
assert(panel.apply(cfg,{kind='toggle_all'},-1,true)); panel.refresh(cfg)
play(3)
assert(caption():find('What your storage holds',1,true), 'not the storage list: '..caption())
assert(tiles()==27, 'storage page stopped at '..tiles()..' of 27 tiles')
assert(not rb.pending and play(5)==0, 'the storage page kept filling')

-- 4: a fill that makes no progress is bounded. A grid row the engine will
-- not host leaves the page pending on every draw; the fast loop gives up
-- after rb.FILL_IDLE_MAX tries and the maintenance refresh carries on.
panel.apply(cfg,{kind='page',by=1},-1,true)
local row_host_refused=true
local add=Widget.AddChild
function Widget:AddChild(child)
    if row_host_refused and self==overlay.parts.ItemList then return nil end
    return add(self,child)
end
-- A fresh tree with no hosts yet, as after a reopen.
panel.close(); panel.toggle(); panel.refresh(cfg)
panel.set_screen('item'); panel.refresh(cfg)
assert(rb.pending, 'fixture: a refused row did not leave the page pending')
local stuck=play(5)
assert(stuck<=rb.FILL_IDLE_MAX, 'a page that cannot progress filled '..stuck..' times in 5s')
assert(play(5)==0, 'the bounded fill started again without progress')
-- Once the engine hosts the rows the maintenance refresh fills the page
-- and the fast loop takes over again.
row_host_refused=false
play(3)
assert(tiles()>0 and not rb.pending, 'the page did not recover: '..tiles()..' tiles')
Widget.AddChild=add
assert(stale==0)
]=], '@panel-fill-progress-fixture'))()
print('PASS panel fill progress: Show all and storage pages settle, a page turn fills, a stalled fill is bounded')
