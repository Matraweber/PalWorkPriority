-- Checked local two-stream trial, explicitly loaded in the production Lua VM.
-- Default-off. One world per process; no rearm, legacy fallback or native retry.
-- The installer must preserve and reuse the existing compiled journal root.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/settings_live_combined.lua$'))
local Caps,Store,Session,Log=require('caps'),require('store'),require('session'),require('log')
local M={}
local streams={'limits','priorities'}
local function equal(a,b)
    if type(a)~=type(b)then return false end
    if type(a)~='table'then return a==b end
    if getmetatable(a) or getmetatable(b)then return false end
    for k,v in pairs(a)do if not equal(v,rawget(b,k))then return false end end
    for k in pairs(b)do if rawget(a,k)==nil then return false end end
    return true
end
function M.install(o)
    if type(o)~='table' or o.enabled~=true then return nil,'disabled' end
    local Group=dofile(root..'/settings_startup_gate_group.lua')
    local group=assert(Group.new{enabled=true}) -- held before any deferred work
    local Combined=dofile(root..'/settings_combined_owner.lua')
    local Startup=dofile(root..'/settings_startup.lua')
    local Lifecycle=dofile(root..'/settings_startup_lifecycle.lua')
    local Proof=dofile(root..'/settings_startup_authority.lua')
    local Direct=dofile(root..'/settings_priority_live_reader.lua')
    local Roster=dofile(root..'/settings_priority_roster.lua')
    local Coverage=dofile(root..'/settings_priority_coverage.lua')
    local Pair=dofile(root..'/save_context_pair_probe.lua')
    local Local=dofile(root..'/save_local_authority.lua')
    local Files=dofile(root..'/settings_startup_files.lua')
    local Migration=dofile(root..'/settings_migration_guard.lua')
    local Backend=dofile(root..'/save_draining_backend.lua')
    local Wire=dofile(root..'/save_native_backend.lua')
    local Dormant=dofile(root..'/settings_dormant_cleanup.lua')
    local api,workdefs=require('palapi'),require('workdefs')
    local receipt=assert(o.receipt)
    local files=assert(Files.new{enabled=true,source_root=receipt.source_root,
        backup_root=receipt.backup_root,manifest=receipt.manifest,files=receipt.files})
    local nonce=assert(o.nonce)
    assert(type(nonce)=='string' and nonce:match('^[%w%-]+$') and #nonce<=64)
    -- Capture the installed target, not the mutable caller options table.
    local storage,guild,alias,dll=o.storage,o.guild,o.runtime_guild,o.dll
    local stopped,attempted,active=false,false,false
    local client_opted_out=false
    local children,life={},nil
    local shutdown_reason,cleanup_scheduled
    local function emit(event,fields)
        local parts={'PWP_ASYNC_TRIAL',nonce,event}
        local keys={};for k in pairs(fields or {})do keys[#keys+1]=k end;table.sort(keys)
        for _,k in ipairs(keys)do
            local v=fields[k];assert(type(v)=='string' or type(v)=='number' or type(v)=='boolean')
            parts[#parts+1]=k..'='..tostring(v):gsub('[\r\n\t]',' ')
        end
        Log.say(table.concat(parts,'\t'))
    end
    local function fence()
        stopped,active=true,false
        return group:fence()
    end
    local combined=assert(Combined.new{enabled=true,fence=fence})
    -- Lifecycle's own admission proof is distinct from both stream proofs.
    -- CombinedOwner revokes and checks every child proof before any child retire.
    local revoked=false
    local aggregate_proof={revoke=function()revoked=true;fence();return false end,
        status=function()return {state=revoked and 'revoked' or 'bound'}end}
    local function report(event)
        if type(event)=='table' and (event.event=='closing' or event.event=='cleanup_complete')then fence()end
        if type(event)=='table'then emit('lifecycle',event)end
        if type(event)=='table' and event.event=='cleanup_complete'then
            for _,name in ipairs(streams)do
                local s=children[name]
                if s and s.backend then
                    local b=s.backend:inspect();local fields={stream=name,handle=s.handle or 0}
                    for _,k in ipairs({'phase','generation','committed','accepted','cleaned','joined','state'})do
                        if b[k]~=nil then fields[k]=b[k]end
                    end
                    emit('native_exit',fields)
                end
            end
        end
    end
    life=assert(Lifecycle.new{enabled=true,report=report})
    assert(life:install(_G),'lifecycle hooks unavailable')
    local function running()
        assert(not stopped and not revoked and not life:status().terminal,'lifecycle closed during startup')
    end
    local function read_pair(operation)
        local h=require('UEHelpers')
        -- Fixed labels use the shared bounded profiler: counts without timing by
        -- default, inclusive timing/frame events only when explicitly enabled.
        -- Only the explicit authorization context may share a CDO between its
        -- two ordered snapshots. Standalone reads still resolve every time.
        -- Never retry a failed resolution or reuse observed world/guild results.
        assert(not operation or operation.closed~=true,'evidence operation closed')
        local cdo
        if operation and operation.resolved then cdo=operation.cdo
        else
            if operation then operation.resolved=true end
            cdo=Log.around('async: forced GameplayStatics',h.GetGameplayStatics,true)
            assert(not operation or operation.closed~=true,'evidence operation closed')
            if operation then operation.cdo=cdo end
        end
        local function usable()
            assert(not operation or operation.closed~=true,'evidence operation closed')
            assert(cdo and cdo:IsValid()==true,'GameplayStatics unavailable')
            assert(not operation or operation.closed~=true,'evidence operation closed')
        end
        usable()
        return Log.around('async: Pair.read',Pair.read,h.GetEngine(),function(c)usable();return cdo:GetGameState(c)end,
            function(c)usable();return cdo:GetGameInstance(c)end)
    end
    local function read_authority(c)return Local.read(require('UEHelpers').GetEngine(),c)end
    local function read_context()
        local p=read_pair();assert(p.status=='context_agrees' and p.agrees==true)
        local a=read_authority(p)
        assert(a.authority_status=='read' and a.authority==true and a.guild_status=='format_valid')
        return {storage=p.directory,guild=a.guild,alias=a.legacy_guild,legacy_guild=a.legacy_guild,world=p.world,
            world_address=p.world_address,state_address=p.state_address,instance_address=p.instance_address,
            manager_address=p.manager_address,player_address=a.player_address,controller_address=a.controller_address,
            player_state_address=a.player_state_address,guild_address=a.guild_address}
    end
    local function close(reason)
        fence()
        local yes=life:close(reason)
        emit('closed',{reason=reason,drained=yes==true,streams='limits,priorities'})
        return yes
    end
    local function request_close(reason)
        -- A failed admission in either stream immediately blocks BOTH. Joining
        -- inside an ownership callback would reenter that writer, so defer the
        -- original-owner cleanup until callback unwind. Existing poll/exit hooks
        -- remain fallback cleanup routes if scheduling has an uncertain result.
        shutdown_reason=shutdown_reason or reason
        fence()
        if not cleanup_scheduled then
            cleanup_scheduled=true
            local ok,yes=pcall(ExecuteInGameThreadWithDelay,1,function()close(shutdown_reason)end)
            if not ok or yes==false then pcall(emit,'cleanup_deferred_unavailable',{reason=shutdown_reason})end
        end
        return false
    end
    local function fail(reason)
        pcall(close,'failure');fence()
        local unknown=false
        for _,s in pairs(children)do if s.binding_attempted and not s.handle then unknown=true end end
        pcall(emit,'failed',{reason=type(reason)=='string' and reason:sub(1,1000) or 'callback failure',
            owner_retained=combined:status().owner_retained,ownership_unknown=unknown})
    end
    local function authorize(s,c,a)
        local yes=not stopped and not revoked and a==alias and Session.epoch==s.context.epoch
            and Caps.decided and not Caps.is_client and not Caps.submit and Caps.session==s.context.epoch
            and Store.decided and not Store.is_client and not Store.submit and Store.session==s.context.epoch
            and Log.around('async: proof '..s.context.stream,s.proof.authorize,c,a)==true and not stopped and not revoked
        if yes~=true then return request_close('authority_invalidated')end
        return true
    end
    local function coverage(s,c,recovered)
        if not s.startup:fenced() or not authorize(s,c,alias)then return false end
        local first=Roster.read(api,workdefs,alias)
        local second=Roster.read(api,workdefs,alias)
        if not first.complete or not second.complete or not equal(first,second)then return false end
        local flat={complete=true,pals={}}
        for _,camp in ipairs(first.camps)do
            for _,pal in ipairs(camp.pals)do
                if s.owns_key(pal.key,c)~=true then return false end
                flat.pals[#flat.pals+1]=pal
            end
        end
        return Coverage.check(recovered.settings,flat)==true and authorize(s,c,alias)
            and s.startup:fenced()
    end
    local function try_start()
        if attempted or stopped or not Caps.decided or Caps.is_client or Caps.submit
            or not Store.decided or Store.is_client or Store.submit or Session.epoch<1 then return false end
        local p=read_pair();if p.status~='context_agrees'then return false end
        local a=read_authority(p);if a.authority_status~='read' or a.authority~=true then return false end
        assert(p.directory==storage and a.guild==guild and a.legacy_guild==alias,'unexpected trial world/guild')
        if not life:admit(function()
            local q=read_pair();local h=read_authority(q)
            return q.status=='context_agrees' and q.directory==storage and h.authority_status=='read'
                and h.authority==true and h.guild==guild and h.legacy_guild==alias
        end)then return false end
        running();attempted=true
        local epoch=Session.epoch
        -- Set up BOTH immutable original owners and their proofs before native bind.
        for _,name in ipairs(streams)do
            local s={module=name=='limits' and Caps or Store,closed=false,binding_attempted=false}
            children[name]=s
            s.context={scope='PWP-SCOPE-1:'..storage..':'..guild..':'..name,storage=storage,guild=guild,
                stream=name,epoch=epoch,camp='local-combined-trial',authority=true,
                session=nonce..'-'..epoch,incarnation=nonce..'-'..epoch}
            s.gate=assert(group:child(name))
            s.proof=assert(Proof.new{enabled=true,context=s.context,runtime_guild=alias,operation_context=true,
                get_epoch=function()local e=life:epoch();return {available=e.available,supported=e.supported,
                    epoch=Session.epoch,token=e.token}end,read_evidence=read_pair,read_authority=read_authority})
            assert(authorize(s,s.context,alias),'fresh startup authority unavailable');running()
            local proofs={s.proof}
            if name=='priorities'then
                s.membership=assert(Direct.new{enabled=true,context=s.context,runtime_guild=alias,
                    authorize=function(c,g)return authorize(s,c,g)end,read_context=read_context,
                    get_engine=function()return require('UEHelpers').GetEngine()end,api=api})
                s.owns_key=function(key,c)
                    local ok,yes=pcall(s.membership.owns_key,key,c)
                    if not ok or yes~=true then return request_close('priority_membership_unavailable')end
                    return not stopped
                end
                proofs[#proofs+1]=s.membership
            end
            local owner={}
            function owner:retire()
                if s.startup then return s.startup:retire()end
                return false
            end
            function owner:drain()
                if s.startup then
                    local yes=s.startup:drain()
                    if s.startup:status().queue_owned then s.closed=yes==true;return s.closed end
                    if yes~=true then return false end
                end
                if not s.binding_attempted then s.closed=true
                else s.closed=s.dormant~=nil and s.dormant.drain()==true end
                return s.closed==true
            end
            function owner:status()return {state=s.closed and 'closed' or 'retained',owner_retained=not s.closed}end
            assert(combined:register(name,owner,proofs));running()
        end
        assert(life:attach(combined,aggregate_proof),'combined lifecycle attachment refused');running()
        local native=assert(package.loadlib(dll,'luaopen_pwp_draining_bridge'));running()
        local configured=Wire.call(native,0,0,0,{})
        assert(configured[1]==1 and Wire.unpack(configured[2],1)[1]=='1','native configuration failed');running()
        local game=configured[3]
        for _,name in ipairs(streams)do
            local s=children[name];local c=s.context
            assert(authorize(s,c,alias));running()
            s.binding_attempted=true -- even a lost reply remains owned, never retry
            local bound=Wire.call(native,1,1,0,{storage,guild,name,c.incarnation,tostring(c.epoch)})
            assert(bound[1]==1 and bound[3]==game,'native binding refused')
            local id=Wire.unpack(bound[2],1)[1];local handle=math.tointeger(tonumber(id))
            assert(handle and tostring(handle)==id and handle>=1 and handle<=128,'native binding malformed')
            for other,prior in pairs(children)do
                assert(other==name or prior.handle~=handle,'native binding reused another owner')
            end
            s.handle=handle
            s.dormant=Dormant.new{enabled=true,native=native,handle=s.handle,game_thread=game,
                scope=c.scope,incarnation=c.incarnation,epoch=c.epoch}
            running()
            s.backend=Backend.new{enabled=true,native=native,binding=s.handle,game_thread=game,
                storage=storage,guild=guild,stream=name,session=c.session,incarnation=c.incarnation,epoch=c.epoch,
                authorize=function()return authorize(s,c,alias)end}
            running()
            -- Limits already has an authoritative journal in this checked trial.
            -- Never seed a missing limits journal from its stale legacy file.
            local migration
            if name=='priorities' then
                migration=assert(Migration.new{enabled=true,stream=name,files=receipt.files,
                storage=storage,guild=guild,runtime_guild=alias,read_source=files.read_source,
                read_backup=files.read_backup,verify_receipt=files.verify_receipt,
                owns_key=s.owns_key,
                fenced=function()return s.startup and s.startup:fenced()==true end})
            end
            running()
            s.startup=assert(Startup.new{enabled=true,stream=name,gate=s.gate,storage=storage,guild=guild,
                session=c.session,incarnation=c.incarnation,epoch=c.epoch,camp=c.camp,runtime_guild=alias,
                backend=s.backend,lease={},clock=os.clock,timeout=120,
                authorize=function(ctx,g)return authorize(s,ctx,g)end,
                migration_body=migration and migration:body() or nil,
                verify_migration=migration and function(ctx,b)return migration:verify(ctx,b)end or nil,
                owns_key=s.owns_key,
                verify_coverage=name=='priorities' and function(ctx,r)return coverage(s,ctx,r)end or nil,
                activate=s.module.activate_recovered,detach=s.module.retire_persistence,finalize=s.module.finish_retirement})
            running()
        end
        for _,name in ipairs(streams)do
            local s=children[name];assert(s.startup:start(),'startup refused: '..name);running()
            emit('started',{stream=name,storage=storage,guild=guild,epoch=epoch,handle=s.handle})
        end
        return true
    end
    local function opt_out_client()
        if stopped or attempted or revoked or next(children)~=nil or Session.epoch<1
            or Caps.decided~=true or Caps.is_client~=true or Caps.session~=Session.epoch
            or Store.decided~=true or Store.is_client~=true or Store.session~=Session.epoch
            or type(Caps.submit)~='function' or type(Store.submit)~='function'then return false end
        local l,c=life:status(),combined:status()
        if l.terminal or l.admitted or l.attached or l.owner_retained or c.owner_retained then return false end
        assert(group:opt_out(),'client opt-out refused')
        client_opted_out,stopped=true,true
        emit('client_opted_out',{epoch=Session.epoch})
        return true
    end
    local poll;local deadline=os.time()+600
    local function poll_body()
        if stopped then
            if shutdown_reason then close(shutdown_reason)end
            return
        end
        local ok,err=pcall(function()
            -- A current client needs only network submission. This consumes
            -- the launcher permanently; transition refences before role reset.
            if opt_out_client()then return end
            if not attempted then assert(os.time()<=deadline,'world readiness timed out');try_start()end
            running()
            local both=true
            for _,name in ipairs(streams)do
                local s=children[name]
                if not s or not s.startup then both=false
                else
                    assert(Log.around('async: startup poll '..name,s.startup.poll,s.startup),'startup/poll refused: '..name);running()
                    local state=s.startup:status()
                    both=both and state.state=='active'
                    if state.state~=s.last_state then
                        s.last_state=state.state;local b=s.backend:inspect()
                        emit('state',{stream=name,state=state.state,initialization=state.initialization_attempted,
                            generation=b.generation or -1,committed=b.committed or -1,settings_state=s.module.state})
                    end
                end
            end
            if both and not active then
                assert(group:commit(function(name)
                    local s=children[name]
                    return not stopped and s.startup:status().state=='active' and authorize(s,s.context,alias)
                end),'combined admission refused');running()
                active=true
                emit('active',{streams='limits,priorities',limits_bytes=assert(Caps.serialize()):len(),
                    priority_bytes=assert(Store.serialize()):len()})
                Log.say('PWP_ASYNC_READY session='..Session.epoch..' role=authority settings=available limits=journal priorities=journal')
            end
            running()
            assert(ExecuteInGameThreadWithDelay(active and 1000 or 100,poll)~=false,'poll scheduling refused')
        end)
        if not ok then fail(err)end
    end
    poll=function()return Log.around('async: combined poll',poll_body)end
    assert(ExecuteInGameThreadWithDelay(30000,poll)~=false,'initial scheduling refused')
    emit('armed',{default_enabled=false,limits_only=false,streams='limits,priorities'})
    return {transition=function()if attempted or client_opted_out then return close('client_restart')end end,
        status=function()return {active=active,stopped=stopped,attempted=attempted,client_opted_out=client_opted_out,
            owner=combined:status(),gate=group:status()}end}
end
return M
