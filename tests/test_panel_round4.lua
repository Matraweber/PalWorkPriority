-- Regressions for the fourth review round (docs/review-round4-2026-10-30.md),
-- Production Limits panel: the keyboard row keeps the caret and the rail
-- while the pointer rests elsewhere (accessibility P2-2), the search hint
-- and the spent pager in words (P3-2, P3-3), an armed tile that expires,
-- a Remove cancelled by a changed amount, a new search on page 1, Up and
-- Down at the grid's edges, Escape while typing a search (panel bugs P3-1
-- to P3-5), the hover spacing set live (performance P2-1), and the texts
-- of panel_status and install_check (newcomer P2-1, P2-2, P3-4, P3-5).
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
local function block(key) return up(rb.clear_widgets,'blocks')[key] end
local function surface(key) return up(rb.clear_widgets,'tile_face')[key] end
local function same(c,t) return c and math.abs(c.R-t.R)<1e-9 and math.abs(c.G-t.G)<1e-9 and math.abs(c.B-t.B)<1e-9 end
local ACCENT={R=0.42,G=0.80,B=1.00}
local function rail(i)
    local s=up(rb.clear_widgets,'stripes')['selrail'..i]
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
local function draw() panel.refresh(cfg); panel.refresh(cfg) end

rules(3)
panel.refresh(cfg); panel.toggle(); draw()
assert(panel.open)

-- Accessibility P2-2: the pointer resting on row 2 while the keys put the
-- selection on row 1. The caret and the cyan rail go where Right acts.
panel.set_screen('list'); draw()
local hot=assert(block('cap2'), 'fixture: no limit text on row 2')
hot.IsHovered=function() return true end
draw()
assert(block('mk2').text=='>', 'fixture: the resting pointer does not light row 2')
assert(panel.nav(cfg,'down') and panel.nav(cfg,'up')); draw()
assert(selected().kind=='rule' and selected().rule.item=='Stone01', 'keyboard selection not on row 1')
assert(block('mk1').text=='>' and block('mk2').text=='', 'the caret stayed under the pointer: '
    ..tostring(block('mk1').text)..'|'..tostring(block('mk2').text))
assert(rail(1) and not rail(2), 'the cyan rail stayed under the pointer')
-- Right raises the row the caret is on.
local before=data.Stone01
assert(panel.nav(cfg,'right')); draw()
assert(data.Stone01~=before and data.Stone02==102, 'Right changed another row than the one marked')
assert(block('mk1').text=='>', 'the caret left row 1 after Right')
-- A click hands the highlight back to the pointer.
assert(panel.apply(cfg,{kind='tab',mode='list'},-1,true)~=nil)
assert(rb.kbd_focus==nil, 'a click left the keys in charge of the highlight')
draw()
assert(block('mk2').text=='>', 'after a click the pointer row is not current')
hot.IsHovered=function() return false end
draw()

-- Panel bugs P3-2: another change to an armed limit cancels Remove, and
-- the notice row says so instead of still asking for the second press.
data.Stone01=101; draw()
assert(panel.apply(cfg,{kind='drop',rule={work='Mining',item='Stone01',amount=101}},-1,false))
panel.refresh(cfg)
assert(notice():find('again to delete',1,true), 'fixture: Remove not armed: '..tostring(notice()))
data.Stone01=555; draw()
assert(notice()=='This limit changed; Remove cancelled.', 'a silent cancel: '..tostring(notice()))
data.Stone01=101; draw()

-- Panel bugs P3-1: an armed tile expires with Remove's timer, and says so.
panel.set_screen('item'); draw()
local tile=select_where(function(w) return w.kind=='item' end, 'a tile')
local writes0=writes
assert(panel.apply(cfg,tile,-1,true) and rb.armed, 'fixture: the tile did not arm')
now=now+rb.ARM_S+0.5; panel.refresh(cfg)
assert(rb.armed==nil and notice()=='Timed out. No limit was added.', 'arm kept: '..tostring(notice()))
assert(panel.apply(cfg,tile,-1,true) and writes==writes0, 'a click after the timeout created the limit')
assert(rb.armed, 'the click after the timeout did not arm again')
panel.escape(); draw()

-- Accessibility P3-3: the spent pager button says so in words.
assert(in_part('Caption') and not caption():find('page',1,true), 'the caption repeats the page: '..caption())
assert(block('prev').text=='First page' and block('next').text=='Next   >',
    'pager: '..tostring(block('prev').text)..' / '..tostring(block('next').text))
-- Newcomer P3-6: the page is said once, by the pager.
assert(block('pageno').text:find('^page 1 of '), 'pager count: '..tostring(block('pageno').text))

-- Panel bugs P3-4: Up from the top row leaves the grid for the search row,
-- Down from the bottom row for what is under the grid. Neither steps
-- sideways onto the next tile.
select_where(function(_,k) return k=='pick1' end, 'pick1')
assert(panel.nav(cfg,'up') and selected().kind=='search', 'Up on the top row: '..tostring(sel_key()))
draw()
select_where(function(_,k) return k=='pick25' end, 'pick25')
assert(panel.nav(cfg,'down'))
assert(selected().kind~='item', 'Down on the bottom row stepped to '..tostring(sel_key()))
draw()

-- Accessibility P3-2: the Enter hint follows the keyboard row, not the
-- pointer. The pointer resting on a tile hid it while the keys were on
-- the search row.
select_where(function(w) return w.kind=='search' end, 'search row'); draw()
local tile_face=assert(surface('pick4'))
tile_face.IsHovered=function() return true end
rb.kbd_focus=nil -- the pointer has moved since
draw()
assert(block('hint').text=='Search items: press Enter, then type', 'hint: '..tostring(block('hint').text))
tile_face.IsHovered=function() return false end

-- Panel bugs P3-3: a new search starts on page 1.
select_where(function(_,k) return k=='pick0' end, 'pick0')
assert(panel.page_step(cfg,1)); draw(); assert(panel.page_step(cfg,1)); draw()
assert(block('pageno').text:find('^page 3 of '), 'fixture: not on page 3: '..tostring(block('pageno').text))
local box=assert(search_box())
box.text='Stone'; draw()
assert(caption():find('Matching Stone',1,true), 'fixture: search not applied: '..tostring(caption()))
assert(block('pageno').text:find('^page 1 of [3-9]'), 'a new search kept page 3: '..tostring(block('pageno').text))

-- Panel bugs P3-5: Escape while typing a search ends the typing and keeps
-- the text; the next Escape closes.
local handed=0
overlay.focus_shell=function() handed=handed+1; box.focus=false; return true end
select_where(function(w) return w.kind=='search' end, 'search row')
rb.search_dirty=nil -- the typing above has ended
assert(panel.nav(cfg,'enter')); draw()
assert(box.focus==true, 'fixture: the box did not take the keyboard')
assert(panel.escape()==true and panel.open, 'Escape while typing closed the panel')
panel.refresh(cfg)
assert(notice()=='Search kept. Esc again closes.', 'escape notice: '..tostring(notice()))
assert(handed==1 and box.focus==false, 'the shell did not take the keyboard back')
assert(caption():find('Matching Stone',1,true), 'the query was dropped: '..tostring(caption()))
panel.escape()
assert(not panel.open, 'the second Escape did not close')
overlay.focus_shell=nil
panel.toggle(); draw()

-- Performance P2-1: the hover spacing can be tried live during a capture.
assert(rb.HOVER_GAP==0.033)
assert(panel.command(cfg,'hovergap 0.05'):find('0.05',1,true) and rb.HOVER_GAP==0.05)
assert(panel.command(cfg,'hovergap 5'):find('usage',1,true) and rb.HOVER_GAP==0.05)
rb.HOVER_GAP=0.033
]=], '@panel-round4-fixture'))()

-- Newcomer P2-1, P2-2, P3-4, P3-5: panel_status and install_check texts.
local status=require('panel_status')
-- Round 5 (multiplayer P3-3): a modded server that does not answer ends here too.
local stand='No answer from Pal Work Priority on this server. Limits cannot be set. Without the mod, the stand works as in the base game.'
assert(status.plain_reason('handshake_timeout')==stand, status.plain_reason('handshake_timeout'))
assert(status.plain_reason('Session role is not established')=='Still loading. Try again in a moment.')
local two=status.scope_label({scope='camp', choices={'a','b'}, index=1})
assert(two=='Base 1 of 2, each base stops on its own count', two)
assert(status.scope_label({scope='camp', choices={'a'}, index=1})=='your base')
-- The sub line holds about 125 characters: the two-base label, "change
-- base" and any install warning fit together.
local check=require('install_check')
for _,found in ipairs({{old_ue4ss='Pal/Binaries/Win64', sep='/'}, {old_copy='x'}, {workshop=true},
        {workshop=true, managed='0.4.1'}}) do
    local line='Storage: Base 10 of 12, each base stops on its own count - change base. '..check.short(found)
    assert(#line<=125, #line..': '..line)
end
print('PASS panel round 4: keyboard row keeps the caret, search hint, spent pager, tile arm expiry, '
    ..'Remove cancel notice, search page reset, grid edges, Escape in search, hover spacing, status texts')
