-- Existing picker items must reveal their exact rule, not the previous page.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
rules(27)
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
local function selected()
    local values={}
    local action
    for i=1,100 do
        local name,value=debug.getupvalue(panel.activate,i)
        if name=='action' then action=value break end
    end
    for i=1,100 do
        local name,value=debug.getupvalue(assert(action),i)
        if not name then break end
        values[name]=value
    end
    return values.hits[values.order[values.sel]]
end
for _,case in ipairs({{15,2},{27,3},{1,1},{26,2}}) do
    panel.set_screen('item'); panel.refresh(cfg)
    local id='Stone'..string.format('%02d',case[1])
    assert(panel.apply(cfg,{kind='item',item=id},-1,true))
    panel.refresh(cfg)
    assert(rendered('page '..case[2]..' of 3, 27 limits'), 'picker revealed wrong rules page for '..id)
    local target=assert(selected())
    assert(target.kind=='rule' and target.rule.work=='Mining' and target.rule.item==id,
        'picker selected another rule instead of '..id)
    assert(writes==0 and data[id]==100+case[1], 'navigation changed a saved limit')
end
-- Recompute placement from the next current snapshot, not the click-time index.
panel.set_screen('item'); panel.refresh(cfg)
assert(panel.apply(cfg,{kind='item',item='Stone14'},-1,true))
data.Stone01=nil
panel.refresh(cfg)
assert(rendered('page 1 of 2, 26 limits'), 'rule reorder used a stale page index')
assert(selected().rule.item=='Stone14', 'rule reorder revealed the wrong target')
-- An explicit intervening tab change cancels the pending reveal.
assert(panel.apply(cfg,{kind='item',item='Stone27'},-1,true))
assert(panel.set_screen('item')); assert(panel.set_screen('list'))
panel.refresh(cfg)
assert(rendered('page 1 of 2, 26 limits'), 'cancelled reveal changed the rules page')
for _,navigate in ipairs({'move','move_row'}) do
    assert(panel.apply(cfg,{kind='item',item='Stone27'},-1,true))
    panel[navigate](1)
    panel.refresh(cfg)
    assert(rendered('page 1 of 2, 26 limits'),navigate..' did not cancel the old reveal')
end
assert(panel.apply(cfg,{kind='item',item='Stone27'},-1,true))
package.loaded.palapi.my_guild=function() return 'other-guild' end
panel.refresh(cfg)
assert(rendered('page 1 of 2, 26 limits'), 'guild change retained the old reveal')
assert(writes==0, 'reveal performed a settings write')
]=], '@rule-reveal-fixture'))()
