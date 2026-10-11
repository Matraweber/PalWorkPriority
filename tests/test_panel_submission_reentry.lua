-- The post-submit guild lookup can reenter with the SAME guild and a new editor.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a');f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
rules(2);panel.refresh(cfg);panel.toggle();panel.refresh(cfg)
local original=caps.set
local armed=false
package.loaded.palapi.my_guild=function()
    if armed then armed=armed-1 end
    if armed==0 then
        armed=false
        panel.cancel_edit()
        panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone02',amount=102},row=5},-1,true)
        panel.refresh(cfg);assert(bound_editor)
    end
    return 'guild'
end
for _,boundary in ipairs({1,2})do
for _,pending in ipairs({false,true})do
    data.Stone01=101;data.Stone02=102
    panel.cancel_edit()
    panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4},-1,true)
    panel.refresh(cfg);panel.wants_pass=false
    caps.set=function(...)
        original(...);armed=boundary
        if pending then return false,'pending',{}end
        return true
    end
    assert(not panel.confirm_edit(cfg,'700'),'old action claimed completion in replacement editor')
    panel.refresh(cfg)
    assert(bound_editor,'post-submit same-guild reentry closed replacement editor')
    assert(data.Stone01==700 and data.Stone02==102)
    assert(not panel.wants_pass,'stale action requested a new-view pass')
    caps.set=original
    assert(panel.confirm_edit(cfg,'800'),'replacement editor was damaged')
    assert(data.Stone02==800)
end
end
]=],'@panel-submission-reentry'))()
print('PASS panel submit reentry: same-guild replacement editor survives true and pending replies')
