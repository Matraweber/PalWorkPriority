-- One-shot passive callback observation. Never invokes a save/load function.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/Scripts/main.lua$'))
local f=io.open(root..'/run.txt','r');if not f then return end
local request=f:read('*a');f:close()
local nonce=request and request:match('^PWP_DESTINATION_RUN ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
f=assert(io.open(root..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local Identity=dofile(root..'/experiments/save_identity_probe.lua')
local Destination=dofile(root..'/experiments/save_destination_probe.lua')
local finished,handle,events,last=false,nil,{},nil
local started=os.time()
local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP destination '..nonce..' '..message
    print(line..'\n')
    local file=assert(io.open(root..'/destination.log','a'))
    assert(file:write(line..'\n'));assert(file:close())
end
local function stop(reason)
    if finished then return end
    finished=true
    local ok,result=pcall(function() return handle and CancelDelayedAction(handle) end)
    -- A broken diagnostic sink must not escape into an engine callback.
    pcall(report,reason..' timer_cancelled='..tostring(ok and result==true))
end
local function copy_arg(param,kind)
    local ok,value=pcall(function()
        local v=param
        if type(v)~=kind then v=v:get() end
        if kind=='string' and type(v)~='string' then v=v:ToString() end
        if type(v)==kind and (kind~='string' or #v<=1024) then return v end
    end)
    if ok then return value end
end
report('ARM_CONSUMED passive callback entry observation; no persistence calls')
local hooked=pcall(function()
    RegisterHook('/Script/Pal.PalSaveGameManager:OnFinishedWorldAsyncSaveGameInternal',
        function(_,slot,_,success,world)
            if finished or #events>=4 then return end
            -- No Engine reads, file IO or retained wrappers in the hook. Its
            -- calling thread and relationship to the current session are unproven.
            local ok,out=pcall(Destination.read,copy_arg(slot,'string'),
                copy_arg(success,'boolean'),copy_arg(world,'string'))
            events[#events+1]=ok and out or {state='classifier_failed',verified=false}
        end)
end)
if not hooked then stop('HOOK_UNAVAILABLE');return end
local timer_ok,result=pcall(function()
    return LoopInGameThreadWithDelay(1000,function()
        if finished then return end
        local ok=pcall(function()
            local observation=Identity.read(require('UEHelpers').GetEngine())
            local parts={}
            for _,key in ipairs({'world','selected','loaded_status','loaded_world','verified'}) do
                parts[#parts+1]=key..'='..tostring(observation[key])
            end
            local current=table.concat(parts,' | ')
            if current~=last then report('SAMPLE '..current);last=current end
            if #events>0 then
                for _,event in ipairs(events) do
                    local fields={}
                    for _,key in ipairs({'state','success_status','success','slot_status',
                        'slot_candidate','world_status','world_candidate','verified'}) do
                        fields[#fields+1]=key..'='..tostring(event[key])
                    end
                    report('CALLBACK '..table.concat(fields,' | '))
                end
                stop('OBSERVATION_COMPLETE callback not session-verified')
            elseif os.time()-started>=300 then stop('TIMEOUT no callback observed') end
        end)
        if not ok then stop('FAIL observation unavailable') end
    end)
end)
handle=result
if not timer_ok or not handle then handle=nil;stop('TIMER_UNAVAILABLE') end
