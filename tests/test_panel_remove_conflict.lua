local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
rules(1)
panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
local clears=0
local clear=caps.clear
caps.clear=function(...) clears=clears+1; return clear(...) end
local function drop(amount)
    return panel.apply(cfg,{kind='drop',rule={work='Mining',item='Stone01',amount=amount}},1,true)
end
assert(drop(101))
data.Stone01=202
assert(not drop(101),'stale removal accepted a changed rule')
assert(clears==0 and data.Stone01==202)
assert(drop(202) and clears==0,'changed rule did not require a new first click')
later()
assert(drop(202) and clears==1 and data.Stone01==nil,'fresh confirmed removal failed')
data.Stone01=101; panel.refresh(cfg)
assert(drop(101)); panel.close(); panel.toggle(); panel.refresh(cfg)
assert(drop(101) and clears==1,'close/reopen retained removal confirmation')
panel.apply(cfg,{kind='tab',mode='item'},-1,true)
panel.set_screen('list'); panel.refresh(cfg)
assert(drop(101) and clears==1,'tab navigation retained removal confirmation')
package.loaded.palapi.my_guild=function() return 'other-guild' end
assert(drop(101) and clears==1,'old guild confirmation deleted a new guild rule')
-- Same rule/value, stable scope: two current clicks still remove exactly once.
later()
assert(drop(101) and clears==2)
data.Stone01=101; panel.refresh(cfg)
assert(drop(101))
local queued={}
ExecuteInGameThread=function(fn) queued[#queued+1]=fn end
drop(101)
data.Stone01=303
for _,fn in ipairs(queued) do fn() end
ExecuteInGameThread=nil
assert(clears==2 and data.Stone01==303,'queued removal deleted a newer value')
assert(drop(303)); data.Stone01=nil
assert(not drop(303) and clears==2,'missing current data permitted removal')
]=], '@remove-conflict-fixture'))()
