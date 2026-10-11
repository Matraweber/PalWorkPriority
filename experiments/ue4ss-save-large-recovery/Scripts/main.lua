-- Isolated fresh-process readback. Never invokes a save/write function.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/Scripts/main.lua$'))
local f=io.open(root..'/run.txt','r');if not f then return end
local request=f:read(180);f:close()
local nonce,written
if request then nonce,written=request:match('^PWP_LARGE_RECOVERY ([%w%-]+) ([%w%-]+)%s*$') end
if not nonce or not written or #nonce>64 or #written>64 or #request>=180 then return end
f=assert(io.open(root..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local scope=dofile(root..'/experiments/save_scope.lua').new(string.rep('8',32),string.rep('e',32),'priorities')
local payload=('PWP-SCOPED-LARGE:'..written..':X|'..string.rep('12345X',44000)):sub(1,262144)
local tag='PWP-LARGE-READ:'..nonce
local path='/Engine/Transient.PWP_SaveLargeRecovery'
local classpath='/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV6'
local handle,finished,phase,samples=nil,false,'initialize',0
local started=os.time()
local function valid(x) return x~=nil and x:IsValid() end
local function text(x) return type(x)=='string' and x or x:ToString() end
local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP large recovery '..nonce..' '..message
    print(line..'\n')
    local file=assert(io.open(root..'/large-recovery.log','a'))
    assert(file:write(line..'\n'));assert(file:close())
end
local function stop(message)
    if finished then return end
    finished=true
    local ok,result=pcall(function() return handle and CancelDelayedAction(handle) end)
    pcall(report,message..' samples='..samples..' timer_cancelled='..tostring(ok and result==true))
end
local function step()
    if finished then return end
    if samples>=240 or os.time()-started>=120 then stop('TIMEOUT read incomplete');return end
    samples=samples+1
    if phase=='initialize' then
        local engine=require('UEHelpers').GetEngine();if not valid(engine) then return end
        local viewport=engine.GameViewport;if not valid(viewport) then return end
        local world=viewport.World;if not valid(world) then return end
        local registry=StaticFindObject('/Script/AssetRegistry.Default__AssetRegistryHelpers')
        assert(valid(registry),'missing registry')
        local cls=registry:GetAsset({PackageName=FName(classpath,EFindName.FNAME_Add),AssetName=FName('BP_ScratchBridgeV6_C',EFindName.FNAME_Add)})
        assert(valid(cls),'missing V6 asset')
        for _,existing in ipairs(FindAllOf('BP_ScratchBridgeV6_C') or {}) do
            assert(not valid(existing) or existing:GetFullName():find('Default__',1,true),
                'existing coordinator: fresh process required')
        end
        local outer=engine:GetOuter()
        assert(valid(outer) and outer:GetFullName()=='Package /Engine/Transient','wrong outer')
        local value=StaticConstructObject(cls,outer,FName('PWP_SaveLargeRecovery',EFindName.FNAME_Add),0xC0,0)
        assert(valid(value) and value:HasAnyInternalFlags(0x40000000),'unrooted coordinator')
        value.TrialTag=tag
        assert(value:GetFullName():match('^%S+ (.+)$')==path,'unexpected path')
        assert(value:BindStorage(scope.storage,scope.guild,scope.stream)==true,'storage refused')
        assert(text(value.BoundSlotB)==scope.b,'wrong slot')
        assert(value:BindOwner(scope.key,tag,1)==true,'owner refused')
        value.WorldContext=world
        phase='read'
        value:LoadScratch(201,false,scope.key,tag,1)
        assert(value.ActiveGeneration==201,'read not admitted')
        report('READ_ENQUEUED ticket=201 expected_bytes=262144 source_nonce='..written)
    else
        local value=StaticFindObject(path)
        assert(valid(value) and value:HasAnyInternalFlags(0x40000000),'coordinator disappeared')
        assert(text(value.TrialTag)==tag and text(value.BoundOwner)==tag
            and text(value.BoundScope)==scope.key and value.BoundEpoch==1,'owner changed')
        if value.Done~=true then return end
        assert(value.Busy==false and value.Success==true and value.CompletedGeneration==201,'read failed')
        local record=value.LoadedSave
        assert(valid(record) and record.Generation==101 and text(record.Session)==scope.key
            and text(record.Payload)==payload and text(record.Checksum)=='synthetic','persisted record mismatch')
        assert(value:ConsumeResult(scope.key,tag,201,'read',false,1)==true,'consume refused')
        assert(value.Done==false and not valid(value.LoadedSave),'result not released')
        assert(value:RetireOwner(scope.key,tag,1)==true,'retirement refused')
        stop('RECOVERY_PASS bytes=262144 writes=0 source_nonce='..written)
    end
end
if not pcall(report,'ARM_CONSUMED read-only prior-process synthetic slot; no production storage') then return end
local ok,result=pcall(function()
    return LoopInGameThreadWithDelay(500,function()
        local success,why=pcall(step)
        if not success then stop('FAIL '..tostring(why)) end
    end)
end)
handle=ok and result or nil
if not handle then stop('TIMER_UNAVAILABLE')
elseif finished then pcall(function() CancelDelayedAction(handle) end) end
