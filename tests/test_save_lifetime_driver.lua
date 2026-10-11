local path=TEST_ROOT..'/experiments/ue4ss-save-lifetime-v4/Scripts/main.lua'
local f=assert(io.open(path));local code=f:read('*a');f:close()
local function trial(fault)
    local env=setmetatable({}, {__index=_G})
    local output,control={},'PWP_LIFETIME_V4_RUN fixture'
    local loop,root,pending,disk,now,cancelled=nil,nil,nil,nil,0,false
    local function object(t) t=t or {};t.IsValid=function() return true end;return t end
    local current=object{GetFullName=function() return 'World title' end}
    local package=object{GetFullName=function()
        return fault=='wrong outer' and 'Package /Game/Maps/World' or 'Package /Engine/Transient'
    end}
    local engine=object{GameViewport=object{World=current},GetOuter=function() return package end}
    -- UE4SS exposes this through UEHelpers, not a global GetEngine function.
    env.GetEngine=nil
    env.require=function(name)
        assert(name=='UEHelpers')
        return {GetEngine=function() return engine end}
    end
    env.os=setmetatable({time=function() return now end},{__index=os})
    env.print=function() end
    env.io={open=function(p,mode)
        if p:match('/run.txt$') then return {
            read=function() return control end,
            write=function(_,s) control=s;return fault~='disarm failure' end,
            close=function() return true end} end
        if p:match('/tests/test_save_.*%.lua$') then return {
            read=function() return 'assert(TEST_ROOT)' end,close=function() return true end} end
        assert(p:match('/lifetime.log$') and mode=='a')
        return {write=function(_,s) output[#output+1]=s;return true end,close=function() return true end}
    end}
    env.EFindName={FNAME_Add=1};env.FName=function(s) return s end
    env.LoopInGameThreadWithDelay=function(ms,fn) assert(ms==500);loop=fn;return 1 end
    env.CancelDelayedAction=function(h) assert(h==1);cancelled=true;return true end
    local lib=object{CreateSaveGameObject=function() return object() end}
    local registry=object{GetAsset=function() return fault~='missing pak' and object() or nil end}
    env.StaticFindObject=function(p)
        if p=='/Script/AssetRegistry.Default__AssetRegistryHelpers' then return registry end
        if p=='/Script/Engine.Default__GameplayStatics' then return lib end
        assert(p=='/Engine/Transient.PWP_SaveLifetimeV4');return root
    end
    env.FindAllOf=function() return fault=='duplicate' and {object{GetFullName=function() return 'existing' end}} or {} end
    env.StaticConstructObject=function(cls,outer,name,flags)
        assert(control=='DISABLED\n' and outer==package and name=='PWP_SaveLifetimeV4' and flags==0xC0 and not root)
        root=object{
            GetFullName=function() return 'BP_ScratchBridgeV4_C /Engine/Transient.PWP_SaveLifetimeV4' end,
            HasAnyInternalFlags=function(_,flag) assert(flag==0x40000000);return fault~='not rooted' end}
        root.SubmitScratch=function(self,r,t,a)
            assert(not pending and t==101 and a==false)
            pending={record=r,ticket=t};self.ActiveGeneration=t;self.Busy=true;self.Done=false
        end
        root.LoadScratch=function(self,t,a)
            if self.Busy then return end
            assert(t==102 and a==false)
            pending={ticket=t};self.ActiveGeneration=t;self.Busy=true;self.Done=false
        end
        return root
    end
    local ok,err=pcall(assert(load(code,'@'..path,'t',env)))
    if fault=='disarm failure' then assert(not ok and not loop);return end
    assert(ok,err)
    loop()
    if fault=='duplicate' or fault=='missing pak' or fault=='not rooted' or fault=='wrong outer' then
        assert(cancelled and table.concat(output):find('FAIL',1,true));return
    end
    assert(root and pending and pending.ticket==101)
    for i=1,2 do
        local p=assert(pending);pending=nil
        if p.record then disk=p.record end
        root.LoadedSave=disk;root.CompletedGeneration=p.ticket;root.Busy=false;root.Done=true;root.Success=true
        if fault=='corrupt' then disk.Payload='bad' end
        now=now+1;loop()
        if fault=='corrupt' then assert(cancelled and table.concat(output):find('FAIL',1,true));return end
    end
    if fault=='disappeared' then root=nil end
    if fault=='wrong owner' then root.TrialTag='other owner' end
    -- An intermediate login world does not complete the gameplay travel test.
    if not fault then
        engine.GameViewport.World=object{GetFullName=function() return 'World login' end}
        loop();assert(not cancelled)
    end
    if fault=='timeout' then now=421 else engine.GameViewport.World=object{GetFullName=function()
        return 'World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
    end} end
    loop()
    assert(cancelled and control=='DISABLED\n')
    local log=table.concat(output)
    assert(log:find(fault and 'FAIL' or 'PASS_WORLD_TRANSITION',1,true),log)
    assert((fault and not log:find('PASS_WORLD_TRANSITION',1,true)) or not fault)
end
trial()
for _,fault in ipairs({'disarm failure','duplicate','missing pak','not rooted','wrong outer','corrupt','disappeared','wrong owner','timeout'}) do trial(fault) end
print('lifetime driver: one-shot arm, exact readback, transition and failure guards passed')
