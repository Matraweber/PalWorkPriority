local Clock=dofile(TEST_ROOT..'/experiments/dedicated_parameter_clock.lua')
local path=TEST_ROOT..'/experiments/dedicated_clock_probe.lua'
local forbidden=0
local env=setmetatable({}, {__index=function(_,k)
 if k=='StaticFindObject' or k=='FindFirstOf' or k=='io' or k=='os'then
  forbidden=forbidden+1;error('forbidden API '..k)
 end
 return _G[k]
end})
local Probe=assert(loadfile(path,'t',env))()
local function fixture(mode)
 local f={time=0,resolves=0,reads=0,events={},cancels=0,registered=0,valid=true}
 local leased=false
 local wrapped={new=function(resolve)
  local c=Clock.new(resolve)
  return {diagnostics=c.diagnostics,begin=function()leased=true;c.begin()end,read=c.read,
   finish=function()leased=false;c.finish()end,close=function()leased=false;c.close()end}
 end}
 local function fault(stage)
  if f.faulted or mode~=stage then return end
  f.faulted=true
  if f.callback then f.callback()end
 end
 f.options={enabled=true,nonce=string.rep('a',32),clock_module=wrapped,
  resolve=function()
   f.resolves=f.resolves+1;fault('resolve_reentry')
   if mode=='resolve_error'then error('SECRET')end
   return {IsValid=function()fault('valid_reentry');return f.valid end,
    GetAccurateRealTime=function(_,s,p)
     f.reads=f.reads+1;assert(leased);fault('read_reentry')
     if mode=='clock_error'then error('SECRET')end
     if mode=='late_close' and f.control then f.control.close()end
     if mode=='malformed'then s[1]=1;p[1]=0;return end
     if mode~='frozen' and mode~='frame'then f.time=f.time+(mode=='slow' and 0.101 or 0.00001)end
     if mode=='backwards' and f.reads==2 then f.time=0 end
     s.Seconds=math.floor(f.time);p.PartialSeconds=f.time-math.floor(f.time)
    end}
  end,
  schedule=function(ms,callback)
   assert(ms==1000);f.registered=f.registered+1;f.callback=callback
   if mode=='schedule_error'then error('SECRET')end
   if mode=='schedule_false'then return false end
   if mode=='sync'then for _=1,12 do callback()end end
   return 0
  end,
  cancel=function(handle)
   assert(handle==0);f.cancels=f.cancels+1;f.callback()
   if mode=='cancel_error'then error('SECRET')end
   return mode~='cancel_false'
  end,
  emit=function(out)
   assert(not leased,'lease retained through evidence emission')
   assert(out.verified==false and out.active==false and out.storage_grant==false
    and out.authority_grant==false and out.coverage_grant==false)
   assert(out.elapsed_validated==false and out.total_callback_ms=='unknown' and out.resolver_ms=='unknown')
   for _,v in pairs(out)do
    assert(type(v)=='number' or type(v)=='string' or type(v)=='boolean')
    if type(v)=='string'then assert(#v<=80 and not v:find('SECRET'))end
   end
   f.events[#f.events+1]=out
   if mode=='emit_reentry'then f.callback()end
   if mode=='emit_error'then error('SECRET')end
  end}
 function f.start()f.control=assert(Probe.start(f.options));return f end
 function f.run()
  for i=1,20 do
   if mode~='frozen' and mode~='sync'then f.time=f.time+1 end
   f.callback();assert(not leased)
  end
 end
 return f
end
assert(not Probe.start(nil));assert(not Probe.start({enabled='true'}))
for _,key in ipairs({'nonce','resolve','schedule','cancel','emit','clock_module'})do
 local f=fixture();f.options[key]=false;assert(not Probe.start(f.options));assert(f.registered==0)
end
for _,mode in ipairs({'normal','frozen','frame','sync','resolve_error','clock_error','malformed','backwards',
 'resolve_reentry','valid_reentry','read_reentry','late_close','emit_reentry','emit_error',
 'slow','cancel_error','cancel_false','schedule_error','schedule_false','invalid'})do
 local f=fixture(mode);if mode=='invalid'then f.valid=false end
 f.start();f.run();f.control.close();f.control.close()
 assert(f.resolves<=8 and f.reads<=8*34 and f.cancels<=1 and #f.events<=9,mode)
 local final=f.events[#f.events];assert(final and final.status=='finished',mode)
 if mode=='normal' or mode=='sync' or mode=='frozen' or mode=='frame' or mode=='cancel_error' or mode=='cancel_false'then
  assert(f.resolves==8 and f.reads==272 and #f.events==9,mode)
  assert(final.reason==(mode=='frozen' and 'no_between_sample_advancement'
   or mode=='frame' and 'no_within_sample_advancement' or 'sample_limit'))
  assert(final.advancement_observed==(mode~='frozen' and mode~='frame'))
  for i=1,8 do
   local out=f.events[i];assert(out.reads==34 and out.read_intervals==32 and out.work_steps==4096)
   assert(out.within_sample_advanced==(mode~='frozen' and mode~='frame'))
   if i==1 then assert(out.between_sample_ms=='unknown')
   else assert(type(out.between_sample_ms)=='number' and out.between_sample_advanced==(mode~='frozen'))end
   if mode=='frozen'then assert(out.first_to_last_read_ms==0 and out.read_burst_ms==0)end
  end
 elseif mode=='schedule_error' or mode=='schedule_false'then
  assert(f.reads==0 and f.resolves==0 and f.cancels==0 and final.reason=='timer_unavailable')
 else assert(f.resolves==1 and final.reason~='sample_limit',mode)end
 assert(final.timer_cancelled==(mode~='cancel_error' and mode~='cancel_false'
  and mode~='schedule_error' and mode~='schedule_false'))
end
local f=fixture():start();f.control.close();f.run();assert(f.resolves==0 and f.cancels==1)
f=fixture():start();f.callback();f.time=61;f.callback()
assert(f.events[#f.events].reason=='elapsed_limit' and f.cancels==1)
f=fixture():start();f.options.resolve=function()error('mutated')end
f.options.emit=function()error('mutated')end;f.run();assert(f.resolves==8)
assert(forbidden==0,'forbidden API hidden by pcall')
print('clock-only probe: bounded reads/work, elapsed observations, default-off, faults and cleanup passed')

-- Failure details remain plain scalar observations, never a clock fallback.
do
 local f=fixture('malformed').start();f.callback()
 local out=f.events[#f.events]
 assert(out.status=='finished' and out.reason=='clock_unavailable')
 assert(out.clock_stage=='seconds' and out.clock_seconds_type=='nil')
 assert(out.advancement_observed==false and out.timer_cancelled==true)
end
