-- Regressions for the round-5 fixes, Production Limits panel: the pointer
-- takes the highlight back from the keys when the hover map is off (panel
-- P2), a new search never draws page 1 of the old list (P3), a second
-- Escape closes when the shell could not take the keyboard back (P3), a
-- search that clears an armed tile says so (P3), a rule under another work
-- that matches the item is its rule (scheduler P3-2), and an old limit on an
-- item no base work makes is explained in the help row (scheduler P3-1).
-- Real renderer against the small UMG model of test_panel_render.lua, with
-- a clock the test moves.
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
rb.SLICE=math.huge
local action=assert(up(panel.activate,'action'))
local function sel_key() return up(action,'order')[up(action,'sel')] end
local function selected() return up(action,'hits')[sel_key() or ''] end
local function in_part(part)
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts[part] and w.text and w.text~='' then return w end
    end
end
local function notice() local w=in_part('Notice') return w and w.text end
local function caption() local w=in_part('Caption') return w and w.text end
local function search_box()
    for _,w in ipairs(registry) do
        if not w.dead and w.kind=='EditableTextBox' and w.parent==overlay.parts.Search then return w end
    end
end
local function surface(key) return up(rb.clear_widgets,'tile_face')[key] end
local function same(c,t) return c and math.abs(c.R-t.R)<1e-9 and math.abs(c.G-t.G)<1e-9 and math.abs(c.B-t.B)<1e-9 end
local ACCENT={R=0.42,G=0.80,B=1.00}
local function tile_rail(key)
    local s=up(rb.clear_widgets,'stripes')['rail:'..key]
    return s~=nil and same(s.colour,ACCENT)
end
local function select_where(pred, why)
    for _=1,400 do
        local w=selected()
        if w and pred(w, sel_key()) then return w end
        panel.move(1)
    end
    error('selection never reached '..why)
end
caps.support=function() return true end
local items=package.loaded.items
items.prepare_picker=function() return {}, 'ready' end
items.search_picker=function()
    local out={}
    for id in pairs(stock) do if id:find('^Stone') then out[#out+1]=id end end
    table.sort(out)
    return out
end
-- Thirty items that are not Stone and fill page 1 of the storage list.
for i=1,30 do stock[string.format('Wood%02d',i)]=1000+i end
local function draw() panel.refresh(cfg); panel.refresh(cfg) end

rules(3)
panel.refresh(cfg); panel.toggle(); draw()
assert(panel.open)

-- Panel P2: without the hover map the keys kept the highlight for good.
-- The map off (as after eight disagreements); one arrow, then the pointer
-- moves onto another tile.
panel.set_screen('item'); draw()
rb.hover_off=true
local function lit(key, on) assert(surface(key)).IsHovered=function() return on end end
-- The pointer rests on pick10 and has the highlight.
lit('pick10', true); draw()
assert(rb.current_key()=='pick10', 'fixture: the resting pointer is not current')
assert(panel.nav(cfg,'right'))
local kbd=assert(sel_key())
assert(kbd:find('^pick') and kbd~='pick10' and kbd~='pick11' and kbd~='pick12' and rb.kbd_focus,
    'fixture: the keys are not on another tile: '..tostring(kbd))
-- The press moved what lies under the pointer, which never moved (a page,
-- a tab, the editor): the first reading is of the old layout, the next of
-- the new one. Neither is a pointer move.
panel.refresh(cfg)
lit('pick10', false); lit('pick11', true)
panel.refresh(cfg); panel.refresh(cfg); panel.refresh(cfg)
assert(rb.kbd_focus and rb.current_key()==kbd and tile_rail(kbd) and not tile_rail('pick11'),
    'a layout change under a resting pointer took the highlight from the keys: '..tostring(rb.current_key()))
-- Now the pointer moves onto another tile.
lit('pick11', false); lit('pick12', true)
draw()
assert(rb.kbd_focus==nil, 'a pointer move did not take the highlight back')
assert(rb.current_key()=='pick12' and tile_rail('pick12') and not tile_rail(kbd),
    'the caret stayed on the tile of the keys: '..tostring(rb.current_key()))
-- A pad user with the mouse untouched keeps the highlight while nothing
-- under the pointer changes.
assert(panel.nav(cfg,'right')); kbd=sel_key()
for _=1,4 do panel.refresh(cfg) end
assert(rb.kbd_focus and rb.current_key()==kbd, 'the keys lost the highlight with the pointer at rest')
lit('pick12', false)
rb.hover_off=nil
draw()

-- Search changed while a tile was armed (panel P3, older code): said.
local tile=select_where(function(w) return w.kind=='item' end, 'a tile')
assert(panel.apply(cfg,tile,-1,true) and rb.armed, 'fixture: the tile did not arm')
panel.refresh(cfg)
local box=assert(search_box())
box.text='S'; panel.refresh(cfg)
assert(rb.armed==nil and notice()=='Search changed; no limit was added.', 'a silent disarm: '..tostring(notice()))
box.text=''; draw()

-- Panel P3: a new search drew one frame of page 1 of the old list.
select_where(function(_,k) return k=='pick0' end, 'pick0')
assert(up(action,'hits').pick0.item:find('^Wood'), 'fixture: page 1 is not the Wood items: '..tostring(up(action,'hits').pick0.item))
assert(panel.page_step(cfg,1)); draw(); assert(panel.page_step(cfg,1)); draw()
assert(not up(action,'hits').pick0.item:find('^Wood'), 'fixture: page 3 still shows Wood')
box.text='Stone'; panel.refresh(cfg)
for key,w in pairs(up(action,'hits')) do
    if key:find('^pick') and w.item then
        assert(not w.item:find('^Wood'), 'one frame drew page 1 of the old list: '..key..'='..w.item)
    end
end
assert(not caption():find('Matching',1,true), 'the caption named the new search over the old list: '..caption())
panel.refresh(cfg)
assert(caption():find('Matching Stone',1,true), 'the search was not applied: '..tostring(caption()))
for key,w in pairs(up(action,'hits')) do
    if key:find('^pick') and w.item then assert(w.item:find('^Stone'), key..'='..w.item) end
end

-- Panel P3: the shell could not take the keyboard back, so every Escape
-- said "Search kept" and none closed. It gets the widget host() resolved.
local handed, got=0, nil
overlay.focus_shell=function(w) handed=handed+1; got=w; return false end
select_where(function(w) return w.kind=='search' end, 'search row')
rb.search_dirty=nil
assert(panel.nav(cfg,'enter')); draw()
assert(box.focus==true, 'fixture: the box did not take the keyboard')
assert(panel.escape()==true and panel.open, 'the first Escape closed the panel')
panel.refresh(cfg)
assert(handed==1 and got==overlay.parts.Root, 'focus_shell did not get this frame\'s shell: '..tostring(got))
assert(box.focus==true and notice()=='Search kept. Esc again closes.', 'fixture: '..tostring(notice()))
now=now+1
panel.escape()
assert(not panel.open, 'the second Escape did not close while the box kept the keyboard')
-- Later than that, the box still has the keyboard: the search is kept.
panel.toggle(); draw(); panel.set_screen('item'); draw()
box=assert(search_box())
select_where(function(w) return w.kind=='search' end, 'search row')
rb.search_dirty=nil
assert(panel.nav(cfg,'enter')); draw()
assert(panel.escape()==true and panel.open)
panel.refresh(cfg)
now=now+rb.ESC_AGAIN_S+0.5
assert(panel.escape()==true and panel.open, 'a late Escape closed instead of keeping the search')
overlay.focus_shell=nil
box.focus=false; draw()
panel.escape(); panel.escape()
if panel.open then panel.close() end

-- Scheduler P3-2: Sandwich moved to Kindling; its old Mining limit is its
-- rule, shown as Edit and opened by a click, never a second rule.
local classifier=rb.picker
local sandwich=classifier.describe(caps,{Mining={Sandwich=500}},'EmitFlame','Sandwich','guild',cfg)
assert(sandwich.state=='existing' and sandwich.amount==500 and sandwich.work=='Mining'
    and sandwich.label:find('^Edit'), 'Sandwich offered a second limit: '..tostring(sandwich.label))
local own=classifier.describe(caps,{Mining={Sandwich=500},EmitFlame={Sandwich=50}},'EmitFlame','Sandwich','guild',cfg)
assert(own.state=='existing' and own.amount==50 and own.work==nil, 'the item\'s own rule lost to the other')
data.Sandwich=500
panel.toggle(); draw(); panel.set_screen('item'); draw()
local writes0=writes
assert(panel.apply(cfg,{kind='item',item='Sandwich'},-1,true) and writes==writes0, 'the click did not open the rule')
assert(rb.reveal_rule and rb.reveal_rule.work=='Mining' and rb.reveal_rule.item=='Sandwich',
    'the click revealed a rule that does not exist: '..tostring(rb.reveal_rule and rb.reveal_rule.work))
data.Sandwich=nil
panel.close()

-- Scheduler P3-1: a Leather limit from 0.4.1 still stops all ranch work.
local plain_all=caps.all
caps.all=function() return { Mining = data, MonsterFarm = { Leather = 50 } } end
-- Every row counted, so the help row is free for the note.
local verdict=rb.status.verdict
rb.status.verdict=function() return false, nil, 1 end
panel.toggle(); draw()
local said=notice()
assert(said=='Leather: no base work makes it, so this limit stops all Farming work once reached.',
    'no note on the Leather limit: '..tostring(said))
assert(#said<=125, #said..': '..said)
caps.all=plain_all
rb.status.verdict=verdict
draw()
assert(notice()~=said, 'the note stayed after the rule went')
panel.close()
]=], '@panel-round5-fixture'))()
print('PASS panel round 5: pointer takes the keys\' highlight without the map, no old page on a new search, '
    ..'second Escape closes, search disarm said, a rule under a matching work, old Pal-drop limit explained')
