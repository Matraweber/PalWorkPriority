local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a');f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
rules(14);panel.refresh(cfg);panel.toggle();panel.refresh(cfg)
panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4},-1,true)
panel.refresh(cfg)
local box=assert(bound_editor)
local original=box.SetVisibility
box.SetVisibility=function(self,v) if v==1 then error('hide failure') end return original(self,v) end
panel.cancel_edit()
box.SetVisibility=original
panel.refresh(cfg)
assert(box.visibility==1,'cancelled editor remained visible after recovery')
assert(writes==0 and not panel.confirm_edit(cfg,'900'),'cancelled draft committed')
-- A same-name wrapper replacement must be resolved afresh on retry.
panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4},-1,true)
panel.refresh(cfg)
box=assert(bound_editor)
box.SetVisibility=function() return false end
panel.cancel_edit()
local replacement={}
for k,v in pairs(box) do replacement[k]=v end
setmetatable(replacement,getmetatable(box))
replacement.SetVisibility=original
for i,w in ipairs(box.parent.children) do if w==box then box.parent.children[i]=replacement end end
box.dead=true
panel.refresh(cfg)
assert(replacement.visibility==1 and stale==0,'retry touched stale editor wrapper')
-- Same-generation reentrant cancellation must not recursively unbind.
local native_bind=overlay.set_amount_editor
local bindings=0
overlay.set_amount_editor=function(w,...)
 if w==nil then
  bindings=bindings+1
  assert(bindings<5,'recursive cancellation was unbounded')
  panel.cancel_edit()
 end
 return native_bind(w,...)
end
panel.cancel_edit()
assert(bindings==1,'reentrant cancellation repeated native unbind')
overlay.set_amount_editor=native_bind
-- Failed native unbinding is retried too; permanent failures close the shell.
panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4},-1,true)
panel.refresh(cfg)
local bind=overlay.set_amount_editor
local attempts=0
overlay.set_amount_editor=function(w,...)
 if w==nil then attempts=attempts+1;return false end
 return bind(w,...)
end
panel.cancel_edit()
panel.refresh(cfg);panel.refresh(cfg)
assert(not panel.open and not overlay.open and attempts==3,'cleanup did not fail closed within bound')
overlay.set_amount_editor=bind
panel.toggle();panel.refresh(cfg)
assert(panel.open and writes==0,'cleanup poisoned next generation')
]=], '@cancel-cleanup'))()
