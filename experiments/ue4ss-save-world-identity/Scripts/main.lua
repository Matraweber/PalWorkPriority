-- Isolated, armed once; property reads only, no save/load invocation.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/Scripts/main.lua$'))
local f=io.open(root..'/run.txt','r');if not f then return end
local request=f:read('*a');f:close()
local nonce=request and request:match('^PWP_WORLD_IDENTITY_RUN ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
f=assert(io.open(root..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local Probe=dofile(root..'/experiments/save_world_identity_probe.lua')
local Identity=dofile(root..'/experiments/save_identity_probe.lua')
local finished,handle,last=false,nil,nil
local started,samples,stable=os.time(),0,nil
local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP world identity '..nonce..' '..message
    print(line..'\n')
    local file=assert(io.open(root..'/world-identity.log','a'))
    assert(file:write(line..'\n'));assert(file:close())
end
local function stop(reason)
    if finished then return end
    finished=true
    local ok,result=pcall(function() return handle and CancelDelayedAction(handle) end)
    pcall(report,reason..' samples='..samples..' timer_cancelled='..tostring(ok and result==true))
end
if not pcall(report,'ARM_CONSUMED property-only; interval=1000ms world-scoped field; verified=false') then return end
local ok,result=pcall(function()
    return LoopInGameThreadWithDelay(1000,function()
        if finished then return end
        local success=pcall(function()
            if os.time()-started>=180 or samples>=180 then stop('COMPLETE');return end
            local engine=require('UEHelpers').GetEngine()
            local before=os.clock()
            local out=Probe.read(engine)
            local elapsed=(os.clock()-before)*1000
            local identity=Identity.read(engine)
            samples=samples+1
            local parts={}
            for _,key in ipairs({'status','world','directory_status','directory','role_status','role','dedicated_status','dedicated','verified'}) do
                parts[#parts+1]=key..'='..tostring(out[key])
            end
            for _,key in ipairs({'world','selected_status','selected','loaded_status','loaded_world'}) do
                parts[#parts+1]='instance_'..key..'='..tostring(identity[key])
            end
            local current=table.concat(parts,' | ')
            if current~=last then report('SAMPLE '..current);last=current;stable=nil end
            if out.status=='observed' and out.directory_status=='format_valid'
                and out.role_status=='read' and out.world~=nil and out.world==identity.world then
                stable=stable or os.time()
            else stable=nil end
            if out.status=='read_failed' then
                stop('UNSUPPORTED '..out.status)
            elseif elapsed>10 then
                stop('SLOW_READ elapsed_ms='..tostring(elapsed))
            elseif stable and os.time()-stable>=10 then
                stop('OBSERVATION_COMPLETE identity remains unverified')
            end
        end)
        if not success then stop('FAIL observation unavailable') end
    end)
end)
handle=result
if not ok or not handle then handle=nil;stop('TIMER_UNAVAILABLE') end
