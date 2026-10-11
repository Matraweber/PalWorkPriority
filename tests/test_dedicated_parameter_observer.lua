-- Offline reflected-ID stand-ins; no native call, timer, installed file or IO.
local f=assert(io.open(TEST_ROOT..'/tests/test_dedicated_guild_probe.lua','r'))
local source=f:read('*a');f:close()
local start=assert(source:find('local f=fixture%(%)%;local out=f.read%(%)'))
assert(load(source:sub(1,start-1)..'\n'..[=[
local function prepare()
 local f=fixture()
 f.time,f.lookups=0,0
 f.native={}
 for _,item in ipairs(f.items)do f.native[item.HandleId]=true end
 f.p={IndividualId=f.items[1].HandleId,GetGroupId=function()return guid(1)end}
 f.parameter=f.object(10,f.p)
 f.u={GetGroupManager=function(_,w)return f.o.get_manager(w)end,
  GetIndividualCharacterParameterByIstanceID=function(_,w,id)
   f.lookups=f.lookups+1
   assert(w==f.world and f.native[id] and (id==f.items[1].HandleId or id==f.items[2].HandleId),
    'lookup did not receive original roster HandleId')
   f.p.IndividualId=id
   if f.lookup then return f.lookup(w,id)end
   return f.parameter
  end}
 f.utility=f.object(11,f.u)
 -- Stand-ins are table proxies only in this offline environment. Production
 -- has no type override or switch allowing a reconstructed Lua ID argument.
 local env=setmetatable({type=function(v)if f.native[v]then return 'userdata'end;return type(v)end}, {__index=_G})
 f.module=assert(loadfile(TEST_ROOT..'/experiments/dedicated_parameter_observer.lua','t',env))()
 f.options={enabled=true,directory=string.rep('a',32),guild=string.rep('0',31)..'1',
  get_engine=function()return f.engine end,get_state=function(v)return f.o.get_state(v)end,
  get_instance=function(v)return f.o.get_instance(v)end,get_utility=function()return f.utility end,
  unwrap=function(v)return f.o.unwrap(v)end,clock=function()return f.time end}
 function f.start() f.observer=assert(f.module.new(f.options));return f end
 function f.sample()
  local before=f.lookups
  local out=f.observer.sample()
  assert(f.lookups-before<=1,'more than one parameter lookup/sample')
  assert(f.forbidden==0,'forbidden access swallowed')
  for k,v in pairs(out)do
   assert(type(v)=='number' or type(v)=='string' or type(v)=='boolean','non-scalar result')
   assert(type(v)~='string' or (#v<=80 and not v:find('SECRET',1,true)))
  end
  assert(out.verified==false and out.active==false and out.authority_grant==false
   and out.storage_grant==false and out.coverage_grant==false and out.pal_kind=='unknown')
  return out
 end
 return f
end
local f=prepare():start();local out=f.sample()
assert(out.complete and out.membership=='matched' and out.reason=='member_parameter'
 and out.roster_count==2 and out.lookup_attempts==1 and f.lookups==1)
-- Same timestamp is throttled; a second sample selects the other reflected ID.
assert(f.sample().status=='deferred' and f.lookups==1)
f.time=1;out=f.sample();assert(out.membership=='matched' and f.p.IndividualId==f.items[2].HandleId)
assert(out.pal_kind=='unknown','human-looking handle was inferred to be a Pal')
f=prepare();f.options.enabled=false;assert(not f.module.new(f.options) and f.lookups==0)
f=prepare();f.options.enabled=nil;assert(not f.module.new(f.options))
f=prepare();f.options.guild=string.rep('0',32);assert(not f.module.new(f.options))
-- Captured function identities/config are unaffected by options mutation.
f=prepare():start();f.options.get_engine=function()error('changed options')end
f.options.guild=string.rep('b',32);assert(f.sample().membership=='matched')
for _,case in ipairs({'foreign','missing','invalid','wrong_identity','lookup_error','duplicate','duplicate_map',
 'zero_instance','malformed_guid','lua_id','oversize_map','oversize_roster','sparse','empty',
 'world','state','instance','save_owner','group_owner','manager','directory','role','unloaded',
 'roster_change','parameter_address','parameter_identity','group_changed','reentry','close','slow'})do
 f=prepare()
 if case=='foreign'then f.p.GetGroupId=function()return guid(2)end
 elseif case=='missing'then f.lookup=function()return nil end
 elseif case=='invalid'then f.p.IsValid=function()return false end
 elseif case=='wrong_identity'then f.lookup=function()f.p.IndividualId={PlayerUId=guid(0),InstanceId=guid(99)};return f.parameter end
 elseif case=='lookup_error'then f.lookup=function()error('SECRET native error')end
 elseif case=='duplicate'then f.items[2]=f.items[1]
 elseif case=='duplicate_map'then f.entries[2]=f.entries[1]
 elseif case=='zero_instance'then f.items[1].HandleId.InstanceId=guid(0)
 elseif case=='malformed_guid'then f.items[1].HandleId.InstanceId.D=1.5
 elseif case=='lua_id'then f.native={}
 elseif case=='oversize_map'then f.map_size=129
 elseif case=='oversize_roster'then f.a.IndividualCharacterHandleIds.Items=setmetatable({}, {__len=function()return 4097 end,
  __index=function()f.forbidden=f.forbidden+1;error('indexed oversized')end})
 elseif case=='sparse'then f.items.extra={}
 elseif case=='empty'then f.a.IndividualCharacterHandleIds.Items={}
 else
  f.lookup=function()
   if case=='world'then f.l.OwningWorld=f.object(99,{})
   elseif case=='state'then f.w.GameState=f.object(99,{})
   elseif case=='instance'then f.e.GameInstance=f.object(99,{})
   elseif case=='save_owner'then f.save.GetOuter=function()return f.object(99,{})end
   elseif case=='group_owner'then f.m.GetOuter=function()return f.object(99,{})end
   elseif case=='manager'then f.manager=f.object(99,f.m)
   elseif case=='directory'then f.s.WorldSaveDirectoryName=string.rep('b',32)
   elseif case=='role'then f.s.Role=1
   elseif case=='unloaded'then f.save.bIsLoadedWorldSaveData=false
   elseif case=='roster_change'then f.items[2].HandleId.InstanceId=guid(99)
   elseif case=='parameter_address'then
    local n=0;f.p.GetGroupId=function()n=n+1;f.p.GetAddress=function()return 10+n end;return guid(1)end
   elseif case=='parameter_identity'then f.p.GetGroupId=function()f.p.IndividualId={PlayerUId=guid(0),InstanceId=guid(99)};return guid(1)end
   elseif case=='group_changed'then local n=0;f.p.GetGroupId=function()n=n+1;return guid(n)end
   elseif case=='reentry'then assert(f.observer.sample().reason=='reentrant')
   elseif case=='close'then f.observer.close()
   else f.time=0.101 end
   return f.parameter
  end
 end
 f.start();out=f.sample()
 assert(out.membership=='unknown',case)
 if case=='foreign'then assert(out.reason=='foreign_group' and out.roster_count==2)
 elseif case=='missing'then assert(out.reason=='parameter_unavailable' and out.roster_count==2 and not out.complete)
 elseif case=='empty'then assert(out.reason=='empty_roster' and out.roster_count==0 and f.lookups==0)
 else assert(not out.complete,case)end
 if case=='reentry' or case=='close' or case=='slow'then
  local n=f.lookups;f.time=2;assert(f.sample().status=='closed' and f.lookups==n)
 end
end
-- A late group resolver must not change the roster after its last check.
f=prepare():start()
f.change=function(n)if n==6 then f.items[2].HandleId.InstanceId=guid(99)end end
out=f.sample()
assert(out.membership~='matched' or f.manager_calls<6,'late resolver changed accepted membership')
-- Final resolver/roster callbacks can change a previously checked parameter.
for _,boundary in ipairs({'resolver','roster'})do
 for _,change in ipairs({'group','identity','address','validity'})do
  f=prepare():start()
  local changed=false
  local function mutate()
   if changed then return end;changed=true
   if change=='group'then f.p.GetGroupId=function()return guid(2)end
   elseif change=='identity'then f.p.IndividualId={PlayerUId=guid(0),InstanceId=guid(99)}
   elseif change=='address'then f.p.GetAddress=function()return 99 end
   else f.p.IsValid=function()return false end
   end
  end
  if boundary=='resolver'then f.change=function(n)if n==5 then mutate()end end
  else f.o.unwrap=function(v)if f.manager_calls==5 then mutate()end;return v end end
  out=f.sample()
  assert(changed and out.membership=='unknown' and not out.complete,
   'late '..boundary..' changed accepted parameter '..change)
 end
end
-- Conversely, final parameter functions may invalidate the closing ownership
-- chain. A non-nil matching parameter cannot override that changed context.
for _,change in ipairs({'world','manager_owner'})do
 f=prepare():start()
 f.p.GetGroupId=function()
  if f.manager_calls==5 then
   if change=='world'then f.w.GameState=f.object(99,{})
   else f.m.GetOuter=function()return f.object(99,{})end end
  end
  return guid(1)
 end
 out=f.sample();assert(out.membership=='unknown' and not out.complete,
  'final parameter callback changed accepted '..change)
end
-- No wrappers remain necessary after a callback: invalidate every old wrapper
-- and replace the entire native graph with a same-address fresh graph.
f=prepare():start();assert(f.sample().membership=='matched')
local fresh=prepare()
for _,fields in ipairs({f.e,f.i,f.s,f.w,f.l,f.save,f.m,f.g,f.a,f.p,f.u})do
 fields.IsValid=function()error('retired wrapper')end
end
f.engine,f.world,f.utility=fresh.engine,fresh.world,fresh.utility
f.o.get_state,f.o.get_instance=fresh.o.get_state,fresh.o.get_instance
for k in pairs(fresh.native)do f.native[k]=true end
f.time=1;assert(f.sample().membership=='matched')
-- Hard bounds even if the injected timer fires too often or never cancels.
f=prepare():start()
for i=0,59 do f.time=i;assert(f.sample().membership=='matched')end
assert(f.lookups==60);f.time=60;assert(f.sample().status=='closed' and f.lookups==60)
f=prepare():start();f.sample();f.time=60;assert(f.sample().status=='closed' and f.lookups==1)
f=prepare():start();f.time=5;f.sample();f.time=4;assert(f.sample().status=='closed')
for _,case in ipairs({'normal','cancel_false','emit_throw','reentry','synchronous','no_timer','schedule_throw','cancel_throw','frozen_clock'})do
 f=prepare();local callback,cancels,events=nil,0,{}
 f.options.schedule=function(ms,fn)
  assert(ms==1000);callback=fn
  if case=='synchronous'then fn()end
  if case=='no_timer'then return nil end
  if case=='schedule_throw'then error('SECRET schedule')end
  return 42
 end
 f.options.cancel=function(id)assert(id==42);cancels=cancels+1
  if case=='cancel_throw'then error('SECRET cancel')end
  return case~='cancel_false'end
 f.options.emit=function(out)
  events[#events+1]=out
  if out.status~='finished' then
   if case=='emit_throw'then error('SECRET log error')end
   if case=='reentry'then callback()end
  end
 end
 local runner=assert(f.module.start(f.options))
 for i=0,70 do f.time=case=='frozen_clock' and 0 or i;callback()end
 runner.close();runner.close()
 local lookups=f.lookups;callback();assert(f.lookups==lookups and lookups<=60)
 assert(cancels==((case=='no_timer'or case=='schedule_throw')and 0 or 1))
 local terminal=events[#events];assert(terminal.status=='finished')
 assert(terminal.timer_cancelled==(case~='no_timer' and case~='schedule_throw' and case~='cancel_false' and case~='cancel_throw'))
 assert(terminal.samples<=60)
 if case=='frozen_clock'then assert(terminal.reason=='callback_limit' and terminal.callbacks==60 and f.lookups==1)end
end
print('dedicated parameter observer: original IDs, fresh scoped reads, unknowns, no grants, 60-sample/reentry bounds passed')
]=], '@dedicated-parameter-fixture'))()
