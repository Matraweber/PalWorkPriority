local H=dofile(TEST_ROOT..'/experiments/save_headless_identity_probe.lua')
local P=dofile(TEST_ROOT..'/experiments/dedicated_identity.lua')
local R=dofile(TEST_ROOT..'/experiments/dedicated_identity_runner.lua')
local directory=string.rep('a',32)
local function fixture()
    local f={calls=0,forbidden=0,wrappers={}}
    local function object(id,fields)
        fields.IsValid=function()return true end
        fields.GetAddress=function()return id end
        local wrapper=setmetatable({}, {__index=function(_,k)
            if f.on_read then f.on_read(id,k,fields)end
            if id==6 and k=='bIsLoadedWorldSaveData' then return fields[k]end
            if fields[k]~=nil then return fields[k]end
            f.forbidden=f.forbidden+1;error('SECRET forbidden field '..k)
        end,__newindex=function()f.forbidden=f.forbidden+1;error('native write')end,
        __pairs=function()f.forbidden=f.forbidden+1;error('enumeration')end})
        f.wrappers[wrapper]=true;return wrapper
    end
    f.i={};f.instance=object(1,f.i)
    f.s={WorldSaveDirectoryName=directory,Role=3,bIsDedicatedServer=true};f.state=object(2,f.s)
    f.w={GameState=f.state,OwningGameInstance=f.instance,GetFullName=function()return 'World same-map'end}
    f.world=object(3,f.w)
    f.l={OwningWorld=f.world};local level=object(4,f.l);f.s.GetLevel=function()return level end
    f.e={GameInstance=f.instance};f.engine=object(5,f.e)
    f.m={bIsLoadedWorldSaveData=true,GetOuter=function()return f.instance end}
    f.manager=object(6,f.m);f.i.SaveGameManager=f.manager
    f.root='C:/Fixture/Pal/Saved/'
    f.get_state=function(c)assert(c==f.instance);f.calls=f.calls+1;return f.state end
    f.get_instance=function(c)assert(c==f.state);return f.instance end
    f.get_saved=function()return f.root end
    f.object=object
    function f.read()
        local out=P.read(H,f.engine,f.get_state,f.get_instance,f.get_saved,directory,'C:/Fixture/Pal/Saved')
        assert(out.verified==false and out.active==false and out.storage_grant==false)
        for _,v in pairs(out)do
            assert(not f.wrappers[v] and (type(v)=='string' or type(v)=='number' or type(v)=='boolean'))
            assert(type(v)~='string' or not v:find('SECRET',1,true))
        end
        assert(f.forbidden==0,'forbidden engine access')
        return out
    end
    return f
end
local f=fixture();local out=f.read()
assert(out.status=='context_agrees' and out.expected_root_matches and f.calls==5 and f.forbidden==0)
assert(out.manager_address==6 and out.directory==directory)
for _,root in ipairs({'../../../Pal/Saved','C:/Other/Saved','//server/share','C:/Fixture/../Pal/Saved'})do
    f=fixture();f.root=root;out=f.read()
    assert(out.status=='context_agrees' and out.project_saved==root and not out.expected_root_matches)
    if root:sub(1,3)=='../' then assert(out.path_status=='relative_unresolved')end
end
for _,root in ipairs({'',string.rep('x',2049),'C:/SECRET\nforged','C:/SECRET|forged'})do
    f=fixture();f.root=root;assert(f.read().status=='unavailable')
end
for _,change in ipairs({'guildless_client','foreign_directory','manager_owner','instance','world','manager',
    'root_error','state_error','loaded_unknown','retiring_state','owner_during_root'})do
    f=fixture()
    if change=='guildless_client' then f.s.Role=1
    elseif change=='foreign_directory' then f.s.WorldSaveDirectoryName=string.rep('b',32)
    elseif change=='manager_owner' then f.m.GetOuter=function()return f.object(99,{})end
    elseif change=='instance' then f.get_saved=function()f.e.GameInstance=f.object(99,{});return f.root end
    elseif change=='world' then f.get_saved=function()f.w.GameState=f.object(99,{});return f.root end
    elseif change=='manager' then f.get_saved=function()f.i.SaveGameManager=f.object(99,{});return f.root end
    elseif change=='root_error' then f.get_saved=function()error('SECRET root')end
    elseif change=='owner_during_root' then f.get_saved=function()
        f.m.GetOuter=function()return f.object(99,{})end;return f.root end
    elseif change=='state_error' then f.get_state=function()error('SECRET state')end
    elseif change=='loaded_unknown' then f.m.bIsLoadedWorldSaveData='true'
    else f.get_state=function()f.calls=f.calls+1;return f.calls>=3 and f.object(99,{})or f.state end end
    out=f.read();assert(out.status=='unavailable' and out.directory==nil,change)
end
f=fixture();f.s.bIsDedicatedServer=false;assert(f.read().status=='unavailable')
f=fixture();f.m.bIsLoadedWorldSaveData=false;out=f.read()
assert(out.status=='context_agrees' and out.loaded_world==false and not out.verified)
-- Same-address aliases are valid; no selected-world or viewport reads occur.
f=fixture();f.m.GetOuter=function()return f.object(1,{})end;assert(f.read().status=='context_agrees')

-- Regressions: getters late in the second headless read can invalidate fields
-- already sampled. Failure must publish neither mixed context nor loaded flag.
local escaped={}
for _,change in ipairs({'loaded_during_root','loaded_late','world_owner_late','level_world_late','state_owner_late'})do
    f=fixture()
    if change=='loaded_during_root' then
        f.get_saved=function()f.m.bIsLoadedWorldSaveData=false;return f.root end
    else
        f.get_state=function(c)
            assert(c==f.instance);f.calls=f.calls+1
            if f.calls==4 then
                if change=='loaded_late' then f.m.bIsLoadedWorldSaveData=false
                elseif change=='world_owner_late' then f.w.OwningGameInstance=f.object(99,{})
                elseif change=='level_world_late' then
                    f.l.OwningWorld=f.object(99,{GameState=f.state,OwningGameInstance=f.instance})
                else f.get_instance=function()return f.object(99,{})end end
            end
            return f.state
        end
        -- Forward through the live fixture callable to model state-owner change.
        if change=='state_owner_late' then
            local original=f.get_instance
            f.get_instance=function(c)
                if f.calls>=4 then return f.object(99,{})end
                return original(c)
            end
        end
    end
    out=f.read()
    if out.status~='unavailable' or out.loaded_world~=nil or out.directory~=nil then escaped[#escaped+1]=change end
end
assert(#escaped==0,'inconsistent diagnostics escaped: '..table.concat(escaped,','))
for _,change in ipairs({'nil','nonboolean','throw','false_to_true'})do
    f=fixture();local reads=0
    if change=='false_to_true' then f.m.bIsLoadedWorldSaveData=false end
    f.on_read=function(id,key,fields)
        if id==6 and key=='bIsLoadedWorldSaveData' then
            reads=reads+1
            if reads==2 then
                if change=='throw' then error('SECRET loaded read')
                elseif change=='nil' then fields[key]=nil
                elseif change=='nonboolean' then fields[key]='true'
                else fields[key]=true end
            end
        end
    end
    out=f.read()
    assert(reads==2 and out.status=='unavailable' and out.loaded_world==nil,change)
end

local function runner(options)
    options=options or {};local t,cpu=0,0
    local callback,cancelled,emitted,n=nil,0,{},0
    local api={wall=function()return t end,clock=function()return cpu end,
        emit=function(v)emitted[#emitted+1]=v end,
        cancel=function(h)assert(h==42);cancelled=cancelled+1
            if options.cancel_throw then error('SECRET cancel')end
            return not options.cancel_false end,
        sample=function()
            n=n+1
            if options.reenter then callback()end
            if options.throw then error('SECRET sample')end
            if options.slow then cpu=cpu+0.101 end
            if options.deadline then t=60 end
            return options.success and fixture().read() or
                {status='unavailable',verified=false,active=false,storage_grant=false}
        end}
    api.schedule=function(ms,fn)
        assert(ms==1000);callback=fn
        if options.immediate then fn()end
        return not options.nohandle and 42 or nil
    end
    R.start(api)
    return {tick=function(time)t=time;callback()end, count=function()return n end,
        cancels=function()return cancelled end,output=emitted}
end
local r=runner();for i=1,100 do r.tick(0)end
assert(r.count()==60 and r.cancels()==1 and r.output[#r.output].status=='sample_limit')
r=runner();r.tick(60);assert(r.count()==0 and r.cancels()==1)
r=runner({success=true});for i=1,25 do r.tick(i)end
assert(r.count()==11 and r.output[#r.output].status=='observation_complete')
for _,opts in ipairs({{throw=true},{slow=true},{deadline=true},{throw=true,cancel_throw=true},
    {throw=true,cancel_false=true},{throw=true,immediate=true},{nohandle=true},{immediate=true,nohandle=true}})do
    r=runner(opts);r.tick(1);local n=r.count();r.tick(2)
    assert(r.count()==n,'terminal callback retained activity')
    assert(r.output[#r.output].verified==false)
end
r=runner({reenter=true});r.tick(1);assert(r.count()==1)
r.tick(-1);assert(r.cancels()==1)
-- Exercise the actual entry/collector/runner together with diagnostic-only IO.
local entry=TEST_ROOT..'/experiments/dedicated-identity-observer/main.lua'
local nonce='1234567890abcdef'
for _,armed in ipairs({true,false})do
    f=fixture();f.root='../../../Pal/Saved'
    local files={['/diagnostic/run.txt']=armed and 'PWP_DEDICATED_IDENTITY '..nonce..'\n' or 'DISABLED\n'}
    local callback,cancelled,t=nil,0,0
    local env=setmetatable({
        debug={getinfo=function()return {source='@/diagnostic/main.lua'}end},
        os={time=function()return t end,clock=function()return 0 end},
        io={open=function(p,mode)
            assert(p=='/diagnostic/run.txt' or p=='/diagnostic/identity.log','non-diagnostic IO')
            if mode=='r' then return {read=function()return files[p]end,close=function()return true end}end
            assert(mode=='a' or (p=='/diagnostic/run.txt' and mode=='w'))
            if mode=='w' then files[p]='' end
            return {write=function(_,value)files[p]=(files[p]or '')..value;return true end,
                close=function()return true end}
        end},
        dofile=function(p)
            if p=='/diagnostic/config.lua' then return {nonce=nonce,directory=directory,saved='C:/Fixture/Pal/Saved'}end
            if p=='/diagnostic/save_headless_identity_probe.lua' then return H end
            if p=='/diagnostic/dedicated_identity.lua' then return P end
            assert(p=='/diagnostic/dedicated_identity_runner.lua');return R
        end,
        FindFirstOf=function(kind)assert(kind=='GameEngine');return f.engine end,
        StaticFindObject=function(name)
            if name=='/Script/Engine.Default__GameplayStatics' then
                return {GetGameState=function(_,c)return f.get_state(c)end,
                    GetGameInstance=function(_,c)return f.get_instance(c)end}
            end
            assert(name=='/Script/Engine.Default__KismetSystemLibrary')
            return {GetProjectSavedDirectory=function()return f.root end}
        end,
        LoopInGameThreadWithDelay=function(ms,fn)assert(ms==1000);callback=fn;return 42 end,
        CancelDelayedAction=function(h)assert(h==42);cancelled=cancelled+1;return true end,
    },{__index=_G})
    assert(loadfile(entry,'t',env))()
    if armed then
        assert(files['/diagnostic/run.txt']=='DISABLED\n')
        for i=1,20 do t=i;callback()end
        local log=files['/diagnostic/identity.log']
        assert(log:find('path_status=relative_unresolved',1,true))
        assert(log:find('project_saved=../../../Pal/Saved',1,true))
        assert(log:find('status=observation_complete',1,true) and cancelled==1)
        assert(not log:find('verified=true',1,true) and not log:find('storage_grant=true',1,true))
    else assert(callback==nil and files['/diagnostic/identity.log']==nil)end
end
print('dedicated identity: context/manager revocation, relative root, no grants, bounded/reentrant cancellation passed')
