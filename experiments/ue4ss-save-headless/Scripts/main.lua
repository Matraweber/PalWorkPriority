-- Isolated, one-shot observational diagnostic. No native save/load or writes.
-- Only this diagnostic's run.txt and headless-identity.log may be written.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/Scripts/main.lua$'))
local f=io.open(root..'/run.txt','r');if not f then return end
local request=f:read(128);f:close()
local nonce=request and request:match('^PWP_HEADLESS_IDENTITY_RUN ([%w%-]+)%s*$')
if not nonce or #nonce>64 or #request>=128 then return end
f=assert(io.open(root..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local Probe=dofile(root..'/experiments/save_headless_identity_probe.lua')
local finished,handle,last=false,nil,nil
local started,samples,stable=os.time(),0,nil
local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP headless identity '..nonce..' '..message
    print(line..'\n')
    local file=assert(io.open(root..'/headless-identity.log','a'))
    assert(file:write(line..'\n'));assert(file:close())
end
local function stop(reason)
    if finished then return end
    finished=true
    local ok,result=pcall(function() return handle and CancelDelayedAction(handle) end)
    pcall(report,reason..' samples='..samples..' verified=false timer_cancelled='..tostring(ok and result==true))
end
if not pcall(report,'ARM_CONSUMED read-only context getters; interval=1000ms max_samples=60 max_seconds=60 budget_ms=100; verified=false') then return end
local ok,result=pcall(function()
    return LoopInGameThreadWithDelay(1000,function()
        if finished then return end
        local success=pcall(function()
            if os.time()-started>=60 then stop('TIME_LIMIT current_world_unestablished');return end
            if samples>=60 then stop('SAMPLE_LIMIT current_world_unestablished');return end
            samples=samples+1
            local before=os.clock()
            -- Fresh discovery, NOT evidence of current-world identity. No cached
            -- UEHelpers wrapper and no arbitrary GameMode/GameState fallback.
            local engine=FindFirstOf('GameEngine')
            local lib=StaticFindObject('/Script/Engine.Default__GameplayStatics')
            local available=lib and lib:IsValid()==true
            local out=Probe.read(engine,
                available and function(context) return lib:GetGameState(context) end or nil,
                available and function(context) return lib:GetGameInstance(context) end or nil)
            local read_ms=(os.clock()-before)*1000
            local parts={}
            for _,key in ipairs({'status','route','engine_status','instance_status',
                'current_world_status','world','world_address','state_address','instance_address',
                'directory_status','directory','role_status','role','dedicated_status','dedicated','verified'}) do
                parts[#parts+1]=key..'='..tostring(out[key])
            end
            local current=table.concat(parts,' | ')
            if current~=last then
                report('SAMPLE '..current..' read_ms='..tostring(read_ms))
                last=current;stable=nil
            end
            if out.status=='observed' and out.current_world_status=='context_agrees'
                and out.directory_status=='format_valid' and out.role_status=='read' and out.role==3
                and out.dedicated_status=='read' and out.dedicated==true and out.world~=nil then
                local now=os.time()
                if not stable or now<stable then stable=now end
            else stable=nil end
            -- Inclusive CPU-clock budget: discovery, getters, scalar formatting
            -- and sample sink. A blocking native call cannot be preempted here;
            -- the wall deadline is checked again once it returns.
            local elapsed=(os.clock()-before)*1000
            if out.status=='unsupported_getter' or out.status=='read_failed' then
                stop('UNSUPPORTED '..out.status)
            elseif elapsed>100 then
                stop('SLOW_READ elapsed_ms='..tostring(elapsed)..' budget_ms=100')
            elseif os.time()-started>=60 then
                stop('TIME_LIMIT current_world_unestablished')
            elseif samples>=60 then
                stop('SAMPLE_LIMIT current_world_unestablished')
            elseif stable and os.time()-stable>=10 then
                stop('OBSERVATION_COMPLETE identity remains unverified')
            end
        end)
        if not success then stop('FAIL observation unavailable') end
    end)
end)
handle=ok and result or nil
if not handle then stop('TIMER_UNAVAILABLE')
elseif finished then
    -- A scheduler may invoke the callback before returning its handle.
    pcall(function() CancelDelayedAction(handle) end)
end
