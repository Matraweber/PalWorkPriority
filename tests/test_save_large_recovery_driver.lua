local path=TEST_ROOT..'/experiments/ue4ss-save-large-recovery/Scripts/main.lua'
local f=assert(io.open(path));local code=f:read('*a');f:close()
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local scope=Scope.new(string.rep('8',32),string.rep('e',32),'priorities')
local function trial(fault)
    local env=setmetatable({}, {__index=_G})
    local control='PWP_LARGE_RECOVERY reader writer'
    if fault=='disabled' then control='DISABLED' end
    local callback,bridge,now,cancelled,reads=nil,nil,0,0,0
    local logs={}
    local function obj(t)
        t=t or {};t.IsValid=function() return true end
        return setmetatable(t,{__index=function(_,key) error('unexpected native access '..key) end})
    end
    local cls=obj{}
    local world=obj{}
    local outer=obj{GetFullName=function() return 'Package /Engine/Transient' end}
    local engine=obj{GameViewport=obj{World=world},GetOuter=function() return outer end}
    env.require=function(n) assert(n=='UEHelpers');return {GetEngine=function() return engine end} end
    env.dofile=function(p) assert(p:match('/save_scope.lua$'));return Scope end
    env.FName=function(x) return x end;env.EFindName={FNAME_Add=1}
    env.os={time=function() return now end,date=function() return 'time ' end}
    env.print=function() end
    env.io={open=function(p,mode)
        if p:match('/run.txt$') then return {read=function() return control end,
            write=function(_,s) control=s;return true end,close=function() return true end} end
        assert(p:match('/large%-recovery.log$') and mode=='a')
        return {write=function(_,s) logs[#logs+1]=s;return true end,close=function() return true end}
    end}
    env.StaticFindObject=function(p)
        if p=='/Script/AssetRegistry.Default__AssetRegistryHelpers' then
            return obj{GetAsset=function() return cls end}
        end
        assert(p=='/Engine/Transient.PWP_SaveLargeRecovery');return bridge
    end
    env.FindAllOf=function(n)
        assert(n=='BP_ScratchBridgeV6_C')
        return fault=='duplicate' and {obj{GetFullName=function() return 'existing bridge' end}} or {}
    end
    env.StaticConstructObject=function(c,o,name)
        assert(c==cls and o==outer and name=='PWP_SaveLargeRecovery')
        bridge=obj{HasAnyInternalFlags=function() return fault~='unrooted' end,
            GetFullName=function() return 'BP_ScratchBridgeV6_C /Engine/Transient.PWP_SaveLargeRecovery' end,
            BindStorage=function(self,w,g,s)
                assert(w==scope.storage and g==scope.guild and s=='priorities')
                self.BoundSlotB=scope.b;self.BoundScope=scope.key;return true
            end,
            BindOwner=function(self,k,t,e) assert(k==scope.key and e==1);self.BoundOwner=t;self.BoundEpoch=e;return true end,
            LoadScratch=function(self,t,a,k,owner,e)
                assert(t==201 and not a and k==scope.key and owner==self.BoundOwner and e==1)
                reads=reads+1;self.ActiveGeneration=t;self.Done=false
            end,
            ConsumeResult=function(self,k,owner,t,kind,a,e)
                assert(k==scope.key and owner==self.BoundOwner and t==201 and kind=='read' and not a and e==1)
                if fault=='consume' then return false end
                self.Done=false;self.LoadedSave={IsValid=function() return false end};return true
            end,
            RetireOwner=function() return fault~='retire' end}
        return bridge
    end
    env.LoopInGameThreadWithDelay=function(ms,fn) assert(ms==500);callback=fn;return 42 end
    env.CancelDelayedAction=function(h) assert(h==42);cancelled=cancelled+1;return true end
    assert(load(code,'@'..path,'t',env))()
    if fault=='disabled' then assert(not callback and reads==0);return end
    assert(control=='DISABLED\n');callback()
    if cancelled==0 then
        if fault=='timeout' then now=120
        else
            bridge.Busy=false;bridge.Done=true;bridge.Success=fault~='failed read';bridge.CompletedGeneration=201
            local payload=('PWP-SCOPED-LARGE:writer:X|'..string.rep('12345X',44000)):sub(1,262144)
            bridge.LoadedSave=obj{Generation=101,Session=scope.key,Payload=fault=='corrupt' and 'bad' or payload,Checksum='synthetic'}
            if fault=='wrong scope' then bridge.LoadedSave.Session='foreign' end
        end
        callback()
    end
    local output=table.concat(logs)
    assert(cancelled==1 and reads<=1,tostring(fault).." "..output)
    if fault then assert(not output:find('RECOVERY_PASS',1,true),output)
    else assert(reads==1 and output:find('RECOVERY_PASS bytes=262144 writes=0 source_nonce=writer',1,true),output) end
    local n=#logs;callback();assert(#logs==n and cancelled==1)
end
trial()
for _,fault in ipairs({'disabled','duplicate','unrooted','timeout','failed read','corrupt','wrong scope','consume','retire'}) do trial(fault) end
print('large recovery driver: read-only exact prior payload, failure rejection, single read and inert shutdown')
