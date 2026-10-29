-- Regressions for the second review round (docs/review-round2-2026-10-29.md):
-- Enter in the search box (P1), the "joins" first click (P1), double-clicks,
-- wording by input, "Others below", the opaque backdrop, disarming, reset,
-- the capped invisible first frame, Confirm by mouse, the Add bar glyph and
-- the scoped "Rocks stopped". Real renderer against the small UMG model of
-- test_panel_render.lua, with a clock the test moves.
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
local function selected()
    return up(action,'hits')[up(action,'order')[up(action,'sel')] or '']
end
local function select_where(pred, why)
    for _=1,400 do
        local w=selected()
        if w and pred(w) then return w end
        panel.move(1)
    end
    error('selection never reached '..why)
end
local function notice()
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts.Notice and w.text and w.text~='' then return w.text end
    end
end
local function search_box()
    for _,w in ipairs(registry) do
        if not w.dead and w.kind=='EditableTextBox' and w.parent==overlay.parts.Search then return w end
    end
end
local function caption()
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts.Caption and w.text and w.text~='' then return w.text end
    end
end
local session=require('session')
local api=package.loaded.palapi
local items=package.loaded.items
caps.support=function() return true end
items.catalogue_ids=function() return {'Stone01','StoneNew','Wood'}, 'ready' end
items.prepare_picker=function() return {}, 'ready' end
items.search_picker=function() return {'Stone01','StoneNew'} end

-- First on the storage page, which sorts by quantity.
stock.Wood, stock.Stone01=96, 95
rules(1)
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg); panel.refresh(cfg)
assert(panel.open)

-- P2: the shell's own backdrop is opaque. Its cooked 0.92 let the stand
-- grid show through the panel (retest r03/r04).
local backdrop=overlay.parts.Backdrop
assert(backdrop.colour and backdrop.colour.A==1 and backdrop.opacity==1,
    'the area behind the panel is not opaque')

-- P1: Enter in the search box, as the engine delivers it. The key handler
-- is queued (session.enqueue) and runs on a later beat; UMG has committed
-- the box and cleared its focus by then. The handler must not ask the box
-- anything either: it is a wrapper from an earlier callback.
panel.set_screen('item'); panel.refresh(cfg); panel.refresh(cfg)
local box=assert(search_box(), 'no search box')
local asked=0
box.HasKeyboardFocus=function(self) asked=asked+1 return self.focus==true end
local before=writes
-- StoneNew has no limit and is found only by the search, so an Enter that
-- reaches it arms it.
local function pick_new() return select_where(function(w) return w.kind=='item' and w.item=='StoneNew' end, 'StoneNew') end
local function press(key, between)
    session.enqueue(function() panel.nav(cfg,key) end, true)
    if key=='enter' then box.focus=false end -- the commit clears focus first
    if between then panel.refresh(cfg) end    -- a draw may land in between
    asked=0
    session.drain()
    assert(asked==0, 'the queued key asked a widget kept from an earlier callback')
end
for _,between in ipairs({false,true}) do
    -- Typing: the draws while the box has the keyboard (two, because the
    -- draw lists the tiles before it reads the box).
    box.focus=true; box.text=between and 'Stone0' or 'Ston'
    panel.refresh(cfg); panel.refresh(cfg); pick_new()
    press('enter', between)
    panel.refresh(cfg)
    assert(not rb.armed and writes==before, 'Enter in the search box armed or created a limit')
end
-- The NEXT Enter is meant for the grid again.
pick_new()
press('enter'); panel.refresh(cfg)
assert(rb.armed and rb.armed.item=='StoneNew' and writes==before, 'second Enter did not reach the tile')
panel.escape(); panel.refresh(cfg)
-- An arrow after typing ends it too; the Enter after that acts.
box.focus=true; box.text='Stone'; panel.refresh(cfg); panel.refresh(cfg)
box.focus=false; panel.refresh(cfg)
press('right'); press('left'); panel.refresh(cfg)
pick_new()
press('enter'); panel.refresh(cfg)
assert(rb.armed, 'Enter after an arrow was still swallowed')
panel.escape(); panel.command(cfg,'filter'); panel.refresh(cfg)
assert(writes==before)

-- P1: the first click on a group item whose job already has another group
-- limit (Stone01 here) says it joins them; "stops all Mining" was false.
data.StoneNew, stock.StoneNew=nil, 94 -- on the storage page now
panel.refresh(cfg)
local tile={kind='item',item='StoneNew'}
assert(panel.apply(cfg,tile,-1,true) and writes==before); panel.refresh(cfg)
assert(notice()=='StoneNew: joins the Mining limits: Mining stops once all are reached. Click again to add a limit of 100.',
    'joins notice: '..tostring(notice()))

-- P2: a double-click is not a decision. The second click within 0.4 s keeps
-- the arm and its prompt; a later one creates.
now=now+0.1
assert(panel.apply(cfg,tile,-1,true)); panel.refresh(cfg)
assert(writes==before and data.StoneNew==nil and rb.armed, 'a double-click created a limit')
assert(notice():find('Click again to add a limit of 100.',1,true), 'double-click lost the prompt')
assert(rendered('Click again to add'), 'double-click lost the armed label')
now=now+0.5
assert(panel.apply(cfg,tile,-1,true) and writes==before+1 and data.StoneNew==100, 'a deliberate second click did not create')
panel.refresh(cfg)
before=writes
-- Remove likewise.
panel.set_screen('list'); panel.refresh(cfg)
local remove={kind='drop',rule={work='Mining',item='StoneNew',amount=100}}
assert(panel.apply(cfg,remove,-1,true)); now=now+0.1
assert(panel.apply(cfg,remove,-1,true)); panel.refresh(cfg)
assert(data.StoneNew==100 and rendered('Sure?'), 'a double-click on Remove deleted the limit')
now=now+0.5
assert(panel.apply(cfg,remove,-1,true) and data.StoneNew==nil, 'a deliberate second click did not remove')
panel.refresh(cfg)

-- P2: the confirming press is named for the input in use.
-- Delete arms Remove; a click on Sure? works as well.
select_where(function(w) return w.kind=='rule' and w.rule.item=='Stone01' end, 'Stone01 limit')
assert(panel.row_action(cfg,'drop')); panel.refresh(cfg)
assert(notice()=='Click Sure? or press Delete again to delete the Mining limit for Stone01.',
    'Delete prompt: '..tostring(notice()))
panel.escape(); panel.refresh(cfg)
-- Tiles: Enter, then the pad's Y, then the mouse.
panel.set_screen('item'); panel.refresh(cfg); panel.refresh(cfg)
select_where(function(w) return w.kind=='item' and w.item=='Wood' end, 'Wood')
assert(panel.nav(cfg,'enter')); panel.refresh(cfg)
assert(notice()=='Wood: stops all Lumbering once reached, not only this item. Press Enter again to add a limit of 100.',
    'keyboard tile prompt: '..tostring(notice()))
assert(rendered('Press Enter to add'), 'armed tile does not name Enter')
assert(caption():find('Under each item: what Enter does',1,true), 'caption still says click: '..tostring(caption()))
panel.escape(); panel.refresh(cfg)
api.last_input_type=1
assert(panel.nav(cfg,'enter')); panel.refresh(cfg)
assert(notice()=='Wood: stops all Lumbering once reached, not only this item. Press Y again to add a limit of 100.',
    'pad tile prompt: '..tostring(notice()))
assert(rendered('Press Y to add') and caption():find('what Y does',1,true), 'pad label or caption')
panel.escape(); panel.refresh(cfg)
api.last_input_type=nil
assert(panel.apply(cfg,{kind='item',item='Wood'},-1,true)); panel.refresh(cfg)
assert(notice():find('Click again to add a limit',1,true) and rendered('Click again to add')
    and caption():find('what a click does',1,true), 'mouse wording')
for by,label in pairs(rb.AGAIN_TILE) do assert(#label<=21, by..' tile label too long: '..label) end

-- P3: an empty-space click, Escape and a right click take the arm back.
assert(panel.handle_click(cfg,-1)==false); panel.refresh(cfg)
assert(not rb.armed and not rendered('Click again to add'), 'an empty click kept the tile armed')
now=now+1
assert(panel.apply(cfg,{kind='item',item='Wood'},-1,true) and writes==before and data.Wood==nil,
    'one click after an empty click created a limit')
assert(panel.escape() and panel.open, 'Escape on an armed tile closed the panel')
assert(not rb.armed and writes==before, 'Escape kept the arm')
panel.refresh(cfg)
assert(notice()=='Cancelled. No limit was added.', 'Escape disarm: '..tostring(notice()))
assert(panel.apply(cfg,{kind='item',item='Wood'},-1,true)); now=now+1
assert(not panel.apply(cfg,{kind='item',item='Wood'},1,true) and writes==before and data.Wood==nil,
    'a right click confirmed an armed tile')
assert(not rb.armed, 'a right click kept the arm')
assert(not panel.apply(cfg,{kind='item',item='Wood'},1,true) and not rb.armed, 'a right click armed a tile')

-- P3: reset forgets the notice and the arm.
assert(panel.apply(cfg,{kind='item',item='Wood'},-1,true) and rb.armed)
panel.refresh(cfg)
local prompt=assert(notice())
panel.reset()
assert(rb.armed==nil, 'reset kept the armed tile')
panel.toggle(); panel.refresh(cfg)
assert(notice()~=prompt, 'reset kept the notice')

-- P2: "Others below" is explained in the help row.
local status=require('panel_status')
local verdict=status.verdict
status.verdict=function() return false,nil,1 end
data.Stone01=10 -- storage holds 95
panel.set_screen('list'); panel.refresh(cfg)
assert(rendered('Others below'), 'fixture does not show Others below')
assert(notice()=='Others below: this item is reached; the job waits for its other limits.',
    'Others below not explained: '..tostring(notice()))
status.verdict=verdict
data.Stone01=101

-- P3: the Add bar's glyph is "+", not the selection caret ">".
local plus=assert(rendered('+'), 'Add bar glyph is not +')
assert(plus.parent==overlay.parts.Foot)

-- P3: a mouse Confirm leaves the selection on the edited limit; the
-- Confirm it clicked goes away with the editor.
rules(3)
panel.refresh(cfg)
assert(panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone02',amount=102},row=5},-1,true))
panel.refresh(cfg)
bound_editor.text='70'
local confirm=assert(rendered('Confirm'))
confirm.IsHovered=function() return true end
panel.handle_click(cfg,-1)
confirm.IsHovered=function() return false end
assert(data.Stone02==70, 'mouse Confirm did not save')
panel.refresh(cfg)
assert(selected() and selected().kind=='rule' and selected().rule.item=='Stone02',
    'selection left the edited limit: '..tostring(selected() and selected().kind))

-- Net interface: "Rocks stopped" is asked for the scope the panel shows.
cfg.item_limits_on_rocks=nil
local view
status.item_stopped=function(item, v) view=v return false end
panel.refresh(cfg)
assert(view~=nil and view==rb.stock, 'item_stopped was not handed the stock view')
status.item_stopped=nil
cfg.item_limits_on_rocks=false

-- P2: on a client the uncounted picker caption waits for the server.
scheduler.last_storage_by_camp.base1.verified=false
caps.is_client=true
panel.set_screen('item'); panel.refresh(cfg)
assert(caption():find("^Waiting for the server's count%."), 'client caption: '..tostring(caption()))
assert(not caption():find('., page',1,true), 'page count glued to a sentence: '..caption())
caps.is_client=nil
scheduler.last_storage_by_camp.base1.verified=true

-- P3: the opening panel is invisible for at most half a second, even while
-- a page is still filling.
panel.close()
local tidy=rb.tidy_rows
rb.tidy_rows=function(...) tidy(...); rb.pending=true end
panel.toggle()
assert(overlay.parts.Root.opacity==0, 'first frame drawn visible')
now=now+0.2; panel.refresh(cfg)
assert(overlay.parts.Root.opacity==0, 'unveiled before it was laid out')
now=now+0.4; panel.refresh(cfg)
assert(overlay.parts.Root.opacity==1, 'a filling page kept the panel invisible past 0.5 s')
rb.tidy_rows=tidy
assert(stale==0)
]=], '@panel-round2-fixture'))()
print('PASS panel round 2: queued search Enter, joins, double-click, input wording, disarm, reset, Others below, backdrop, unveil')
