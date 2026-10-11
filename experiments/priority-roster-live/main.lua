-- One-shot, read-only diagnostic. Never authorizes migration or writes settings.
local dir=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/'):match('^(.*)/main.lua$'))
local f=io.open(dir..'/run.txt','r');if not f then return end
local marker=f:read('*a');assert(f:close())
local nonce=marker:match('^PWP_PRIORITY_ROSTER ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
f=assert(io.open(dir..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
package.path=dir..'/?.lua;'..package.path
local config=dofile(dir..'/target.lua')
assert(config.route==nil or config.route=='camp' or config.route=='guild' or config.route=='parameter' or config.route=='world' or config.route=='direct','unsupported diagnostic route')
local direct_route=config.route=='direct'
local world_route=config.route=='world'
local parameter_route=config.route=='parameter' or world_route
local guild_route=config.route=='guild' or parameter_route or direct_route
local Pair=dofile(dir..'/experiments/save_context_pair_probe.lua')
local Authority=dofile(dir..'/experiments/save_local_authority.lua')
local Roster=dofile(dir..'/experiments/settings_priority_roster.lua')
local GuildRoster=guild_route and dofile(dir..'/experiments/settings_priority_guild_roster.lua')
local ParameterRoster=parameter_route and dofile(dir..'/experiments/settings_priority_parameter_roster.lua')
local WorldLookup=world_route and dofile(dir..'/experiments/settings_priority_world_lookup.lua')
local Direct=direct_route and dofile(dir..'/experiments/settings_priority_live_reader.lua')
local api,workdefs=require('palapi'),require('workdefs')
for name,method in pairs({palapi='camp_pals',workdefs='value',log='say',trace='at',perf='new',frame_trace='new'})do
    local source=debug.getinfo(assert(require(name)[method]),'S').source:gsub('^@',''):gsub('\\','/')
    assert(source==dir..'/'..name..'.lua','unexpected loaded module '..name)
end
if direct_route then
    for name,method in pairs({store='durable_key',datafile='read',settings_gate='blocked'})do
        local source=debug.getinfo(assert(require(name)[method]),'S').source:gsub('^@',''):gsub('\\','/')
        assert(source==dir..'/'..name..'.lua','unexpected loaded module '..name)
    end
end
local batch
local function emit(event,fields)
    local line={os.date('!%Y-%m-%dT%H:%M:%SZ'),nonce,event}
    local keys={};for k in pairs(fields)do keys[#keys+1]=k end;table.sort(keys)
    for _,k in ipairs(keys)do
        local v=fields[k];assert(type(v)=='string' or type(v)=='number' or type(v)=='boolean')
        line[#line+1]=k..'='..tostring(v):gsub('[\r\n\t]',' ')
    end
    local text=table.concat(line,'\t')..'\n'
    if batch then batch[#batch+1]=text;return end
    local out=assert(io.open(dir..'/roster.log','a'))
    local wrote=out:write(text);local closed=out:close();assert(wrote and closed)
end
local function context()
    local h=require('UEHelpers');local engine=h.GetEngine();local cdo=h.GetGameplayStatics(true)
    assert(cdo and cdo:IsValid()==true,'GameplayStatics unavailable')
    local p=Pair.read(engine,function(c)return cdo:GetGameState(c)end,function(c)return cdo:GetGameInstance(c)end)
    if p.status~='context_agrees' or p.agrees~=true then return end
    if p.identity_loaded_status~='read' or p.identity_loaded_world~=true
        or p.identity_selected_status~='format_valid' or p.identity_selected~=config.storage then return end
    if not(p.identity_autosave_status=='empty' and p.identity_autosave==nil)
        and not(p.identity_autosave_status=='format_valid' and p.identity_autosave==config.storage) then return end
    local a=Authority.read(engine,p)
    if a.authority_status~='read' or a.authority~=true or a.guild_status~='format_valid' then return end
    assert(p.directory==config.storage and a.guild==config.guild and a.legacy_guild==config.alias,'unexpected world/guild')
    return {storage=p.directory,guild=a.guild,alias=a.legacy_guild,legacy_guild=a.legacy_guild,world=p.world,
        world_address=p.world_address,state_address=p.state_address,instance_address=p.instance_address,
        manager_address=p.manager_address,player_address=a.player_address,controller_address=a.controller_address,
        player_state_address=a.player_state_address,guild_address=a.guild_address}
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a)do if not equal(v,b[k])then return false end end
    for k in pairs(b)do if a[k]==nil then return false end end
    return true
end
local tries,samples=0,0
local function tick()
    tries=tries+1
    local ok,reason=pcall(function()
        local before=context();if not before then return false end
        local function roster()
            if direct_route then
                -- Diagnostic context only. No startup, writer, native save handle
                -- or authority grant is created by this isolated process-local read.
                local c={scope='PWP-SCOPE-1:'..before.storage..':'..before.guild..':priorities',
                    storage=before.storage,guild=before.guild,stream='priorities',session=nonce,
                    incarnation=tostring(before.world_address),epoch=1,camp='diagnostic',authority=true}
                local reader=assert(Direct.new{enabled=true,context=c,runtime_guild=before.alias,
                    read_context=context,get_engine=function()return require('UEHelpers').GetEngine()end,
                    api=api,authorize=function()local fresh=context();return fresh~=nil and equal(before,fresh)end})
                local keys,decisions={},{}
                local complete=true
                for _,key in ipairs(config.keys)do
                    local accepted=reader.owns_key(key,c)==true
                    decisions[#decisions+1]={key=key,accepted=accepted}
                    if accepted then keys[#keys+1]=key else complete=false end
                end
                reader.revoke()
                return {complete=complete,keys=keys,decisions=decisions,reason='direct_guild_id'}
            end
            if guild_route then
                local g=GuildRoster.read(require('UEHelpers').GetEngine(),before,api)
                if not parameter_route then return g end
                local wanted={};for _,k in ipairs(config.keys)do wanted[k]=true end
                local resolver
                if world_route then
                    resolver=function(native_id)
                        assert(type(native_id)=='userdata','original reflected identity required')
                        local engine=require('UEHelpers').GetEngine()
                        local util=api.cdo('/Script/Pal.Default__PalUtility')
                        return WorldLookup.read(engine,before,native_id,util)
                    end
                end
                local p=ParameterRoster.read(function()return FindAllOf('PalIndividualCharacterParameter')end,api,before.guild,wanted,resolver)
                local in_guild={};for _,k in ipairs(g.keys or {})do in_guild[k]=true end
                local keys={};for _,r in ipairs(p.records)do
                    if r.matches and in_guild[r.key]then keys[#keys+1]=r.key end
                end
                return {complete=g.complete and p.complete,keys=keys,records=p.records,
                    array_address=g.array_address,reason=g.complete and p.reason or g.reason}
            end
            return Roster.read(api,workdefs,config.alias)
        end
        local first,second=roster(),roster()
        local after=context()
        assert(after and equal(before,after),'context changed during observation')
        batch={}
        samples=samples+1
        local stable=equal(first,second)
        local present,total={},0
        if direct_route then
            for _,r in ipairs(first.decisions)do
                emit('ownership',{sample=samples,key=r.key,accepted=r.accepted})
            end
        end
        if parameter_route then
            for _,r in ipairs(first.records or {})do
                emit('parameter',{sample=samples,key=r.key,group=r.group,matches=r.matches,address=r.address,world_resolved=r.world_resolved==true})
            end
        end
        if guild_route then
            for _,key in ipairs(first.keys or {})do
                present[key]='guild-roster';total=total+1
                emit('guild_key',{sample=samples,key=key})
            end
        end
        for _,camp in ipairs(first.camps or {})do
            for _,pal in ipairs(camp.pals or {})do
                present[pal.key]=camp.key;total=total+1
                local works={};for work in pairs(pal.capable)do works[#works+1]=work end;table.sort(works)
                emit('pal',{sample=samples,camp=camp.key,key=pal.key,capable=table.concat(works,',')})
            end
        end
        local matched=0
        for _,key in ipairs(config.keys)do
            if present[key]then matched=matched+1 end
            emit('saved_key',{sample=samples,key=key,observed=present[key]~=nil,camp=present[key] or 'unknown'})
        end
        emit('sample',{sample=samples,route=direct_route and 'direct' or world_route and 'world' or parameter_route and 'parameter' or guild_route and 'guild' or 'camp',complete=first.complete==true,second_complete=second.complete==true,stable=stable,pals=total,
            camps=#(first.camps or {}),saved=#config.keys,matched=matched,unknown=#config.keys-matched,
            target_camps=first.target_camps or 0,foreign_camps=first.foreign_camps or 0,
            expected_camps_observed=#(first.camps or {})==2,
            storage=before.storage,guild=before.guild,reason=first.reason or '',activation_allowed=false,
            array_address=first.array_address or 0,
            world_membership_proven=false})
        local text=table.concat(batch);batch=nil
        local out=assert(io.open(dir..'/roster.log','a'))
        local wrote=out:write(text);local closed=out:close();assert(wrote and closed)
        return true
    end)
    if not ok then batch=nil;pcall(emit,'failed',{reason=tostring(reason):sub(1,1000),activation_allowed=false});return end
    if samples>=3 then emit('done',{samples=samples,activation_allowed=false});return end
    if tries>=120 then emit('failed',{reason='context readiness timeout',activation_allowed=false});return end
    ExecuteInGameThreadWithDelay(reason==true and 10000 or 2000,tick)
end
emit('armed',{read_only=true,activation_allowed=false})
ExecuteInGameThreadWithDelay(30000,tick)
