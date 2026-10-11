-- Bounded one-shot runner. All engine wrappers stay inside sample().
local M={}
function M.start(api)
    local handle,finished,running,pending=nil,false,false,nil
    local started=api.wall()
    local samples,stable,key=0,nil,nil
    local function terminal(reason)
        local ok,cancelled=pcall(api.cancel,handle)
        pcall(api.emit,{status=ok and cancelled==true and reason or 'cancel_failed',
            samples=samples,timer_cancelled=ok and cancelled==true,
            verified=false,active=false,storage_grant=false})
    end
    local function stop(reason)
        if finished then return end
        finished=true
        if handle then terminal(reason) else pending=reason end
    end
    local function tick()
        if finished or running then return end
        running=true
        local ok=pcall(function()
            local t=api.wall()
            if t<started or t-started>=60 then stop('time_limit');return end
            if samples>=60 then stop('sample_limit');return end
            samples=samples+1
            local before=api.clock()
            local out=api.sample()
            assert(out.verified==false and out.active==false and out.storage_grant==false)
            api.emit(out)
            local after=api.wall()
            if api.clock()-before>0.1 then stop('slow_sample');return end
            if after<t or after-started>=60 then stop('time_limit');return end
            if samples>=60 then stop('sample_limit');return end
            if out.status=='context_agrees' then
                local nextkey=table.concat({out.directory,out.project_saved,out.world_address,
                    out.state_address,out.instance_address,out.manager_address,tostring(out.loaded_world)},'|')
                if key~=nextkey then key,stable=nextkey,after end
                if after-stable>=10 then stop('observation_complete') end
            else key,stable=nil,nil end
        end)
        running=false
        if not ok then stop('sample_failed') end
    end
    local ok,value=pcall(api.schedule,1000,tick)
    handle=ok and value or nil
    if not handle then
        finished=true
        pcall(api.emit,{status='timer_unavailable',samples=samples,timer_cancelled=false,
            verified=false,active=false,storage_grant=false})
    elseif pending then terminal(pending) end
end
return M
