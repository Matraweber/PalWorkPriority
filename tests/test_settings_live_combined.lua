-- Real combined launcher and all composition modules. Only OS file reads,
-- native wire endpoint and engine objects are fixtures. No DLL/player files.
-- A temporary Lua-owned userdata shell models the original const-ref ID, as
-- in test_priority_direct_reader; its metatable is restored before closing.
local real_dofile,real_loadlib,real_open,real_time=dofile,package.loadlib,io.open,os.time
local ROOT=TEST_ROOT..'/experiments/'
local W,G,ALIAS=string.rep('3',32),'ffffffff000000020000000300000004','-1-2-3-4'
local KEY=string.rep('0',32)..string.format('%032X',1)
local hooknames={'RegisterLoadMapPreHook','RegisterLoadMapPostHook','RegisterInitGameStatePreHook',
    'RegisterInitGameStatePostHook','RegisterEndPlayPreHook'}
local function fixture(fault)
    for _,name in ipairs({'caps','store','settings_gate','datafile','session','palapi'})do package.loaded[name]=nil end
    local f={fault=fault,scheduled={},delays={},hooks={},events={},owners={},startups={},proofs={},loads={},
        calls={},registered={},activations={},proof_contexts={},lookups=0,discovery=0,hold=true,files_read=0,now=1000}
    os.time=function()return f.now end
    f.profile_clock_calls=0;f.profile_time=0;f.profile_events={};f.profile_order={}
    f.profiler=require('perf').new{resolution_ms=1,clock=function()
        f.profile_clock_calls=f.profile_clock_calls+1;f.profile_time=f.profile_time+.001;return f.profile_time
    end,wall_clock=function()return f.now end,on_finish=function(name,first,last)
        f.profile_events[#f.profile_events+1]={name=name,first=first,last=last}
    end}
    package.loaded.log={say=function(s)f.events[#f.events+1]=s end,warn=function()end,error=function()end,
        around=function(name,fn,...)
            f.profile_order[#f.profile_order+1]=name
            return f.profiler:around(name,fn,...)
        end}
    local gate=require('settings_gate');f.gate=gate
    local file=require('datafile');local fs=require('memory_fs')();file.fs=fs;f.fs=fs
    local caps,store=require('caps'),require('store');f.caps,f.store=caps,store
    local files={}
    for _,base in ipairs({'caps.txt','priorities.txt'})do
        for _,suffix in ipairs({'','.tmp','.pending','.bak'})do files[base..suffix]=false end
    end
    files['caps.txt']=assert(caps.serialize_snapshot({[ALIAS]={Mining={Stone=100}}}))
    files['priorities.txt']=assert(store.serialize_snapshot({[KEY]={[1]=2,[2]=false}},true))
    fs.files['caps.txt'],fs.files['priorities.txt']=files['caps.txt'],files['priorities.txt']
    caps.load('caps.txt');store.load('priorities.txt');caps.set_role('authority',1);store.set_role('authority',1)
    f.session=require('session');assert(f.session.begin('World fixture')==1)
    f.options={enabled=true,nonce='combined-fixture',dll='fixture-only.dll',storage=W,guild=G,runtime_guild=ALIAS,
        receipt={source_root='C:/fixture-source',backup_root='D:/fixture-backup',manifest='pinned',files=files}}
    io.open=function(path,mode)
        assert(mode=='rb','launcher must not write files');f.files_read=f.files_read+1
        path=path:gsub('\\','/')
        local raw
        if path=='D:/fixture-backup/manifest.json'then raw='pinned'
        else
            local name=path:match('^[CD]:/fixture%-[^/]+/(.+)$')
            assert(name and files[name]~=nil,'unexpected file '..path)
            raw=files[name]
        end
        if raw==false then return nil,'missing',2 end
        return {read=function()return raw end,close=function()return true end}
    end
    local function obj(address,t)
        t=t or {};t.IsValid=function()return true end;t.GetAddress=function()return address end;return t
    end
    local id=assert(io.tmpfile());local id_mt=debug.getmetatable(id)
    debug.setmetatable(id,{__index={PlayerUId={A=0,B=0,C=0,D=0},InstanceId={A=0,B=0,C=0,D=1}}})
    f.dispose=function()debug.setmetatable(id,id_mt);id:close()end
    local guild=obj(8,{Id={A=-1,B=2,C=3,D=4},IndividualIdArray=obj(11,
        {IndividualCharacterHandleIds={Items={{HandleId=id}}}})})
    local state=obj(3,{Role=3,bIsDedicatedServer=false,WorldSaveDirectoryName=W})
    local world=obj(1,{GameState=state,GetFullName=function()return 'World fixture' end})
    local level=obj(9,{OwningWorld=world});state.GetLevel=function()return level end
    local ps=obj(7,{GuildBelongTo=guild,GetLevel=function()return level end})
    local pc=obj(6,{Role=3,PlayerState=ps,GetLevel=function()return level end})
    local manager=obj(12,{AutoSaveWorldDefaultName='',bIsLoadedWorldSaveData=true})
    local inst=obj(2,{LocalPlayers={obj(5,{PlayerController=pc})},SaveGameManager=manager,
        SelectedWorldSaveDirectoryName=W})
    manager.GetOuter=function()return inst end;world.OwningGameInstance=inst
    local engine=obj(10,{GameViewport=obj(4,{World=world}),GameInstance=inst})
    f.state,f.world,f.guild=state,world,guild
    local parameter=obj(99,{IndividualId=id,GetGroupId=function()return guild.Id end})
    parameter.GetWorkSuitabilityRankWithCharacterRank=function(_,value)return value<=2 and 1 or 0 end
    local handle=obj(102,{GetIndividualID=function()return id end,TryGetIndividualParameter=function()return parameter end})
    local camp=obj(103,{GetId=function()return {A=1,B=2,C=3,D=4}end,
        GetGroupIdBelongTo=function()return guild.Id end,
        WorkerDirector=obj(104,{CharacterContainer=obj(105,{SlotArray={obj(106,
            {IsEmpty=function()return false end,Handle=handle})}})})})
    FindAllOf=function(name)f.discovery=f.discovery+1;assert(name=='PalBaseCampModel','global parameter scan forbidden');return {camp}end
    local utility=obj(100,{GetIndividualCharacterParameterByIstanceID=function(_,w,native_id)
        assert(w==world and native_id==id and type(native_id)=='userdata');f.lookups=f.lookups+1
        if f.foreign then return nil end;return parameter
    end})
    package.loaded.UEHelpers={GetEngine=function()f.discovery=f.discovery+1;return f.ready and engine or nil end,GetGameplayStatics=function(force)
        assert(force==true,'proof CDO lookup must remain forced')
        f.forced_lookups=(f.forced_lookups or 0)+1
        if f.cdo_fault then error(f.cdo_fault)end
        f.discovery=f.discovery+1
        if f.on_cdo_resolve then f.on_cdo_resolve()end
        local cdo=obj(101,{GetGameState=function(_,i)
            assert(i==inst);f.state_reads=(f.state_reads or 0)+1
            if f.on_state_read then f.on_state_read()end
            return state
        end,GetGameInstance=function(_,s)assert(s==state);return inst end})
        cdo.IsValid=function()return not f.invalid_cdo end
        return cdo
    end}
    local palapi=require('palapi')
    palapi.cdo=function(name)f.discovery=f.discovery+1;assert(name=='/Script/Pal.Default__PalUtility');return utility end
    for _,name in ipairs(hooknames)do _G[name]=function(cb)f.hooks[name]=cb end end
    ExecuteInGameThreadWithDelay=function(delay,cb)
        if delay==1 and f.reject_cleanup_schedule then return false end
        f.delays[cb]=delay;f.scheduled[#f.scheduled+1]=cb;return true
    end
    local Wire=real_dofile(ROOT..'save_native_backend.lua')
    local Codec=real_dofile(ROOT..'save_settings_codec.lua')
    local function status(n)
        return {n.scope,n.incarnation,n.epoch,tostring(n.accepted),tostring(n.committed),n.phase,'none',
            tostring(n.generation),'0',n.terminal,n.certain,n.terr,tostring(n.ticket),tostring(n.command),
            tostring(n.revision),n.outcome}
    end
    local function missing(n)
        return (fault=='limits_missing' and n.stream=='limits')
            or (fault=='priority_missing' and n.stream=='priorities')
    end
    function f.native(cmd,handle,ticket,hex,length)
        assert(#hex==length and not hex:find('[^0-9a-f]'))
        local raw=hex:gsub('..',function(s)return string.char(tonumber(s,16))end)
        local fields=Wire.unpack(raw,cmd==1 and 5 or (cmd==4 or cmd==5)and 1 or 0)
        f.calls[#f.calls+1]={cmd=cmd,handle=handle,ticket=ticket}
        if cmd==0 then assert(gate.blocked());return 1,Wire.pack({'1'}),10,20,21,1000 end
        if cmd==1 then
            assert(gate.blocked() and f.registered.limits and f.registered.priorities,
                'both original placeholders must precede first bind')
            assert(f.lifecycle:status().attached,'lifecycle must retain combined owner before native creation')
            local stream=fields[3];assert(stream=='limits' or stream=='priorities')
            assert(not f.owners[stream],'no native rebind')
            local n={stream=stream,scope='PWP-SCOPE-1:'..W..':'..G..':'..stream,incarnation=fields[4],epoch=fields[5],
                phase='dormant',accepted=0,committed=0,generation=0,ticket=0,command=0,revision=0,
                terminal='',certain='',terr='',outcome='none',handle=stream=='limits' and 1 or 2,drains=0}
            n.codec=Codec.new{storage=W,guild=G,stream=stream}
            n.payload=assert(n.codec.encode(stream=='limits' and
                assert(caps.serialize_snapshot({[G]={Mining={Stone=100}}}))or files['priorities.txt']))
            f.owners[stream]=n
            if fault=='bind_lost' and stream=='priorities'then error('lost binding reply')end
            if fault=='duplicate_handle' and stream=='priorities'then return 1,Wire.pack({'1'}),10,20,21,1000 end
            return 1,Wire.pack({tostring(n.handle)}),10,20,21,1000
        end
        local n=f.owners[handle==1 and 'limits' or 'priorities'];assert(n and n.handle==handle)
        if f.closing and (cmd==7 or cmd==8)then
            for _,proof in ipairs(f.all_proofs)do assert(proof.status().state=='revoked',
                'all registered proofs must be revoked before original-owner cleanup')end
        end
        if f.on_shutdown and (cmd==7 or cmd==8) then f.on_shutdown(cmd,n) end
        local data,code='',1
        if cmd==6 then
            if n.phase=='recovering' and (n.stream=='limits' or not f.hold)then
                n.phase='awaiting_validation';n.terminal='recovered';n.certain='1';n.terr='0'
                n.generation=missing(n)and 0 or 7
            end
            if n.initial and n.accepted>n.committed then
                n.committed=n.accepted;n.generation=1;n.terminal='initialized';n.certain='1';n.terr='0';n.initial=false
            end
            data=Wire.pack(status(n))
        elseif cmd==3 then
            if n.phase=='recovering'then code=2
            else
                local absent=missing(n)
                data=Wire.pack({n.scope,n.incarnation,n.epoch,'recovered','1',tostring(n.generation),'0','pair-1','0','0',
                    absent and 'missing'or'valid',absent and '0'or'6',absent and ''or n.payload,
                    absent and 'missing'or'valid',absent and '0'or'7',absent and ''or n.payload})
            end
            if fault=='recovery_lost' and n.stream=='priorities'then error('lost recovery reply')end
        elseif cmd==9 then assert(n.phase=='closed');n.cleaned=true
        else
            assert(ticket>n.ticket,'mutation ticket replay');n.ticket,n.command,n.revision,n.outcome=ticket,cmd,0,'accepted'
            if cmd==2 then
                assert(n.phase=='dormant');n.phase='recovering'
                if fault=='open_lost' and n.stream=='priorities'then error('lost open reply')end
            elseif cmd==4 then
                assert(n.phase=='awaiting_validation' and fields[1]==(missing(n)and'initialize_missing'or'existing'))
                assert(not missing(n)or n.stream=='priorities','limits initialization forbidden')
                n.initial=missing(n);n.phase='ready'
            elseif cmd==5 then
                assert(n.phase=='ready' and n.codec.decode(fields[1]));n.accepted=n.accepted+1
                n.revision=n.accepted;n.payload=fields[1];data=Wire.pack({tostring(n.accepted)})
            elseif cmd==7 then n.phase='closing';n.retired=true
            elseif cmd==8 then
                n.drains=n.drains+1;assert(n.drains==1,'lost drain replay')
                n.phase='closed'
                if n.accepted>n.committed then n.generation=n.generation+1;n.terminal='updated';n.certain='1';n.terr='0' end
                n.committed=n.accepted
                data=Wire.pack(status(n))
                if fault=='drain_lost' and n.stream=='limits'then error('lost drain reply')end
            else error('unsupported fixture native command '..cmd)end
        end
        return code,data,10,20,21,1000
    end
    package.loadlib=function(path,symbol)
        assert(path=='fixture-only.dll' and symbol=='luaopen_pwp_draining_bridge')
        return f.native
    end
    -- Instrument real constructors/methods, never replace behavior with success.
    dofile=function(path)
        local mod=real_dofile(path);local name=path:gsub('\\','/'):match('([^/]+)$')
        f.loads[name]=(f.loads[name]or 0)+1
        if name=='settings_combined_owner.lua'then
            local new=mod.new;mod.new=function(o)
                local c=assert(new(o));f.combined=c;local register=c.register
                c.register=function(self,stream,owner,proofs)
                    local yes=register(self,stream,owner,proofs)
                    if yes then
                        f.registered[stream]=true;f.all_proofs=f.all_proofs or {}
                        for _,p in ipairs(proofs)do f.all_proofs[#f.all_proofs+1]=p end
                    end;return yes
                end;return c
            end
        elseif name=='settings_startup_lifecycle.lua'then
            local new=mod.new;mod.new=function(o)local life=new(o);f.lifecycle=life;return life end
        elseif name=='settings_startup.lua'then
            local new=mod.new;mod.new=function(o)
                assert(o.stream=='limits' or o.stream=='priorities','explicit startup stream')
                assert(o.camp=='local-combined-trial' and o.epoch==1 and o.gate)
                if o.stream=='limits'then assert(o.migration_body==nil and o.verify_migration==nil,
                    'limits must recover existing journal, never initialize')end
                local s=new(o);f.startups[o.stream]=s;return s
            end
        elseif name=='settings_migration_guard.lua'then
            local new=mod.new;mod.new=function(o)
                assert(o.stream=='priorities','only priorities may migrate')
                return new(o)
            end
        elseif name=='settings_startup_authority.lua'then
            local new=mod.new;mod.new=function(o)local p=new(o);f.proofs[o.context.stream]=p
                f.proof_contexts[o.context.stream]=o.context;return p end
        elseif name=='save_draining_backend.lua'then
            local new=mod.new;mod.new=function(o)
                local b=new(o)
                if fault=='backend_constructor' and o.stream=='priorities'then error('lost constructor return')end
                return b
            end
        end
        return mod
    end
    for stream,module in pairs({limits=caps,priorities=store})do
        local activate=module.activate_recovered
        module.activate_recovered=function(o)
            assert(gate.blocked(),'no activation outside shared barrier')
            f.activations[stream]=(f.activations[stream]or 0)+1
            local yes,why=activate(o)
            if fault=='activate_lost' and stream=='priorities'then assert(yes);error('lost activation reply')end
            return yes,why
        end
    end
    local live=real_dofile(ROOT..'settings_live_combined.lua')
    assert(not live.install() and not live.install{} and not live.install{enabled='true'})
    assert(not gate.blocked() and #f.calls==0 and #f.scheduled==0,'disabled install must be inert')
    f.runtime=assert(live.install(f.options))
    function f:step(delay)
        local index=1
        if delay then
            index=nil
            for i,cb in ipairs(self.scheduled)do if self.delays[cb]==delay then index=i;break end end
            assert(index,'missing scheduled callback for delay '..delay)
        end
        local cb=table.remove(self.scheduled,index);assert(cb,'missing scheduled poll')
        self.delays[cb]=nil;cb()
    end
    function f:init()self.hooks.RegisterInitGameStatePreHook();self.hooks.RegisterInitGameStatePostHook();self.ready=true end
    function f:pump(predicate)
        for _=1,16 do if predicate()then return end;self:step()end
        assert(predicate(),'bounded launcher progress failed: '..table.concat(self.events,'\n'))
    end
    function f:close()
        self.closing=true
        self.runtime.transition();local n=#self.calls;self.runtime.transition()
        self.hooks.RegisterEndPlayPreHook(nil,{get=function()return 4 end})
        assert(#self.calls==n,'duplicate cleanup native call')
    end
    return f
end
local function run(fault,body)
    local f
    local ok,err=xpcall(function()f=fixture(fault);body(f)end,debug.traceback)
    if f then f.dispose()end
    dofile,package.loadlib,io.open=real_dofile,real_loadlib,real_open
    os.time=real_time
    assert(ok,err)
end
local function client(f)
    f.state.Role=1
    f.store.set_role('client',f.session.epoch);f.caps.set_role('client',f.session.epoch)
    f.requests=0
    local function submit()f.requests=f.requests+1;return true end
    f.store.submit,f.caps.submit=submit,submit
end
for _,route in ipairs({'transition','quit'})do
    run(nil,function(f)
        f.runtime.transition() -- initial spawn must still allow first admission/opt-out
        assert(not f.runtime.status().stopped)
        client(f)
        local operations=#f.fs.operations
        local p,c=f.store.serialize(),f.caps.serialize()
        local late=f.scheduled[1]
        if route=='quit'then f.now=1601 end -- positive client is checked before authority timeout
        f:step()
        local s=f.runtime.status()
        assert(s.client_opted_out and s.stopped and not s.active and not s.attempted,
            'fresh client must terminally opt out instead of waiting for authority')
        assert(not f.gate.blocked() and s.gate.terminal and not s.gate.committed)
        assert(not f.lifecycle:status().admitted and not s.owner.owner_retained)
        assert(f.store.set(KEY,1,4) and f.caps.set('Mining','Stone',123,ALIAS))
        assert(f.store.clear(KEY,1) and f.caps.clear('Mining','Stone',ALIAS))
        assert(f.requests==4)
        assert(not f.store.apply_set(KEY,1,5) and not f.caps.apply_set('Mining','Stone',999,ALIAS))
        assert(not f.store.save() and not f.caps.save())
        f.now=1601;late()
        assert(#f.scheduled==0 and not f.gate.blocked(),'opt-out must not time out or reschedule')
        if route=='transition'then f.runtime.transition()
        else f.hooks.RegisterEndPlayPreHook(nil,{get=function()return 4 end})end
        assert(f.session.epoch==1 and f.store.is_client and f.caps.is_client)
        assert(f.gate.status()=='restart_required','transition must refence before role reset')
        assert(not f.store.set(KEY,1,4) and not f.caps.set('Mining','Stone',123,ALIAS))
        assert(f.session.begin('World fixture')==2)
        f.store.set_role(nil,2);f.caps.set_role(nil,2)
        f.store.set_role('authority',2);f.caps.set_role('authority',2);f.state.Role=3
        f.hooks.RegisterLoadMapPostHook();f:init();late();f.runtime.transition()
        assert(not f.store.apply_set(KEY,1,5) and not f.caps.apply_set('Mining','Stone',999,ALIAS))
        assert(not f.store.save() and not f.caps.save())
        assert(#f.calls==0 and next(f.activations)==nil and next(f.registered)==nil)
        assert(#f.fs.operations==operations and f.store.serialize()==p and f.caps.serialize()==c)
        assert(f.requests==4 and not f.runtime.status().attempted and #f.scheduled==0)
        client(f);late()
        assert(not f.store.set(KEY,1,4) and not f.caps.set('Mining','Stone',123,ALIAS))
        assert(f.requests==0 and f.gate.status()=='restart_required' and #f.calls==0)
    end)
end
for _,mode in ipairs({'unknown','authority','mixed','stale_caps','stale_store','zero_epoch',
    'undecided_caps','undecided_store','missing_caps_submit','missing_store_submit','invalid_submit'})do
    run(nil,function(f)
        client(f)
        if mode=='unknown'then f.store.set_role(nil,1);f.caps.set_role(nil,1)
        elseif mode=='authority'then f.store.set_role('authority',1);f.caps.set_role('authority',1)
        elseif mode=='mixed'then f.caps.set_role('authority',1)
        elseif mode=='stale_caps'then f.caps.session=0
        elseif mode=='stale_store'then f.store.session=0
        elseif mode=='zero_epoch'then f.session.epoch=0;f.store.session=0;f.caps.session=0
        elseif mode=='undecided_caps'then f.caps.decided=false
        elseif mode=='undecided_store'then f.store.decided=false
        elseif mode=='missing_caps_submit'then f.caps.submit=nil
        elseif mode=='missing_store_submit'then f.store.submit=nil
        elseif mode=='invalid_submit'then f.caps.submit=true end
        f:step();assert(f.gate.blocked() and not f.runtime.status().stopped,mode)
        f.now=1600;f:step();assert(not f.runtime.status().stopped,mode)
        f.now=1601;f:step()
        assert(f.runtime.status().stopped and f.gate.status()=='restart_required',mode)
        assert(table.concat(f.events,'\n'):find('world readiness timed out',1,true),mode)
        client(f)
        assert(not f.store.set(KEY,1,4) and not f.caps.set('Mining','Stone',123,ALIAS))
        assert(#f.calls==0 and not f.runtime.status().client_opted_out)
    end)
end
run(nil,function(f)
    -- Admission itself disqualifies opt-out, even before child creation.
    f:init();assert(f.lifecycle:admit(function()return true end))
    client(f);f:step()
    assert(f.gate.blocked() and not f.runtime.status().client_opted_out)
    f.now=1601;f:step()
    assert(f.gate.status()=='restart_required' and #f.calls==0)
end)
run(nil,function(f)
    assert(f.gate.blocked() and not f.runtime.status().active and #f.calls==0)
    f:step();assert(#f.calls==0,'native creation before complete lifecycle readiness')
    f:init();f:pump(function()return f.startups.limits and f.startups.limits:status().state=='active'end)
    assert(f.startups.priorities:status().state~='active' and f.gate.blocked() and not f.runtime.status().active)
    local before=f.store.serialize();assert(not f.store.apply_set(KEY,1,4));assert(f.store.serialize()==before)
    assert(not f.caps.apply_set('Mining','Stone',101,ALIAS))
    f.hold=false;f:pump(function()return f.runtime.status().active end)
    assert(not f.gate.blocked() and f.activations.limits==1 and f.activations.priorities==1 and f.lookups>0)
    for _,name in ipairs({'settings_startup_gate_group.lua','settings_combined_owner.lua','settings_startup.lua',
        'settings_startup_lifecycle.lua','settings_startup_authority.lua','settings_startup_files.lua',
        'settings_migration_guard.lua','save_draining_backend.lua','save_native_backend.lua',
        'settings_dormant_cleanup.lua','settings_priority_live_reader.lua'})do assert(f.loads[name],name)end
    local yes,why=f.store.apply_set(KEY,1,4);assert(not yes and why=='pending')
    yes,why=f.caps.apply_set('Mining','Stone',101,ALIAS);assert(not yes and why=='pending',why)
    assert(f.owners.limits.accepted>0 and f.owners.priorities.accepted>0)
    f:close();assert(f.gate.blocked() and f.runtime.status().stopped)
    assert(f.owners.limits.drains==1 and f.owners.priorities.drains==1)
    assert(f.combined:status().cleanup_verified and not f.combined:status().owner_retained)
    assert(f.fs.files['caps.txt']==f.options.receipt.files['caps.txt']
        and f.fs.files['priorities.txt']==f.options.receipt.files['priorities.txt'],'legacy files must stay unchanged')
end)
for _,fault in ipairs({'bind_lost','duplicate_handle','backend_constructor','limits_missing','open_lost','recovery_lost','activate_lost','drain_lost'})do
    run(fault,function(f)
        f.hold=false;f:init()
        f:pump(function()return f.runtime.status().stopped or f.runtime.status().active end)
        if fault=='drain_lost'then assert(f.runtime.status().active);f:close()end
        assert(f.runtime.status().stopped and not f.runtime.status().active and f.gate.blocked(),fault)
        client(f)
        while #f.scheduled>0 do f:step()end
        assert(not f.runtime.status().client_opted_out and f.gate.status()=='restart_required',fault)
        assert(f.combined:status().children.limits.drain_attempted and f.combined:status().children.priorities.drain_attempted)
        assert(f.owners.limits.drains==1,'other child must drain after partial failure')
        if fault~='bind_lost' and fault~='duplicate_handle'then assert(f.owners.priorities.drains==1)end
        if fault=='bind_lost' or fault=='duplicate_handle' or fault=='drain_lost'then assert(f.combined:status().owner_retained)end
        local before=f.store.serialize();assert(not f.store.apply_set(KEY,1,4));assert(f.store.serialize()==before)
        f:close()
    end)
end
-- Actual registered travel callback, with both native endpoints deliberately
-- pending. This is a wire fixture; real worker blocking is tested natively.
for _,fault in ipairs({'travel_pending','drain_lost'})do
    run(fault,function(f)
        f.hold=false;f:init();f:pump(function()return f.runtime.status().active end)
        for _,v in ipairs({4,5})do
            local yes,why=f.store.apply_set(KEY,1,v);assert(not yes and why=='pending')
            yes,why=f.caps.apply_set('Mining','Stone',100+v,ALIAS);assert(not yes and why=='pending')
        end
        local yes,why=f.store.apply_set(KEY,1,false);assert(not yes and why=='pending')
        local expected={}
        for name,n in pairs(f.owners)do
            assert(n.accepted>n.committed and n.committed==0,'test did not establish pending writes')
            expected[name]={owner=n,payload=n.payload,accepted=n.accepted}
        end
        local decoded=f.owners.priorities.codec.decode(expected.priorities.payload)
        assert(decoded.data[KEY][1]==false,'latest pending X lost before transition')
        local before_p,before_c=f.store.serialize(),f.caps.serialize()
        local calls,lookups,discovery=#f.calls,f.lookups,f.discovery
        -- World is already unavailable: cleanup must use retained original
        -- owners, never discover a new world or reauthorize against it.
        f.ready=false;f.foreign=true;package.loaded.session.epoch=2;f.closing=true
        f.on_shutdown=function(cmd,n)
            assert(f.gate.blocked() and f.gate.status()=='restart_required')
            assert(f.runtime.status().owner.owner_retained,'owner released before drain returns')
            assert(n==expected[n.stream].owner)
            if cmd==8 then
                assert(f.owners.limits.retired and f.owners.priorities.retired,
                    'both streams must retire before either drain begins')
            end
            local ok,reason=f.store.apply_set(KEY,1,1)
            assert(not ok and reason=='settings_recovering')
            ok,reason=f.caps.apply_set('Mining','Stone',999,ALIAS)
            assert(not ok and reason=='settings_recovering')
        end
        f.hooks.RegisterLoadMapPreHook()
        assert(f.lookups==lookups,'cleanup rediscovered dying-world objects')
        assert(f.discovery==discovery,'cleanup attempted engine discovery even if failure was swallowed')
        assert(f.runtime.status().stopped and not f.runtime.status().active)
        assert(f.store.serialize()==before_p and f.caps.serialize()==before_c)
        for name,n in pairs(f.owners)do
            assert(n.drains==1 and n.accepted==expected[name].accepted)
            assert(n.committed==n.accepted and n.payload==expected[name].payload)
        end
        local status=f.combined:status()
        if fault=='drain_lost'then
            assert(status.owner_retained and not status.cleanup_verified,
                'lost reply must not turn fixture publication into verified cleanup')
            assert(status.children.limits.owner_retained and status.children.priorities.owner_retained,
                'lost reply must retain both original stream owners')
        else assert(status.cleanup_verified and not status.owner_retained)end
        local done=#f.calls;assert(done>calls)
        f.hooks.RegisterLoadMapPostHook();f:init()
        while #f.scheduled>0 do f:step()end
        f:close();assert(#f.calls==done,'travel/late polls replayed or replaced original writers')
        assert(f.fs.files['caps.txt']==f.options.receipt.files['caps.txt'])
        assert(f.fs.files['priorities.txt']==f.options.receipt.files['priorities.txt'])
    end)
end

-- Offline composition regression: real Session and actual launcher/modules,
-- with native/engine boundaries faked. Drive main's transition ordering here;
-- this does not execute main.lua's ClientRestart callback or a network handshake.
for _,fault in ipairs({'role_roundtrip','drain_lost'})do
    run(fault,function(f)
        f.hold=false;f:init();f:pump(function()return f.runtime.status().active end)
        local session=f.session
        local legacy={};for path,bytes in pairs(f.fs.files)do legacy[path]=bytes end
        local operations=#f.fs.operations
        local yes,why=f.store.apply_set(KEY,1,false);assert(not yes and why=='pending')
        yes,why=f.caps.apply_set('Mining','Stone',321,ALIAS);assert(not yes and why=='pending')
        local originals={}
        for name,n in pairs(f.owners)do
            assert(n.accepted>n.committed)
            originals[name]={owner=n,accepted=n.accepted,payload=n.payload}
        end
        local stale=0
        assert(session.enqueue(function()stale=stale+1;f.store.apply_set(KEY,1,5)end,true))
        local old_guard=session.guard(function()stale=stale+1;f.caps.save()end)
        f.closing=true
        f.on_shutdown=function(cmd,n)
            assert(session.epoch==1 and f.store.session==1 and f.caps.session==1,
                'original-owner cleanup must precede main session/role reset')
            assert(f.gate.status()=='restart_required' and n==originals[n.stream].owner)
            if cmd==8 then assert(f.owners.limits.retired and f.owners.priorities.retired)end
        end
        f.runtime.transition()
        for _,proof in ipairs(f.all_proofs)do assert(proof.status().state=='revoked')end
        local done=#f.calls
        local local_p,local_c=f.store.serialize(),f.caps.serialize()
        local function unchanged()
            assert(f.gate.status()=='restart_required' and not f.runtime.status().active)
            assert(f.store.serialize()==local_p and f.caps.serialize()==local_c)
            assert(#f.calls==done,'terminal role change issued native work')
            assert(#f.fs.operations==operations,'terminal role change attempted legacy IO')
            for path,bytes in pairs(legacy)do assert(f.fs.files[path]==bytes)end
            for path,bytes in pairs(f.fs.files)do assert(legacy[path]==bytes)end
            for name,n in pairs(f.owners)do
                local old=originals[name]
                assert(n==old.owner and n.drains==1 and n.accepted==old.accepted
                    and n.committed==old.accepted and n.payload==old.payload)
                assert(f.activations[name]==1,'terminal launcher reactivated a stream')
            end
            local status=f.combined:status()
            assert(status.cleanup_verified==(fault~='drain_lost'))
            assert(status.owner_retained==(fault=='drain_lost'))
            for _,child in pairs(status.children)do
                assert(child.owner_retained==(fault=='drain_lost'))
            end
        end
        local function invalidate(epoch)
            assert(session.begin('World fixture')==epoch,'same map must still advance epoch')
            f.store.set_role(nil,epoch);f.caps.set_role(nil,epoch)
            assert(not f.store.decided and not f.caps.decided)
            session.drain(error);old_guard();assert(stale==0,'stale session action survived')
            assert(not f.store.set(KEY,1,3) and not f.caps.set('Mining','Stone',999,ALIAS))
            unchanged()
        end
        invalidate(2)
        f.state.Role=1
        f.store.set_role('client',2);f.caps.set_role('client',2)
        assert(f.store.is_client and f.caps.is_client)
        local requests=0
        f.store.submit=function()requests=requests+1;return true end
        f.caps.submit=function()requests=requests+1;return true end
        assert(f.caps.replace_all({{work='Mining',item='Stone',amount=777}},2,'remote-guild')==1)
        assert(f.caps.remote['remote-guild'].Mining.Stone==777 and f.caps.data['remote-guild']==nil)
        assert(not f.caps.replace_all({},1,'remote-guild'))
        assert(not f.store.set(KEY,1,4) and not f.caps.set('Mining','Stone',888,'remote-guild'))
        assert(not f.store.save() and not f.caps.save() and requests==0)
        unchanged()
        assert(session.enqueue(function()stale=stale+1 end,false))
        old_guard=session.guard(function()stale=stale+1 end)
        f.runtime.transition();invalidate(3)
        f.state.Role=3
        f.store.set_role('authority',3);f.caps.set_role('authority',3)
        assert(not f.store.is_client and not f.caps.is_client)
        assert(f.caps.remote==nil and f.caps.remote_scope==nil)
        assert(f.store.submit==nil and f.caps.submit==nil)
        assert(not f.caps.replace_all({},2,'remote-guild'))
        f.hooks.RegisterLoadMapPostHook();f:init()
        while #f.scheduled>0 do f:step()end
        assert(not f.store.apply_set(KEY,1,5) and not f.caps.apply_set('Mining','Stone',999,ALIAS))
        assert(not f.store.save() and not f.caps.save())
        f.store.flush();f.caps.flush();f:close();unchanged()
        assert(session.epoch==3 and session.world=='World fixture' and stale==0)
    end)
end

run('priority_missing',function(f)
    f.hold=false;f:init();f:pump(function()return f.runtime.status().active end)
    assert(f.files_read>=25 and f.lookups>0,'real migration receipt/source/backup/ownership checks required')
    assert(f.owners.priorities.accepted==1 and f.owners.priorities.committed==1)
    assert(f.owners.limits.accepted==0,'limits must never initialize')
    f:close();assert(f.combined:status().cleanup_verified)
end)
for _,mode in ipairs({'foreign','foreign_poll_fallback','epoch'})do
    run(nil,function(f)
        f.hold=false;f:init();f:pump(function()return f.runtime.status().active end)
        local p,l=f.store.serialize(),f.caps.serialize()
        local a,b=f.owners.limits.accepted,f.owners.priorities.accepted
        local lookups=f.lookups
        if mode=='epoch'then package.loaded.session.epoch=2
        else f.foreign=true end
        f.reject_cleanup_schedule=mode=='foreign_poll_fallback'
        assert(not f.store.apply_set(KEY,1,4))
        if mode~='epoch'then assert(f.lookups>lookups,'must perform fresh failing membership read')end
        -- No scheduler step, poll, transition or exit may intervene here.
        assert(f.gate.blocked(),'priority rejection must fence limits synchronously')
        local yes,why=f.caps.apply_set('Mining','Stone',101,ALIAS)
        assert(not yes and why=='settings_recovering','same-stack limits edit must hit the shared fence')
        assert(f.store.serialize()==p and f.caps.serialize()==l)
        assert(f.owners.limits.accepted==a and f.owners.priorities.accepted==b)
        local s=f.runtime.status()
        assert(s.stopped and not s.active and s.owner.owner_retained and not s.owner.drain_attempted)
        for _,stream in ipairs({'limits','priorities'})do
            assert(s.owner.children[stream].owner_retained and f.owners[stream].drains==0,
                'original owners must remain retained until callback unwind')
        end
        -- Exercise the 1ms callback itself, not the already queued poll. When
        -- scheduling is refused, require that existing poll to perform cleanup.
        f.closing=true
        if mode=='foreign_poll_fallback'then f:step()else f:step(1)end
        assert(f.gate.blocked() and f.owners.limits.drains==1 and f.owners.priorities.drains==1)
        local calls=#f.calls
        while #f.scheduled>0 do f:step()end
        f:close()
        assert(#f.calls==calls and f.owners.limits.drains==1 and f.owners.priorities.drains==1,
            'deferred/poll/exit cleanup must not replay either original drain')
        assert(f.store.serialize()==p and f.caps.serialize()==l)
        assert(f.owners.limits.accepted==a and f.owners.priorities.accepted==b)
    end)
end
-- Real readers must not replace a failed scoped CDO or hide a context transition.
for _,mode in ipairs({'invalid_second','throw_second','reentry_resolve','revoke_resolve',
    'world_same_instance','viewport','guild','epoch','loaded'})do
    run(nil,function(f)
        f.hold=false;f:init();f:pump(function()return f.runtime.status().active end)
        local lookups=f.forced_lookups
        local proof=f.proofs.limits
        if mode=='reentry_resolve' or mode=='revoke_resolve'then
            f.on_cdo_resolve=function()
                f.on_cdo_resolve=nil
                if mode=='revoke_resolve'then proof.revoke()
                else
                    local yes,why=proof.authorize(f.proof_contexts.limits,ALIAS)
                    assert(not yes and why=='reentrant');f.reentered=true
                end
            end
        else
            local start=f.state_reads
            f.on_state_read=function()
                if f.state_reads-start~=2 then return end -- final state read of first snapshot
                if mode=='invalid_second'then f.invalid_cdo=true
                elseif mode=='throw_second'then f.on_state_read=function()error('second snapshot getter failure')end
                elseif mode=='world_same_instance'then f.world.GameState={IsValid=function()return true end,GetAddress=function()return 777 end}
                elseif mode=='viewport'then package.loaded.UEHelpers.GetEngine().GameViewport.World=nil
                elseif mode=='guild'then f.guild.Id={A=1,B=2,C=3,D=4}
                elseif mode=='epoch'then f.session.epoch=2
                elseif mode=='loaded'then f.world.OwningGameInstance.SaveGameManager.bIsLoadedWorldSaveData=false end
            end
        end
        f:step(1000)
        assert(f.runtime.status().stopped and f.gate.blocked(),mode)
        assert(f.forced_lookups-lookups==1,'no reacquisition/fallback: '..mode)
        if mode=='reentry_resolve'then assert(f.reentered)end
        f:close()
    end)
end
local count_order
for _,timed in ipairs({false,true})do
    run(nil,function(f)
        f.hold=false;f:init();f:pump(function()return f.runtime.status().active end)
        f.profiler:set_enabled(timed);f.profiler:reset()
        f.profile_events={};f.profile_order={}
        local clocks,lookups=f.profile_clock_calls,f.forced_lookups
        local calls=#f.calls
        f:step(1000)
        assert(f.runtime.status().active and not f.gate.blocked())
        local expected={['async: combined poll']=1,['async: startup poll limits']=1,
            ['async: startup poll priorities']=1,['async: proof limits']=17,
            ['async: proof priorities']=17,['async: forced GameplayStatics']=34,['async: Pair.read']=68}
        local labels=0
        for name,b in pairs(f.profiler.marks)do
            labels=labels+1;assert(b.n==expected[name],name..' count '..b.n)
            assert(b.timed_n==(timed and b.n or 0),name..' timing mode')
        end
        assert(labels==7 and f.forced_lookups-lookups==34,'one CDO per proof, no snapshot deduplication')
        assert(#f.calls==calls+2,'one native status per stream')
        local order=table.concat(f.profile_order,'\n')
        if timed then
            assert(order==count_order,'profiling mode changed operation order')
            local outer=f.profile_events[#f.profile_events]
            assert(outer.name=='async: combined poll')
            for _,event in ipairs(f.profile_events)do
                assert(event.first>=outer.first and event.last<=outer.last,'inclusive whole poll envelope')
            end
            assert(f.profile_clock_calls>clocks)
        else
            count_order=order
            assert(f.profile_clock_calls==clocks and #f.profile_events==0,'count-only must not read timing clock')
        end
        -- The separate maintenance route also runs all proofs while saved.
        f.profiler:reset();lookups=f.forced_lookups
        assert(f.store.flush());assert(f.caps.flush())
        assert(f.forced_lookups-lookups==34)
        assert(not f.profiler.marks['async: combined poll'] and not f.profiler.marks['async: startup poll limits'])
        assert(f.profiler.marks['async: proof limits'].n==17 and f.profiler.marks['async: proof priorities'].n==17)
        f:close()
    end)
    run(nil,function(f)
        f.hold=false;f:init();f:pump(function()return f.runtime.status().active end)
        f.profiler:set_enabled(timed);f.profiler:reset();f.profile_events={}
        f.cdo_fault='forced lookup fixture failure'
        f:step(1000)
        assert(f.runtime.status().stopped and not f.runtime.status().active and f.gate.blocked())
        assert(f.profiler.marks['async: forced GameplayStatics'].n==1)
        assert(not f.profiler.marks['async: Pair.read'],'failed CDO cannot reach Pair.read')
        assert(not f.profiler.marks['async: startup poll priorities'],'failure must retain stream short circuit')
        assert(f.profiler.marks['async: combined poll'].timed_n==(timed and 1 or 0))
        if timed then assert(f.profile_events[#f.profile_events].name=='async: combined poll')end
        f:close()
    end)
end
print('combined live: real two-stream barrier, recovery/writers, epoch fencing and bounded inclusive profiling')
