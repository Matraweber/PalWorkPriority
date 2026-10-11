-- A draft cannot overwrite a newer rule or recreate a removed one.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
rules(1)
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
local function edit()
    panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4},-1,true)
    panel.refresh(cfg)
end
edit()
data.Stone01=202
assert(not panel.confirm_edit(cfg,'700'), 'stale draft overwrote newer limit')
assert(data.Stone01==202 and writes==0, 'conflicting edit wrote data')
panel.refresh(cfg)
assert(rendered('This limit changed; cancel and reopen it before editing.'), 'conflict explanation missing')
panel.cancel_edit()
data.Stone01=101; edit(); data.Stone01=nil
assert(not panel.confirm_edit(cfg,'700'), 'stale draft recreated deleted limit')
assert(data.Stone01==nil and writes==0)
panel.cancel_edit()
data.Stone01=101; edit(); data.Unrelated=300
assert(panel.confirm_edit(cfg,'700'), 'unrelated change blocked valid draft')
assert(data.Stone01==700 and data.Unrelated==300 and writes==1)
-- Confirm is queued: validate at execution, not when the click was captured.
data.Stone01=101; edit()
local deferred={}
ExecuteInGameThread=function(fn) deferred[#deferred+1]=fn end
panel.confirm_edit(cfg,'800')
assert(#deferred>0, 'fixture did not defer confirmation')
data.Stone01=404
for _,fn in ipairs(deferred) do fn() end
ExecuteInGameThread=nil
assert(data.Stone01==404 and writes==1, 'queued confirmation overwrote newer rule')
]=], '@panel-edit-conflict-fixture'))()
print('PASS panel edit conflict: changed/removed rules refused; unrelated changes preserved')
