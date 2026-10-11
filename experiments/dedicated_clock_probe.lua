-- Separate, default-off clock-only entry. No autostart, IO, world or Pal reads.
-- Caller supplies the pinned reviewed dedicated_parameter_clock module and timer.
-- Measurements use the clock under test: observations, never independent proof.
local M={}
local MAX_SAMPLES,INTERVAL_MS,READ_INTERVALS,WORK_STEPS=8,1000,32,4096
local function plain(v)return type(v)=='table' and getmetatable(v)==nil end
function M.start(o)
    if not plain(o) or o.enabled~=true then return nil,'disabled'end
    if type(o.nonce)~='string' or #o.nonce~=32 or not o.nonce:match('^[0-9a-f]+$')
        or o.nonce==string.rep('0',32)then return nil,'invalid_nonce'end
    for _,k in ipairs({'resolve','schedule','cancel','emit'})do
        if type(o[k])~='function'then return nil,'invalid_provider'end
    end
    if not plain(o.clock_module) or type(o.clock_module.new)~='function'then return nil,'invalid_clock'end
    local nonce,resolve,schedule,cancel,emit=o.nonce,o.resolve,o.schedule,o.cancel,o.emit
    local ok,clock=pcall(o.clock_module.new,resolve)
    if not ok or not plain(clock)then return nil,'invalid_clock'end
    for _,k in ipairs({'begin','read','finish','close'})do
        if type(clock[k])~='function'then return nil,'invalid_clock'end
    end
    -- Capture the reviewed functions; changing the options/module cannot switch clocks.
    local begin,read,finish,revoke=clock.begin,clock.read,clock.finish,clock.close
    local diagnostics=type(clock.diagnostics)=="function" and clock.diagnostics or nil
    local handle,registering,busy,stopped,reported=nil,true,false,false,false
    local reason,samples,callbacks,started,previous=nil,0,0,nil,nil
    local observed,forward_intervals,within_advances=0,0,0
    local function record(status,why)
        return {nonce=nonce,status=status,reason=why,samples=samples,callbacks=callbacks,
            clock='GameplayStatics_GetAccurateRealTime',measurement='clock_under_test',
            elapsed_validated=false,total_callback_ms='unknown',resolver_ms='unknown',
            verified=false,active=false,storage_grant=false,authority_grant=false,coverage_grant=false}
    end
    local function report()
        if not stopped or busy or registering or reported then return end
        reported=true -- Cancel/emit callbacks must not recursively finalize.
        local yes,value=false,false
        if handle~=nil then yes,value=pcall(cancel,handle)end
        local out=record('finished',reason)
        if reason=='clock_unavailable' and diagnostics then
            local valid,detail=pcall(diagnostics)
            if valid and plain(detail) then
                for _,key in ipairs({'stage','seconds_type','partial_type','seconds_kind','partial_kind'})do
                    local value=detail[key]
                    if type(value)=='string' and #value<=32 and value:match('^[a-z_]+$') then
                        out['clock_'..key]=value
                    end
                end
            end
        end
        out.observed_samples=observed;out.forward_intervals=forward_intervals
        out.within_sample_advances=within_advances
        out.advancement_observed=reason=='sample_limit' and observed==MAX_SAMPLES and forward_intervals==MAX_SAMPLES-1
            and within_advances>0
        out.timer_cancelled=yes and value==true
        out.cancellation_attempted=handle~=nil
        pcall(emit,out)
    end
    local function stop(why)
        if not stopped then stopped=true;reason=why;pcall(revoke)end
        report()
    end
    local function tick()
        if stopped then return end
        if busy then stop('reentrant');return end
        busy=true;callbacks=callbacks+1;samples=samples+1
        local reads,began,last=0,nil,nil
        local ok,out=pcall(function()
            begin();assert(not stopped)
            local function now()
                assert(not stopped);local t=read();reads=reads+1
                assert(not stopped and type(t)=='number' and t==t and t>=0 and t<math.huge)
                assert(not last or t>=last);last=t
                return t
            end
            began=now();started=started or began
            if began-started>=60 then stop('elapsed_limit');return end
            local answer=record('observed','sample')
            answer.between_sample_ms=previous and math.min((began-previous)*1000,60000) or 'unknown'
            answer.between_sample_advanced=previous~=nil and began>previous
            previous=began
            local burst_end=began
            for _=1,READ_INTERVALS do
                burst_end=now()
                if burst_end-began>0.1 then stop('read_span_budget');return end
            end
            -- Fixed synchronous Lua work; no waiting, system APIs or native calls.
            local checksum=0
            for i=1,WORK_STEPS do checksum=(checksum+i)%65521 end
            local ended=now()
            if ended-began>0.1 then stop('read_span_budget');return end
            answer.reads=reads;answer.read_intervals=READ_INTERVALS;answer.work_steps=WORK_STEPS
            answer.checksum=checksum;answer.read_burst_ms=(burst_end-began)*1000
            answer.mean_read_interval_ms=answer.read_burst_ms/READ_INTERVALS
            answer.work_and_final_read_ms=(ended-burst_end)*1000
            answer.within_sample_advanced=ended>began
            answer.first_to_last_read_ms=(ended-began)*1000
            return answer
        end)
        local cleaned=pcall(finish) -- Always drop callback-local CDO before emission.
        if not ok or not cleaned then stop('clock_unavailable')end
        if not stopped and out then
            observed=observed+1
            if out.between_sample_advanced then forward_intervals=forward_intervals+1 end
            if out.within_sample_advanced then within_advances=within_advances+1 end
            if not pcall(emit,out)then stop('emit_failed')end
        end
        if not stopped and callbacks>=MAX_SAMPLES then
            stop(forward_intervals~=MAX_SAMPLES-1 and 'no_between_sample_advancement'
                or within_advances==0 and 'no_within_sample_advancement' or 'sample_limit')
        end
        busy=false;report()
    end
    local scheduled,value=pcall(schedule,INTERVAL_MS,tick)
    -- Timer contract: a non-nil/non-false opaque handle, including integer zero.
    if scheduled and value~=nil and value~=false then handle=value end
    registering=false
    if handle==nil then stop('timer_unavailable')else report()end
    return {close=function()stop('closed')end}
end
return M
