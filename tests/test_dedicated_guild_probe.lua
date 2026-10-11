local P=dofile(TEST_ROOT..'/experiments/dedicated_guild_probe.lua')
local function guid(n)return {A=0,B=0,C=0,D=n}end
local function fixture()
    local f={forbidden=0,visits=0,manager_calls=0,wrappers={}}
    local function object(id,fields)
        fields.IsValid=function()return true end;fields.GetAddress=function()return id end
        local proxy=setmetatable({}, {__index=function(_,k)
            if f.on_read then f.on_read(id,k,fields)end
            if fields[k]~=nil then return fields[k]end
            f.forbidden=f.forbidden+1;error('SECRET forbidden read '..k)
        end,__newindex=function()f.forbidden=f.forbidden+1;error('native write')end,
        __pairs=function()f.forbidden=f.forbidden+1;error('native enumeration')end})
        f.wrappers[proxy]=true;return proxy
    end
    f.object=object
    f.i={};f.instance=object(1,f.i)
    f.s={WorldSaveDirectoryName=string.rep('a',32),Role=3,bIsDedicatedServer=true}
    f.state=object(2,f.s)
    f.w={OwningGameInstance=f.instance,GameState=f.state,GetFullName=function()return 'World dedicated'end}
    f.world=object(3,f.w)
    f.l={OwningWorld=f.world};local level=object(4,f.l);f.s.GetLevel=function()return level end
    f.e={GameInstance=f.instance};f.engine=object(5,f.e)
    f.save={bIsLoadedWorldSaveData=true,GetOuter=function()return f.instance end}
    f.i.SaveGameManager=object(6,f.save)
    f.items={{HandleId={PlayerUId=guid(0),InstanceId=guid(11)}},
        {HandleId={PlayerUId=guid(9),InstanceId=guid(12)}}}
    f.a={IndividualCharacterHandleIds={Items=f.items}};f.array=object(7,f.a)
    f.g={GetId=function()return guid(1)end,IndividualIdArray=f.array};f.guild=object(8,f.g)
    f.entries={{guid(1),f.guild}};f.map_size=nil
    f.map=setmetatable({}, {__len=function()return f.map_size or #f.entries end,
        __index={type=function()return 'TMap'end,ForEach=function(_,visit)
            for _,row in ipairs(f.entries)do
                f.visits=f.visits+1
                if visit(row[1],row[2])then break end
            end
        end}})
    f.m={GuildMap=f.map,GetOuter=function()return f.world end};f.manager=object(9,f.m)
    f.o={enabled=true,engine=f.engine,guild=string.rep('0',31)..'1',
        expected={directory=string.rep('a',32),world_address=3,state_address=2,
            instance_address=1,manager_address=6,loaded_world=true},
        get_state=function(c)assert(c==f.instance);return f.state end,
        get_instance=function(s)assert(s==f.state);return f.instance end,
        get_manager=function(w)
            assert(w==f.world);f.manager_calls=f.manager_calls+1
            if f.change then f.change(f.manager_calls)end
            return f.manager
        end,unwrap=function(v)return v end}
    function f.read()
        local out=P.read(f.o)
        assert(f.forbidden==0,'forbidden access was swallowed')
        assert(out.verified==false and out.active==false and out.storage_grant==false and out.authority_grant==false)
        local function safe(v)
            assert(not f.wrappers[v])
            if type(v)=='table'then assert(getmetatable(v)==nil);for _,x in pairs(v)do safe(x)end
            else assert(type(v)=='string' or type(v)=='number' or type(v)=='boolean')
                assert(type(v)~='string' or not v:find('SECRET',1,true))end
        end
        safe(out);return out
    end
    return f
end
local f=fixture();local out=f.read()
assert(out.complete and out.status=='observed' and out.count==2 and #out.keys==2)
assert(f.manager_calls==4 and f.visits==4)
assert(out.keys[1]==string.rep('0',63)..'B') -- zero player ID allowed, nonzero instance required
f.items[1].HandleId.InstanceId=guid(13);assert(out.keys[1]==string.rep('0',63)..'B','retained native data')
f=fixture();f.o.enabled=false;assert(f.read().status=='disabled' and f.manager_calls==0)
f=fixture();f.a.IndividualCharacterHandleIds.Items={};out=f.read();assert(out.complete and out.count==0)
for _,case in ipairs({'missing','wrong_key','duplicate_guild','duplicate_id','oversize_map','oversize_roster',
    'manager_owner','client','directory','world_owner','state_owner','save_owner','unloaded',
    'changed_roster','changed_manager','changed_world','changed_loaded','changed_role',
    'changed_directory','changed_save_owner','nil_manager','throws'})do
    f=fixture()
    if case=='missing'then f.entries={}
    elseif case=='wrong_key'then f.entries[1][1]=guid(2)
    elseif case=='duplicate_guild'then f.entries[2]=f.entries[1]
    elseif case=='duplicate_id'then f.items[2]=f.items[1]
    elseif case=='oversize_map'then f.map_size=129
    elseif case=='oversize_roster'then
        f.a.IndividualCharacterHandleIds.Items=setmetatable({}, {__len=function()return 4097 end,
            __index=function()f.forbidden=f.forbidden+1;error('indexed oversize roster')end})
    elseif case=='manager_owner'then f.m.GetOuter=function()return f.object(99,{})end
    elseif case=='client'then f.s.Role=1
    elseif case=='directory'then f.s.WorldSaveDirectoryName=string.rep('b',32)
    elseif case=='world_owner'then f.w.OwningGameInstance=f.object(99,{})
    elseif case=='state_owner'then f.o.get_instance=function()return f.object(99,{})end
    elseif case=='save_owner'then f.save.GetOuter=function()return f.object(99,{})end
    elseif case=='unloaded'then f.save.bIsLoadedWorldSaveData=false
    elseif case=='changed_roster'then f.change=function(n)if n==2 then f.items[1].HandleId.InstanceId=guid(99)end end
    elseif case=='changed_manager'then f.change=function(n)if n==2 then f.manager=f.object(99,f.m)end end
    elseif case=='changed_world'then f.change=function(n)if n==4 then f.w.OwningGameInstance=f.object(99,{})end end
    elseif case=='changed_loaded'then f.change=function(n)if n==4 then f.save.bIsLoadedWorldSaveData=false end end
    elseif case=='changed_role'then f.change=function(n)if n==4 then f.s.Role=1 end end
    elseif case=='changed_directory'then f.change=function(n)if n==4 then f.s.WorldSaveDirectoryName=string.rep('b',32)end end
    elseif case=='changed_save_owner'then f.change=function(n)if n==4 then f.save.GetOuter=function()return f.object(99,{})end end end
    elseif case=='nil_manager'then f.o.get_manager=function()return nil end
    else f.o.get_manager=function()error('SECRET getter')end end
    out=f.read();assert(not out.complete and #out.keys==0 and out.guild==nil,case)
    if case=='oversize_map'then assert(f.visits==0)end
end
-- A foreign guild is observed only to validate the exact map selection; never
-- read its roster or substitute it for the requested guild.
f=fixture();f.entries[2]={guid(2),f.object(12,{GetId=function()return guid(2)end})}
assert(f.read().complete)
f=fixture();f.entries[2]={guid(2),f.object(12,{GetId=function()return guid(3)end})}
assert(not f.read().complete,'foreign map key/object mismatch accepted')
f=fixture();f.entries[1][1]=guid(0);assert(not f.read().complete)
for _,bad in ipairs({0,-1,1.5,'1',math.huge})do
    f=fixture();f.items[1].HandleId.InstanceId.D=bad
    if bad==-1 then assert(f.read().complete) -- signed FGuid word is valid
    else assert(not f.read().complete)end
end
-- Incomplete/truncated map enumeration cannot look like an empty valid result.
f=fixture();f.map_size=2;assert(not f.read().complete)
for _,case in ipairs({'group_manager_resolve','group_manager_identity','group_manager_owner',
    'guild_map','guild_map_count','guild_lookup','roster_array','roster_items','roster_count','roster_ids'})do
    f=fixture()
    if case=='group_manager_resolve'then f.o.get_manager=function()error('SECRET native exception')end
    elseif case=='group_manager_identity'then f.o.get_manager=function()return nil end
    elseif case=='group_manager_owner'then f.m.GetOuter=function()error('SECRET outer')end
    elseif case=='guild_map'then f.on_read=function(id,key)if id==9 and key=='GuildMap'then error('SECRET map')end end
    elseif case=='guild_map_count'then f.map_size=129
    elseif case=='guild_lookup'then f.entries={}
    elseif case=='roster_array'then f.on_read=function(id,key)if id==8 and key=='IndividualIdArray'then error('SECRET array')end end
    elseif case=='roster_items'then f.on_read=function(id,key)if id==7 and key=='IndividualCharacterHandleIds'then error('SECRET items')end end
    elseif case=='roster_count'then f.a.IndividualCharacterHandleIds.Items=setmetatable({}, {__len=function()return 4097 end})
    else f.items[2]=f.items[1]end
    out=f.read()
    assert(out.stage==case and out.reason=='unavailable_or_changed',case..':'..tostring(out.stage))
    assert(not out.complete and #out.keys==0 and out.count==nil and out.guild==nil)
end
local escaped={}
for _,change in ipairs({'removed_guild','guild_id','array','contents'})do
    f=fixture()
    f.change=function(n)
        if n==4 then
            if change=='removed_guild'then f.entries={}
            elseif change=='guild_id'then f.g.GetId=function()return guid(2)end
            elseif change=='array'then
                f.g.IndividualIdArray=f.object(99,{IndividualCharacterHandleIds={Items={}}})
            else f.items[1].HandleId.InstanceId=guid(99)end
        end
    end
    out=f.read()
    if out.complete or #out.keys~=0 then escaped[#escaped+1]=change end
end
assert(#escaped==0,'late guild changes escaped: '..table.concat(escaped,','))
for _,change in ipairs({'world','role','loaded','manager_owner','manager_invalid'})do
    f=fixture()
    f.o.unwrap=function(v)
        if f.manager_calls==4 then
            if change=='world'then f.w.OwningGameInstance=f.object(99,{})
            elseif change=='role'then f.s.Role=1
            elseif change=='manager_owner'then f.m.GetOuter=function()return f.object(99,{})end
            elseif change=='manager_invalid'then f.m.IsValid=function()return false end
            else f.save.bIsLoadedWorldSaveData=false end
        end
        return v
    end
    assert(not f.read().complete,'final roster callback changed '..change)
end
-- Real optional entry integration: no utility resolution without an explicit
-- target; native failure is unknown, genuine empty roster remains distinct.
local H=dofile(TEST_ROOT..'/experiments/save_headless_identity_probe.lua')
local Identity=dofile(TEST_ROOT..'/experiments/dedicated_identity.lua')
local Runner=dofile(TEST_ROOT..'/experiments/dedicated_identity_runner.lua')
for _,case in ipairs({'disabled','matched','absent','empty','throw','context_changed','changing','injected_stage'})do
    local callback,time,cancelled,utility_calls= nil,0,0,0
    local files={['/probe/run.txt']='PWP_DEDICATED_IDENTITY nonce\n'}
    local target=case~='disabled' and string.rep('0',31)..'1' or nil
    local env=setmetatable({debug={getinfo=function()return {source='@/probe/main.lua'}end},
        os={time=function()return time end,clock=function()return 0 end},
        io={open=function(path,mode)
            assert(path=='/probe/run.txt' or path=='/probe/identity.log')
            if mode=='r'then return {read=function()return files[path]end,close=function()return true end}end
            assert(mode=='a' or (path=='/probe/run.txt' and mode=='w'))
            if mode=='w'then files[path]=''end
            return {write=function(_,s)files[path]=(files[path]or '')..s;return true end,close=function()return true end}
        end},
        dofile=function(path)
            if path=='/probe/config.lua'then return {nonce='nonce',directory=string.rep('a',32),
                saved='C:/Fixture/Pal/Saved',guild=target}end
            if path=='/probe/save_headless_identity_probe.lua'then return H end
            if path=='/probe/dedicated_identity.lua'then return Identity end
            if path=='/probe/dedicated_identity_runner.lua'then return Runner end
            assert(path=='/probe/dedicated_guild_probe.lua' and target)
            if case=='injected_stage'then return {read=function()
                return {status='unavailable',complete=false,stage='SECRET\nforged',reason='SECRET raw exception',
                    count=999,keys={'SECRET leaked ID'}}
            end}end
            return P
        end,
        FindFirstOf=function(kind)assert(kind=='GameEngine');return f.engine end,
        StaticFindObject=function(name)
            if name=='/Script/Engine.Default__GameplayStatics'then return {
                GetGameState=function(_,c)return f.o.get_state(c)end,
                GetGameInstance=function(_,c)return f.o.get_instance(c)end}end
            if name=='/Script/Engine.Default__KismetSystemLibrary'then return {
                GetProjectSavedDirectory=function()return 'C:/Fixture/Pal/Saved'end}end
            assert(name=='/Script/Pal.Default__PalUtility' and target)
            utility_calls=utility_calls+1
            return {GetGroupManager=function(_,w)
                if case=='throw'then error('SECRET native failure')end
                if case=='context_changed'then f.w.OwningGameInstance=f.object(99,{})end
                return f.o.get_manager(w)
            end}
        end,
        LoopInGameThreadWithDelay=function(ms,fn)assert(ms==1000);callback=fn;return 42 end,
        CancelDelayedAction=function(handle)assert(handle==42);cancelled=cancelled+1;return true end,
    },{__index=_G})
    assert(loadfile(TEST_ROOT..'/experiments/dedicated-identity-observer/main.lua','t',env))()
    for i=1,(case=='changing' and 15 or 2) do
        f=fixture() -- entirely fresh wrappers on each sample
        if case=='absent'then f.entries={}elseif case=='empty'then f.a.IndividualCharacterHandleIds.Items={}end
        if case=='changing'then
            if i%2==0 then f.a.IndividualCharacterHandleIds.Items={}end
            f.manager=f.object(100+i,f.m)
        end
        time=i;callback();assert(f.forbidden==0)
        f.e.IsValid=function()error('retired engine wrapper')end
    end
    time=60;callback();assert(cancelled==1)
    local log=assert(files['/probe/identity.log'])
    assert(not log:find('SECRET',1,true) and not log:find('verified=true',1,true)
        and not log:find('grant=true',1,true))
    for line in log:gmatch('[^\n]+')do assert(#line<1400)end
    if case=='disabled'then assert(utility_calls==0 and not log:find('guild_count=',1,true))
    elseif case=='changing'then
        assert(utility_calls==11 and log:find('status=identity_observation_complete',1,true))
        assert(log:find('guild_count=0',1,true) and log:find('guild_count=2',1,true))
        assert(log:find('guild_stability=not_evaluated',1,true)
            and not log:find('status=observation_complete',1,true))
    elseif case=='matched' or case=='empty'then
        assert(utility_calls==2 and log:find('guild_complete=true',1,true))
        assert(log:find('guild_count='..(case=='empty'and '0' or '2'),1,true))
        assert(not log:find(string.rep('0',63)..'B',1,true),'per-ID log')
    else
        assert(log:find('guild_count=unknown',1,true) and log:find('guild_complete=false',1,true))
        assert(not log:find('guild_count=0',1,true))
        if case=='absent'then assert(log:find('guild_stage=guild_lookup',1,true))end
        if case=='throw'then assert(log:find('guild_stage=group_manager_resolve',1,true))end
        if case=='injected_stage'then assert(log:find('guild_stage=result_rejected',1,true))end
    end
end
print('dedicated guild probe and optional entry: bounded copied roster, unknown vs empty, fresh samples and no grants passed')
