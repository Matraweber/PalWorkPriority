-- One-shot LOCAL developer diagnostic, not the scoped production backend.
-- Native IO touches only PWP_SaveLifetime_v4_A/B. Production saves untouched.
-- Ordinary rooted UObject has no world outer; no Unreal wrapper is cached here.
local source=debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
local root=assert(source:match('^(.*)/Scripts/main.lua$'))
local trigger=io.open(root..'/run.txt','r')
if not trigger then return end
local request=trigger:read('*a');trigger:close()
local nonce=request and request:match('^PWP_LIFETIME_V4_RUN ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
-- Consume the arm before scheduling: a later boot cannot replay writes.
local consumed=assert(io.open(root..'/run.txt','w'))
local wrote=consumed:write('DISABLED\n');local closed=consumed:close()
assert(wrote and closed,'could not disarm diagnostic')
assert(type(LoopInGameThreadWithDelay)=='function' and type(CancelDelayedAction)=='function')
local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP lifetime V4 '..nonce..' '..message
    print(line..'\n')
    local f=assert(io.open(root..'/lifetime.log','a'))
    local ok=f:write(line..'\n');local done=f:close();assert(ok and done,'diagnostic log failure')
end
local classpath='/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV4'
local recordpath='/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchRecord'
local path='/Engine/Transient.PWP_SaveLifetimeV4'
-- Observed gameplay world for this local RAM-join trial. A splash-to-login
-- transition alone must not satisfy the requested title-to-server test.
local target_world='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local tag='PWP-LIFETIME-4:'..nonce
local payload=('PWP-LIFETIME-4:'..nonce..':X|'..string.rep('12345X',11000)):sub(1,65536)
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
    assert(text(value.TrialTag)==tag,'different diagnostic owner; refusing adoption')
    return value
end
local function stop(message)
    finished=true
    local cancelled=handle and CancelDelayedAction(handle)==true
    report(message..' timer_cancelled='..tostring(cancelled))
end
local function verify_record(value)
    local record=value.LoadedSave
    assert(valid(record) and record.Generation==101 and text(record.Session)==tag
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
        for _,existing in ipairs(FindAllOf('BP_ScratchBridgeV4_C') or {}) do
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
        local value=StaticConstructObject(cls,outer,FName('PWP_SaveLifetimeV4',EFindName.FNAME_Add),0xC0,0)
        assert(valid(value) and value:HasAnyInternalFlags(0x40000000),'rooted construction failed')
        value.TrialTag=tag
        assert(value:GetFullName():match('^%S+ (.+)$')==path,'unexpected native object path')
        value.WorldContext=current
        local lib=StaticFindObject('/Script/Engine.Default__GameplayStatics');assert(valid(lib))
        local record=lib:CreateSaveGameObject(class(recordpath));assert(valid(record))
        record.Generation=101;record.Session=tag;record.Payload=payload;record.Checksum='synthetic'
        phase='write'
        value:SubmitScratch(record,101,false)
        assert(value.ActiveGeneration==101,'write not admitted')
        if value.Busy==true then
            value:LoadScratch(999,true)
            assert(value.ActiveGeneration==101,'busy guard changed active ticket')
        end
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
            value.WorldContext=world()
            phase='read';value:LoadScratch(102,false)
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
        stop('PASS_WORLD_TRANSITION from='..first_world..' to='..name..'; rooted state and exact record retained')
    end
end
report('ARM_CONSUMED; local synthetic lifetime diagnostic only')
handle=LoopInGameThreadWithDelay(500,function()
    if finished then return end
    local ok,err=pcall(step)
    if not ok then stop('FAIL '..tostring(err)) end
end)
assert(handle,'diagnostic timer registration failed')
