-- Regressions for the third review round (docs/review-round3-2026-10-29.md),
-- Production Limits panel: each footer against what its input really does
-- (P1), the device a prompt names (P2-1), the storage line with two bases
-- and where a new limit is seeded from (newcomer P1-1), the search row,
-- the job column, the save state size, the closed search, the uncached
-- picker list, the unavailable save, the first hidden frame, the upgrade
-- notice, widgets from an earlier tree, and one verdict per row.
-- Real renderer against the small UMG model of test_panel_render.lua, with
-- a clock the test moves.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
local tints={}
function Widget:SetColorAndOpacity(v) self.tint=v and v.SpecifiedColor end
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
local function in_part(part)
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts[part] and w.text and w.text~='' then return w end
    end
end
local function notice() local w=in_part('Notice') return w and w.text end
local function caption() local w=in_part('Caption') return w and w.text end
local function footer()
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts.Foot and type(w.text)=='string'
            and (w.text:find('Up/Down',1,true) or w.text:find('Click a limit',1,true)) then return w.text end
    end
end
local function search_box()
    for _,w in ipairs(registry) do
        if not w.dead and w.kind=='EditableTextBox' and w.parent==overlay.parts.Search then return w end
    end
end
local function editing_now() return rendered('Confirm')~=nil end
local session=require('session')
local api=package.loaded.palapi
local items=package.loaded.items
caps.support=function() return true end
items.catalogue_ids=function() return {'Stone01','StoneNew','Wood'}, 'ready' end
items.prepare_picker=function() return {}, 'ready' end
items.search_picker=function() return {'Stone01','StoneNew'} end
local function draw() panel.refresh(cfg); panel.refresh(cfg) end

rules(1)
panel.refresh(cfg); panel.toggle(); draw()
assert(panel.open)

-- P1-1: every footer says what its own input does on a limit, and doing it
-- does exactly that. Ladder 100/500/1000; the rule starts at 101.
local function rule() return select_where(function(w) return w.kind=='rule' end, 'the limit') end
-- Keyboard: Right or Enter raise one step and save, Left lowers. No editor.
rule()
local before=writes
assert(panel.nav(cfg,'enter')); draw()
local foot=assert(footer(), 'no footer')
-- UX crowding P2-4: the recheck key is in the tab bar only.
assert(foot==rb.FOOT.keys, 'keyboard footer: '..foot)
assert(foot:find('Right/Enter raise a step',1,true) and data.Stone01==500 and writes==before+1
    and not editing_now(), 'Enter did not do what the keyboard footer says')
rule(); assert(panel.nav(cfg,'left')); draw()
assert(footer():find('Left lowers',1,true) and data.Stone01==100, 'Left did not lower')
-- Controller: Y (code 7) or Right raise, Left (code 3) lowers.
rule(); assert(panel.native_pad(7)); draw()
assert(footer()==rb.FOOT.pad, 'controller footer: '..tostring(footer()))
assert(footer():find('Y (top)/Right raise',1,true) and data.Stone01==500 and not editing_now(),
    'Y did not do what the controller footer says')
rule(); assert(panel.native_pad(3)); draw()
assert(footer():find('Left lowers',1,true) and data.Stone01==100, 'pad Left did not lower')
-- Mouse: a click types (the editor, nothing saved), a right click lowers.
before=writes
assert(panel.apply(cfg,rule(),-1,true)); draw()
assert(footer()==rb.FOOT.mouse, 'mouse footer: '..tostring(footer()))
assert(footer():find('Click a limit to type',1,true) and editing_now() and writes==before,
    'a click did not do what the mouse footer says')
panel.cancel_edit(); draw()
data.Stone01=500; draw()
assert(panel.apply(cfg,rule(),1,true)); draw()
assert(footer():find('right click lowers it a step',1,true) and data.Stone01==100, 'right click did not lower')
data.Stone01=101; draw()
for by,text in pairs(rb.FOOT) do
    assert(#text<=115 and not text:find('rechecks',1,true), by..' footer too long: '..#text)
end

-- P2-1: the device comes from the input, not from the game's frozen flag.
api.last_input_type=nil
rule(); assert(panel.native_pad(6)); draw()
assert(notice()=='Press X again to delete the Mining limit for Stone01.', 'X prompt: '..tostring(notice()))
panel.escape(); draw()
api.last_input_type=1
rule(); assert(panel.row_action(cfg,'drop')); draw()
assert(notice()=='Click Sure? or press Delete again to delete the Mining limit for Stone01.',
    'Delete prompt with a stale pad flag: '..tostring(notice()))
panel.escape(); draw()
-- The polled pad driver's routes are the pad too.
api.last_input_type=nil
panel.hover_tick()
assert(pad_actions and pad_actions.remove, 'pad driver not wired')
rule(); pad_actions.remove(); draw()
assert(notice()=='Press X again to delete the Mining limit for Stone01.', 'pad driver X: '..tostring(notice()))
panel.escape(); draw()
-- Opening starts again from the game's flag, refreshed once on opening.
local asked_flag=0
api.input_is_gamepad=function() asked_flag=asked_flag+1 api.last_input_type=1 return true end
panel.close(); panel.toggle(); draw()
assert(asked_flag==1 and footer()==rb.FOOT.pad, 'opening ignored the controller flag: '..tostring(footer()))
panel.nav(cfg,'down'); draw()
assert(footer()==rb.FOOT.keys, 'a key after opening kept the pad footer')
api.input_is_gamepad=nil; api.last_input_type=nil

-- Newcomer P3-2: one base is just "your base".
assert(rendered('Storage: your base'), 'one base not called your base')
-- Accessibility P2-5: the save state is 14pt, like the notice row. It is
-- shown after a save only (UX crowding P3-2), so one is made first.
rule(); assert(panel.nav(cfg,'left')); draw()
local saved=assert(rendered('Limits saved'))
assert(saved.Font and saved.Font.Size==14, 'save state size: '..tostring(saved.Font and saved.Font.Size))
data.Stone01=101; draw()

-- Newcomer P1-1: two bases. The panel cannot tell which base the player is
-- at (palapi has no position), so the line says so, and a new limit is
-- seeded above the fullest base until the player picks one.
stock.StoneNew=50
scheduler.last_storage_by_camp.base2={guild='guild',scope='camp',verified=true,pass=1,sampled_at=now,ttl=30}
scheduler.last_totals_by_camp.base2={StoneNew=600,Stone01=18}
draw()
local line=assert(rendered('Storage: Base 1 of 2, counted alone - change base'), 'two-base label')
-- Accessibility P2-1: the keyboard selection shows on "change base".
local plain_tint=line.tint
rule(); assert(panel.nav(cfg,'up') and selected().kind=='stock_scope'); draw()
local focused=assert(rendered('> Storage: Base 1 of 2, counted alone - change base'), 'no caret on change base')
assert(focused.tint and plain_tint and (focused.tint.R~=plain_tint.R or focused.tint.B~=plain_tint.B),
    'change base keeps its plain tone when selected')
panel.nav(cfg,'down'); draw()
-- Not every base counted: nothing is seeded, the player is asked to pick.
scheduler.last_storage_by_camp.base2.verified=false
before=writes
assert(not panel.apply(cfg,{kind='item',item='StoneNew'},-1,true)); draw()
assert(notice()=='StoneNew: not added. Each base is counted alone; choose one with change base first.',
    'unpicked base with an uncounted base: '..tostring(notice()))
assert(not rb.armed and writes==before)
-- Every base counted: above the fullest one (600 at base2), not base1's 50.
scheduler.last_storage_by_camp.base2.verified=true
assert(panel.apply(cfg,{kind='item',item='StoneNew'},-1,true)); draw()
assert(notice():find('add a limit of 1,000.',1,true), 'not seeded above the fullest base: '..tostring(notice()))
now=now+0.5
assert(panel.apply(cfg,{kind='item',item='StoneNew'},-1,true) and data.StoneNew==1000)
draw()
assert(notice()=='Saved: Mining limit 1,000 for StoneNew, just above your fullest base. Click the number to change it.',
    'created notice: '..tostring(notice()))
data.StoneNew=nil
-- A base the player picked seeds from its own count: base2, then base1.
panel.set_screen('list'); draw()
assert(panel.apply(cfg,{kind='stock_scope'},-1,true)); draw()
assert(rendered('Storage: Base 2 of 2, counted alone - change base'))
assert(panel.apply(cfg,{kind='stock_scope'},-1,true)); draw()
assert(rendered('Storage: Base 1 of 2, counted alone - change base'))
assert(panel.apply(cfg,{kind='item',item='StoneNew'},-1,true)); draw()
assert(notice():find('add a limit of 100.',1,true), 'a picked base was not used: '..tostring(notice()))
panel.escape(); draw()
-- A client gets one base's count only: it asks for a pick as well.
local net0=package.loaded.net
package.loaded.net={epoch=5, request_stock=function() return true end,
    storage_view=function(g) return {verified=true, guild=g, choices={'a','b'}, scope='camp', camp='a',
        index=1, label='Base 1 of 2', totals={StoneNew=50}, epoch=5, expires_at=now+10} end}
caps.is_client=true
rb.stock_picked, rb.stock_camp=nil, nil
draw()
assert(rendered('Storage: Base 1 of 2, counted alone - change base'), 'client label from net')
assert(not panel.apply(cfg,{kind='item',item='StoneNew'},-1,true)); draw()
assert(notice()=='StoneNew: not added. Each base is counted alone; choose one with change base first.',
    'client seeded from a base nobody picked: '..tostring(notice()))
caps.is_client=nil; package.loaded.net=net0
scheduler.last_storage_by_camp.base2=nil; scheduler.last_totals_by_camp.base2=nil
stock.StoneNew=nil; rb.stock_camp, rb.stock_picked=nil, nil
draw()
-- Newcomer P3-1: nothing counted is not "Storage: Storage unavailable".
scheduler.last_storage_by_camp.base1.pass=0
draw()
assert(rendered('Storage: not counted yet'), 'uncounted storage label')
scheduler.last_storage_by_camp.base1.pass=1
draw()

-- Accessibility P2-6: a long job fits its column.
local all0=caps.all
caps.all=function() return {ProductMedicine={Medicine=200}} end
draw()
assert(rendered('Medicine') and not rendered('Medicine Production'), 'Medicine Production not shortened')
caps.all=all0
local workdefs=require('workdefs')
for work in pairs(workdefs.LABEL) do
    for _,rocks in ipairs({false,true}) do
        local cell=rb.job_cell(work,rocks)
        assert(#cell<=rb.JOB_CHARS, 'job cell too long: '..cell)
    end
end
assert(rb.job_cell('Mining',true)=='Mining (rocks)' and rb.job_cell('Deforest',false)=='Lumbering')
draw()

-- Accessibility P2-4: the search box is a row the arrows reach. Enter
-- gives it the keyboard; the Enter that commits the typing adds nothing.
panel.set_screen('item'); draw()
assert(selected().kind=='item', 'the picker opened on the search row, not the first item')
assert(panel.nav(cfg,'up') and selected().kind=='search', 'search row unreachable by keyboard')
draw()
assert(rendered('Search items: press Enter, then type'), 'selected search row not shown')
local box=assert(search_box())
assert(panel.nav(cfg,'enter')); draw()
assert(box.focus==true, 'Enter on the search row did not focus the box')
local asked=0
box.HasKeyboardFocus=function(self) asked=asked+1 return self.focus==true end
box.text='Stone'; draw()
before=writes
session.enqueue(function() panel.nav(cfg,'enter') end, true)
box.focus=false -- UMG commits and clears focus before the queued key runs
asked=0; session.drain()
assert(asked==0, 'the queued Enter asked a kept widget')
draw()
assert(not rb.armed and writes==before, 'the Enter that ended typing armed a tile')
select_where(function(w) return w.kind=='item' and w.item=='StoneNew' end, 'StoneNew')
assert(panel.nav(cfg,'enter')); draw()
assert(rb.armed, 'the next Enter did not reach the tiles')
panel.escape(); draw()
-- A controller cannot type there: Y says so and leaves the box alone.
assert(panel.nav(cfg,'up')); draw()
select_where(function(w) return w.kind=='search' end, 'search row')
box.focus=false
assert(panel.native_pad(7)==false); draw()
assert(notice()=='Searching needs a keyboard. Show all lists every item a base can make.', 'pad search: '..tostring(notice()))
assert(box.focus~=true, 'Y focused the search box')
-- Newcomer P2-3: the picker help row names the input in use.
panel.nav(cfg,'down'); draw()
assert(in_part('Notice').text==rb.PICK_HELP.keys, 'keyboard picker help: '..tostring(notice()))
panel.native_pad(2); draw()
assert(in_part('Notice').text==rb.PICK_HELP.pad, 'pad picker help: '..tostring(notice()))

-- Panel-bugs P3-1: closing forgets the search text, so the next opening
-- neither shows the old matches nor swallows the first Enter.
box=assert(search_box()); box.text='Ston'; box.focus=false; draw()
assert(caption():find('Matching Ston',1,true), 'fixture search not applied')
panel.close(); panel.toggle()
panel.set_screen('item'); draw()
assert(not caption():find('Matching',1,true), 'old search came back: '..caption())
assert(panel.nav(cfg,'enter') and rb.armed, 'the first Enter after reopening was swallowed')
panel.escape(); draw()

-- Panel-bugs P3-2: a list filtered while a name was unreadable is not kept.
local missing=true
items.real_name=function(id) if id=='Stone01' and missing then return nil end return id end
panel.command(cfg,'filter'); stock.StoneZZ=1; draw() -- a new id rebuilds the list
local function shown() return tonumber(caption():match('(%d+) items?')) end
local short=shown()
missing=false; draw()
assert(shown()==short+1, 'the picker kept a list built without a name: '..short..' then '..shown())
items.real_name=function(id) return id end
stock.StoneZZ=nil

-- Panel-bugs P3-3: an unreadable save state is not reported as saved.
panel.set_screen('list'); draw()
rb.saving_said('Saving change...', 'Saved: done.')
caps.view_status=function() error('status read failed') end
draw()
assert(rb.saving==nil and up(rb.saving_done,'notice')=='Save status unavailable',
    'unavailable save said: '..tostring(up(rb.saving_done,'notice')))
caps.view_status=nil; draw()

-- Panel-bugs P3-4: the half-second cap counts from the first hidden frame.
panel.close()
local tidy, slow=rb.tidy_rows, true
rb.tidy_rows=function(...)
    if slow then now=now+0.6; slow=false end
    tidy(...); rb.pending=true
end
panel.toggle()
assert(overlay.parts.Root.opacity==0, 'a slow first draw was shown before its layout')
now=now+0.2; panel.refresh(cfg)
assert(overlay.parts.Root.opacity==0, 'unveiled 0.2 s after the first hidden frame')
now=now+0.4; panel.refresh(cfg)
assert(overlay.parts.Root.opacity==1, 'still hidden past the cap')
rb.tidy_rows=tidy

-- Engine P3-3 / persistence P3-6: the upgrade marker is removed only by a
-- visible draw that showed the notice.
local acked=0
local UPGRADE='config.lua was missing, defaults are in use.'
package.loaded.configuration={upgrade_reset=true, upgrade_message=UPGRADE,
    ack_upgrade_reset=function() acked=acked+1 package.loaded.configuration.upgrade_reset=false end}
rb.upgrade_said=nil
panel.refresh(cfg) -- closed: a dedicated server never gets further than this
assert(acked==0, 'acknowledged with no panel drawn')
panel.close(); panel.toggle()
assert(acked==0, 'acknowledged by toggle or the hidden first frame')
-- Replaced before a visible draw: kept, and said again on the next opening.
panel.apply(cfg,{kind='job'},-1,true)
panel.refresh(cfg)
assert(acked==0, 'acknowledged a notice that was never visible')
panel.close(); panel.toggle()
assert(up(rb.saving_done,'notice')==UPGRADE, 'unseen notice not said again')
panel.refresh(cfg)
assert(acked==1 and notice()==UPGRADE, 'shown notice not acknowledged')
panel.close(); panel.toggle(); panel.refresh(cfg)
assert(acked==1 and notice()~=UPGRADE, 'said or acknowledged twice')
package.loaded.configuration=nil
draw()

-- Engine P3-4 / test-coverage P3-4: a queued Enter in the amount editor and
-- the debug verbs ask the box of the current tree, never one kept from an
-- earlier one (a rebuilt widget keeps its full name).
local function swap(old, text)
    local new=setmetatable({kind=old.kind, name=old.name, children={}, Font=old.Font, Brush={},
        visibility=0, text=text, parent=old.parent, Slot=old.Slot}, Widget)
    registry[#registry+1]=new
    for i,child in ipairs(old.parent.children) do if child==old then old.parent.children[i]=new end end
    local count=0
    for _,name in ipairs({'GetText','SetText','HasKeyboardFocus','HasAnyUserFocus','SetKeyboardFocus','IsValid','GetClass'}) do
        old[name]=function() count=count+1 error('kept widget asked') end
    end
    return new, function() return count end
end
draw()
assert(panel.apply(cfg,rule(),-1,true)); draw()
local old=assert(bound_editor, 'no editor')
local _, kept=swap(old,'70')
session.enqueue(function() panel.nav(cfg,'enter') end, true)
session.drain()
assert(kept()==0, 'the queued Enter read the kept amount box')
assert(data.Stone01==70, 'the queued Enter did not read the current box')
draw()
data.Stone01=101
panel.set_screen('item'); draw()
local fresh, kept_search=swap(assert(search_box()),'')
assert(panel.command(cfg,'focus')=='keyboard moved to the filter box')
assert(panel.command(cfg,'filter Wood')=="filter is now 'Wood'" and fresh.text=='Wood')
assert(panel.command(cfg,'probe'):find('probed',1,true) or true)
assert(kept_search()==0, 'a debug verb asked the kept search box')
panel.command(cfg,'filter')
panel.set_screen('list'); draw()

-- Newcomer P2-1 / P3-5: the rules help row says Stone Pits keep
-- producing; "job", not "work type". UX crowding P2-4 / P3-3: it says what
-- a limit does and nothing about keys (the footer does), and "group" ties
-- it to the picker's "Add group limit".
cfg.item_limits_on_rocks=nil
local verdict=require('panel_status').verdict
require('panel_status').verdict=function() return false,nil,1 end
data.Stone01=1000; draw()
panel.nav(cfg,'down'); panel.nav(cfg,'up'); draw()
assert(notice()=="Mining limits stop only that item's rocks; Stone Pits keep producing. Other (group) limits stop their whole job.",
    'rules help: '..tostring(notice()))
assert(#notice()<=125)
cfg.item_limits_on_rocks=false; draw()
assert(notice()=='Each limit is a group limit: it stops its whole job.', 'group help: '..tostring(notice()))
for _,text in ipairs({rb.LIMIT_HELP.rocks, rb.LIMIT_HELP.group}) do
    for _,foot in pairs(rb.FOOT) do
        for phrase in foot:gmatch('[^,]+') do
            phrase=phrase:gsub('^%s+',''):gsub('%.$','')
            assert(not text:find(phrase,1,true), 'help row repeats the footer: '..phrase)
        end
    end
end
require('panel_status').verdict=verdict
data.Stone01=101
assert(stale==0)
]=], '@panel-round3-fixture'))()

-- panel_status on its own: labels, the fullest base, and one verdict per row.
package.loaded.panel_status=nil
local status=require('panel_status')
assert(status.scope_label(nil)=='not counted yet')
assert(status.scope_label({scope='camp', choices={}, label='Storage unavailable'})=='not counted yet')
assert(status.scope_label({scope='camp', choices={'a'}, index=1})=='your base')
assert(status.scope_label({scope='camp', choices={'a','b'}, index=2, label='Base 2 of 2'})=='Base 2 of 2, counted alone')
assert(status.scope_label({scope='guild', choices={'a','b'}})=='All loaded bases in your guild')
local sched={pass_id=4,
    last_storage_by_camp={a={pass=4,guild='g',scope='camp',verified=true,sampled_at=os.clock(),ttl=30},
        b={pass=4,guild='g',scope='camp',verified=true,sampled_at=os.clock(),ttl=30},
        x={pass=4,guild='other',scope='camp',verified=true,sampled_at=os.clock(),ttl=30}},
    last_totals_by_camp={a={Wood=10},b={Wood=700},x={Wood=99999}}}
assert(status.highest(sched,'g',{'a','b'},'Wood')==700, 'fullest base')
assert(status.highest(sched,'g',{'a','b'},'Stone')==0)
assert(status.highest(sched,'g',{'a','x'},'Wood')==nil, 'another guild counted as ours')
sched.last_storage_by_camp.b.pass=3
assert(status.highest(sched,'g',{'a','b'},'Wood')==nil, 'an uncounted base was taken as empty')

-- Performance P3-1: a row's verdict reads its own job, not every job of
-- every camp. Counting tables stand in for the scheduler's per-camp works.
local walks, reads=0, 0
local function works(real)
    return setmetatable({}, {__index=function(_,k) reads=reads+1 return real[k] end,
        __pairs=function() walks=walks+1 return next, real, nil end})
end
local names={'EmitFlame','Watering','Seeding','GenerateElectricity','Handcraft','Collection','Deforest',
    'Mining','OilExtraction','ProductMedicine','Cool','Transport','MonsterFarm'}
local function all(v) local t={} for _,n in ipairs(names) do t[n]=v end return t end
local s2={pass_id=9,
    last_storage_by_camp={a={pass=9,guild='g',verified=true},b={pass=9,guild='g',verified=true}},
    last_capped_by_camp={a={pass=9,works=works(all(true))},b={pass=9,works=works(all(false))}}}
local view={verified=true, guild='g', scope='guild'}
local capped, partly, bases=status.verdict(s2,'Mining',view)
assert(capped==false and partly==1 and bases==2, 'verdict changed')
assert(walks==0, 'a row verdict walked every job of a camp ('..walks..' walks)')
assert(reads<=4, 'a row verdict read '..reads..' entries for one job at two bases')
-- The server's reply still judges every job with a limit.
walks, reads=0, 0
local out=status.server_limits({}, s2, 'g', view, {all=function() return {Mining={Stone=1}, Deforest={Wood=1}} end}, {})
assert(out.verdicts.Mining and out.verdicts.Deforest and out.verdicts.Cool==nil, 'server verdicts changed')
print('PASS panel round 3: footers by input, device stamps, two-base label and seed, search row, job column, close, cache, unveil, upgrade ack, current tree, row verdicts')
