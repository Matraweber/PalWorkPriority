-- Regressions for the 2026-10-28 audit, bundles C and E
-- (docs/review-2026-10-28.md): per-item Mining rows judged by their own item,
-- item-limit wording, plain help texts, the upgrade notice, readable sizes,
-- both rails on a selected tile, controller hints and the hidden first frame.
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
local function notice()
    for _,w in ipairs(registry) do
        if not w.dead and w.parent==overlay.parts.Notice and w.text and w.text~='' then return w.text end
    end
end
local function same(c,r,g,b) return c and math.abs(c.R-r)<1e-9 and math.abs(c.G-g)<1e-9 and math.abs(c.B-b)<1e-9 end
local function border(r,g,b,w,h)
    for _,x in ipairs(registry) do
        if not x.dead and x.kind=='Border' and same(x.colour,r,g,b) and x.Slot and x.Slot.size
            and (w==nil or x.Slot.size.X==w) and (h==nil or x.Slot.size.Y==h) then return x end
    end
end
local status=require('panel_status')

-- E: the first frame is invisible, the next refresh shows it (screenshot 02a).
panel.refresh(cfg); panel.toggle()
assert(overlay.parts.Root.opacity==0, 'first frame drawn visible')
panel.refresh(cfg)
assert(overlay.parts.Root.opacity==1, 'panel stayed invisible after its first layout')
panel.refresh(cfg)

-- C: per-item Mining rows. Fixture: Stone01 limit 101 holds 37, Stone02 none.
cfg.item_limits_on_rocks=nil
rules(2)
local verdict=status.verdict
status.verdict=function() return false,1,2 end
panel.refresh(cfg)
assert(rendered('Item limit, rocks'), 'per-item Mining row sub-label')
assert(not rendered('Reached 1/2') and rendered('Below limit'), 'per-item row showed the whole-Mining verdict')
assert(notice()~='Reached 1/2: this job is off at 1 of your 2 bases.')
-- Its own item first: held rocks, then storage against the limit.
package.loaded.item_sources={item_stopped=function(item) return item=='Stone01' end}
panel.refresh(cfg)
assert(rendered('Rocks stopped'), 'held rocks not said')
package.loaded.item_sources=nil
status.item_stopped=function(item) return item=='Stone02' end
data.Stone01=30
panel.refresh(cfg)
assert(rendered('Rocks stopped') and rendered('Limit reached'), 'item state from panel_status ignored')
status.item_stopped=nil
data.Stone01=101
-- The server says per-item is off: group rows, "Reached N/M" and its notice.
status.per_item=function() return false end
panel.refresh(cfg)
assert(rendered('Group limit') and not rendered('Item limit, rocks'), 'server setting ignored')
assert(rendered('Reached 1/2'), 'group row lost Reached N/M')
assert(notice()=='Reached 1/2: this job is off at 1 of your 2 bases.', 'reached notice: '..tostring(notice()))
status.per_item=nil
status.verdict=verdict

-- C: uncounted texts, host and client.
panel.refresh(cfg)
assert(notice()=='? or No count yet: storage is not counted yet. Alt+F2 rechecks now.' or
    notice():find('Mining stops by item',1,true), 'host help: '..tostring(notice()))
scheduler.last_storage_by_camp.base1.verified=false
panel.refresh(cfg)
assert(notice()=='? or No count yet: storage is not counted yet. Alt+F2 rechecks now.', 'host uncounted: '..tostring(notice()))
assert(rendered('No count yet') and rendered('?'))
caps.is_client=true
panel.refresh(cfg)
assert(notice()=="Waiting for the server's count.", 'client uncounted: '..tostring(notice()))
caps.is_client=nil
scheduler.last_storage_by_camp.base1.verified=true
scheduler.last_storage_by_camp.base1.sampled_at=os.clock()

-- C: empty list.
rules(0)
panel.refresh(cfg)
assert(notice()=="No limits yet. Mining limits stop only that item's rocks; others stop their whole job.")
assert(rendered('Click "Add a limit" below to start.'))
rules(2)

-- E: the selected rules row: the darker fill and a 3 px cyan rail.
panel.set_screen('list'); panel.refresh(cfg); panel.refresh(cfg)
assert(border(0.060,0.080,0.110), 'selected row fill is not ROW_SEL')
assert(border(0.42,0.80,1.00,3,30), 'selected row has no cyan rail')

-- C: picker wording for Mining item limits, the help and the caption.
caps.support=function() return true end
caps.rule_kind=function(_,item) return data[item] and 'legacy' or 'item' end
stock.Stone01=95 -- first on page 1: the picker sorts by quantity
panel.set_screen('item'); panel.refresh(cfg); panel.refresh(cfg)
assert(rendered('Add item limit'), 'Mining create tile uses group wording')
assert(rendered('Edit item limit'), 'Mining existing tile uses group wording')
assert(not rendered('Edit group limit') and not rendered('Add group limit'))
assert(notice()=='Click an item to add a limit. Items saying Edit already have one: click to open it.')
local caption=false
for _,w in ipairs(registry) do
    if not w.dead and w.text and w.text:find('Under each item: what a click does',1,true) then caption=true end
end
assert(caption, 'caption does not say what the line under an item means')
-- E: 12pt labels in the item colour, 14pt names.
local label=assert(rendered('Edit item limit'))
assert(label.Font.Size==12 and same(label.tint,0.86,0.89,0.95), 'tile label not 12pt item colour')
assert(rendered('Stone01').Font.Size==14, 'tile name not 14pt')
-- E: a selected tile that has a limit keeps the green rail and adds the cyan.
for _=1,200 do
    local w=selected()
    if w and w.kind=='item' and w.item=='Stone01' then break end
    panel.move(1)
end
assert(selected().item=='Stone01')
panel.refresh(cfg); panel.refresh(cfg)
assert(border(0.558,0.847,0.631,3,36), 'green has-a-limit rail lost on the selected tile')
assert(border(0.42,0.80,1.00,3,36), 'cyan selection rail missing on the selected tile')
local opened=assert(panel.apply(cfg,{kind='item',item='Stone01'},-1,true))
panel.refresh(cfg)
assert(notice():find('Item limit for Mining',1,true), 'existing item limit notice: '..tostring(notice()))

-- C: Show all during a search is dimmed and explained, and does nothing.
local items=package.loaded.items
items.prepare_picker=function() return {}, 'ready' end
items.search_picker=function() return {'Stone01'} end
panel.set_screen('item')
assert(panel.command(cfg,'filter ston')=="filter is now 'ston'")
panel.refresh(cfg)
local all=assert(rendered('Show all items a base can make (a search already does)'), 'Show all not explained')
assert(same(all.tint,0.62,0.67,0.73), 'Show all not dimmed during a search')
assert(not panel.apply(cfg,{kind='toggle_all'},-1,true), 'Show all toggled during a search')
panel.refresh(cfg)
assert(notice()=='A search already covers every item a base can make. Clear it to use Show all.')
assert(rendered('Show all items a base can make (a search already does)'))
panel.command(cfg,'filter')
panel.refresh(cfg)
assert(rendered('Show all items a base can make'))

stock.Stone01=37
-- E: a controller: no keyboard keys in the header, Left/Right in the hint,
-- and the editor says Y and B.
local api=package.loaded.palapi
api.last_input_type=1
panel.set_screen('list'); panel.refresh(cfg)
assert(not rendered('ALT+F2 RECHECK NOW') and not rendered('ESC / ALT+F1') and rendered('B'),
    'controller header still names keyboard keys')
assert(rendered('Controller: Up/Down move, Left/Right step a limit, Y opens or raises, X removes, LB/RB tabs, LT/RT pages, B closes.'))
assert(panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4},-1,true))
panel.refresh(cfg)
assert(notice()=='Set Stone01: whole number. Y saves, B cancels.', 'pad editor hint: '..tostring(notice()))
panel.escape(); panel.refresh(cfg)
api.last_input_type=nil
cfg.item_limits_on_rocks=false

-- C: an upgrade that reset config.lua is said once, on opening.
local UPGRADE='Your earlier config.lua was not found (the Workshop or Vortex update removed it). '
    ..'Default settings are in use; options-menu settings are kept.'
package.loaded.configuration={upgrade_reset=true}
panel.close(); panel.toggle(); panel.refresh(cfg)
assert(notice()==UPGRADE, 'upgrade reset not said: '..tostring(notice()))
panel.close(); panel.toggle(); panel.refresh(cfg)
assert(notice()~=UPGRADE, 'upgrade reset said twice')
package.loaded.configuration=nil
assert(writes==0 and stale==0)
]=], '@panel-item-wording-fixture'))()
print('PASS panel wording and access: per-item rows, item-limit words, help, sizes, rails, controller, first frame')
