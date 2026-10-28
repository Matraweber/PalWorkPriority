-- Regressions for the 2026-10-28 audit, bundle B (docs/review-2026-10-28.md):
-- keys inside text boxes (B1), a selection that follows what it points at
-- (B2), no limit on a guess (B3), two clicks to add (B4), one Remove timer
-- (B5), cache key, follow the new limit, notices until the next input (B6).
-- Real renderer against the small UMG model of test_panel_render.lua.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
function Widget:SetColorAndOpacity(v) self.tint=v and v.SpecifiedColor end
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
local function editor()
    return bound_editor
end
local function search_box()
    for _,w in ipairs(registry) do
        if not w.dead and w.kind=='EditableTextBox' and w.parent==overlay.parts.Search then return w end
    end
end
caps.support=function() return true end
package.loaded.items.catalogue_ids=function() return {'Stone01','StoneNew','Wood'}, 'ready' end

rules(3)
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg); panel.refresh(cfg)
assert(panel.open)

-- B2: opening an editor puts Confirm/Cancel above the rules. The selection
-- used to be an index and slid two entries up, onto the previous row.
local row2=select_where(function(w) return w.kind=='rule' and w.rule.item=='Stone02' end, 'Stone02')
assert(panel.apply(cfg,row2,-1,true))
panel.refresh(cfg)
assert(editor() and rendered('Confirm'), 'editor did not open')
local now=selected()
assert(now and now.kind=='rule' and now.rule.item=='Stone02',
    'selection drifted while editing: '..tostring(now and now.kind)..' '..tostring(now and now.rule and now.rule.item))

-- B1: while the editor is open the arrows and Delete leave everything alone,
-- and Enter only confirms.
local before=writes
editor().text='70'
for _,verb in ipairs({'right','left','up','down'}) do
    assert(not panel.nav(cfg,verb), verb..' acted inside the amount editor')
    panel.refresh(cfg)
    assert(writes==before and data.Stone02==102 and rendered('Confirm'), verb..' saved or closed the editor')
end
assert(not panel.row_action(cfg,'drop') and not rendered('Sure?'), 'Delete armed Remove inside the editor')
assert(panel.nav(cfg,'enter') and data.Stone02==70 and writes==before+1, 'Enter did not confirm the editor')
panel.refresh(cfg)
assert(not rendered('Confirm'), 'editor stayed open after Enter')
assert(selected().rule.item=='Stone02', 'selection lost after the editor closed')

-- B2: two raise presses after an edit raise the same limit; nothing else moves.
data.Stone02=102
panel.refresh(cfg)
assert(panel.nav(cfg,'right')); panel.refresh(cfg)
assert(panel.nav(cfg,'right')); panel.refresh(cfg)
assert(data.Stone02==1000 and data.Stone01==101 and data.Stone03==103, 'raise reached another row')
assert(not rendered('Sure?'), 'raise armed a Remove')

-- B2: removing a limit lands the cursor on a limit, never on Remove.
assert(panel.row_action(cfg,'drop')); panel.refresh(cfg)
assert(panel.row_action(cfg,'drop') and data.Stone02==nil, 'Remove did not delete on the second press')
panel.refresh(cfg)
assert(selected().kind=='rule', 'cursor landed on '..tostring(selected().kind)..' after a removal')

-- B2: "change base" is reachable by keyboard: up from the first limit.
scheduler.last_storage_by_camp.base2={guild='guild',scope='camp',verified=true,pass=1,sampled_at=os.clock(),ttl=30}
scheduler.last_totals_by_camp.base2={Stone01=18}
panel.set_screen('list'); panel.refresh(cfg); panel.refresh(cfg)
assert(selected().kind=='rule', 'first row is not the first limit')
assert(panel.nav(cfg,'up') and selected().kind=='stock_scope', 'change base unreachable by keyboard')
assert(panel.nav(cfg,'enter')); panel.refresh(cfg)
assert(rendered('18'), 'Enter on change base did not switch the base')
assert(selected().kind=='stock_scope', 'selection left change base after switching')
assert(panel.nav(cfg,'enter')); panel.refresh(cfg)
assert(rendered('37'), 'second Enter did not switch back')
scheduler.last_storage_by_camp.base2=nil; scheduler.last_totals_by_camp.base2=nil
panel.refresh(cfg)

-- B2: Enter on Show all toggles it and stays on it; it never becomes a tile.
panel.set_screen('item'); panel.refresh(cfg); panel.refresh(cfg)
select_where(function(w) return w.kind=='toggle_all' end, 'Show all')
before=writes
for _=1,2 do
    assert(panel.nav(cfg,'enter')); panel.refresh(cfg); panel.refresh(cfg)
    assert(selected().kind=='toggle_all', 'Show all drifted to '..tostring(selected().kind))
end
assert(panel.nav(cfg,'enter')); panel.refresh(cfg)
assert(writes==before and not rb.armed, 'Enter on Show all armed or created a limit')
panel.set_screen('item'); panel.refresh(cfg)
-- Make the toggle off again for the pager below.
if rendered('Showing all items a base can make') then
    select_where(function(w) return w.kind=='toggle_all' end, 'Show all')
    panel.nav(cfg,'enter'); panel.refresh(cfg)
end

-- B2: Enter on Next goes forward every time; it used to bounce 1-2-1.
panel.set_screen('item'); panel.refresh(cfg)
select_where(function(w) return w.kind=='page' and w.by==1 end, 'Next')
for page=2,4 do
    assert(panel.nav(cfg,'enter')); panel.refresh(cfg)
    assert(rendered('page '..page..' of 4'), 'Enter on Next did not reach page '..page)
    assert(selected().kind=='page' and selected().by==1, 'selection left Next on page '..page)
end
assert(not panel.nav(cfg,'enter')); panel.refresh(cfg)
assert(rendered('page 4 of 4') and notice()=='This is the last page.', 'spent Next moved or said nothing')

-- B1: the search box keeps its keys: Enter does not add a limit, arrows do
-- not move the grid.
panel.set_screen('item'); panel.refresh(cfg); panel.refresh(cfg)
local box=assert(search_box(), 'no search box')
local was=selected()
box.focus=true
assert(not panel.nav(cfg,'enter') and not rb.armed and writes==before, 'Enter in the search box acted on a tile')
assert(not panel.nav(cfg,'right') and selected()==was, 'arrow in the search box moved the grid')
box.focus=false

-- B3: no limit while storage is not counted.
data.StoneNew=nil
scheduler.last_storage_by_camp.base1.verified=false
panel.refresh(cfg)
local tile={kind='item',item='StoneNew'}
assert(not panel.apply(cfg,tile,-1,true) and not panel.apply(cfg,tile,-1,true))
assert(writes==before and data.StoneNew==nil, 'a limit was created on unknown storage')
panel.refresh(cfg)
assert(notice()=='StoneNew: storage is not counted yet, so no limit was added. Alt+F2 rechecks now.',
    'unknown storage refusal: '..tostring(notice()))
scheduler.last_storage_by_camp.base1.verified=true
scheduler.last_storage_by_camp.base1.sampled_at=os.clock()

-- B4: two clicks. The first says what the limit stops and the amount, and
-- the tile says the next click adds it; the second creates and follows it.
cfg.item_limits_on_rocks=nil
stock.StoneNew=95 -- first on the page: sorted by quantity
panel.set_screen('item'); panel.refresh(cfg)
assert(panel.apply(cfg,tile,-1,true) and writes==before, 'the first click created a limit')
panel.refresh(cfg)
assert(notice()=='StoneNew: stops only the rocks that mainly give it once reached. Click again to add a limit of 100.',
    'first click notice: '..tostring(notice()))
assert(rendered('Click again to add'), 'armed tile does not say the next click adds')
-- Any other input in between disarms.
panel.nav(cfg,'right'); panel.refresh(cfg)
assert(not rendered('Click again to add') and not rb.armed, 'moving away kept the tile armed')
assert(panel.apply(cfg,tile,-1,true) and writes==before, 'a disarmed tile created on one click')
assert(panel.apply(cfg,tile,-1,true) and writes==before+1 and data.StoneNew==100, 'second click did not create')
panel.refresh(cfg)
assert(notice()=='Saved: Mining limit 100 for StoneNew, just above storage. Click the number to change it.',
    'created notice: '..tostring(notice()))
-- B6: the new limit is followed, like opening an existing one.
assert(selected() and selected().kind=='rule' and selected().rule.item=='StoneNew', 'new limit not selected')
-- Other work types stop their whole job.
stock.Wood=7
panel.set_screen('item'); panel.refresh(cfg)
assert(panel.apply(cfg,{kind='item',item='Wood'},-1,true)); panel.refresh(cfg)
assert(notice()=='Wood: stops all Lumbering once reached, not only this item. Click again to add a limit of 100.',
    'group first click notice: '..tostring(notice()))
assert(panel.apply(cfg,{kind='item',item='Wood'},-1,true)); panel.refresh(cfg)
assert(notice()=='Saved: Lumbering limit 100 for Wood, just above storage. Click the number to change it.')
data.Wood, stock.Wood=nil, nil

-- B3: past the top step (1,000 in this fixture) the seed goes above storage
-- instead of seeding a limit that is already reached.
data.StoneNew, stock.StoneNew=nil, 1500
panel.set_screen('item'); panel.refresh(cfg)
before=writes
assert(panel.apply(cfg,tile,-1,true)); assert(panel.apply(cfg,tile,-1,true))
assert(data.StoneNew==10000 and writes==before+1, 'big stock seeded '..tostring(data.StoneNew))
data.StoneNew, stock.StoneNew=nil, 9999999
panel.set_screen('item'); panel.refresh(cfg)
assert(not panel.apply(cfg,tile,-1,true) and data.StoneNew==nil, 'created a limit below storage at the maximum')
panel.refresh(cfg)
assert(notice()=='StoneNew: storage already holds more than the largest limit (9,999,999). No limit was added.')
stock.StoneNew=nil
cfg.item_limits_on_rocks=false

-- B6: closing the panel forgets its notice.
panel.close(); panel.toggle(); panel.refresh(cfg)
assert(notice()~='StoneNew: storage already holds more than the largest limit (9,999,999). No limit was added.',
    'an old notice greeted the next opening')
assert(stale==0)
]=], '@panel-input-safety-fixture'))()

-- B5: one 8 s timer for the arm and its notice, the item named, and the
-- timeout said. Separate chunk: os.clock is replaced, and the panel module
-- is loaded again against this chunk's own fixture.
package.loaded.panel=nil
assert(load(source:sub(1,start-1)..'\n'..[=[
function Widget:SetColorAndOpacity(v) self.tint=v and v.SpecifiedColor end
local now=100
os.clock=function() return now end
for _,meta in pairs(scheduler.last_storage_by_camp) do meta.sampled_at=now end
local function notice()
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts.Notice and w.text and w.text~='' then return w.text end
    end
end
rules(2)
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
local remove={kind='drop',rule={work='Mining',item='Stone02',amount=102}}
assert(panel.apply(cfg,remove,-1,true)); panel.refresh(cfg)
assert(notice()=='Click Sure? to delete the Mining limit for Stone02.', 'armed notice: '..tostring(notice()))
local sure=assert(rendered('Sure?'))
assert(sure.tint and sure.tint.R==1 and sure.tint.G==1 and sure.tint.B==1, 'Sure? is not white')
now=107.9; panel.refresh(cfg)
assert(rendered('Sure?') and notice()=='Click Sure? to delete the Mining limit for Stone02.',
    'arm or its notice ended before 8 s')
now=108.1; panel.refresh(cfg)
assert(not rendered('Sure?') and rendered('Remove'), 'arm outlived 8 s')
assert(notice()=='Remove timed out. The limit is kept.', 'timeout not said: '..tostring(notice()))
assert(data.Stone02==102)
-- A click after the timeout arms again; it never deletes.
assert(panel.apply(cfg,remove,-1,true) and data.Stone02==102)
-- On a controller the confirming press is X.
panel.escape(); panel.refresh(cfg)
package.loaded.palapi.last_input_type=1
assert(panel.apply(cfg,remove,-1,true)); panel.refresh(cfg)
assert(notice()=='Press X again to delete the Mining limit for Stone02.', 'pad prompt: '..tostring(notice()))
package.loaded.palapi.last_input_type=nil
assert(writes==0 and stale==0)
]=], '@panel-remove-timer-fixture'))()
print('PASS panel input safety: text-box keys, identity selection, no guessed limits, two clicks, Remove timer, notices')
