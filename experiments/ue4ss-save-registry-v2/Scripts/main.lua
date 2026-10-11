-- One-shot fixed-CDO registry diagnostic. Synthetic state only; NO save IO/GC.
-- Requires the separately staged PalWorkPrioritySaveRegistryV2 pak.
-- Arm for a normal restart with: PWP_REGISTRY_V2_RUN <unique-nonce>
-- Must begin in the observed Splash map and finish in MainWorld5 in one process.
-- Rooted objects intentionally survive until process exit, even on failure.
local source=debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
local root=assert(source:match('^(.*)/Scripts/main.lua$'))
local arm=io.open(root..'/run.txt','r');if not arm then return end
local request=arm:read('*a');arm:close()
local nonce=request and request:match('^PWP_REGISTRY_V2_RUN ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
local disarm=assert(io.open(root..'/run.txt','w'))
local wrote=disarm:write('DISABLED\n');local closed=disarm:close()
assert(wrote and closed,'could not disarm registry diagnostic')
assert(type(LoopInGameThreadWithDelay)=='function' and type(CancelDelayedAction)=='function')

local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP registry V2 '..nonce..' '..message
    local f=assert(io.open(root..'/registry.log','a'))
    local ok=f:write(line..'\n');local done=f:close()
    assert(ok and done,'registry diagnostic log failure')
    print(line..'\n')
end
local base='/Game/Mods/PalWorkPrioritySaveRegistryV2/'
local assets={anchor='BP_SaveRegistryV2',a='BP_RegistryBridgeV2A',duplicate='BP_RegistryBridgeV2A',b='BP_RegistryBridgeV2B'}
local order={'anchor','a','duplicate','b'}
local names,paths,addresses={},{},{} -- copied scalars only; never UObject wrappers
for _,key in ipairs(order) do
    names[key]='PWP_RegistryV2_'..nonce..'_'..key
    paths[key]='/Engine/Transient.'..names[key]
end
local scope1='PWP-REGISTRY-DEV-2:'..nonce..':one'
local scope2='PWP-REGISTRY-DEV-2:'..nonce..':two'
local splash='World /Game/Pal/Maps/Splash/PL_PPSplash.PL_PPSplash'
local target='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local started,handle,finished,phase=os.time(),nil,false,'initialize'
local function valid(value) return value~=nil and value:IsValid() end
local function address(value)
    local scalar=value:GetAddress()
    assert(type(scalar)=='number' or type(scalar)=='string','non-scalar native address')
    return tostring(scalar)
end
local function validate(value,key)
    assert(valid(value),'registry object disappeared: '..key)
    assert(value:GetFullName()==assets[key]..'_C '..paths[key],'registry object identity mismatch: '..key)
    assert(value:HasAnyInternalFlags(0x40000000),'registry object lost RootSet: '..key)
    return value
end
local function resolve(key)
    local value=validate(StaticFindObject(paths[key]),key)
    assert(address(value)==addresses[key],'registry object address changed: '..key)
    return value
end
local function current_world()
    local engine=require('UEHelpers').GetEngine();if not valid(engine) then return end
    local viewport=engine.GameViewport;if not valid(viewport) then return end
    local world=viewport.World;if not valid(world) then return end
    return world:GetFullName()
end
local function class(name)
    local registry=StaticFindObject('/Script/AssetRegistry.Default__AssetRegistryHelpers')
    assert(valid(registry),'asset registry unavailable')
    local cls=registry:GetAsset({PackageName=FName(base..name,EFindName.FNAME_Add),AssetName=FName(name..'_C',EFindName.FNAME_Add)})
    assert(valid(cls),'missing registry fixture asset: '..name)
    return cls
end
local function no_existing(name)
    local found=FindAllOf(name..'_C')
    assert(found==nil or type(found)=='table','invalid coordinator scan')
    for _,object in pairs(found or {}) do
        assert(valid(object),'unreadable existing registry object')
        assert(object:GetFullName()==name..'_C '..base..name..'.Default__'..name..'_C',
            'existing registry object; refusing adoption or duplicate construction')
    end
end
local function expect(object,method,scope,ticket,expected,label,epoch)
    assert(object[method](object,scope,epoch or 1,ticket)==expected,label)
end
local function finish(ok,message)
    finished=true
    local called,cancelled=pcall(CancelDelayedAction,handle)
    if not called or cancelled~=true then ok=false;message='timer cancellation failed; '..message end
    local logged,err=pcall(report,(ok and 'PASS_WORLD_TRANSITION ' or 'FAIL ')..message..' timer_cancelled='..tostring(called and cancelled==true))
    if not logged then pcall(print,'PWP registry V2 '..nonce..' FAIL logging '..tostring(err)..'\n') end
end
local function step()
    assert(os.time()-started<420,'timeout: rooted fixture state preserved until process exit')
    if phase=='initialize' then
        local world=current_world();if not world then return end
        assert(world==splash,'initial world is not Splash; normal restart required')
        -- Load all three classes and reject prior instances before constructing any.
        local classes={}
        for _,name in ipairs({'BP_SaveRegistryV2','BP_RegistryBridgeV2A','BP_RegistryBridgeV2B'}) do
            classes[name]=class(name);no_existing(name)
        end
        for _,key in ipairs(order) do
            assert(not valid(StaticFindObject(paths[key])),'fixture path already exists')
        end
        local outer=require('UEHelpers').GetEngine():GetOuter()
        assert(valid(outer) and outer:GetFullName()=='Package /Engine/Transient','transient package unavailable')
        local objects={}
        for _,key in ipairs(order) do
            local value=StaticConstructObject(classes[assets[key]],outer,FName(names[key],EFindName.FNAME_Add),0xC0,0)
            validate(value,key);addresses[key]=address(value);objects[key]=value
        end
        local a,d,b=objects.a,objects.duplicate,objects.b
        expect(a,'Reserve',scope1,101,false,'unclaimed admission accepted')
        expect(a,'Claim',scope1,0,true,'initial claim failed')
        expect(d,'Claim',scope1,0,false,'same-class duplicate claim accepted')
        expect(d,'Reserve',scope1,101,false,'same-class duplicate admission accepted')
        expect(b,'Claim',scope1,0,false,'cross-class duplicate claim accepted')
        expect(b,'Reserve',scope1,101,false,'cross-class duplicate admission accepted')
        expect(b,'Claim',scope2,0,true,'distinct scope claim failed')
        expect(b,'Reserve',scope2,201,true,'distinct scope reservation failed')
        expect(b,'Retire',scope2,0,true,'distinct scope retirement failed')
        expect(b,'Release',scope2,0,false,'busy distinct scope released')
        expect(a,'Reserve',scope1,101,true,'initial reservation failed')
        expect(a,'Reserve',scope1,102,false,'busy admission accepted')
        expect(a,'Retire',scope1,0,true,'busy retirement failed')
        expect(a,'Release',scope1,0,false,'busy owner released')
        expect(d,'Claim',scope1,0,false,'busy owner replaced')
        expect(a,'Complete',scope1,101,true,'synthetic completion failed')
        expect(a,'Release',scope1,0,false,'terminal owner released')
        expect(a,'Consume',scope1,100,false,'wrong ticket consumed result')
        expect(d,'Claim',scope1,0,false,'terminal owner replaced')
        -- Entries remain allocated after release; never evict to admit scope33.
        for i=3,32 do
            local scope='PWP-REGISTRY-DEV-2:'..nonce..':'..i
            expect(b,'Claim',scope,0,true,'capacity scope refused')
            expect(b,'Retire',scope,0,true,'capacity scope retirement failed')
            expect(b,'Release',scope,0,true,'capacity scope release failed')
        end
        expect(b,'Claim','PWP-REGISTRY-DEV-2:'..nonce..':33',0,false,'capacity overflow accepted')
        report('REGISTRY_CAPACITY_PASS retained_scopes=32 overflow_refused=1')
        phase='travel'
        report('REGISTRY_GUARDS_PASS same_class=refused cross_class=refused distinct_scope=allowed disk_io=0')
        report('PENDING_TRAVEL from='..world..' scope_one=terminal_101 scope_two=busy_201')
    else
        -- Resolve every object on EVERY callback. Unique nonce/path + exact class,
        -- root flag and copied address check are fixture identity, not authorization.
        local anchor=resolve('anchor')
        local a,d,b=resolve('a'),resolve('duplicate'),resolve('b')
        local world=current_world();if world~=target then return end
        expect(a,'Release',scope1,0,false,'travel terminal owner released')
        expect(d,'Claim',scope1,0,false,'travel terminal owner replaced')
        expect(d,'Reserve',scope1,102,false,'travel duplicate admission accepted')
        expect(a,'Complete',scope1,101,false,'travel terminal state lost or repeated completion accepted')
        expect(b,'Release',scope2,0,false,'travel busy owner released')
        expect(b,'Complete',scope2,201,true,'travel busy reservation lost')
        expect(b,'Release',scope2,0,false,'travel completed distinct scope released before consume')
        expect(a,'Consume',scope1,101,true,'travel terminal result lost')
        expect(a,'Release',scope1,0,true,'drained release failed')
        expect(d,'Claim',scope1,0,false,'handover reset epoch fence')
        expect(d,'Claim',scope1,0,true,'drained handover failed',2)
        expect(d,'Reserve',scope1,101,false,'handover reset ticket fence',2)
        expect(d,'Reserve',scope1,102,true,'new owner reservation failed',2)
        expect(a,'Complete',scope1,102,false,'old owner completed new reservation')
        expect(a,'Consume',scope1,102,false,'old owner consumed new result')
        expect(a,'Release',scope1,0,false,'old owner released replacement')
        expect(d,'Complete',scope1,102,true,'new owner completion failed',2)
        expect(d,'Consume',scope1,102,true,'new owner consume failed',2)
        expect(d,'Retire',scope1,0,true,'new owner retirement failed',2)
        expect(d,'Release',scope1,0,true,'new owner release failed',2)
        expect(b,'Consume',scope2,201,true,'distinct scope consume failed')
        expect(b,'Release',scope2,0,true,'distinct scope drain failed')
        local third='PWP-REGISTRY-DEV-2:'..nonce..':3'
        expect(b,'Claim',third,0,false,'travel lost released epoch')
        expect(b,'Claim',third,0,true,'released scope reclaim failed',2)
        expect(b,'Reserve',third,1,true,'reclaimed reservation failed',2)
        expect(b,'Complete',third,1,true,'reclaimed completion failed',2)
        expect(b,'Consume',third,1,true,'reclaimed consumption failed',2)
        expect(b,'Retire',third,0,true,'reclaimed retirement failed',2)
        expect(b,'Release',third,0,true,'reclaimed release failed',2)
        expect(b,'Claim','PWP-REGISTRY-DEV-2:'..nonce..':33',0,false,'travel lost retained capacity')
        report('REGISTRY_TRAVEL_DRAIN_PASS terminal_and_busy_retained=1 stale_owner_refused=1 disk_io=0')
        finish(true,'from='..splash..' to='..world..' synthetic_registry_only=1 rooted_objects_retained_until_exit=1')
    end
end
report('ARM_CONSUMED synthetic_registry_only=1 disk_io=0 no_game_gc=1')
handle=LoopInGameThreadWithDelay(500,function()
    if finished then return end
    local ok,err=pcall(step)
    if not ok then finish(false,tostring(err)) end
end)
assert(handle,'registry timer registration failed')
