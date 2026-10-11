local path=TEST_ROOT..'/experiments/ue4ss-save-scratch/Scripts/main.lua'
local f=assert(io.open(path,'r')); local source=f:read('*a'); f:close()
local slots={}
local function trial(mode, fault)
    local loop, cancelled, now, actor, pending, writes, reads, output = nil,false,0,nil,nil,0,0,{}
    local actor_resolves=0
    local first_round={}
    local monitor, monitor_cancelled, first_write_at, cancellation_attempts = nil,nil,nil,0
    local env=setmetatable({}, {__index=_G})
    env.print=function() end
    env.os=setmetatable({time=function() return now end,clock=function() return now end},{__index=os})
    env.io={open=function(p, how)
        assert(p:find('/experiments/ue4ss-save-scratch/',1,true),'outside scratch directory')
        if p:match('/run.txt$') then return {read=function() return 'PWP_SCRATCH_V2_'..mode..' regression' end,close=function() return true end} end
        assert(p:match('/scratch.log$') and how=='a')
        if fault=='log failure' then return nil,'denied' end
        return {write=function(_,line) output[#output+1]=line; return true end,close=function() return true end}
    end}
    env.EFindName={FNAME_Add=1}; env.FName=function(x) return x end
    env.LoopInGameThreadWithDelay=function(ms,fn)
        if ms==33 then
            if fault=='observer registration' then error('observer unavailable') end
            monitor=fn; return 2
        end
        assert(ms==500); loop=fn; return 1
    end
    env.CancelDelayedAction=function(h)
        assert(h==1 or h==2)
        if h==1 then
            cancellation_attempts=cancellation_attempts+1
            if fault=='cancel throws' then error('cancel rejected') end
            cancelled=true
        else monitor_cancelled=true end
        return true
    end
    local function object(t) t=t or {}; t.IsValid=function() return true end; return t end
    local function copy(t) local c={} for k,v in pairs(t) do c[k]=v end return object(c) end
    local registry=object({GetAsset=function() if fault=='missing pak' then return nil end return object() end})
    local lib=object({CreateSaveGameObject=function() return object() end})
    lib.BeginDeferredActorSpawnFromClass=function()
        if mode=='WARM' then now=now+2 end -- cold setup must precede baseline
        actor=object({Busy=false,Done=false,GetFullName=function() return 'BP_ScratchBridgeV2_C /Game/Fixture.Actor' end})
        actor.SubmitScratch=function(self, record, ticket, a)
            assert(not pending,'overlapping IO'); writes=writes+1
            first_write_at=first_write_at or now
            self.Busy=true; self.Done=false; self.ActiveGeneration=ticket
            pending={record=copy(record),ticket=ticket,slot=a and 'A' or 'B'}
        end
        actor.LoadScratch=function(self,ticket,a)
            assert(not pending,'overlapping read'); reads=reads+1
            self.Busy=true; self.Done=false; self.ActiveGeneration=ticket
            pending={ticket=ticket,slot=a and 'A' or 'B'}
        end
        return actor
    end
    lib.FinishSpawningActor=function(_,a) return a end
    env.StaticFindObject=function(p)
        now=now+0.004 -- observable work within callbacks, rather than a frozen clock
        if p=='/Script/AssetRegistry.Default__AssetRegistryHelpers' then return registry end
        if p=='/Script/Engine.Default__GameplayStatics' then return lib end
        assert(p=='/Game/Fixture.Actor'); actor_resolves=actor_resolves+1; return actor
    end
    env.FindAllOf=function(cls)
        if cls=='PalPlayerController' and fault~='no player' and not (fault=='player left' and writes>=8) then
            return {object({PlayerState=object(),GetFullName=function() return 'PalPlayerController /World.Player' end})}
        end
        return {}
    end
    env.FindFirstOf=function() return object() end
    local ran,why=pcall(assert(load(source,'@'..path,'t',env)))
    if fault=='log failure' then assert(not ran and not loop); return end
    assert(ran,why)
    assert(loop)
    for i=1,1400 do
        if cancelled then break end
        for _=1,15 do
            now=now+0.033
            if monitor and not monitor_cancelled and fault~='inert observer' then monitor() end
        end
        now=now+0.005
        if pending and i%3==0 and fault~='timeout' then
            local p=pending; pending=nil
            if p.record then
                slots[p.slot]=p.record
                if p.record.Generation<=8 then first_round[p.record.Generation]=copy(p.record) end
            end
            actor.LoadedSave=slots[p.slot] and copy(slots[p.slot])
            actor.CompletedGeneration=p.ticket; actor.Busy=false; actor.Done=true; actor.Success=true
            actor.StartedSeconds=10; actor.SaveFinishedSeconds=10.03; actor.ReadStartedSeconds=10.03; actor.CompletedSeconds=10.05
            if fault=='stale round' and writes>8 then actor.LoadedSave=first_round[(p.record.Generation-1)%8+1] end
            if fault=='corruption' then actor.LoadedSave.Checksum='bad' end
            if fault=='session' then actor.TrialTag='other incarnation' end
            if fault=='stale trial' then actor.LoadedSave.Session='old trial' end
        end
        loop()
        if cancelled then break end
    end
    assert(cancelled or fault=='cancel throws','timer did not stop')
    local log=table.concat(output)
    if fault=='cancel throws' then
        assert(monitor_cancelled and log:find('timer_cancelled=false monitor_cancelled=true',1,true),log)
        assert(cancellation_attempts==1 and writes==24,'failed timer cancellation repeated work')
    elseif fault then
        assert(log:find('FAIL',1,true) and not log:find('COMPLETE',1,true),log)
        assert(writes<=(fault=='stale round' and 9 or fault=='inert observer' and 24 or fault=='player left' and 8 or 1))
    else
        assert(log:find('COMPLETE exact readbacks verified',1,true),log)
        assert(writes==(mode=='WARM' and 24 or mode=='WRITE' and 8 or 0) and reads==((mode=='READ' or mode=='READWARM') and 2 or 0))
        if mode=='WARM' then
            assert(first_write_at>=210,'write before warmup and baseline')
            assert(monitor_cancelled and log:find('METRIC round1:baseline:gap',1,true) and log:find('METRIC round3:active:callback',1,true),log)
            assert(#output==2,'warm path performed per-sample file logging')
            local starts, phases, pass_counts = {}, {}, {}
            for r,p,t in log:gmatch('PHASE round=(%d+) phase=(%a+) lua_clock=([%d%.]+)') do
                starts[r..p]=tonumber(t); phases[#phases+1]={r=r,p=p,t=tonumber(t)}
            end
            assert(#phases==6 and starts['1baseline']>=182,'setup contaminated first baseline')
            for r in log:gmatch('PASS mode=WARM round=(%d+)') do pass_counts[r]=(pass_counts[r] or 0)+1 end
            for r=1,3 do
                assert(pass_counts[tostring(r)]==8,'incorrect writes per round')
                assert(starts[r..'active']-starts[r..'baseline']>=30,'baseline too short')
                if r<3 then assert(starts[(r+1)..'baseline']-starts[r..'active']>=30,'active too short') end
            end
            local p50=log:match('METRIC round1:baseline:callback[^\n]-p50_ms=([%d%.]+)')
            assert(p50 and tonumber(p50)==0,'idle baseline still resolves engine objects')
            local active_max=log:match('METRIC round1:active:callback[^\n]-max_ms=([%d%.]+)')
            assert(active_max and tonumber(active_max)>=3.9,'active callback work not measured')
            local polls=tonumber(log:match('samples=24 polls=(%d+)'))
            assert(polls and actor_resolves<=24+polls,'idle spacing performed engine lookups')
            assert(tonumber(log:match('bridge_resolves=(%d+)'))==actor_resolves,'lookup count incorrect')
            assert(slots.A.Generation==23 and slots.B.Generation==24,'warm generations reused')
            local gap=log:match('METRIC round1:baseline:gap[^\n]-p50_ms=([%d%.]+)')
            assert(gap and tonumber(gap)>=32.9 and tonumber(gap)<40,'observer cadence not exercised')
        end
    end
end
trial('WRITE'); trial('READ')
for _,fault in ipairs({'missing pak','corruption','session','timeout','stale trial','log failure'}) do trial('WRITE',fault) end
trial('WARM'); trial('READWARM')
for _,fault in ipairs({'no player','player left','observer registration','inert observer','stale round','corruption','timeout','log failure','cancel throws'}) do trial('WARM',fault) end
print('scratch driver: eight exact writes, fresh read-only trial, fail-stop/cancellation passed')
