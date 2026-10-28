-- Real panel + caps + settings_writer/session/journal barrier; only UMG and
-- storage completion are fixtures. Reuse existing fixture constructors, not their tests.
local function read(name)
    local f=assert(io.open(TEST_ROOT..'/tests/'..name,'r'));local s=f:read('*a');f:close();return s
end
local persistence=read('test_caps_recovery_activation.lua')
local cut=assert(persistence:find('\nlocal function fresh%(%)'))
local build=assert(load(persistence:sub(1,cut-1)..'\nreturn fixture','@panel-real-caps-fixture'))()
local source=read('test_panel_render.lua')
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
source=source:sub(1,start-1)
local setup=[=[
local alias='-758686034-1314655308-1294252187-537966059'
local live=make_persistence_fixture('caps',nil,alias)
caps=live.m;caps.set_role('authority',7);assert(live:activate())
caps.on_change=function()live.notices=live.notices+1 end
package.loaded.palapi.my_guild=function()return alias end
local original_set=caps.set
local last_receipt
caps.set=function(...)
    local yes,why,receipt=original_set(...);last_receipt=receipt
    return yes,why,receipt
end
]=]
source=source:gsub('local panel = require%("panel"%)',function()return setup..'\nlocal panel = require("panel")'end,1)
local checks=[=[
panel.refresh(cfg);panel.toggle();panel.refresh(cfg)
local function edit(amount)
    panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone',amount=amount},row=4},-1,true)
    panel.refresh(cfg);panel.wants_pass=false
end
edit(42000)
local submit=caps.set
for _,why in ipairs({'rejected','uncertain','pending'})do
    caps.set=function()return false,why,{} end
    assert(not panel.confirm_edit(cfg,'35001'),'unaccepted reply closed editor')
    panel.refresh(cfg);assert(bound_editor and not panel.wants_pass)
    assert(caps.data[alias].Mining.Stone==42000 and live.writes==0)
end
caps.set=submit
assert(panel.confirm_edit(cfg,'35001'),'accepted pending edit must close successfully')
assert(caps.data[alias].Mining.Stone==35001 and caps.state=='saving' and live.notices==0)
assert(not panel.wants_pass,'pending must not request scheduler reconciliation')
assert(last_receipt and last_receipt.revision==1)
panel.refresh(cfg);assert(rendered('Saving change...') and rendered('Saving...'))
assert(not panel.confirm_edit(cfg,'35001'),'accepted edit was left open')
local writes=live.writes;panel.cancel_edit();assert(live.writes==writes,'cancel replayed accepted submission')
live:complete();assert(caps.flush() and caps.state=='saved' and live.notices==1)
panel.refresh(cfg);assert(rendered('Limits saved'))

-- Step and confirmed removal must use exactly the same pending contract.
panel.wants_pass=false
assert(panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone',amount=35001},row=4},1,false))
assert(caps.state=='saving' and not panel.wants_pass)
panel.refresh(cfg);assert(rendered('Saving change...'))
live:complete();assert(caps.flush())
local amount=caps.data[alias].Mining.Stone
local drop={kind='drop',rule={work='Mining',item='Stone',amount=amount}}
panel.wants_pass=false
assert(panel.apply(cfg,drop,1,true));assert(panel.apply(cfg,drop,1,true))
assert(caps.state=='saving' and not panel.wants_pass)
panel.refresh(cfg);assert(rendered('Saving removal...'))
live:complete();assert(caps.flush())
assert(caps.data[alias].Mining==nil or caps.data[alias].Mining.Stone==nil or caps.data[alias].Mining.Stone==false)

-- A structurally invalid, stale, foreign, or uncertain reply never becomes pending success.
local status=require('panel_status')
local r=last_receipt
local model={session=7,decided=true,state='saving',data={[alias]={Mining={Stone=35001}}}}
local function classify(why,receipt)
    return status.submission(model,false,why,receipt,alias,'Mining','Stone',35001,7)
end
assert(classify('pending',r))
for _,why in ipairs({'rejected','uncertain','error','stale','unsupported_limit','applied_unsaved'})do assert(not classify(why,r))end
for _,key in ipairs({'scope','session','incarnation','epoch','revision'})do
    local bad={};for k,v in pairs(r)do bad[k]=v end;bad[key]=nil
    assert(not classify('pending',bad),key)
end
local bad={};for k,v in pairs(r)do bad[k]=v end
bad.scope='PWP-SCOPE-1:'..string.rep('a',32)..':'..string.rep('c',32)..':limits'
assert(not classify('pending',bad))
model.state='saved';assert(not classify('pending',r));model.state='saving'
model.session=8;assert(not classify('pending',r));model.session=7
model.data[alias].Mining.Stone=9;assert(not classify('pending',r))
]=]
assert(load('local make_persistence_fixture=...\n'..source..'\n'..checks,'@panel-async-submission'))(build)
print('PASS panel async submission: real caps/writer pending edit, step, clear; completion and receipt refusal')
