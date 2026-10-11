local Clock=dofile(TEST_ROOT..'/experiments/dedicated_parameter_clock.lua')
for _,count in ipairs({1,4096})do
 local resolves,reads=0,0
 local c=Clock.new(function()
  resolves=resolves+1
  return {IsValid=function()return true end,GetAccurateRealTime=function(_,s,p)
   reads=reads+1;s.Seconds=reads;p.PartialSeconds=0
  end}
 end)
 c.begin()
 for i=1,count do assert(c.read()==i)end
 c.finish()
 assert(resolves==1 and reads==count,'resolver count scales with guards')
 c.begin();assert(c.read()==count+1);c.finish();assert(resolves==2)
end
for _,stage in ipairs({'resolve','valid','read'})do
 for _,action in ipairs({'close','reenter','finish','throw'})do
  local c,resolves,reads,armed=nil,0,0,true
  local function trigger(at)
   if at~=stage or not armed then return end
   armed=false
   if action=='close'then c.close()
   elseif action=='finish'then c.finish()
   elseif action=='reenter'then pcall(c.read)
   else error('private native exception')end
  end
  c=Clock.new(function()
   resolves=resolves+1;trigger('resolve')
   return {IsValid=function()trigger('valid');return true end,
    GetAccurateRealTime=function(_,s,p)reads=reads+1;trigger('read');s.Seconds=1;p.PartialSeconds=0 end}
  end)
  local ok=pcall(function()c.begin();return c.read()end)
  c.finish()
  assert(not ok,stage..' '..action..' published revoked time')
  assert(not pcall(c.begin) and resolves==1,'revoked clock reacquired')
 end
end
-- Same-sample nested acquisition poisons the outer lease.
local c=Clock.new(function()return {}end)
c.begin();assert(not pcall(c.begin));assert(not pcall(c.read));c.finish()
-- Scalar monotonicity survives release, while wrapper identity does not.
local n=0
c=Clock.new(function()
 n=n+1;local current=n
 return {IsValid=function()return true end,GetAccurateRealTime=function(_,s,p)
  s.Seconds=3-current;p.PartialSeconds=0
 end}
end)
c.begin();assert(c.read()==2);c.finish();c.begin();assert(not pcall(c.read));c.finish()
assert(not pcall(c.begin) and n==2)

-- Diagnostics never acquire a provider or expose native values/exceptions.
local stages={unknown=true,resolve=true,validity=true,call=true,outputs=true,
 seconds=true,fraction=true,monotonic=true}
local keys={stage=true,seconds_type=true,partial_type=true,seconds_kind=true,partial_kind=true}
local function diagnostic(clock,stage,st,pt,sk,pk)
 local d=clock.diagnostics();local count=0
 for k,v in pairs(d)do
  count=count+1;assert(keys[k] and type(v)=='string' and #v<=16)
  assert(not v:find('SECRET',1,true))
 end
 assert(count==5 and stages[d.stage])
 assert(d.stage==stage and d.seconds_type==(st or 'unknown') and d.partial_type==(pt or 'unknown'))
 assert(d.seconds_kind==(sk or 'unknown') and d.partial_kind==(pk or 'unknown'))
 d.stage='mutated';d.seconds_type={}
 assert(clock.diagnostics().stage==stage and type(clock.diagnostics().seconds_type)=='string')
end
local cases={
 {stage='resolve',resolve=function()error('SECRET')end},
 {stage='resolve',resolve=function()return nil end},
 {stage='validity',valid=function()return false end},
 {stage='validity',valid=function()error('SECRET')end},
 {stage='call',read=function()error('SECRET')end},
 {stage='outputs',read=function(_,s,p)s.Seconds=1;p.PartialSeconds=0;setmetatable(s,{})end},
 {stage='outputs',read=function(_,s,p)s.Seconds=1;p.PartialSeconds=0;setmetatable(p,{})end},
 {stage='seconds',read=function()end,st='nil',pt='nil',sk='none',pk='none'},
 {stage='seconds',s=1.0,p=0,st='number',pt='number',sk='float',pk='integer'},
 {stage='seconds',s=-1,p=0,st='number',pt='number',sk='integer',pk='integer'},
 {stage='seconds',s=2147483648,p=0,st='number',pt='number',sk='integer',pk='integer'},
 {stage='seconds',s='SECRET',p=0,st='string',pt='number',sk='none',pk='integer'},
 {stage='seconds',s=setmetatable({},{__tostring=function()error('SECRET')end}),p=false,
  st='table',pt='boolean',sk='none',pk='none'},
 {stage='fraction',s=1,p='SECRET',st='number',pt='string',sk='integer',pk='none'},
 {stage='fraction',s=1,p=0/0,st='number',pt='number',sk='integer',pk='float'},
 {stage='fraction',s=1,p=math.huge,st='number',pt='number',sk='integer',pk='float'},
 {stage='fraction',s=1,p=-0.1,st='number',pt='number',sk='integer',pk='float'},
 {stage='fraction',s=1,p=1,st='number',pt='number',sk='integer',pk='integer'},
}
for _,case in ipairs(cases)do
 local calls=0
 local clock=Clock.new(function()
  calls=calls+1
  if case.resolve then return case.resolve()end
  return {IsValid=case.valid or function()return true end,
   GetAccurateRealTime=case.read or function(_,s,p)s.Seconds=case.s;p.PartialSeconds=case.p end}
 end)
 diagnostic(clock,'unknown');assert(calls==0)
 assert(not pcall(function()clock.begin();clock.read()end))
 diagnostic(clock,case.stage,case.st,case.pt,case.sk,case.pk)
 clock.finish();clock.close();assert(not pcall(clock.begin))
 diagnostic(clock,case.stage,case.st,case.pt,case.sk,case.pk);assert(calls==1)
end
-- Successful observations retain strict integer seconds and allow a fractional
-- number; decreasing time fails at monotonic, across callback lease release.
do
 local seconds=2
 local clock=Clock.new(function()return {IsValid=function()return true end,
  GetAccurateRealTime=function(_,s,p)s.Seconds=seconds;p.PartialSeconds=0.25 end}end)
 clock.begin();assert(clock.read()==2.25);clock.finish()
 diagnostic(clock,'monotonic','number','number','integer','float')
 seconds=1;clock.begin();assert(not pcall(clock.read));clock.finish()
 diagnostic(clock,'monotonic','number','number','integer','float')
end
-- Reentrant revocation keeps the native boundary's stage through cleanup.
for _,at in ipairs({'resolve','validity','call'})do
 local clock
 local function revoke(stage)if stage==at then clock.finish()end end
 clock=Clock.new(function()
  revoke('resolve')
  return {IsValid=function()revoke('validity');return true end,
   GetAccurateRealTime=function(_,s,p)revoke('call');s.Seconds=1;p.PartialSeconds=0 end}
 end)
 assert(not pcall(function()clock.begin();clock.read()end))
 clock.finish();diagnostic(clock,at)
end
print('parameter clock: bounded resolver, fresh reads, lease revocation and monotonicity passed')

-- Pinned UE4SS scalar out binding: both values land in argument one. The
-- adapter supplies the same table explicitly, and reads both strict names.
do
 local c=Clock.new(function()return {IsValid=function()return true end,
  GetAccurateRealTime=function(_,first,second)
   assert(first==second,'clock must explicitly bind shared scalar output table')
   first.Seconds=7;first.PartialSeconds=0.125
  end}end)
 c.begin();assert(c.read()==7.125);c.finish()
end
