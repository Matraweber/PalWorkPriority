-- Execute the real armed main -> entry -> clock -> observer using native stand-ins.
local function read(path)local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local guild=read(TEST_ROOT..'/tests/test_dedicated_guild_probe.lua')
local base=assert(guild:find('local f=fixture%(%)%;local out=f.read%(%)'))
local observer=read(TEST_ROOT..'/tests/test_dedicated_parameter_observer.lua')
local first=assert(observer:find('local function prepare%(%)'))
local last=assert(observer:find('local f=prepare%(%):start%(%)'))
assert(load(guild:sub(1,base-1)..observer:sub(first,last-1)..'\n'..[=[
local Clock=dofile(TEST_ROOT..'/experiments/dedicated_parameter_clock.lua')
for _,case in ipairs({'bad_shape','negative','fractional','nan','overflow','partial_one','throw','backwards'})do
 local calls=0
 local clock=Clock.new(function()return {IsValid=function()return true end,
  GetAccurateRealTime=function(_,s,p)
   calls=calls+1;s.Seconds=10;p.PartialSeconds=0.5
   if case=='bad_shape'then s.Seconds=nil;s[1]=10
   elseif case=='negative'then s.Seconds=-1
   elseif case=='fractional'then s.Seconds=1.5
   elseif case=='nan'then p.PartialSeconds=0/0
   elseif case=='overflow'then s.Seconds=2147483648
   elseif case=='partial_one'then p.PartialSeconds=1
   elseif case=='throw'then error('SECRET clock')
   elseif calls>1 then s.Seconds=9 end
  end}end)
 clock.begin()
 if case=='backwards'then assert(clock.read()==10.5)end
 assert(not pcall(clock.read),case)
 local before=calls;assert(not pcall(clock.read) and calls==before,'failed clock retried native')
 clock.finish()
end
for _,case in ipairs({'normal','empty','large','no_arm','wrong_arm','missing_guild','bad_optin','clock_missing',
 'clock_shape','frozen','slow','lookup_error','cancel_fail','clock_reentry','emit_error'})do
 local f=prepare()
 if case=='empty'then f.a.IndividualCharacterHandleIds.Items={}end
 if case=='large'then
  for i=3,128 do f.items[i]={HandleId={PlayerUId=guid(0),InstanceId=guid(i+100)}}end
 end
 local callback,cancels,scheduled=nil,0,0
 local leases,resolves,finishes,clock_reads,in_lease=0,0,0,0,false
 local clock_module={new=function(resolve)
  local c=Clock.new(function()resolves=resolves+1;return resolve()end)
  return {begin=function()leases=leases+1;in_lease=true;c.begin()end,
   read=c.read,finish=function()finishes=finishes+1;in_lease=false;c.finish()end,
   close=function()in_lease=false;c.close()end}
 end}
 local nonce=string.rep('c',32)
 local config={nonce=nonce,directory=string.rep('a',32),guild=string.rep('0',31)..'1',parameters=true}
 if case=='missing_guild'then config.guild=nil end
 if case=='bad_optin'then config.parameters='true'end
 local files={['/probe/run.txt']='PWP_DEDICATED_IDENTITY '..nonce..'\n'}
 if case=='no_arm'then files['/probe/run.txt']=nil end
 if case=='wrong_arm'then files['/probe/run.txt']='wrong\n'end
 local env
 env=setmetatable({debug={getinfo=function()return {source='@/probe/main.lua'}end},
  FindFirstOf=function(name)assert(name=='GameEngine');return f.engine end,
  StaticFindObject=function(path)
   if path=='/Script/Pal.Default__PalUtility'then return f.utility end
   assert(path=='/Script/Engine.Default__GameplayStatics')
   return {IsValid=function()return true end,
    GetGameState=function(_,v)return f.o.get_state(v)end,
    GetGameInstance=function(_,v)return f.o.get_instance(v)end,
    GetAccurateRealTime=function(_,s,p)
     assert(in_lease);clock_reads=clock_reads+1
     if case=='clock_reentry' and callback then callback()end
     if case=='clock_missing'then error('SECRET absent clock')end
     if case=='clock_shape'then s[1]=1;p[1]=0;return end
     s.Seconds=math.floor(f.time);p.PartialSeconds=f.time-math.floor(f.time)
    end}
  end,
  io={open=function(path,mode)
   assert(path=='/probe/run.txt' or path=='/probe/parameter.log','unexpected IO path')
   if mode=='r'then if files[path]==nil then return nil end
    return {read=function()return files[path]end,close=function()return true end}end
   assert(mode=='a' or (path=='/probe/run.txt' and mode=='w'))
   if mode=='w'then files[path]=''end
   return {write=function(_,s)
    assert(not in_lease,'clock wrapper retained during evidence emission')
    if case=='emit_error' and path=='/probe/parameter.log'then error('SECRET emit')end
    files[path]=(files[path]or '')..s;return true end,close=function()return true end}
  end},
  LoopInGameThreadWithDelay=function(ms,fn)
   assert(ms==1000 and files['/probe/run.txt']=='DISABLED\n','scheduled before arm consumed')
   scheduled=scheduled+1;callback=fn;return 42
  end,
  CancelDelayedAction=function(id)assert(id==42);cancels=cancels+1;return case~='cancel_fail'end,
  dofile=function(path)
   if path=='/probe/config.lua'then return config end
   if path=='/probe/dedicated_parameter_observer.lua'then return f.module end
   if path=='/probe/dedicated_parameter_clock.lua'then return clock_module end
   assert(path=='/probe/dedicated_parameter_entry.lua','identity runner or unapproved module loaded')
   return assert(loadfile(TEST_ROOT..'/experiments/dedicated_parameter_entry.lua','t',env))()
  end}, {__index=_G})
 if case=='slow'then f.lookup=function()f.time=f.time+0.101;return f.parameter end end
 if case=='lookup_error'then f.lookup=function()error('SECRET lookup')end end
 local ok=pcall(assert(loadfile(TEST_ROOT..'/experiments/dedicated-identity-observer/main.lua','t',env)))
 if case=='missing_guild' or case=='bad_optin'then
  assert(not ok and scheduled==0 and f.lookups==0)
 else
  assert(ok,case)
  if case=='normal' or case=='empty' or case=='large' or case=='frozen' or case=='slow'
   or case=='lookup_error' or case=='cancel_fail' or case=='clock_reentry' or case=='emit_error'then
   assert(scheduled==1)
   for i=0,70 do f.time=case=='frozen' and 0 or i;callback();assert(not in_lease)end
   assert(cancels==1 and f.lookups<=60)
   if case=='normal'then assert(f.lookups==60)end
   if case=='frozen' or case=='slow'then assert(f.lookups==1)end
   local log=files['/probe/parameter.log'] or ''
   if case~='emit_error'then assert(log:find('timer_cancelled='..tostring(case~='cancel_fail'),1,true))end
   if case=='normal' or case=='empty' or case=='large'then
    assert(resolves==61 and leases==61 and finishes==61,'clock resolver scaled with roster/guard count')
    assert(clock_reads>resolves and log:find('complete=true',1,true))
   end
   if case=='clock_reentry'then assert(f.lookups==0)end
  else assert(scheduled==0 and f.lookups==0)end
 end
 local log=files['/probe/parameter.log'] or ''
 assert(not in_lease and finishes==leases,'clock lease leaked')
 assert(not log:find('SECRET',1,true) and not log:find('grant=true',1,true))
 for line in log:gmatch('[^\n]+')do assert(#line<1400)end
end
print('parameter entry: explicit arm, exact elapsed clock, one runner, no grants, bounded failures passed')
]=], '@parameter-entry-fixture'))()
