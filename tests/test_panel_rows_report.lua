local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
local output={}
package.loaded.log.say=function(s) output[#output+1]=s end
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
panel.set_screen('item'); panel.refresh(cfg)
-- Existing diagnostics reacquire the tree. Reset counters after that snapshot
-- to isolate the new direct-child report's 32-entry bound.
local list=overlay.parts.ItemList
local nodes={}
for i=1,40 do
    local w=make('SizeBox')
    w.HeightOverride,w.bOverride_HeightOverride= i==3 and 34 or 40,true
    function w:GetVisibility() check(self); return self.visibility end
    nodes[i]=w
end
local reads=0
list.GetChildAt=function(_,i) reads=reads+1; return nodes[i+1] end
list.GetChildrenCount=function() return #nodes end
local rb
for i=1,100 do local n,v=debug.getupvalue(panel.refresh,i); if n=='RB' then rb=v end end
assert(rb)
-- M.command snapshots before entering its verb. Instrument the first legacy
-- report log, which precedes the direct-child census and follows that snapshot.
package.loaded.log.say=function(s)
    if s:find('parts.Root belongs to:',1,true) then reads=0 end
    output[#output+1]=s
end
local before=count
assert(panel.command(cfg,'rows')=='row report done')
local report=table.concat(output,'\n')
assert(report:find('ItemList current children: 40 (showing 32)',1,true), 'bounded child census missing')
assert(reads==32 and count==before and writes==0, 'report changed UI/settings or exceeded read bound')
assert(report:find('height_override=34',1,true) and report:find('children=0',1,true))
assert(not report:find(nodes[33].name,1,true), 'reported more than 32 children')
for _,w in ipairs(nodes) do w.dead=true end
local fresh=make('SizeBox'); fresh.HeightOverride=40
function fresh:GetVisibility() error('unavailable visibility') end
nodes={fresh}; output={}
assert(panel.command(cfg,'rows')=='row report done')
report=table.concat(output,'\n')
assert(report:find(fresh.name,1,true) and report:find('visibility=unavailable',1,true))
assert(stale==0, 'report retained a child wrapper between commands')
output={}; list.GetChildrenCount=function() error('unavailable children') end
-- An unreadable container now refuses the whole snapshot before diagnostics.
assert(panel.command(cfg,'rows')=='the current panel tree is unavailable')
assert(#output==0 and stale==0, 'incomplete snapshot entered row diagnostics')
]=], '@panel-rows-report-fixture'))()
print('PASS panel rows report: bounded fresh children, scalar properties, read failures, no writes')
