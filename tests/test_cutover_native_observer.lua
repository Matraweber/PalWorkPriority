local source=TEST_ROOT..'/experiments/cutover_native_observer.lua'
local real_dofile,real_open,real_print=dofile,io.open,print
local saved={}
for _,key in ipairs({'store','caps','settings_gate'})do saved[key]=package.loaded[key]end
local root='C:/fixture/PalWorkPriority/'
local function options()return {nonce='fixture_123-A',phase='fenced',root=root,
 production=root..'Scripts/production_main.lua'}end
local function fixture(entry,adjust,phase)
 local observer=real_dofile(source)
 local lines,calls={},{}
 package.loaded.settings_gate={status=function()return 'restart_required'end,blocked=function()return true end}
 package.loaded.store={state='unavailable',serialize=function()return 'A\0\n\255'end}
 package.loaded.caps={state='saved',serialize=function()return 'B\t'end}
 io.open=function(...)calls[#calls+1]=table.pack(...);return nil,'missing',2,nil,'tail'end
 print=function(line)lines[#lines+1]=line end
 dofile=function(path)assert(path==options().production);return entry(observer)end
 if adjust then adjust()end
 local baseline=io.open
 local ok,err=pcall(function()
  local o=options();o.phase=phase or o.phase
  local out=assert(observer.run(o))
  assert(io.open==baseline,'open not restored')
  assert(#lines==1 and lines[1]:match('^PWP_CUTOVER_NATIVE\t'))
  assert(#lines[1]<=4*262144+1024 and lines[1]:sub(-1)=='\n'
   and not lines[1]:sub(1,-2):find('[\r\n]'),'exactly one terminal newline required')
  local again,why=observer.run(options());assert(again==nil and why=='already_invoked')
  return out
 end)
 io.open=real_open;dofile=real_dofile;print=real_print
 assert(ok,err)
 return err,calls,lines
end
local out,calls=fixture(function(observer)
 local again,why=observer.run(options());assert(not again and why=='already_invoked')
 for _,name in ipairs({'priorities.txt','caps.txt'})do
  for _,suffix in ipairs({'','.tmp','.pending','.bak'})do
   local r=table.pack(io.open(root..name..suffix,'rb',nil,'extra'))
   assert(r.n==5 and r[1]==nil and r[2]=='missing' and r[3]==2 and r[5]=='tail')
  end
 end
 io.open(root..'async-trial/launch.lua');io.open(root..'async-trial/receipt.lua')
 io.open(root..'other.txt');io.open(root..'caps.txt.extra');io.open('caps.txt')
 io.open(root..'.settings-cutover');io.open(root..'other/async-trial/launch.lua')
 -- Entry replacing print must not intercept the observer's event.
 print=function()error('wrong print')end
end)
assert(out.loaded and out.settings_opens==8 and out.trial_opens==2 and #calls==15)
assert(calls[1].n==4 and calls[1][2]=='rb' and calls[1][4]=='extra')
assert(out.gate=='restart_required' and out.gate_blocked==true)
assert(out.priority_hex=='41000aff' and out.limit_hex=='4209' and out.error=='none')
out=fixture(function()io.open(root..'caps.txt');error('SECRET\n'..string.rep('x',10000))end,
 function()package.loaded.store.serialize=function()error('must not serialize failed entry')end end)
assert(not out.loaded and out.error=='entry_failed' and out.settings_opens==1 and out.priority_hex=='' and out.limit_hex=='')
out=fixture(function()io.open(root..'priorities.txt')end,function()
 io.open=function()error('PRIVATE open error')end
end)
assert(not out.loaded and out.settings_opens==1 and out.error=='entry_failed')
out=fixture(function()end,function()
 package.loaded.settings_gate={status=function()return 'ready'end,blocked=function()return false end}
 package.loaded.store.state='saved'
 package.loaded.store.serialize=function()return string.rep('\255',262144)end
end,'recovered')
assert(out.phase=='recovered' and out.loaded and out.gate=='ready' and out.gate_blocked==false)
assert(out.priority_state=='saved' and #out.priority_hex==524288 and out.error=='none')
for _,kind in ipairs({'throw','oversize','type','state','gate'})do
 out=fixture(function()end,function()
  if kind=='throw' then package.loaded.caps.serialize=function()error('SECRET')end
  elseif kind=='oversize' then package.loaded.caps.serialize=function()return string.rep('x',262145)end
  elseif kind=='type' then package.loaded.store.serialize=function()return {}end
  elseif kind=='state' then package.loaded.store.state='bad\tstate'
  else package.loaded.settings_gate.status=function()error('SECRET')end end
 end)
 if kind=='state' then assert(out.priority_state=='unknown')
 else assert(out.loaded and out.error=='observation_failed' and out.priority_hex=='' and out.limit_hex=='')end
end
-- Invalid arguments cannot execute entry or consume the one-shot permit.
local observer=real_dofile(source)
local invalid={false,{},setmetatable(options(),{})}
for _,change in ipairs({{'nonce','x\ny'},{'nonce',string.rep('a',65)},{'phase','other'},
 {'root','relative/'},{'root','C:/fixture/../'},{'root','C:/fixture'},
 {'production',root..'Scripts/main.lua'}})do
 local o=options();o[change[1]]=change[2];invalid[#invalid+1]=o
end
dofile=function()error('invalid options executed')end
for _,o in ipairs(invalid)do local a,b=observer.run(o);assert(a==nil and b=='invalid_options')end
dofile=real_dofile
for key,value in pairs(saved)do package.loaded[key]=value end
for _,key in ipairs({'store','caps','settings_gate'})do if saved[key]==nil then package.loaded[key]=nil end end
print('cutover native observer: exact IO forwarding/counts, one-shot, failure and bounds PASS')
