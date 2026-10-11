-- Driver regression only: native IO and timer are mocked; scope mapping is real.
local path=TEST_ROOT..'/experiments/ue4ss-save-scoped-large/Scripts/main.lua'
local f=assert(io.open(path));local code=f:read('*a');f:close()
local scope_path=TEST_ROOT..'/experiments/save_scope.lua'
local expected=dofile(scope_path).new(string.rep('8',32),string.rep('e',32),'priorities')
local target='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local cases={
    ['disarm failure']='could not disarm diagnostic',
    ['duplicate']='existing coordinator', ['missing pak']='missing diagnostic asset',
    ['not rooted']='rooted construction failed', ['wrong outer']='transient package unavailable',
    ['slot mismatch']='native/Lua slot mismatch', ['storage replacement']='storage replacement allowed',
    ['active takeover']='active takeover admitted', ['pending takeover']='undrained takeover admitted',
    ['terminal takeover']='terminal takeover admitted', ['travel takeover']='travel result bypassed handover drain',
    ['retirement failure']='pending retirement failed', ['retired admission']='retired owner admitted',
    -- The post-handover stale-request check also verifies the retained high-water mark.
    ['claim failure']='drained handover failed', ['reset tickets']='stale epoch request admitted',
    ['stale retire']='stale epoch retired new owner', ['wrong epoch consume']='wrong epoch consumed',
    ['stale request admission']='stale epoch request admitted',
    ['synchronous write completion']='write completed before pending-retirement observation',
    ['stale ack accepted']='stale epoch ack accepted', ['ack clears busy']='previous ack changed new operation',
    ['ack clears proxy']='previous ack cleared pending action',
    ['corrupt']='native readback mismatch', ['disappeared']='rooted coordinator disappeared',
    ['wrong owner']='different diagnostic owner', ['wrong epoch']='different diagnostic owner', ['timeout']='timeout:',
    ['final claim failure']='travel handover failed', ['final stale retire']='old epoch retired final owner',
    ['final retire failure']='final retirement failed',
}
local function trial(fault)
    local env=setmetatable({}, {__index=_G})
    local output,control={},'PWP_SCOPED_LARGE_RUN fixture'
    local loop,bridge,pending,now,cancelled=nil,nil,nil,0,false
    local disk,operations,claims={}, {}, {}
    local scope_loads,fixtures=0,0
    local function hit(name)
        return fault==name
    end
    local function object(t) t=t or {};t.IsValid=function() return true end;return t end
    local function copy(r)
        return object{Generation=r.Generation,Session=r.Session,Payload=r.Payload,Checksum=r.Checksum}
    end
    local package=object{GetFullName=function()
        return fault=='wrong outer' and 'Package /Game/Maps/World' or 'Package /Engine/Transient'
    end}
    local engine=object{GameViewport=object{World=object{GetFullName=function() return 'World title' end}},
        GetOuter=function() return package end}
    env.require=function(name) assert(name=='UEHelpers');return {GetEngine=function() return engine end} end
    env.dofile=function(p)
        assert(p==TEST_ROOT..'/experiments/ue4ss-save-scoped-large/experiments/save_scope.lua',p)
        scope_loads=scope_loads+1
        return dofile(scope_path)
    end
    env.os=setmetatable({time=function() return now end},{__index=os})
    env.print=function() end
    env.io={open=function(p,mode)
        if p:match('/run.txt$') then return {
            read=function() return control end,
            write=function(_,s) control=s;return fault~='disarm failure' end,
            close=function() return true end} end
        if p:match('/tests/test_save_.*%.lua$') then
            fixtures=fixtures+1
            -- Nested suite loading is tested here; those suites have their own runners.
            return {read=function() return 'assert(TEST_ROOT)' end,close=function() return true end}
        end
        assert(p:match('/scoped%-large.log$') and mode=='a',p)
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
        assert(p=='/Engine/Transient.PWP_SaveScopedLarge');return bridge
    end
    env.FindAllOf=function(name)
        assert(name=='BP_ScratchBridgeV6_C')
        return fault=='duplicate' and {object{GetFullName=function() return 'existing' end}} or {}
    end
    env.StaticConstructObject=function(cls,outer,name,flags,internal)
        assert(control=='DISABLED\n' and outer==package and name=='PWP_SaveScopedLarge' and flags==0xC0 and internal==0 and not bridge)
        bridge=object{ActiveGeneration=0,Busy=false,Done=false,Retiring=false,
            GetFullName=function() return 'BP_ScratchBridgeV6_C /Engine/Transient.PWP_SaveScopedLarge' end,
            HasAnyInternalFlags=function(_,flag) assert(flag==0x40000000);return fault~='not rooted' end}
        local previous
        bridge.BindStorage=function(self,w,g,stream)
            assert(w==expected.storage and g==expected.guild)
            local next_scope=dofile(scope_path).new(w,g,stream)
            if self.StorageBound then
                if hit('storage replacement') then return true end
                return next_scope.key==self.BoundScope
            end
            self.StorageBound=true;self.BoundScope=next_scope.key
            self.BoundSlotA,self.BoundSlotB=next_scope.a,next_scope.b
            if hit('slot mismatch') then self.BoundSlotB=next_scope.a end
            return true
        end
        bridge.BindOwner=function(self,scope,owner,epoch)
            assert(math.type(epoch)=='integer','missing/misordered BindOwner Epoch')
            if not self.StorageBound or scope~=self.BoundScope or #owner==0 or #owner>256 or epoch<=0 or epoch>=2147483647 then return false end
            if self.BoundEpoch then
                if epoch==self.BoundEpoch then return not self.Retiring and owner==self.BoundOwner end
                if epoch<self.BoundEpoch then return false end
                if not self.Retiring and not hit('active takeover') then return false end
                if self.Busy and not hit('pending takeover') then return false end
                if self.Done and not hit(self.BoundEpoch==1 and 'terminal takeover' or 'travel takeover') then return false end
                if epoch==2 and hit('claim failure') then return false end
                if epoch==3 and hit('final claim failure') then return false end
                if hit('reset tickets') then self.ActiveGeneration=0 end
            end
            self.BoundOwner,self.BoundEpoch,self.Retiring=owner,epoch,false
            previous=nil;claims[#claims+1]=epoch
            return true
        end
        bridge.RetireOwner=function(self,scope,owner,epoch)
            assert(math.type(epoch)=='integer','missing/misordered RetireOwner Epoch')
            if scope~=self.BoundScope or owner~=self.BoundOwner then return false end
            if epoch~=self.BoundEpoch then
                if hit(self.BoundEpoch==2 and 'stale retire' or 'final stale retire') then self.Retiring=true;return true end
                return false
            end
            if epoch==1 and hit('retirement failure') then return false end
            if epoch==3 and hit('final retire failure') then return false end
            self.Retiring=true;return true
        end
        local function start(self,r,t,a,scope,owner,epoch,kind)
            assert(math.type(epoch)=='integer','missing/misordered request Epoch')
            if scope~=self.BoundScope or owner~=self.BoundOwner
                or (epoch~=self.BoundEpoch and not (epoch<self.BoundEpoch and hit('stale request admission')))
                or self.Busy or self.Done or t<=self.ActiveGeneration or t>=2147483647 then return end
            if self.Retiring and not hit('retired admission') then return end
            local slot=a and self.BoundSlotA or self.BoundSlotB
            pending={record=r and copy(r),ticket=t,slot=slot,epoch=epoch,kind=kind}
            operations[#operations+1]=pending
            self.ActiveGeneration,self.Busy,self.Done=t,true,false
            self.ActiveKind,self.ActiveUseA=kind,a
            self.PendingAction=object{GetAddress=function() return t end}
        end
        bridge.SubmitScratch=function(self,r,t,a,scope,owner,epoch)
            start(self,r,t,a,scope,owner,epoch,'write')
            if pending and hit('synchronous write completion') then
                local op=pending;pending=nil
                disk[op.slot]=copy(op.record)
                self.LoadedSave=copy(disk[op.slot]);self.CompletedGeneration=op.ticket
                self.Busy=false;self.Done=true;self.Success=true;self.PendingAction=nil
            end
        end
        bridge.LoadScratch=function(self,t,a,scope,owner,epoch) start(self,nil,t,a,scope,owner,epoch,'read') end
        bridge.ConsumeResult=function(self,scope,owner,t,kind,a,epoch)
            assert(math.type(epoch)=='integer','missing/misordered consume Epoch')
            if scope~=self.BoundScope or owner~=self.BoundOwner then return false end
            if epoch~=self.BoundEpoch then
                if epoch>self.BoundEpoch then
                    if not hit('wrong epoch consume') then return false end
                else
                    if self.Busy then
                        if hit('ack clears busy') then self.Busy=false end
                        if hit('ack clears proxy') then self.PendingAction=nil end
                        if hit('stale ack accepted') then return true end
                    end
                    return false
                end
            end
            if previous and t==previous.t and kind==previous.kind and a==previous.a then return true end
            if self.Busy or not self.Done or t~=self.ActiveGeneration or t~=self.CompletedGeneration
                or kind~=self.ActiveKind or a~=self.ActiveUseA then return false end
            previous={t=t,kind=kind,a=a};self.Done=false;self.LoadedSave=nil
            return true
        end
        return bridge
    end
    local function check_failure()
        local log=table.concat(output)
        assert(cancelled and control=='DISABLED\n',fault)
        assert(log:find('FAIL',1,true) and log:find(assert(cases[fault]),1,true),log)
        assert(not log:find('PASS_WORLD_TRANSITION',1,true),log)
    end
    local ok,err=pcall(assert(load(code,'@'..path,'t',env)))
    if fault=='disarm failure' then assert(not ok and tostring(err):find(cases[fault],1,true) and not loop);return end
    assert(ok,err);assert(scope_loads==1)
    loop()
    if cancelled then check_failure();return end
    assert(bridge and pending and pending.ticket==101 and bridge.Retiring and bridge.BoundEpoch==1)
    for i=1,2 do
        local op=assert(pending);pending=nil
        if op.record then disk[op.slot]=copy(op.record) end
        bridge.LoadedSave=copy(assert(disk[op.slot]))
        bridge.CompletedGeneration=op.ticket;bridge.Busy=false;bridge.Done=true;bridge.Success=true
        bridge.PendingAction=nil
        if hit('corrupt') then bridge.LoadedSave.Payload='bad' end
        now=now+1;loop()
        if cancelled then check_failure();return end
        if i==1 then assert(pending.ticket==102 and pending.epoch==2 and bridge.BoundEpoch==2 and not bridge.Retiring) end
    end
    assert(bridge.Done and bridge.CompletedGeneration==102 and not pending)
    engine.GameViewport.World=object{GetFullName=function() return 'World login' end}
    loop();assert(not cancelled and bridge.Done,'intermediate login must retain mailbox')
    if fault=='disappeared' then bridge=nil end
    if fault=='wrong owner' then bridge.TrialTag='other owner' end
    if fault=='wrong epoch' then bridge.BoundEpoch=bridge.BoundEpoch+1 end
    if fault=='timeout' then now=421 else engine.GameViewport.World=object{GetFullName=function() return target end} end
    loop()
    if fault then check_failure();return end
    local log=table.concat(output)
    assert(cancelled and control=='DISABLED\n' and not log:find('FAIL',1,true),log)
    for _,marker in ipairs({'MAILBOX_GUARDS_PASS','SCOPED_HANDOVER_PASS','TRAVEL_CONSUME_PASS','PASS_WORLD_TRANSITION'}) do
        assert(log:find(marker,1,true),marker)
    end
    assert(fixtures==2 and #operations==2 and #claims==3 and claims[1]==1 and claims[2]==2 and claims[3]==3)
    assert(operations[1].slot==expected.b and operations[2].slot==expected.b)
    assert(#disk[expected.b].Payload==262144 and disk[expected.b].Session==expected.key and not disk[expected.a])
    assert(bridge.BoundEpoch==3 and bridge.Retiring and not bridge.Done and not bridge.Busy and not bridge.LoadedSave and not pending)
end
trial()
local count=0
for fault in pairs(cases) do trial(fault);count=count+1 end
print('large scoped driver: real scope mapping, retirement, epoch handover, gameplay travel; '..count..' failure cases detected')
