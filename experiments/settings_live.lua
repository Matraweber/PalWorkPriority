-- Checked local trial, loaded explicitly by main in the PRODUCTION Lua state.
-- Not a public opt-in/config feature. Installer pins receipt, sources, DLL/root.
-- One world per process: transitions drain, then retain a fence until restart.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/settings_live.lua$'))
local Gate=require('settings_gate')
local Caps=require('caps')
local Store=require('store')
local Session=require('session')
local Log=require('log')
local M={}
function M.install(o)
    assert(type(o)=='table' and o.enabled==true,'checked trial only')
    local boot_gate=assert(Gate.acquire()) -- before any deferred callbacks/legacy edits
    local Startup=dofile(root..'/settings_startup.lua')
    local Lifecycle=dofile(root..'/settings_startup_lifecycle.lua')
    local Proof=dofile(root..'/settings_startup_authority.lua')
    local Pair=dofile(root..'/save_context_pair_probe.lua')
    local Local=dofile(root..'/save_local_authority.lua')
    local Files=dofile(root..'/settings_startup_files.lua')
    local Migration=dofile(root..'/settings_migration_guard.lua')
    local Backend=dofile(root..'/save_draining_backend.lua')
    local Wire=dofile(root..'/save_native_backend.lua')
    local Dormant=dofile(root..'/settings_dormant_cleanup.lua')
    local receipt=assert(o.receipt)
    local files=assert(Files.new{enabled=true,source_root=receipt.source_root,
        backup_root=receipt.backup_root,manifest=receipt.manifest,files=receipt.files})
    local nonce=assert(o.nonce)
    assert(type(nonce)=='string' and nonce:match('^[%w%-]+$') and #nonce<=64)
    local stopped,attempted,active=false,false,false
    local startup,proof,backend,context,life
    local last_state,owner_handle,binding_attempted,owner_closed,dormant
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
        if not Gate.blocked() then boot_gate=assert(Gate.acquire()) end
    end
    local function report(event)
        if type(event)=='table' and (event.event=='closing' or event.event=='cleanup_complete') then fence() end
        if type(event)=='table' then emit('lifecycle',event) end
        if type(event)=='table' and event.event=='cleanup_complete' and backend then
            local b=backend:inspect()
            local fields={}
            for _,k in ipairs({'phase','generation','committed','accepted','cleaned','joined','state'}) do
                if b[k]~=nil then fields[k]=b[k] end
            end
            emit('native_exit',fields)
        end
    end
    life=assert(Lifecycle.new{enabled=true,report=report})
    assert(life:install(_G),'lifecycle hooks unavailable')
    local function read_pair()
        local h=require('UEHelpers')
        local cdo=h.GetGameplayStatics(true)
        assert(cdo and cdo:IsValid()==true,'GameplayStatics unavailable')
        return Pair.read(h.GetEngine(),function(ctx)return cdo:GetGameState(ctx)end,
            function(ctx)return cdo:GetGameInstance(ctx)end)
    end
    local function read_authority(c)
        return Local.read(require('UEHelpers').GetEngine(),c)
    end
    local function close(reason)
        fence() -- block all subsequent legacy edits even if cleanup loses its reply
        local yes=life:close(reason)
        emit('closed',{reason=reason,drained=yes==true,handle=owner_handle or 0})
        return yes
    end
    local function fail(reason)
        pcall(close,'failure')
        fence()
        pcall(emit,'failed',{reason=tostring(reason):sub(1,1000),owner_retained=binding_attempted==true and not owner_closed,
            ownership_unknown=binding_attempted==true and owner_handle==nil})
    end
    local function try_start()
        if attempted or stopped or not Caps.decided or Caps.is_client or Caps.submit
            or not Store.decided or Store.is_client or Session.epoch<1 then return false end
        -- A cheap not-ready check first. No historic observations grant admission.
        local p=read_pair()
        if p.status~='context_agrees' then return false end
        local a=read_authority(p)
        if a.authority_status~='read' or a.authority~=true then return false end
        assert(p.directory==o.storage and a.guild==o.guild and a.legacy_guild==o.runtime_guild,
            'loaded world/guild differs from checked trial target')
        if not life:admit(function()
            local fresh=read_pair()
            local host=read_authority(fresh)
            return fresh.status=='context_agrees' and fresh.directory==o.storage
                and host.authority_status=='read' and host.authority==true
                and host.guild==o.guild and host.legacy_guild==o.runtime_guild
        end) then return false end
        local observed_epoch=Session.epoch
        context={scope='PWP-SCOPE-1:'..p.directory..':'..a.guild..':limits',storage=p.directory,
            guild=a.guild,stream='limits',epoch=observed_epoch,camp='local-limits-trial',authority=true,
            session=nonce..'-'..observed_epoch,incarnation=nonce..'-'..observed_epoch}
        proof=assert(Proof.new{enabled=true,context=context,runtime_guild=a.legacy_guild,
            get_epoch=function()
                local e=life:epoch()
                return {available=e.available,supported=e.supported,epoch=Session.epoch,token=e.token}
            end,read_evidence=read_pair,read_authority=read_authority})
        assert(proof.authorize(context,o.runtime_guild),'fresh startup authority unavailable')
        attempted=true
        -- Retain original-owner cleanup before crossing native owner creation.
        local owner={}
        function owner:retire()
            if startup then return startup:retire() end
            -- Before queue ownership the binding must remain dormant for the
            -- independent no-activity cleanup proof below.
            return false
        end
        function owner:drain()
            if startup then
                local yes=startup:drain()
                if startup:status().queue_owned then owner_closed=yes==true;return owner_closed end
                if yes~=true then return false end
            end
            owner_closed=dormant~=nil and dormant.drain()==true
            return owner_closed==true
        end
        function owner:status()
            return {state=owner_closed and 'closed' or 'retained',owner_retained=not owner_closed}
        end
        assert(life:attach(owner,proof),'lifecycle attachment refused')
        local migration=assert(Migration.new{enabled=true,files=receipt.files,storage=context.storage,
            guild=context.guild,runtime_guild=o.runtime_guild,read_source=files.read_source,
            read_backup=files.read_backup,verify_receipt=files.verify_receipt,
            fenced=function()return startup and startup:fenced()==true end})
        local native=assert(package.loadlib(o.dll,'luaopen_pwp_draining_bridge'))
        local configured=Wire.call(native,0,0,0,{})
        assert(configured[1]==1 and Wire.unpack(configured[2],1)[1]=='1','native configuration failed')
        local game=configured[3]
        binding_attempted=true -- a lost return is unknown ownership, never absence
        local bound=Wire.call(native,1,1,0,{context.storage,context.guild,'limits',context.incarnation,tostring(context.epoch)})
        assert(bound[1]==1 and bound[3]==game,'native binding refused')
        local id=Wire.unpack(bound[2],1)[1]
        owner_handle=math.tointeger(tonumber(id))
        assert(owner_handle and tostring(owner_handle)==id and owner_handle>=1 and owner_handle<=128,'native binding malformed')
        dormant=Dormant.new{enabled=true,native=native,handle=owner_handle,game_thread=game,
            scope=context.scope,incarnation=context.incarnation,epoch=context.epoch}
        local function authorize()
            return not stopped and proof.authorize(context,o.runtime_guild)==true
                and Caps.decided and not Caps.is_client and Caps.session==observed_epoch
        end
        backend=Backend.new{enabled=true,native=native,binding=owner_handle,game_thread=game,
            storage=context.storage,guild=context.guild,stream='limits',session=context.session,
            incarnation=context.incarnation,epoch=context.epoch,authorize=authorize}
        startup=assert(Startup.new{enabled=true,storage=context.storage,guild=context.guild,
            session=context.session,incarnation=context.incarnation,epoch=context.epoch,camp=context.camp,
            runtime_guild=o.runtime_guild,backend=backend,lease={},clock=os.clock,timeout=120,
            authorize=function(c,alias)return alias==o.runtime_guild and authorize() and proof.authorize(c,alias) end,
            migration_body=migration:body(),verify_migration=function(c,b)return migration:verify(c,b)end,
            activate=Caps.activate_recovered,detach=Caps.retire_persistence,finalize=Caps.finish_retirement})
        assert(Gate.release(boot_gate),'boot gate lost');boot_gate=nil
        assert(startup:start(),'startup refused') -- reacquire without yielding/reentrant callback
        emit('started',{storage=context.storage,guild=context.guild,epoch=context.epoch,handle=owner_handle})
        return true
    end
    local poll
    local deadline=os.time()+600
    poll=function()
        if stopped then return end
        local ok,err=pcall(function()
            if not attempted then
                assert(os.time()<=deadline,'world readiness timed out')
                try_start()
            end
            if startup then
                assert(startup:poll(),'startup/poll refused')
                local s=startup:status()
                if s.state~=last_state then
                    last_state=s.state
                    local b=backend:inspect()
                    emit('state',{state=s.state,initialization=s.initialization_attempted,
                        generation=b.generation or -1,committed=b.committed or -1,limits_state=Caps.state})
                end
                if s.state=='active' and not active then
                    active=true
                    emit('active',{limits=assert(Caps.serialize()):gsub('.',function(c)return string.format('%02x',c:byte())end),
                        priority_bytes=assert(Store.serialize()):len()})
                    Log.say('PWP_ASYNC_READY session='..context.epoch..' role=authority settings=available limits=journal')
                end
            end
            assert(ExecuteInGameThreadWithDelay(active and 1000 or 100,poll)~=false,'poll scheduling refused')
        end)
        if not ok then fail(err) end
    end
    -- Let the normal initial + delayed role setup settle. Lifecycle hooks are
    -- already installed above; no late-attachment identity inference.
    assert(ExecuteInGameThreadWithDelay(30000,poll)~=false,'initial scheduling refused')
    emit('armed',{default_enabled=false,limits_only=true})
    return {
        transition=function()
            -- Initial spawn precedes ownership; subsequent spawns revoke it.
            if attempted then return close('client_restart') end
        end,
        status=function()return {active=active,stopped=stopped,attempted=attempted} end,
    }
end
return M
