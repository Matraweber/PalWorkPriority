-- Real picker renderer; model shell row allocation rather than native pixels.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
local now=100
os.clock=function() return now end
for _,meta in pairs(scheduler.last_storage_by_camp) do meta.sampled_at=now end
overlay.fit_width=function() end
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
panel.set_screen('item'); panel.refresh(cfg)
panel.apply(cfg,{kind='page',by=1},-1,true); panel.refresh(cfg)
assert(rendered('page 2 of 4'), 'fixture did not reach a non-first picker page')
assert(overlay.parts.NoticeRow.visibility==0,
    'picker help row is collapsed before an unsupported selection')
local help=assert(rendered('Click an item to add a limit. Items saying Edit already have one: click to open it.'))
assert(help.parent==overlay.parts.Notice, 'help is not in the reserved notice row')
assert(rendered('Search items'), 'picker placeholder still promises item limits')
local row, height, widgets=overlay.parts.NoticeRow,overlay.height,count
local positions={}
for _,w in ipairs(registry) do
    if not w.dead and w.Slot and w.Slot.position then
        positions[w]={w.parent,w.Slot.position.X,w.Slot.position.Y}
    end
end
local function stable()
    assert(overlay.parts.NoticeRow==row and row.visibility==0, 'notice allocation changed')
    assert(overlay.height==height and count==widgets, 'notice changed panel height or created widgets')
    assert(rendered('page 2 of 4'), 'notice reset picker page')
    for w,p in pairs(positions) do
        assert(not w.dead and w.parent==p[1] and w.Slot.position.X==p[2] and w.Slot.position.Y==p[3],
            'notice changed an existing widget position/parent')
    end
end
assert(not panel.apply(cfg,{kind='item',item='StoneAA'},-1,true))
panel.refresh(cfg)
assert(rendered('This item cannot have a limit.')==help,
    'rejection did not replace the existing help text')
stable()
-- Kept until the next input (review B6), then the help comes back in place.
now=108; panel.refresh(cfg)
assert(rendered('This item cannot have a limit.')==help, 'notice expired before any input')
panel.nav(cfg,'right'); panel.refresh(cfg)
assert(rendered('Click an item to add a limit. Items saying Edit already have one: click to open it.')==help,
    'input did not restore help in place')
stable()
assert(not panel.apply(cfg,{kind='item',item='StoneAB'},-1,true))
panel.refresh(cfg); stable()
assert(writes==0, 'unsupported selections wrote settings')
]=], '@picker-notice-layout-fixture'))()
print('PASS picker notice: permanent row, rejection/expiry reuse, positions, page and neutral search')
