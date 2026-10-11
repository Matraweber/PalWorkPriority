local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a');f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
rules(14);panel.refresh(cfg);panel.toggle();panel.refresh(cfg)
panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4},-1,true)
panel.refresh(cfg)
local box=assert(bound_editor)
local original=overlay.set_amount_editor
local once=false
overlay.set_amount_editor=function(w,...)
 local result=original(w,...)
 if w==nil and not once then
  once=true;overlay.generation=overlay.generation+1;box.dead=true
 end
 return result
end
panel.cancel_edit()
assert(stale==0,'cleanup dereferenced a previous generation after unbind')
assert(writes==0,'cleanup wrote settings')
]=], '@cancel-reentrancy'))()
