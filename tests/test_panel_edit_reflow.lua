local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
rules(14)
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
local function edit(id,amount)
    panel.apply(cfg,{kind='rule',rule={work='Mining',item=id,amount=amount},row=4},-1,true)
    panel.refresh(cfg)
    assert(bound_editor, 'editor did not open')
end
-- Deleting the first row reuses its physical slot for a different item.
edit('Stone01',101)
data.Stone01=nil
panel.refresh(cfg)
assert(bound_editor==nil,'deleted rule retained its editor over another rule')
assert(not panel.confirm_edit(cfg,'900') and writes==0,'deleted draft could still commit')
-- A sorted insertion can displace the last visible rule onto the next page.
rules(14); panel.refresh(cfg)
edit('Stone13',113)
data.AFirst=100
panel.refresh(cfg)
assert(bound_editor==nil,'off-page rule retained a stale editor placement')
assert(not panel.confirm_edit(cfg,'900') and writes==0,'off-page draft could still commit')
-- An unrelated insertion that keeps the target visible must preserve its draft.
rules(14); panel.refresh(cfg)
edit('Stone02',102)
local editor=bound_editor
editor.text='777'
data.AFirst=100
panel.refresh(cfg)
assert(bound_editor==editor and editor.text=='777','visible row movement lost the draft')
assert(panel.confirm_edit(cfg) and data.Stone02==777 and writes==1)
-- Cancellation happens in this refresh even when game-thread actions queue.
edit('Stone03',103)
local queue={}
ExecuteInGameThread=function(fn) queue[#queue+1]=fn end
panel.confirm_edit(cfg,'999')
data.Stone03=nil
panel.refresh(cfg)
assert(bound_editor==nil,'reflow cancellation waited for another callback')
for _,fn in ipairs(queue) do fn() end
ExecuteInGameThread=nil
assert(writes==1 and data.Stone03==nil,'queued confirm survived reflow cancellation')
edit('Stone04',104)
package.loaded.palapi.my_guild=function() return 'other-guild' end
panel.refresh(cfg)
assert(bound_editor==nil,'guild change retained a local draft')
assert(not panel.confirm_edit(cfg,'999') and writes==1)
-- A just-opened draft is invalidated before its first paint: never focus it
-- against the previous frame's row before noticing it has disappeared.
package.loaded.palapi.my_guild=function() return 'guild' end
panel.refresh(cfg)
local bind=overlay.set_amount_editor
local bindings=0
overlay.set_amount_editor=function(w,...)
    if w then bindings=bindings+1 end
    return bind(w,...)
end
panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone05',amount=105},row=4},-1,true)
data.Stone05=nil
panel.refresh(cfg)
assert(bindings==0 and bound_editor==nil,'invalid draft was focused before reflow validation')
]=], '@edit-reflow-fixture'))()
