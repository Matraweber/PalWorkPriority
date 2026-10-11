-- Opt-in, one-shot diagnostic. Writes only its arm marker and bounded TSV log.
local dir=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/'):match('^(.*)/main.lua$'))
local open=io.open
local function transfer(path,mode,value)
    local f=open(path,mode);if not f then return nil end
    local ok,result=pcall(function()
        if mode=='r'then return f:read(128)end
        assert(f:write(value));assert(f:flush());return true
    end)
    local closed,yes=pcall(f.close,f)
    if not ok or not closed or not yes then return nil end
    return result
end
local ok,arm=pcall(transfer,dir..'/run.txt','r')
if not ok or type(arm)~='string'then return end
local nonce=arm:match('^PWP_EXPORT_MEMBERSHIP ([0-9a-f]+)\n$')
if not nonce or #nonce~=32 or nonce==string.rep('0',32)then return end
ok,arm=pcall(transfer,dir..'/run.txt','w','DISABLED\n')
if not ok or arm~=true then return end -- no config/modules/engine before disarm
local function plain(t)return type(t)=='table' and getmetatable(t)==nil end
local function copy(t)local r={};for k,v in next,t do r[k]=v end;return r end
local function equal(a,b)
    if not plain(a)or not plain(b)then return false end
    for k,v in next,a do if rawget(b,k)~=v then return false end end
    for k in next,b do if rawget(a,k)==nil then return false end end
    return true
end
local function hex(s,n)
    return type(s)=='string'and #s==n and s:match('^[0-9a-f]+$')and s~=string.rep('0',n)
end
local config_ok,config=pcall(dofile,dir..'/target.lua')
if not config_ok or not plain(config)then return end
local allowed={manifest_sha256=true,storage=true,guild=true,alias=true,keys=true}
for k in next,config do if not allowed[k]then return end end
if type(config.manifest_sha256)~='string'or #config.manifest_sha256~=64
    or not config.manifest_sha256:match('^[0-9a-f]+$')or not hex(config.storage,32)
    or not hex(config.guild,32)or type(config.alias)~='string'or #config.alias>64 then return end
local a,b,c,d=config.alias:match('^(%-?%d+)%-(%-?%d+)%-(%-?%d+)%-(%-?%d+)$')
if not a then return end
local parts={}
for _,word in ipairs({a,b,c,d})do
    local n=tonumber(word)
    if math.type(n)~='integer'or n< -2147483648 or n>4294967295 or tostring(n)~=word then return end
    parts[#parts+1]=string.format('%08x',n%4294967296)
end
if table.concat(parts)~=config.guild or not plain(config.keys)then return end
local count=0
for i in next,config.keys do
    if math.type(i)~='integer'or i<1 or i>256 then return end;count=count+1
end
local keys={}
for i=1,count do
    local k=rawget(config.keys,i)
    if type(k)~='string'or #k~=64 or not k:match('^[0-9A-F]+$')
        or k:sub(33)==string.rep('0',32)or(i>1 and k<=keys[i-1])then return end
    keys[i]=k
end
config={manifest_sha256=config.manifest_sha256,storage=config.storage,guild=config.guild,alias=config.alias,keys=keys}
local addresses={'world_address','state_address','instance_address','manager_address',
    'player_address','controller_address','player_state_address','guild_address'}
local grants={'activation_allowed','ownership_verified','deletion_coverage_verified','history_coverage_verified',
    'authority_grant','storage_grant','coverage_grant','replacement_allowed','deletion_allowed'}
local terminal,busy,scheduling=false,false,false
local before,samples,tries,lines=nil,0,0,0
local totals={confirmed=0,unresolved=0,not_examined=0}
local function emit(event,key,status,complete,counts,reason)
    local fields={'event='..event,'nonce='..nonce,'manifest_sha256='..config.manifest_sha256,
        'storage='..config.storage,'guild='..config.guild,'alias='..config.alias}
    local world=before and before.world:gsub('.',function(ch)return string.format('%02x',string.byte(ch))end)or'none'
    fields[#fields+1]='world_hex='..world
    for _,name in ipairs(addresses)do fields[#fields+1]=name..'='..tostring(before and before[name]or 0)end
    fields[#fields+1]='sample='..samples
    fields[#fields+1]='key='..(key or'none');fields[#fields+1]='status='..(status or'none')
    fields[#fields+1]='complete='..tostring(complete==true)
    for _,name in ipairs({'confirmed','unresolved','not_examined'})do
        fields[#fields+1]=name..'='..tostring(counts and counts[name]or 0)
    end
    fields[#fields+1]='reason='..(reason or'none')
    for _,name in ipairs(grants)do fields[#fields+1]=name..'=false'end
    local line='PWP_EXPORT_MEMBERSHIP\t'..table.concat(fields,'\t')..'\n'
    assert(#line<=4096 and lines<774,'log_bound');lines=lines+1
    assert(transfer(dir..'/export-membership.log','a',line),'log_failed')
end
local function fail(reason)
    if terminal then return end
    terminal=true;pcall(emit,'failed',nil,nil,false,nil,reason)
end
local setup,Pair,Authority,Direct,Observer,api=pcall(function()
    package.path=dir..'/?.lua;'..package.path
    local p=dofile(dir..'/experiments/save_context_pair_probe.lua')
    local a=dofile(dir..'/experiments/save_local_authority.lua')
    local d=dofile(dir..'/experiments/settings_priority_live_reader.lua')
    local o=dofile(dir..'/experiments/settings_export_membership_observer.lua')
    local api=require('palapi')
    for name,method in pairs({palapi='camp_pals',store='durable_key',datafile='read',settings_gate='blocked',
        log='say',trace='at',perf='new',frame_trace='new'})do
        local source=debug.getinfo(assert(require(name)[method]),'S').source:gsub('^@',''):gsub('\\','/')
        assert(source==dir..'/'..name..'.lua','module_origin')
    end
    return p,a,d,o,api
end)
if not setup then fail('runner_error');return end
-- Same Pair + local Authority route as priority-roster-live; no actor sweep.
local function context()
    local h=require('UEHelpers');local engine=h.GetEngine();local cdo=h.GetGameplayStatics(true)
    assert(cdo and cdo:IsValid()==true)
    local p=Pair.read(engine,function(c)return cdo:GetGameState(c)end,function(c)return cdo:GetGameInstance(c)end)
    if p.status~='context_agrees'or p.agrees~=true then return end
    if p.identity_loaded_status~='read'or p.identity_loaded_world~=true
        or p.identity_selected_status~='format_valid'or p.identity_selected~=config.storage then return end
    if not(p.identity_autosave_status=='empty'and p.identity_autosave==nil)
        and not(p.identity_autosave_status=='format_valid'and p.identity_autosave==config.storage)then return end
    local a=Authority.read(engine,p)
    if a.authority_status~='read'or a.authority~=true or a.guild_status~='format_valid'then return end
    assert(p.directory==config.storage and a.guild==config.guild and a.legacy_guild==config.alias)
    local out={storage=p.directory,guild=a.guild,alias=a.legacy_guild,legacy_guild=a.legacy_guild,world=p.world,
        world_address=p.world_address,state_address=p.state_address,instance_address=p.instance_address,
        manager_address=p.manager_address,player_address=a.player_address,controller_address=a.controller_address,
        player_state_address=a.player_state_address,guild_address=a.guild_address}
    assert(type(out.world)=='string'and #out.world>0 and #out.world<=512 and not out.world:find('%c'))
    for _,name in ipairs(addresses)do assert(math.type(out[name])=='integer'and out[name]>0)end
    return out
end
local function current()
    if terminal then error('terminal',0)end
    local fresh=context()
    if terminal or not fresh or not equal(fresh,before)then error('context_changed',0)end
    return fresh
end
local tick
local schedule=ExecuteInGameThreadWithDelay
local function later(ms)
    if terminal then return end
    scheduling=true
    local called=false
    local yes=pcall(schedule,ms,function()
        if terminal then return end
        if called or scheduling or busy then fail('reentrant');return end
        called=true;tick()
    end)
    scheduling=false
    if not yes then fail('schedule_failed')end
end
tick=function()
    if terminal then return end
    if busy then fail('reentrant');return end
    busy=true
    if not before then
        tries=tries+1
        local yes,value=pcall(context)
        if terminal then busy=false;return end
        if not yes or not value then
            busy=false
            if tries>=120 then fail('context_readiness_timeout')else later(2000)end
            return
        end
        before=value
    end
    local yes=pcall(function()
        current();samples=samples+1
        local scoped={scope='PWP-SCOPE-1:'..before.storage..':'..before.guild..':priorities',
            storage=before.storage,guild=before.guild,stream='priorities',session=nonce,
            incarnation=tostring(before.world_address),epoch=1,camp='diagnostic',authority=true}
        local observer=assert(Observer.new{manifest_sha256=config.manifest_sha256,keys=keys,context=scoped,
            read_context=function()current();return copy(scoped)end,
            reader_factory=function(_,c)
                current()
                local made,reader=pcall(Direct.new,{enabled=true,context=c,runtime_guild=before.alias,
                    read_context=current,get_engine=function()return require('UEHelpers').GetEngine()end,
                    api=api,authorize=function()current();return true end})
                if not made or not plain(reader)or type(reader.owns_key)~='function'then
                    fail('observation_failed');error('reader_failed',0)
                end
                local owns=reader.owns_key
                return {owns_key=function(key,ctx)
                    local called,accepted=pcall(owns,key,ctx)
                    if not called then fail('observation_failed');error('reader_failed',0)end
                    return accepted
                end}
            end})
        local result=assert(observer.sample())
        current()
        if result.fenced or not result.complete then fail('observation_failed');return end
        totals={confirmed=0,unresolved=0,not_examined=0}
        for _,row in ipairs(result.keys)do
            local name=row.status=='current_target_confirmed'and'confirmed'or row.status
            assert(totals[name]~=nil);totals[name]=totals[name]+1
            emit('key',row.key,row.status,false)
            if terminal then return end
        end
        current();emit('sample',nil,nil,true,totals)
        if terminal then return end
        current()
        if samples==3 then emit('done',nil,nil,true,totals);terminal=true end
    end)
    busy=false
    if terminal then return end
    if not yes then fail('runner_error');return end
    later(10000)
end
if not pcall(emit,'armed',nil,nil,false)then fail('log_failed');return end
later(30000)
