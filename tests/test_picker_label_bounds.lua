local presentation = require('picker_presentation')
local caps = {rule_kind=function() return 'legacy' end, support=function() return true end}
for _,result in ipairs({'nil', 'unexpected'}) do
    local unknown = presentation.describe({support=function()
        if result == 'unexpected' then return 'yes' end
    end}, {}, 'Mining', 'Example', 'guild')
    assert(unknown.state=='unavailable' and unknown.label=='Support unknown',
        'indeterminate capability was presented as a definite unsupported verdict')
end
for _,work in ipairs({'GenerateElectricity','ProductMedicine','Mining'}) do
    local shown=presentation.describe(caps,{[work]={Example=100}},work,'Example','guild')
    assert(#shown.label<=21, 'capability label can overflow its tile: '..shown.label)
    assert(shown.detail:find(require('workdefs').label(work),1,true), 'full work explanation lost')
end
for _,shown in ipairs({
    presentation.describe(caps,{},'Mining','Example',nil),
    presentation.describe({support=function() return false end},{},'Mining','Example','guild'),
    presentation.describe({}, {},'Mining','Example','guild'),
    presentation.describe(caps,{},'GenerateElectricity','Example','guild'),
    -- Covered by another item's group limit, and the plain 0.5.0 refusal.
    presentation.describe({rule_kind=function() return 'legacy' end, support=function() return false end},
        {GenerateElectricity={Other=1}},'GenerateElectricity','Example','guild'),
    presentation.describe({support=function() return false end},{},'GenerateElectricity','Example','guild'),
}) do
    assert(#shown.label<=21 and type(shown.detail)=='string', 'unbounded or unexplained capability')
end

local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
local workdefs=require('workdefs')
local previous=workdefs.work_for_item
workdefs.work_for_item=function(id)
    if id=='StonePower' then return 'GenerateElectricity' end
    return previous(id)
end
caps.all=function() return {GenerateElectricity={StonePower=500}} end
scheduler.last_totals_by_camp.base1={StonePower=999999999}
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
panel.set_screen('item'); panel.refresh(cfg)
local label=assert(rendered('Edit group limit'))
assert(label.Font.Size==12, 'capability label is not the readable 12pt')
local count=assert(rendered('999,999,999'))
assert(count.Slot.position.Y + 14*1.35 <= label.Slot.position.Y,
    'storage count extends into the capability line')
assert(label.Slot.position.X + #label.text*label.Font.Size*0.83 < count.Slot.position.X,
    'compact label reaches the storage column even with a large count')
assert(panel.apply(cfg,{kind='item',item='StonePower'},-1,true))
panel.refresh(cfg)
local explained=false
for _,w in ipairs(registry) do
    if not w.dead and w.text and w.text:find('Group limit for all Generating Electricity work',1,true) then
        explained=true
    end
end
assert(explained, 'selection notice omitted full legacy scope')
assert(writes==0, 'viewing existing limit wrote settings')
]=], '@picker-label-bounds-fixture'))()
print('PASS picker labels: long work names, large count separation and full notice')
