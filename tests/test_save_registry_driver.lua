-- Driver-only regression: native Blueprint methods are a state-model fixture.
-- Editor commandlet receipts separately establish generated Blueprint behavior.
local path=TEST_ROOT..'/experiments/ue4ss-save-registry/Scripts/main.lua'
local f=assert(io.open(path));local code=f:read('*a');f:close()
local splash='World /Game/Pal/Maps/Splash/PL_PPSplash.PL_PPSplash'
local target='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local faults={
    ['duplicate existing']='existing registry object',
    ['missing asset']='missing registry fixture asset',
    ['wrong outer']='transient package unavailable',
    ['unrooted']='lost RootSet',
    ['wrong constructed name']='identity mismatch',
    ['unclaimed accepted']='unclaimed admission accepted',
    ['same class claim accepted']='same-class duplicate claim accepted',
    ['same class reserve accepted']='same-class duplicate admission accepted',
    ['split class registry']='cross-class duplicate claim accepted',
    ['cross class reserve accepted']='cross-class duplicate admission accepted',
    ['distinct refused']='distinct scope claim failed',
    ['busy release accepted']='busy distinct scope released',
    ['terminal release accepted']='terminal owner released',
    ['wrong ack accepted']='wrong ticket consumed result',
    ['anchor disappeared']='object disappeared: anchor',
    ['bridge disappeared']='object disappeared: a',
    ['same path replacement']='object address changed',
    ['renamed']='identity mismatch',
    ['lost root']='lost RootSet',
    ['lost terminal']='travel terminal owner released',
    ['lost busy']='travel busy owner released',
    ['ticket reset']='handover reset ticket fence',
    ['stale complete accepted']='old owner completed new reservation',
    ['timeout']='timeout:',
    ['cancel failed']='timer cancellation failed',
    ['initial mainworld']='initial world is not Splash',
    ['malformed scan']='invalid coordinator scan',
    ['invalid scan object']='unreadable existing registry object',
}

local function trial(fault,request)
    local env=setmetatable({}, {__index=_G})
    local control=request==nil and 'PWP_REGISTRY_V1_RUN fixture' or request
    local logs,prints,objects,classes,stores={},{},{},{},{}
    local epoch,now,loop,cancelled,constructions,scans=0,0,nil,0,0,0
    local world=fault=='initial mainworld' and target or splash
    local package={kind='package',name=fault=='wrong outer' and 'Package /Game/World' or 'Package /Engine/Transient'}
    local engine={kind='engine'}
    local viewport={kind='viewport'}
    local assetregistry={kind='assets'}
    local unwrapped=setmetatable({}, {__mode='k'})
    local operations={Claim=true,Reserve=true,Complete=true,Consume=true,Retire=true,Release=true}
    local function native(object,method,scope,ticket)
        assert(type(scope)=='string' and scope:match('^PWP%-REGISTRY%-DEV%-1:fixture:'))
        assert(math.type(ticket)=='integer')
        local key=fault=='split class registry' and object.class or 'fixed'
        stores[key]=stores[key] or {};local slots=stores[key]
        local lane=slots[scope]
        if method=='Claim' then
            if fault=='distinct refused' and scope:match(':two$') then return false end
            if fault=='same class claim accepted' and object.key=='duplicate' then return true end
            if not lane then lane={ticket=0};slots[scope]=lane end
            if lane.holder then return lane.holder==object and not lane.retiring end
            lane.holder=object;lane.retiring=false
            if fault=='ticket reset' and object.key=='duplicate' then lane.ticket=0 end
            return true
        end
        if method=='Reserve' then
            if fault=='unclaimed accepted' and not lane then return true end
            if fault=='same class reserve accepted' and object.key=='duplicate' then return true end
            if fault=='cross class reserve accepted' and object.key=='b' and scope:match(':one$') then return true end
        end
        if method=='Complete' and fault=='stale complete accepted' and object.key=='a' and ticket==102 then return true end
        if not lane or lane.holder~=object then return false end
        if method=='Reserve' then
            if lane.busy or lane.done or lane.retiring or ticket<=lane.ticket or ticket>=2147483647 then return false end
            lane.ticket=ticket;lane.busy=true;return true
        elseif method=='Complete' then
            if not lane.busy or ticket~=lane.ticket then return false end
            lane.busy=false;lane.done=true;return true
        elseif method=='Consume' then
            if fault=='wrong ack accepted' and ticket==100 then return true end
            if lane.busy or not lane.done or ticket~=lane.ticket then return false end
            lane.done=false;return true
        elseif method=='Retire' then lane.retiring=true;return true
        elseif method=='Release' then
            if fault=='busy release accepted' and lane.busy then return true end
            if fault=='terminal release accepted' and lane.done then return true end
            if not lane.retiring or lane.busy or lane.done then return false end
            lane.holder=nil;return true
        end
        error('unexpected native method '..method)
    end
    local wrap
    wrap=function(raw)
        if not raw then return end
        local born=epoch
        local result=setmetatable({}, {__index=function(_,field)
            assert(born==epoch,'retained UObject wrapper across callbacks')
            local function callable(fn)
                return function(_,...) assert(born==epoch,'retained UObject method across callbacks');return fn(...) end
            end
            if field=='IsValid' then return callable(function() return raw.valid~=false end) end
            if field=='GetFullName' then return callable(function() return raw.name end) end
            if field=='GetAddress' then return callable(function() return raw.id end) end
            if field=='HasAnyInternalFlags' then return callable(function(flag) assert(flag==0x40000000);return raw.rooted end) end
            if field=='GetOuter' then return callable(function() return wrap(package) end) end
            if raw==engine and field=='GameViewport' then return wrap(viewport) end
            if raw==viewport and field=='World' then return world and wrap({name=world}) end
            if raw==assetregistry and field=='GetAsset' then return callable(function(args)
                local name=args.PackageName:match('([^/]+)$')
                assert(args.AssetName==name..'_C')
                if fault=='missing asset' then return end
                classes[name]=classes[name] or {name=name,class=name};return wrap(classes[name])
            end) end
            if operations[field] then return callable(function(scope,ticket) return native(raw,field,scope,ticket) end) end
            error('unexpected native field '..tostring(field))
        end})
        unwrapped[result]=raw;return result
    end
    env.print=function(s) prints[#prints+1]=s end
    env.os={time=function() return now end,date=function() return 'fixture-time ' end}
    env.require=function(name) assert(name=='UEHelpers');return {GetEngine=function() return wrap(engine) end} end
    env.io={open=function(p,mode)
        if p:match('/run.txt$') then
            if mode=='r' then
                if control==false then return end
                return {read=function() return control end,close=function() return true end}
            end
            assert(mode=='w')
            return {write=function(_,text) if fault=='disarm failure' then return end;control=text;return true end,close=function() return true end}
        end
        assert(p:match('/registry.log$') and mode=='a','unexpected file IO '..p)
        return {write=function(_,s)
            if fault=='final logging failure' and s:find('PASS_WORLD_TRANSITION',1,true) then return end
            logs[#logs+1]=s;return true
        end,close=function() return true end}
    end}
    env.EFindName={FNAME_Add=1};env.FName=function(s) return s end
    env.StaticFindObject=function(p)
        if p=='/Script/AssetRegistry.Default__AssetRegistryHelpers' then return wrap(assetregistry) end
        assert(p:match('^/Engine/Transient%.PWP_RegistryV1_fixture_'))
        return wrap(objects[p])
    end
    env.FindAllOf=function(name)
        scans=scans+1
        if fault=='malformed scan' then return false end
        if fault=='invalid scan object' then return {wrap({valid=false})} end
        if fault=='duplicate existing' then return {wrap({name='prior instance'})} end
        if fault=='nil empty scans' then return end
        local asset=name:gsub('_C$','')
        return {wrap({name=name..' /Game/Mods/PalWorkPrioritySaveRegistry/'..asset..'.Default__'..name})}
    end
    env.StaticConstructObject=function(cls,outer,name,flags,internal)
        assert(control=='DISABLED\n' and unwrapped[outer]==package and flags==0xC0 and internal==0)
        local classname=cls:GetFullName()
        local key=assert(name:match('^PWP_RegistryV1_fixture_(.+)$'))
        local p='/Engine/Transient.'..name
        assert(not objects[p]);constructions=constructions+1
        local raw={key=key,class=classname,id=100+constructions,rooted=fault~='unrooted',
                   name=classname..'_C '..p}
        if fault=='wrong constructed name' then raw.name='wrong' end
        objects[p]=raw;return wrap(raw)
    end
    env.LoopInGameThreadWithDelay=function(ms,fn) assert(ms==500);loop=fn;return 7 end
    env.CancelDelayedAction=function(h) assert(h==7);cancelled=cancelled+1;return fault~='cancel failed' end
    local ok,err=pcall(assert(load(code,'@'..path,'t',env)))
    if fault=='disarm failure' then assert(not ok and tostring(err):find('could not disarm',1,true) and not loop);return end
    assert(ok,err)
    if request~=nil then assert(not loop and constructions==0 and scans==0 and #logs==0);return end
    local function tick() epoch=epoch+1;loop() end
    local function failure(expected)
        local log=table.concat(logs)..table.concat(prints)
        assert(cancelled>0 and control=='DISABLED\n',log)
        assert(log:find('FAIL',1,true) and log:find(expected,1,true),log)
        assert(not log:find('PASS_WORLD_TRANSITION',1,true),log)
        local count=#logs;tick();assert(#logs==count,'finished callback did work')
    end
    tick()
    if cancelled>0 then failure(assert(faults[fault]));return end
    assert(constructions==4 and scans==3)
    assert(table.concat(logs):find('PENDING_TRAVEL',1,true))
    local scan_count=scans
    world=nil;tick();assert(cancelled==0,'world gap ended pending trial')
    world='World /Game/Pal/Maps/Title/PL_Title.PL_Title';tick();assert(cancelled==0)
    world='World Login';tick();assert(cancelled==0,'intermediate map accepted as target')
    assert(scans==scan_count,'repeated global UObject scan')
    local pa='/Engine/Transient.PWP_RegistryV1_fixture_a'
    if fault=='anchor disappeared' then objects['/Engine/Transient.PWP_RegistryV1_fixture_anchor']=nil end
    if fault=='bridge disappeared' then objects[pa]=nil end
    if fault=='same path replacement' then objects[pa].id=999 end
    if fault=='renamed' then objects[pa].name='renamed' end
    if fault=='lost root' then objects[pa].rooted=false end
    if fault=='lost terminal' then stores.fixed['PWP-REGISTRY-DEV-1:fixture:one'].done=false end
    if fault=='lost busy' then stores.fixed['PWP-REGISTRY-DEV-1:fixture:two'].busy=false end
    if fault=='timeout' then now=421 end
    world=target;tick()
    if faults[fault] then failure(faults[fault]);return end
    if fault=='final logging failure' then failure('FAIL logging');return end
    local log=table.concat(logs)
    assert(cancelled==1 and control=='DISABLED\n' and not log:find('FAIL',1,true),log)
    assert(log:find('REGISTRY_TRAVEL_DRAIN_PASS',1,true) and log:find('PASS_WORLD_TRANSITION',1,true),log)
    for _,lane in pairs(stores.fixed) do assert(not lane.holder and not lane.busy and not lane.done) end
    local count=#logs;tick();assert(#logs==count,'finished callback ran again')
end
trial()
trial('nil empty scans')
trial('disarm failure')
trial('final logging failure')
for _,request in ipairs({'DISABLED\n','PWP_REGISTRY_V1_RUN ../bad','PWP_REGISTRY_V1_RUN '..string.rep('x',65)}) do trial(nil,request) end
trial(nil,false)
local count=0
for fault in pairs(faults) do trial(fault);count=count+1 end
print('registry driver: exact Splash-to-MainWorld5, shared registry, busy/terminal drain, stale wrappers poisoned; '..count..' failure cases detected; no native acceptance implied')
