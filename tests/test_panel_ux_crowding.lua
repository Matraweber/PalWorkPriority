-- Regressions for the UX crowding review (docs/review-ux-crowding-2026-10-29.md),
-- Production Limits panel: a notice that outlives a change of the counted
-- base (P2-2), the selection after adding a limit on a client, where the
-- row arrives some beats later (P2-3), one help line and one footer (P2-4),
-- the empty list (P2-5), the Add row and the picker tile when selected
-- (P2-6, P2-7), and "Limits saved" only after a save (P3-2).
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
local function selected()
    return up(action,'hits')[up(action,'order')[up(action,'sel')] or '']
end
local function in_part(part)
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts[part] and w.text and w.text~='' then return w end
    end
end
local function notice() local w=in_part('Notice') return w and w.text end
local function footer()
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts.Foot and type(w.text)=='string'
            and (w.text:find('Up/Down',1,true) or w.text:find('Click a limit',1,true)
                or w.text:find('Controller:',1,true)) then return w.text end
    end
end
local function same(c,r,g,b) return c and math.abs(c.R-r)<1e-9 and math.abs(c.G-g)<1e-9 and math.abs(c.B-b)<1e-9 end
local function border(c,w,h)
    for _,x in ipairs(registry) do
        if not x.dead and x.kind=='Border' and same(x.colour,c.R,c.G,c.B) and x.Slot and x.Slot.size
            and (w==nil or x.Slot.size.X==w) and (h==nil or x.Slot.size.Y==h) then return x end
    end
end
local function draw() panel.refresh(cfg); panel.refresh(cfg) end
local function reopen() panel.close(); panel.toggle(); draw() end
local function rule_of(item)
    for _=1,60 do
        local w=selected()
        if w and w.kind=='rule' and w.rule and w.rule.item==item then return w end
        panel.move(1)
    end
    error('no row for '..item)
end
caps.support=function() return true end
local items=package.loaded.items
items.catalogue_ids=function() return {'Stone01','StoneNew'}, 'ready' end
items.prepare_picker=function() return {}, 'ready' end
items.search_picker=function() return {'Stone01','StoneNew'} end
stock.StoneNew=50

rules(1)
panel.refresh(cfg); panel.toggle(); draw()
assert(panel.open)

-- P2-2: a notice about storage outlives a change of the counted base. The
-- options page switched the scope with the panel open (ScreenShot00394), so
-- no input cleared it. Now it says what is counted instead.
scheduler.last_storage={guild={guild='guild',scope='guild',verified=true,pass=1,sampled_at=now,ttl=30}}
scheduler.last_totals_by_guild={guild={Stone01=51627}}
rule_of('Stone01'); assert(panel.nav(cfg,'left')); draw()
local saved_note=assert(notice())
assert(saved_note:find('Stone01',1,true), 'no save notice: '..saved_note)
cfg.storage_scope='global'; draw()
assert(notice()=='Now counting all loaded bases in your guild.', 'scope change kept: '..tostring((notice())))
cfg.storage_scope='camp'; draw()
assert(notice()=='Now counting your base.', 'back to one base: '..tostring((notice())))
-- Two bases: the line names which one.
scheduler.last_storage_by_camp.base2={guild='guild',scope='camp',verified=true,pass=1,sampled_at=now,ttl=30}
scheduler.last_totals_by_camp.base2={Stone01=5}
panel.apply(cfg,{kind='job'},-1,true); draw()
cfg.storage_scope='global'; draw()
assert(notice()=='Now counting all loaded bases in your guild.')
cfg.storage_scope='camp'; draw()
assert(notice()=='Now counting Base 1 of 2.', 'two bases: '..tostring((notice())))
-- "change base" is an input: it clears the notice itself, and says nothing.
panel.apply(cfg,{kind='job'},-1,true); draw()
assert(panel.apply(cfg,{kind='stock_scope'},-1,true)); draw()
assert(rb.stock and rb.stock.index==2 and not (notice() or ''):find('cannot be changed',1,true),
    'change base kept the old notice: '..tostring((notice())))
-- A prompt waiting for its second press is not replaced.
rule_of('Stone01'); assert(panel.row_action(cfg,'drop')); draw()
local armed=notice()
cfg.storage_scope='global'; draw()
assert(notice()==armed, 'the Remove prompt was replaced')
panel.escape(); cfg.storage_scope='camp'; draw()
-- No notice showing: nothing is said.
now=now+61; cfg.storage_scope='global'; draw()
assert(not (notice() or ''):find('Now counting',1,true), 'an expired notice came back as a scope note')
cfg.storage_scope='camp'
scheduler.last_storage_by_camp.base2=nil; scheduler.last_totals_by_camp.base2=nil
rb.stock_camp, rb.stock_picked=nil, nil
for _,meta in pairs(scheduler.last_storage_by_camp) do meta.sampled_at=now end
data.Stone01=101; draw()

-- P2-3, host: the new row is there on the next draw. The selection is on
-- it and the notice says what changes it.
panel.set_screen('item'); draw()
assert(panel.apply(cfg,{kind='item',item='StoneNew'},-1,true)); now=now+0.5
assert(panel.apply(cfg,{kind='item',item='StoneNew'},-1,true)); panel.refresh(cfg)
local w=selected()
assert(w and w.kind=='rule' and w.rule.item=='StoneNew', 'host: selection not on the new limit')
assert(notice()=='Saved: Mining limit 100 for StoneNew, just above storage. Click the number to change it.',
    'host notice: '..tostring((notice())))
data.StoneNew=nil; draw()

-- P2-3, client: the row comes from the server some beats after the add.
-- The selection waits for it instead of staying on "Add a limit", and
-- "Click the number" is said once it can be done.
local net0=package.loaded.net
package.loaded.net={epoch=5, request_stock=function() return true end,
    storage_view=function(g) return {verified=true, guild=g, choices={'a'}, scope='camp', camp='a',
        index=1, label='your base', totals={StoneNew=50, Stone01=37}, epoch=5, expires_at=now+10} end}
caps.is_client=true
rb.stock_camp, rb.stock_picked=nil, nil
local set0=caps.set
local sent={}
caps.set=function(_, item, amount) sent[#sent+1]={item, amount} return true end
local function client_add()
    panel.set_screen('item'); draw()
    local armed_ok=panel.apply(cfg,{kind='item',item='StoneNew'},-1,true)
    assert(armed_ok, 'client arm refused: '..tostring(up(rb.saving_done,'notice'))); now=now+0.5
    local ok=panel.apply(cfg,{kind='item',item='StoneNew'},-1,true)
    assert(ok, 'client add refused: '..tostring(up(rb.saving_done,'notice')))
end
client_add()
assert(#sent==1 and sent[1][1]=='StoneNew' and data.StoneNew==nil, 'the client wrote the limit itself')
local said='Sent to the server: Mining limit 100 for StoneNew, just above storage.'
for _=1,4 do -- a few beats with no row yet
    panel.refresh(cfg); now=now+0.3
    assert(notice()==said, 'client promised a step before the row arrived: '..tostring((notice())))
end
assert(rb.reveal_rule, 'the reveal was dropped before its row arrived')
data.StoneNew=100 -- the server's row arrives
panel.refresh(cfg)
w=selected()
assert(w and w.kind=='rule' and w.rule.item=='StoneNew',
    'client: selection not on the new limit: '..tostring(w and (w.kind..' '..tostring(w.rule and w.rule.item))))
assert(rb.reveal_rule==nil)
-- The selection is placed after a draw, so the notice row shows the step
-- on the next one.
panel.refresh(cfg)
assert(selected().rule.item=='StoneNew', 'the next draw lost the revealed row')
assert(notice()==said..' Click the number to change it.', 'client notice after the row: '..tostring((notice())))
-- A row that never arrives: given up after RB.REVEAL_S, with no promise.
data.StoneNew=nil; draw()
client_add()
panel.refresh(cfg)
now=now+rb.REVEAL_S+0.1; panel.refresh(cfg)
assert(rb.reveal_rule==nil, 'a reveal waited forever')
assert(notice()==said, 'a row that never came was promised: '..tostring((notice())))
-- An input while waiting cancels it: the selection stays where it was put.
client_add(); panel.refresh(cfg)
panel.move(-1); local moved=rb.ident(selected())
assert(rb.reveal_rule==nil and moved~='rule:Mining|StoneNew')
data.StoneNew=100; panel.refresh(cfg)
assert(rb.ident(selected())==moved, 'a late row took the selection back after a move')
caps.is_client=nil; caps.set=set0; package.loaded.net=net0
rb.stock_camp, rb.stock_picked=nil, nil
data.StoneNew=nil; draw()

-- P2-4: the help row says what a limit does, the footer how to change it,
-- and the recheck key is in the tab bar only.
cfg.item_limits_on_rocks=nil
local status=require('panel_status')
local verdict=status.verdict
status.verdict=function() return false,nil,1 end
data.Stone01=101; panel.nav(cfg,'down'); draw()
assert(notice()==rb.LIMIT_HELP.rocks, 'help row: '..tostring((notice())))
assert(footer()==rb.FOOT.keys, 'footer: '..tostring((footer())))
assert(not notice():find('Right/Enter',1,true) and not notice():find('Click a limit',1,true))
assert(rendered('ALT+F2 RECHECK NOW') and not footer():find('rechecks',1,true))
cfg.item_limits_on_rocks=false; draw()
assert(notice()==rb.LIMIT_HELP.group)
status.verdict=verdict

-- P2-5 and P2-6: the empty list defines a limit, shows no footer, and the
-- selected "Add a limit" keeps its bright fill and gets the cyan rail.
rules(0); draw()
assert(notice()=='No limits yet. A limit stops a job once storage holds that many of an item.', tostring((notice())))
assert(footer()==nil, 'footer on an empty list: '..tostring((footer())))
assert(selected().kind=='new')
local PRIMARY={R=0.034,G=0.188,B=0.305}
local add=assert(border(PRIMARY,nil,30), 'selected Add row lost its bright fill')
assert(border({R=0.42,G=0.80,B=1.00},3,30), 'selected Add row has no cyan rail')
assert(add.Slot.size.X>500)
rules(1); draw()
assert(footer(), 'footer gone with limits')

-- P2-7: the selected picker tile has a fill of its own.
panel.set_screen('item'); draw()
w=selected()
assert(w and w.kind=='item', 'picker selection: '..tostring(w and w.kind))
assert(border(rb.TILE_SEL,nil,36), 'selected tile has no tint')
assert(not same(rb.TILE_SEL,0.080,0.105,0.140) and not same(rb.TILE_SEL,0.060,0.080,0.110))
panel.set_screen('list'); draw()

-- P3-2: "Limits saved" for a few seconds after a save, then nothing.
reopen()
assert(not rendered('Limits saved'), 'Limits saved on opening, with no save')
rule_of('Stone01'); assert(panel.nav(cfg,'right')); draw()
assert(rendered('Limits saved'), 'no Limits saved after a save')
now=now+rb.SAVED_S-0.5; draw()
assert(rendered('Limits saved'), 'Limits saved went too soon')
now=now+1; draw()
assert(not rendered('Limits saved'), 'Limits saved stayed')
-- A save the panel watched finish counts too.
caps.state='saving'; draw()
assert(rendered('Saving...'))
caps.state='saved'; draw()
assert(rendered('Limits saved'), 'a finished save was not said')
now=now+rb.SAVED_S+0.1; draw()
assert(not rendered('Limits saved'))
data.Stone01=101
assert(stale==0)
]=], '@panel-ux-crowding-fixture'))()
print('PASS panel UX crowding: scope notice, client reveal, help and footer, empty list, Add row, tile tint, saved label')
