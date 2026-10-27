-- Reuse only the UMG fixture, without running its unrelated panel scenarios.
local file = assert(io.open(TEST_ROOT .. '/tests/test_panel_render.lua', 'r'))
local source = file:read('*a'); file:close()
local start = assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
local fixture = source:sub(1, start - 1)
assert(load(fixture .. '\n' .. [=[
local all = { Mining = { Stone01=700 }, EmitFlame = { StoneWrong=900 } }
local support_calls, supports = 0, {StoneNew=true}
caps.all=function() return all end
caps.rule_kind=function(work,item)
    if item=='Stone01' or item=='StoneOff' then return 'legacy' end
    return 'item'
end
caps.support=function(work,item,guild)
    support_calls=support_calls+1
    assert(work=='Mining' and guild=='guild', 'wrong picker capability scope')
    if item=='StoneOff' then return true, 'Legacy group' end
    return supports[item]==true, 'Unsupported item limit: no verified output control'
end
local storage={Stone01=4, StoneNew=5, StoneWrong=6, StoneBlocked=7, StoneOff=8}
scheduler.last_totals_by_camp.base1=storage
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
panel.set_screen('item'); panel.refresh(cfg)
-- Every unsupported Mining item here is covered by the Stone01 group limit.
assert(rendered('Group limit applies'),
    'an item stopped by a group limit is not explained before item selection')
assert(not rendered('No item limit support'), 'old jargon label returned')
assert(rendered('Edit group limit'), 'group limit edit scope is hidden')
assert(rendered('Add group limit'), 'supported creation is not distinguished')
assert(rendered('Restore group limit'), 'masked legacy path claims item-only creation')

local function up(fn,name)
    for i=1,100 do local n,v=debug.getupvalue(fn,i); if n==name then return v end end
    error('missing upvalue '..name)
end
local rb=up(panel.refresh,'RB')
rb.SLICE=math.huge
panel.refresh(cfg)
local before={}
for key,w in pairs(rb.runtime.objects) do before[key]=w end
local n=count
panel.refresh(cfg)
assert(count==n, 'stable picker recreated widgets')
for key,w in pairs(before) do assert(rb.runtime.objects[key]==w, 'stable picker replaced widget') end
local unsupported=assert(rendered('Group limit applies'))
local old_x,old_y=unsupported.Slot.position.X,unsupported.Slot.position.Y
-- Storage ordering puts the existing masked group first, unsupported second.
panel.nav(cfg,'right')
assert(not panel.nav(cfg,'enter') and writes==0 and panel.open,
    'keyboard browsing skipped or created the unavailable item')
panel.refresh(cfg)
assert(unsupported.Slot.position.X==old_x and unsupported.Slot.position.Y==old_y,
    'selecting an unavailable item moved its row')
local classifier=assert(rb.picker, 'picker presentation unavailable')
assert(classifier.describe(caps,{EmitFlame={Stone01=700}},'EmitFlame','Stone01','guild').detail==
    'Group limit for all Kindling work', 'picker exposed an internal work name')
-- Without a covering group the tile says when new limits come (review P1-1).
local plain=classifier.describe(caps,{},'Mining','StoneBlocked','guild')
assert(plain.state=='unavailable' and plain.label=='Cannot be limited'
    and plain.detail=='This item cannot have a limit.', 'unsupported item not explained')
local covered=classifier.describe(caps,all,'Mining','StoneBlocked','guild')
assert(covered.state=='unavailable' and covered.label=='Group limit applies' and covered.group=='Stone01'
    and covered.detail:find('switches all Mining work',1,true), 'group-covered item not explained')
assert(classifier.describe(caps,all,'Mining','StoneWrong','guild').state=='unavailable',
    'a rule for a different work type advertised an editable rule')
assert(not panel.apply(cfg,{kind='item',item='StoneWrong'},-1,true) and writes==0,
    'wrong-work rule permitted an unsupported create')
assert(panel.apply(cfg,{kind='item',item='Stone01'},-1,true) and writes==0,
    'existing legacy rule was overwritten or inaccessible')
panel.set_screen('item'); panel.refresh(cfg)
supports.StoneNew=false
assert(not panel.apply(cfg,{kind='item',item='StoneNew'},-1,true) and writes==0,
    'stale supported presentation authorized creation')
panel.refresh(cfg)
assert(not rendered('Add group limit'), 'capability change retained Add label')
supports.StoneNew=true
panel.refresh(cfg)
assert(rendered('Add group limit'), 'capability recovery was cached away')
assert(panel.apply(cfg,{kind='item',item='StoneNew'},-1,true) and writes==1,
    'supported creation path stopped working')
caps.support=nil
assert(classifier.describe(caps,{},'Mining','StoneNew','guild').state=='unavailable')
caps.support=function() error('unavailable') end
assert(classifier.describe(caps,{},'Mining','StoneNew','guild').state=='unavailable')
assert(classifier.describe(caps,all,'Mining','Stone01',nil).state=='unavailable')
-- Cross-check the presentation against actual caps semantics, including OFF.
local actual=dofile(TEST_ROOT..'/Scripts/caps.lua')
actual.data={guild={Mining={Stone01=700,StoneOff=false},EmitFlame={StoneWrong=900}}}
local current=actual.all({},'guild')
assert(classifier.describe(actual,current,'Mining','Stone01','guild').state=='existing')
-- Real caps (2026-10-27): a new Mining item joins the Mining group.
local joins=classifier.describe(actual,current,'Mining','StoneWrong','guild')
assert(joins.state=='create' and joins.label=='Add group limit' and joins.group=='Stone01')
assert(classifier.describe(actual,current,'Mining','StoneOff','guild').label==
    'Restore group limit')
print('PASS picker capability: visible states, exact rule scope, fresh admission and widget reuse')
]=], '@picker-capability-fixture'))()
