-- One-shot LOCAL developer diagnostic, not the scoped production backend.
-- Native IO uses synthetic world/guild/stream slots. Production saves untouched.
-- Ordinary rooted UObject has no world outer; no Unreal wrapper is cached here.
local source=debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
local root=assert(source:match('^(.*)/Scripts/main.lua$'))
local trigger=io.open(root..'/run.txt','r')
if not trigger then return end
local request=trigger:read('*a');trigger:close()
local nonce=request and request:match('^PWP_SCOPED_V6_RUN ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
-- Consume the arm before scheduling: a later boot cannot replay writes.
local consumed=assert(io.open(root..'/run.txt','w'))
local wrote=consumed:write('DISABLED\n');local closed=consumed:close()
assert(wrote and closed,'could not disarm diagnostic')
assert(type(LoopInGameThreadWithDelay)=='function' and type(CancelDelayedAction)=='function')
local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP scoped V6 '..nonce..' '..message
    print(line..'\n')
    local f=assert(io.open(root..'/scoped.log','a'))
    local ok=f:write(line..'\n');local done=f:close();assert(ok and done,'diagnostic log failure')
end
local classpath='/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV6'
local recordpath='/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchRecord'
local path='/Engine/Transient.PWP_SaveScopedV6'
-- Observed gameplay world for this local RAM-join trial. A splash-to-login
-- transition alone must not satisfy the requested title-to-server test.
local target_world='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local tag='PWP-SCOPED-6:'..nonce
local identity=dofile(root..'/experiments/save_scope.lua').new(string.rep('5',32),string.rep('e',32),'priorities')
local scope=identity.key
local epoch=1
local payload=('PWP-SCOPED-6:'..nonce..':X|'..string.rep('12345X',11000)):sub(1,65536)
local started,handle,finished,phase,first_world=os.time(),nil,false,'initialize',nil
local function valid(x) return x~=nil and x:IsValid() end
local function text(x) return type(x)=='string' and x or x:ToString() end
local function class(asset)
    local registry=StaticFindObject('/Script/AssetRegistry.Default__AssetRegistryHelpers')
    assert(valid(registry),'asset registry unavailable')
    local name=asset:match('([^/]+)$')..'_C'
    local cls=registry:GetAsset({PackageName=FName(asset,EFindName.FNAME_Add),AssetName=FName(name,EFindName.FNAME_Add)})
    assert(valid(cls),'missing diagnostic asset '..asset)
    return cls
end
local function world()
    local engine=require('UEHelpers').GetEngine()
    if not valid(engine) then return end
    local viewport=engine.GameViewport
    if not valid(viewport) then return end
    local current=viewport.World
    if not valid(current) then return end
    return current
end
local function resolve()
    local value=StaticFindObject(path)
    assert(valid(value),'rooted coordinator disappeared; never recreate after unknown IO')
    assert(value:HasAnyInternalFlags(0x40000000),'coordinator lost RootSet')
    assert(text(value.TrialTag)==tag and text(value.BoundOwner)==tag and text(value.BoundScope)==scope
        and value.BoundEpoch==epoch,'different diagnostic owner/epoch; refusing adoption')
    return value
end
local function stop(message)
    finished=true
    local cancelled=handle and CancelDelayedAction(handle)==true
    report(message..' timer_cancelled='..tostring(cancelled))
end
local function verify_record(value)
    local record=value.LoadedSave
    assert(valid(record) and record.Generation==101 and text(record.Session)==scope
        and text(record.Payload)==payload and text(record.Checksum)=='synthetic',
        'native readback mismatch')
end
local function step()
    if finished then return end
    assert(os.time()-started<420,'timeout: unresolved state preserved until process exit')
    if phase=='initialize' then
        local current=world();if not current then return end
        first_world=current:GetFullName()
        -- Run the real queue/session/scoping regression in the actual UE4SS VM.
        -- The transport test's backend is explicitly a fixture, not native IO.
        for _,file in ipairs({'test_save_session.lua','test_save_transport.lua'}) do
            local f=assert(io.open(root..'/tests/'..file,'r'));local code=f:read('*a');f:close()
            local env=setmetatable({TEST_ROOT=root,print=function() end},{__index=_G})
            assert(load(code,'@'..root..'/tests/'..file,'t',env))()
            report('LUA_FIXTURE_PASS '..file..' runtime='.._VERSION)
        end
        local cls=class(classpath)
        for _,existing in ipairs(FindAllOf('BP_ScratchBridgeV6_C') or {}) do
            if valid(existing) and not existing:GetFullName():find('Default__',1,true) then
                error('existing coordinator; no duplicate construction or owner replacement')
            end
        end
        -- The one-string StaticFindObject overload requires an object-qualified
        -- path, not a package-only name. Resolve the engine's current outer and
        -- verify its identity; never silently use a world-owned outer.
        local outer=require('UEHelpers').GetEngine():GetOuter()
        assert(valid(outer) and outer:GetFullName()=='Package /Engine/Transient',
            'transient package unavailable')
        local value=StaticConstructObject(cls,outer,FName('PWP_SaveScopedV6',EFindName.FNAME_Add),0xC0,0)
        assert(valid(value) and value:HasAnyInternalFlags(0x40000000),'rooted construction failed')
        value.TrialTag=tag
        assert(value:GetFullName():match('^%S+ (.+)$')==path,'unexpected native object path')
        assert(value:BindStorage(identity.storage,identity.guild,identity.stream)==true,'storage bind failed')
        assert(text(value.BoundSlotA)==identity.a and text(value.BoundSlotB)==identity.b,'native/Lua slot mismatch')
        assert(value:BindStorage(identity.storage,identity.guild,'limits')==false,'storage replacement allowed')
        assert(value:BindOwner(scope,tag,epoch)==true,'owner bind failed')
        assert(value:BindOwner(scope,tag,epoch+1)==false,'active takeover admitted')
        assert(value:BindOwner(scope,tag,epoch)==true,'same bind not idempotent')
        assert(value:BindOwner(scope,tag..'-other',epoch)==false,'owner replacement allowed')
        assert(value:BindOwner('foreign',tag,epoch)==false,'scope replacement allowed')
        value.WorldContext=current
        local lib=StaticFindObject('/Script/Engine.Default__GameplayStatics');assert(valid(lib))
        local record=lib:CreateSaveGameObject(class(recordpath));assert(valid(record))
        record.Generation=101;record.Session=scope;record.Payload=payload;record.Checksum='synthetic'
        phase='write'
        value:SubmitScratch(record,101,false,scope,tag,epoch)
        assert(value.ActiveGeneration==101,'write not admitted')
        if value.Busy==true then
            value:LoadScratch(999,true,scope,tag,epoch)
            assert(value.ActiveGeneration==101,'busy guard changed active ticket')
        end
        assert(value.Busy==true and value.Done==false,'write completed before pending-retirement observation')
        assert(value:RetireOwner(scope,tag,epoch)==true,'pending retirement failed')
        assert(value:BindOwner(scope,tag,epoch+1)==false,'undrained takeover admitted')
        report('WRITE_ENQUEUED bytes='..#payload..' world='..first_world)
    elseif phase=='write' or phase=='read' then
        local value=resolve()
        if value.Done~=true then return end
        local expected=phase=='write' and 101 or 102
        assert(value.Busy==false and value.Success==true and value.CompletedGeneration==expected,'native operation failed')
        assert(not valid(value.PendingAction),'completed action retained')
        verify_record(value)
        if phase=='write' then
            report('WRITE_READBACK_PASS ticket=101 bytes='..#payload)
            assert(value:BindOwner(scope,tag,epoch+1)==false,'terminal takeover admitted')
            assert(value:ConsumeResult(scope,tag,101,'write',false,epoch+1)==false,'wrong epoch consumed')
            value:LoadScratch(999,true,scope,tag,epoch)
            assert(value.Done==true and value.CompletedGeneration==101 and value.ActiveGeneration==101,'unconsumed result overwritten')
            assert(value:ConsumeResult(scope,tag..'-other',101,'write',false,epoch)==false,'wrong owner consumed')
            assert(value:ConsumeResult('foreign',tag,101,'write',false,epoch)==false,'wrong scope consumed')
            assert(value:ConsumeResult(scope,tag,101,'read',false,epoch)==false,'wrong kind consumed')
            assert(value:ConsumeResult(scope,tag,101,'write',true,epoch)==false,'wrong slot consumed')
            assert(value:ConsumeResult(scope,tag,100,'write',false,epoch)==false,'wrong ticket consumed')
            verify_record(value)
            assert(value:ConsumeResult(scope,tag,101,'write',false,epoch)==true,'consume failed')
            assert(value:ConsumeResult(scope,tag,101,'write',false,epoch)==true,'consume retry failed')
            assert(value.Done==false and not valid(value.LoadedSave),'consumed record retained')
            value:LoadScratch(101,false,scope,tag,epoch)
            assert(value.ActiveGeneration==101 and value.Busy==false and value.Done==false,'ticket replay admitted')
            value:LoadScratch(999,false,scope,tag,epoch)
            assert(value.ActiveGeneration==101 and value.Busy==false,'retired owner admitted')
            assert(value:BindOwner(scope,tag,epoch+1)==true,'drained handover failed')
            epoch=epoch+1
            assert(value:RetireOwner(scope,tag,epoch-1)==false,'stale epoch retired new owner')
            value:LoadScratch(999,false,scope,tag,epoch-1)
            assert(value.ActiveGeneration==101 and value.Busy==false and value.Done==false,'stale epoch request admitted')
            value:LoadScratch(101,false,scope,tag,epoch)
            assert(value.ActiveGeneration==101 and value.Busy==false,'handover reset ticket fence')
            value.WorldContext=world()
            phase='read';value:LoadScratch(102,false,scope,tag,epoch)
            assert(value.ActiveGeneration==102,'read not admitted')
            local was_busy,was_done=value.Busy,value.Done
            local pending=value.PendingAction
            local pending_address=valid(pending) and pending:GetAddress() or nil
            assert(value:ConsumeResult(scope,tag,101,'write',false,epoch-1)==false,'stale epoch ack accepted')
            assert(value.ActiveGeneration==102 and value.Busy==was_busy and value.Done==was_done,
                'previous ack changed new operation')
            if was_busy then
                local after=value.PendingAction
                assert(pending_address and valid(after) and after:GetAddress()==pending_address,'previous ack cleared pending action')
            end
            report('MAILBOX_GUARDS_PASS retained result, exact consume, retry and replay protection')
        else
            phase='travel'
            report('READ_PASS ticket=102; awaiting same-process world transition')
        end
    elseif phase=='travel' then
        -- Plain engine chain, not a UObject-array scan on each wait tick.
        local current=world();if not current then return end
        local name=current:GetFullName();if name==first_world then return end
        if name~=target_world then return end
        local value=resolve();verify_record(value)
        assert(value.CompletedGeneration==102 and value.Busy==false,'state changed across world transition')
        assert(value.Done==true,'unconsumed read result lost on travel')
        assert(value:RetireOwner(scope,tag,epoch)==true,'terminal retirement failed')
        assert(value:BindOwner(scope,tag,epoch+1)==false,'travel result bypassed handover drain')
        assert(value:ConsumeResult(scope,tag,101,'write',false,epoch-1)==false and value.Done==true,'old ack cleared travel result')
        assert(value:ConsumeResult(scope,tag,102,'read',false,epoch)==true,'travel consume failed')
        assert(value:ConsumeResult(scope,tag,102,'read',false,epoch)==true,'travel consume retry failed')
        assert(value.Done==false and not valid(value.LoadedSave),'travel result not released')
        assert(value:BindOwner(scope,tag,epoch+1)==true,'travel handover failed')
        assert(value:RetireOwner(scope,tag,epoch)==false,'old epoch retired final owner')
        assert(value:RetireOwner(scope,tag,epoch+1)==true,'final retirement failed')
        report('SCOPED_HANDOVER_PASS canonical slots, drained ownership, stale epoch and monotonic tickets')
        report('TRAVEL_CONSUME_PASS exact pending mailbox retained across gameplay transition')
        stop('PASS_WORLD_TRANSITION from='..first_world..' to='..name..'; rooted state and exact record retained')
    end
end
report('ARM_CONSUMED; local synthetic scoped handover diagnostic only')
handle=LoopInGameThreadWithDelay(500,function()
    if finished then return end
    local ok,err=pcall(step)
    if not ok then stop('FAIL '..tostring(err)) end
end)
assert(handle,'diagnostic timer registration failed')
