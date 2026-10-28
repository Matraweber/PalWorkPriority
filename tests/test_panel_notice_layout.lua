-- RULES notice/edit/error transitions must not collapse a shell flow row.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
local now=100
os.clock=function() return now end
overlay.fit_width=function() end
rules(14)
-- No scheduler verdict in this fixture, so the help explains "?" / "No count yet".
local HELP='? or No count yet: storage is not counted yet. Alt+F2 rechecks now.'
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
panel.page_step(cfg,1); panel.refresh(cfg)
assert(rendered('page 2 of 2, 14 limits'), 'fixture did not reach second rules page')
assert(overlay.parts.NoticeRow.visibility==0,
    'rules help row is collapsed before a notice or edit')
local help=assert(rendered(HELP))
assert(help.parent==overlay.parts.Notice)
local row,height=overlay.parts.NoticeRow,overlay.height
local positions={}
for _,w in ipairs(registry) do
    if not w.dead and w.Slot and w.Slot.position then
        positions[w]={w.parent,w.Slot.position.X,w.Slot.position.Y}
    end
end
local function stable()
    assert(overlay.parts.NoticeRow==row and row.visibility==0, 'rules notice allocation changed')
    assert(overlay.height==height and rendered('page 2 of 2, 14 limits'), 'notice changed panel height/page')
    for w,p in pairs(positions) do
        -- The limit text is intentionally blanked beneath the amount editor;
        -- its right-aligned empty string is not a visible/control surface.
        if w.text~='' then
            assert(not w.dead and w.parent==p[1] and w.Slot.position.X==p[2] and w.Slot.position.Y==p[3],
                'notice/edit/error moved '..tostring(w.text or w.name)..' from '..p[2]..','..p[3]
                    ..' to '..tostring(w.Slot.position.X)..','..tostring(w.Slot.position.Y))
        end
    end
end
assert(panel.apply(cfg,{kind='item',item='Stone14'},-1,true))
panel.refresh(cfg); stable()
assert(help.text:find('Click the limit to change it',1,true), 'existing-rule notice missing')
-- A notice stays until the next input, not 7 seconds (review B6, 2026-10-28),
-- with a long upper bound for a panel left open.
now=108; panel.refresh(cfg); stable()
assert(help.text:find('Click the limit to change it',1,true), 'notice expired before any input')
panel.nav(cfg,'down'); panel.refresh(cfg); stable()
assert(help.text==HELP, 'an input did not clear the notice')
assert(panel.apply(cfg,{kind='item',item='Stone14'},-1,true))
panel.refresh(cfg); stable()
now=108+61; panel.refresh(cfg); stable()
assert(help.text==HELP, 'notice outlived its upper bound')
caps.state,caps.error='error','Disk write failed; retry pending'
panel.refresh(cfg); stable()
assert(rendered(caps.error)==help, 'save error did not reuse notice widget')
caps.state,caps.error='saved',nil
panel.refresh(cfg); stable()
panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone14',amount=114},row=4},-1,true)
panel.refresh(cfg); stable()
assert(rendered('Confirm') and rendered('Cancel'), 'editor controls missing')
assert(not panel.confirm_edit(cfg,'1.5'))
panel.refresh(cfg); stable()
assert(help.text:find('Enter a whole number',1,true), 'editor validation message missing')
panel.cancel_edit(); panel.refresh(cfg); stable()
assert(help.text==HELP)
assert(writes==0 and data.Stone14==114, 'notice transitions altered the rule')
]=], '@rules-notice-layout-fixture'))()
print('PASS rules notice: permanent row, notices/errors/edit/cancel, expiry and fixed controls/page')
