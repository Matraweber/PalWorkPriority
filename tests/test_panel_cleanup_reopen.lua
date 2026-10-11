local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a');f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
rules(14);panel.refresh(cfg);panel.toggle();panel.refresh(cfg)
local function edit()
 panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4},-1,true)
 panel.refresh(cfg);assert(bound_editor)
end
edit()
local bind,hide=overlay.set_amount_editor,overlay.hide
local once=false
overlay.set_amount_editor=function(w,...) if w==nil then return false end return bind(w,...) end
overlay.hide=function(...)
 local result=hide(...)
 if not once then
  once=true;overlay.set_amount_editor=bind
  panel.toggle();panel.refresh(cfg);edit()
 end
 return result
end
panel.cancel_edit();panel.refresh(cfg);panel.refresh(cfg)
assert(panel.open and overlay.open and bound_editor,'old cleanup closed the reopened editor')
assert(writes==0 and stale==0)
]=], '@cleanup-reopen'))()
