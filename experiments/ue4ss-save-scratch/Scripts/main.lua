-- Standalone opt-in developer mod. NOT part of PalWorkPriority release staging.
-- Writes only synthetic PWP_SaveScratch_v1_A/B through the separate V2 pak.
-- No Lua worker, production settings, chat commands, or saved engine wrappers.
local source = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local root = source:match('^(.*)/Scripts/main.lua$')
if not root then print('[PWP scratch] stopped: cannot identify mod directory\n'); return end
local f = io.open(root .. '/run.txt', 'r')
if not f then return end
local request = f:read('*a'); f:close()
local mode, nonce = request:match('^PWP_SCRATCH_V2_(%u+)%s+([%w%-]+)%s*$')
if (mode ~= 'WRITE' and mode ~= 'READ' and mode ~= 'READWARM' and mode ~= 'WARM') or #nonce > 64 then
    print('[PWP scratch] stopped: invalid explicit run token\n'); return
end
if type(LoopInGameThreadWithDelay) ~= 'function' or type(CancelDelayedAction) ~= 'function' then
    print('[PWP scratch] stopped: bounded game-thread timer unavailable\n'); return
end
local label = 'PWP scratch V2 ' .. nonce
local incarnation = nonce .. ':' .. tostring(os.time()) .. ':' .. tostring(os.clock())
local persisted_scope = 'PWP-SCRATCH-V2-SYNTHETIC:' .. nonce
local handle, monitor_handle, bridge_path, finished, waiting, initialized
local warm = mode == 'WARM'
local writing = mode == 'WRITE' or warm
local metrics = warm and assert(loadfile(root .. '/Scripts/metrics.lua'))().new(4096)
local phase, round, phase_started, last_check = 'warmup', 1, nil, nil
local next_sample_at, previous_beat, previous_phase
local buffered, buffering = {}, false
local started_wall, next_index, polls = os.time(), 1, 0
local setup_ms, resolve_ms, enqueue_ms, samples, resolve_n = 0, 0, 0, 0, 0
local bridge_class = '/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV2'
local record_class = '/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchRecord'
local sizes = {32,4096,32768,65536,32,4096,32768,65536}
local function valid(x) return x ~= nil and x:IsValid() end
local function text(x) return type(x)=='string' and x or x:ToString() end
local function report(line)
    local full = os.date('!%Y-%m-%dT%H:%M:%SZ ') .. label .. ' ' .. line
    if buffering then
        assert(#buffered < 128, 'scratch report buffer exhausted')
        buffered[#buffered+1] = full
        return
    end
    print(full .. '\n')
    local out, err = io.open(root .. '/scratch.log', 'a')
    if not out then error('scratch log open: '..tostring(err)) end
    local ok, why = out:write(full .. '\n')
    local closed, close_why = out:close()
    assert(ok and closed, tostring(why or close_why or 'scratch log failed'))
end
local function stop(reason)
    finished = true
    local function cancel(h)
        if not h then return true end
        local ok, result=pcall(CancelDelayedAction,h)
        return ok and result==true
    end
    local cancelled = cancel(handle)
    local monitor_cancelled = cancel(monitor_handle)
    if metrics then
        for _, key in ipairs(metrics:keys()) do
            local s=metrics:summary(key)
            report(string.format('METRIC %s n=%d retained=%d dropped=%d total_ms=%.3f max_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f over50=%d over100=%d over250=%d; callback/gap observations, NOT frame times; percentiles cover retained samples',
                key,s.n,s.retained,s.dropped,s.total_ms,s.max_ms,s.p50_ms,s.p95_ms,s.p99_ms,s.over_50,s.over_100,s.over_250))
        end
    end
    report(reason .. ' timer_cancelled=' .. tostring(cancelled) .. ' monitor_cancelled=' .. tostring(monitor_cancelled) .. string.format(' samples=%d polls=%d setup_ms=%.3f resolve_ms=%.3f enqueue_ms=%.3f bridge_resolves=%d',
        samples,polls,setup_ms,resolve_ms,enqueue_ms,resolve_n))
    if buffering then
        buffering=false
        report('BATCH_BEGIN; timestamps below are original event times\n'..table.concat(buffered,'\n')..'\nBATCH_END')
        buffered={}
    end
end
local function populated()
    for _,pc in ipairs(FindAllOf('PalPlayerController') or {}) do
        if valid(pc) and not pc:GetFullName():find('Default__',1,true) and valid(pc.PlayerState) then return true end
    end
    return false
end
local function set_phase(value)
    phase=value; phase_started=os.clock(); previous_beat=nil; previous_phase=nil
    report(string.format('PHASE round=%d phase=%s lua_clock=%.6f',round,phase,phase_started))
end
local function load_class(path)
    local registry = StaticFindObject('/Script/AssetRegistry.Default__AssetRegistryHelpers')
    assert(valid(registry), 'asset registry unavailable')
    local name = path:match('([^/]+)$') .. '_C'
    local cls = registry:GetAsset({PackageName=FName(path,EFindName.FNAME_Add), AssetName=FName(name,EFindName.FNAME_Add)})
    assert(valid(cls), 'scratch asset not mounted: '..path)
    return cls
end
local function payload(index)
    local prefix = string.format('PWP-SCRATCH-V2:%02d:X:',index)
    return (prefix .. string.rep('12345X', math.ceil(sizes[(index-1)%8+1]/6))):sub(1,sizes[(index-1)%8+1])
end
local function checksum(bytes)
    local n=2166136261
    for i=1,#bytes do n=((n ~ bytes:byte(i))*16777619)&0xffffffff end
    return string.format('%08x',n)
end
local function initialize()
    local context=FindFirstOf('PalGameMode')
    if not valid(context) then return nil end -- no client writes; wait for authority world
    local cls=load_class(bridge_class)
    for _,actor in ipairs(FindAllOf('BP_ScratchBridgeV2_C') or {}) do
        if valid(actor) and not actor:GetFullName():find('Default__',1,true) then
            error('another scratch bridge exists; refusing duplicate owner')
        end
    end
    local lib=StaticFindObject('/Script/Engine.Default__GameplayStatics')
    assert(valid(lib),'gameplay statics unavailable')
    local transform={Rotation={X=0,Y=0,Z=0,W=1}, Translation={X=0,Y=0,Z=0}, Scale3D={X=1,Y=1,Z=1}}
    local actor=lib:BeginDeferredActorSpawnFromClass(context,cls,transform,1,context)
    assert(valid(actor),'scratch actor spawn failed')
    actor=lib:FinishSpawningActor(actor,transform)
    assert(valid(actor),'scratch actor finish failed')
    bridge_path=actor:GetFullName():match('^%S+ (.+)$')
    assert(bridge_path,'scratch actor name unavailable')
    -- Session-owned tag prevents a name-reused actor from being mistaken for ours.
    actor.TrialTag=incarnation
    return actor
end
local function step()
    if finished then return end
    if os.time()-started_wall>(warm and 600 or 180) then stop('FAIL timeout; no retry or acknowledgement'); return end
    if warm and phase=='warmup' then
        if os.time()-started_wall<180 then return end
        if last_check and os.time()-last_check<5 then return end
        last_check=os.time()
        if not populated() then return end
        phase='initializing' -- loading/spawning is outside every baseline window
    end
    -- Idle phase/spacing checks use only Lua state. Resolve a fresh bridge only
    -- for a request or pending completion; never cache its UObject wrapper.
    if initialized then
        if warm and phase=='baseline' then
            if os.clock()-phase_started<30 then return end
            assert(populated(),'no connected player at active boundary')
            set_phase('active'); next_sample_at=os.clock()
            return
        end
        if warm and not waiting then
            if next_index>8 then
                if os.clock()-phase_started<30 then return end
                assert(populated(),'no connected player at completed boundary')
                if round==3 then
                    for r=1,3 do
                        for _,p in ipairs({'baseline','active'}) do
                            assert(metrics:summary('round'..r..':'..p..':gap').n>=30,
                                'insufficient observer samples for '..r..':'..p)
                            assert(metrics:summary('round'..r..':'..p..':callback').n>=10,
                                'insufficient callback samples for '..r..':'..p)
                        end
                    end
                    stop('COMPLETE exact readbacks verified'); return
                end
                round=round+1; next_index=1; set_phase('baseline'); return
            end
            if os.clock()<next_sample_at then return end
            next_sample_at=os.clock()+3
        end
    end
    local lookup=os.clock()
    local actor
    if not initialized then
        actor=initialize()
        setup_ms=setup_ms+(os.clock()-lookup)*1000
        if not actor then return end
        initialized=true
        report('READY mode='..mode..' engine-clock=frame-quantized-world-real-seconds lua-clock-resolution=unmeasured; polling and logging are harness overhead')
        if warm then set_phase('baseline'); return end
    else
        resolve_n=resolve_n+1
        actor=StaticFindObject(bridge_path)
        resolve_ms=resolve_ms+(os.clock()-lookup)*1000
        assert(valid(actor) and text(actor.TrialTag)==incarnation,'world/bridge changed; stopped')
    end
    if waiting then
        polls=polls+1
        if actor.Done~=true then return end
        assert(actor.Busy==false and actor.CompletedGeneration==waiting.ticket,'completion identity mismatch')
        assert(actor.Success==true,'engine save/read operation failed')
        local record=actor.LoadedSave
        assert(valid(record),'no readback object')
        local expected=payload(waiting.index)
        assert(record.Generation==waiting.index and text(record.Session)==persisted_scope
            and text(record.Payload)==expected and text(record.Checksum)==checksum(persisted_scope..'|'..expected),'readback content mismatch')
        local start=actor.StartedSeconds
        local end_at=actor.CompletedSeconds
        local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end
        assert(finite(start) and finite(end_at) and finite(actor.ReadStartedSeconds)
            and end_at>=actor.ReadStartedSeconds and actor.ReadStartedSeconds>=start,'engine read timing invalid')
        if writing then assert(finite(actor.SaveFinishedSeconds) and actor.SaveFinishedSeconds>=start
            and actor.SaveFinishedSeconds<=actor.ReadStartedSeconds,'engine save timing invalid') end
        samples=samples+1
        report(string.format('PASS mode=%s round=%d sample=%d bytes=%d engine_total_ms=%.3f engine_save_ms=%.3f engine_read_ms=%.3f enqueue_ms=%.3f observed_ms=%.3f',
            mode,round,waiting.index,#expected,(end_at-start)*1000,
            writing and (actor.SaveFinishedSeconds-start)*1000 or 0,
            (end_at-actor.ReadStartedSeconds)*1000,waiting.enqueue_ms,(os.clock()-waiting.started)*1000))
        waiting=nil
        next_index=next_index+1
        if not warm and next_index>(writing and 8 or 2) then stop('COMPLETE exact readbacks verified'); return end
        return -- one new operation at most on the following timer callback
    end
    assert(actor.Busy==false,'bridge busy without owned request')
    local index=writing and ((warm and (round-1)*8 or 0)+next_index)
        or ((mode=='READWARM' and 16 or 0)+(next_index==1 and 7 or 8))
    local ticket=(round-1)*8+next_index
    local record
    if writing then
        local lib=StaticFindObject('/Script/Engine.Default__GameplayStatics')
        assert(valid(lib),'gameplay statics unavailable')
        record=lib:CreateSaveGameObject(load_class(record_class))
        assert(valid(record),'cannot create scratch record')
        local bytes=payload(index)
        record.Payload=bytes; record.Session=persisted_scope
        record.Generation=index; record.Checksum=checksum(persisted_scope..'|'..bytes)
    end
    local t=os.clock()
    waiting={ticket=ticket,index=index,started=t}
    if writing then actor:SubmitScratch(record,ticket,index%2==1)
    else actor:LoadScratch(ticket,index%2==1) end
    waiting.enqueue_ms=(os.clock()-t)*1000
    enqueue_ms=enqueue_ms+waiting.enqueue_ms
    assert(actor.ActiveGeneration==ticket,'scratch request was not accepted')
end
report('ARMED '..mode..'; synthetic scratch slots only; '..(warm and '600s timeout; 180s warmup; 3 x baseline/active pairs; buffered reports; 33ms callback-gap observer NOT frames' or '180s timeout')..'; 500ms operation observation cadence')
buffering=warm
handle=LoopInGameThreadWithDelay(500,function()
    local t=os.clock()
    local group=phase
    local group_round=round
    local ok,err=pcall(step)
    if metrics and not finished and (group=='baseline' or group=='active') and group==phase and group_round==round then
        local accepted,why=metrics:add('round'..round..':'..group..':callback',(os.clock()-t)*1000)
        if not accepted then ok=false; err=why end
    end
    if not ok then
        pcall(stop,'FAIL '..tostring(err))
    end
end)
if warm then
    local ok, result=pcall(LoopInGameThreadWithDelay,33,function()
        if finished or (phase~='baseline' and phase~='active') then return end
        local t=os.clock()
        if previous_beat and previous_phase==phase then
            local delta=(t-previous_beat)*1000
            if delta<0 then pcall(stop,'FAIL nonmonotonic observer clock'); return end
            local accepted,why=metrics:add('round'..round..':'..phase..':gap',delta)
            if not accepted then pcall(stop,'FAIL observer sample: '..tostring(why)); return end
        end
        previous_beat=t; previous_phase=phase
    end)
    if ok and result~=nil then monitor_handle=result
    else pcall(stop,'FAIL observer registration: '..tostring(result)) end
end
