local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a');f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
rules(14);panel.refresh(cfg);panel.toggle();panel.refresh(cfg)
local list=overlay.parts.RuleList
local before=#list.children
local original=list.GetChildrenCount
for _,failure in ipairs({'throw','nil','false'}) do
 list.GetChildrenCount=function() if failure=='throw' then error('read failure') end if failure=='false' then return false end end
 panel.refresh(cfg)
 assert(#list.children==before,'incomplete traversal duplicated row hosts: '..failure)
 list.GetChildrenCount=original
 panel.refresh(cfg)
 assert(#list.children==before,'recovered traversal lost row identities')
end
-- Native leaves need no unsupported child-count call.
local runtime=require('panel_runtime').new()
for _,class in ipairs({'TextBlock','Image','Spacer','EditableTextBox'}) do
 local leaf={GetFullName=function() return class..' /Test.Leaf' end,
  GetChildrenCount=function() error('leaf has no panel API') end}
 assert(runtime:snapshot(leaf),'known leaf refused: '..class)
end
for _,value in ipairs({false,'0',-1,0.5}) do
 local container={GetFullName=function() return 'CanvasPanel /Test.Container' end,
  GetChildrenCount=function() return value end}
 assert(not runtime:snapshot(container),'invalid count accepted')
end
]=], '@snapshot-recovery'))()
