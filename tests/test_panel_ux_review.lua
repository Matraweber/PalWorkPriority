-- Regressions for the 2026-10-21 new-user review (docs/ux-review-2026-10-21.md):
-- raise above the top step, Escape with an armed Remove, a search with no
-- results, the version-mismatch message, key hints and plain confirmations.
-- Real renderer against the small UMG model of test_panel_render.lua.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
function Widget:SetColorAndOpacity(v) self.tint=v and v.SpecifiedColor end
-- The text in the reserved notice row (the "why" line).
local function notice()
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts.Notice and w.text and w.text~='' then return w.text end
    end
end
local function same(c,r,g,b) return c and math.abs(c.R-r)<1e-9 and math.abs(c.G-g)<1e-9 and math.abs(c.B-b)<1e-9 end

rules(1)
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
assert(panel.open)

-- P1-3: raise at or above the top step keeps the value (fixture ladder
-- 100/500/1000). It used to return the top step, so raise LOWERED it.
for _,case in ipairs({{100000,'above the highest step (1,000)'},{1000,'at the highest step (1,000)'}}) do
    data.Stone01=case[1]
    local before=writes
    assert(panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=case[1]},row=4},-1))
    assert(writes==before and data.Stone01==case[1], 'raise changed a limit at or above the top step: '..case[1])
    panel.refresh(cfg)
    assert(notice():find(case[2],1,true), 'no notice for the top step: '..tostring(notice()))
end
-- The mirror image: lower below the bottom step keeps the value too.
data.Stone01=50
local before=writes
assert(panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=50},row=4},1))
assert(writes==before and data.Stone01==50, 'lower raised a limit below the bottom step')
panel.refresh(cfg)
assert(notice():find('lowest step (100)',1,true))
-- An ordinary step still works, and says Saved with the readable name.
data.Stone01=500
assert(panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=500},row=4},-1))
assert(data.Stone01==1000 and writes==before+1, 'normal raise stopped working')
panel.refresh(cfg)
assert(notice()=='Saved: Mining limit 1,000 for Stone01.', 'step confirmation: '..tostring(notice()))
assert(not notice():find('requested',1,true))

-- P2-2: a new limit at or below storage says it is already reached
-- (base1 holds 37 Stone01 in this fixture).
data.Stone01=101
panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4},-1,true)
panel.refresh(cfg)
assert(panel.confirm_edit(cfg,'30') and data.Stone01==30)
panel.refresh(cfg)
assert(notice()=='Saved. Storage already holds 37 Stone01, so this limit is reached.',
    'reached warning: '..tostring(notice()))

-- P2-12: a limit is shown in full up to the 9,999,999 maximum.
data.Stone01=9999999
panel.refresh(cfg)
assert(rendered('9,999,999') and not rendered('10.0M'), 'limit shown above its own maximum')
data.Stone01=101
panel.refresh(cfg)

-- P1-2 / P2-14: the armed Remove explains itself, and Escape disarms it
-- first instead of closing the panel; a second Escape closes.
local remove={kind='drop',rule={work='Mining',item='Stone01',amount=101}}
assert(panel.apply(cfg,remove,-1,true))
panel.refresh(cfg)
assert(rendered('Sure?'), 'Remove did not arm')
assert(notice()=='Click Sure? to delete the Mining limit for Stone01.',
    'armed Remove notice: '..tostring(notice()))
panel.escape()
assert(panel.open, 'Escape with an armed Remove closed the panel')
panel.refresh(cfg)
assert(not rendered('Sure?') and rendered('Remove'), 'Escape did not disarm Remove')
assert(data.Stone01==101, 'disarming deleted the limit')
assert(notice():find('Remove cancelled',1,true))
-- The disarmed button needs two clicks again.
assert(panel.apply(cfg,remove,-1,true)); panel.refresh(cfg)
panel.escape(); panel.refresh(cfg)
assert(panel.apply(cfg,remove,-1,true) and data.Stone01==101, 'one click deleted after a disarm')
-- Native Escape takes the same path (RadialMenuCancel -> finish_cancel).
root.cancel_requested=true
panel.refresh(cfg)
assert(panel.open and not rendered('Sure?') and data.Stone01==101, 'native Escape closed instead of disarming')
panel.escape()
assert(not panel.open, 'second Escape did not close')
panel.toggle(); panel.refresh(cfg)

-- Key hints: both close keys, the host-only recheck and the mouse line.
assert(rendered('ESC / ALT+F1'), 'close key hint missing')
assert(rendered('Alt+F2: recheck'), 'host recheck hint missing')
-- The keys too (round 2): the arrows were never hinted. One footer per
-- device since round 3 (P1-1), each true to its input
-- (test_panel_round3.lua drives them); each fits the row.
local MOUSE='Click a limit to type a number, right click lowers it a step, Remove asks first.'
local FOOT='Up/Down move, Right/Enter raise a step, Left lowers, Delete removes, click types.'
-- UX crowding P2-4: the recheck key is said once, in the tab bar.
local foot=assert(rendered(MOUSE), 'mouse footer missing')
assert(#foot.text<=104, 'footer longer than its row: '..#foot.text)
panel.nav(cfg,'down'); panel.refresh(cfg)
foot=assert(rendered(FOOT), 'keyboard footer missing')
assert(#foot.text<=104, 'footer longer than its row: '..#foot.text)
local esc,close=rendered('ESC / ALT+F1'),rendered('CLOSE')
assert(esc.Slot.position.X+#esc.text*13*0.76<=close.Slot.position.X-9, 'close key hint runs into CLOSE')
local dm0=package.loaded.darnmenu
package.loaded.darnmenu={labels={key_panel='ALT+F7',key_pass='ALT+F8'}}
panel.refresh(cfg)
assert(rendered('ESC / ALT+F7') and rendered('Alt+F8: recheck'), 'rebound keys not named')
package.loaded.darnmenu=dm0
caps.is_client=true
panel.refresh(cfg)
assert(not rendered('Alt+F2: recheck'), 'client shown a recheck it cannot do')
assert(rendered(FOOT), 'client footer missing')
caps.is_client=nil
panel.refresh(cfg)

-- P1-6: a version mismatch is amber and says what to do, on both screens.
-- Round 3 (onboarding P2-1): it sends the player to the host, and names
-- this mod's version from ui.MOD_VERSION, not a copy of "0.5.0".
local ui0=package.loaded.ui
package.loaded.ui={MOD_VERSION='9.8.7'}
local MISMATCH='This server runs another Pal Work Priority version, which controls work here. '
    ..'Ask the host to update the server to 9.8.7.'
assert(#MISMATCH<=125, 'mismatch text longer than the notice row')
caps.view_status=function() return 'incompatible','server_requires_matching_mod' end
panel.refresh(cfg)
local label=assert(rendered('Server version incompatible'))
assert(same(label.tint,0.94,0.74,0.36), 'version mismatch is not amber')
local why=assert(rendered(MISMATCH), 'RULES lost the mismatch reason')
assert(same(why.tint,0.94,0.74,0.36))
panel.set_screen('item'); panel.refresh(cfg)
why=assert(rendered(MISMATCH), 'ITEMS does not say why nothing works')
assert(same(why.tint,0.94,0.74,0.36) and why.parent==overlay.parts.Notice)
caps.view_status=nil
panel.refresh(cfg)
assert(not rendered(MISMATCH))
package.loaded.ui=nil
assert(require('panel_status').plain_reason('schema_or_work_width')
    =='This server runs another Pal Work Priority version, which controls work here. Ask the host to update the server.',
    'mismatch without a version: '..tostring(require('panel_status').plain_reason('schema_or_work_width')))
package.loaded.ui=ui0
-- P2-5: an unlisted code never reaches the notice row raw.
local status=require('panel_status')
assert(select(3,status.save({state='error',error='session_not_admitting'}))
    =='Limits are not confirmed right now. Try again in a moment.')
assert(select(3,status.save({state='connecting',error='handshake_timeout'})):find('does not run Pal Work Priority',1,true))
assert(select(3,status.save({state='error',error='Disk write failed; retry pending'}))
    =='Disk write failed; retry pending', 'a sentence was replaced')

-- P2-13: a search with no results says so instead of empty headings.
local items=package.loaded.items
items.prepare_picker=function() return {}, 'ready' end
items.search_picker=function() return {} end
assert(panel.command(cfg,'filter zzz')=="filter is now 'zzz'")
panel.refresh(cfg)
local nomatch=assert(rendered('No item matches "zzz". Try a shorter name or clear the search.'),
    'no-result search shows no message')
assert(nomatch.parent==overlay.parts.Head)
assert(not rendered('ITEM') and not rendered('IN STORAGE'), 'empty headings left beside the message')
-- A search still being prepared is not reported as having no results.
items.prepare_picker=function() return nil, 'pending' end
panel.refresh(cfg)
assert(not rendered('No item matches "zzz". Try a shorter name or clear the search.'))
items.prepare_picker=function() return {}, 'ready' end
panel.command(cfg,'filter')
panel.refresh(cfg)
assert(rendered('ITEM') and not rendered('No item matches "zzz". Try a shorter name or clear the search.'),
    'headings did not come back after clearing the search')

-- P1-4: the partial verdict carries its base count ("Reached 2/3").
local sched={pass_id=7,last_capped={Mining={pass=7,camps=3,capped=2,unknown=0}},
    last_storage_by_camp={a={pass=7,guild='g',verified=true},b={pass=7,guild='g',verified=true},
        c={pass=7,guild='g',verified=true}}}
local capped,partly,bases=status.verdict(sched,'Mining',{verified=true,guild='g',scope='guild'})
assert(capped==false and partly==2 and bases==3, 'partial verdict lost its base count')
assert(writes>0 and stale==0)
]=], '@panel-ux-review-fixture'))()
print('PASS panel UX review: top-step raise, Escape disarm, no-match search, mismatch, hints, plain notices')
