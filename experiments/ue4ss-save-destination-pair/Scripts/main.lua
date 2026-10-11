-- One-shot passive callback observation. Never invokes a save/load function.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/Scripts/main.lua$'))
local f=io.open(root..'/run.txt','r');if not f then return end
local request=f:read('*a');f:close()
local nonce=request and request:match('^PWP_DESTINATION_PAIR_RUN ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
f=assert(io.open(root..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local Identity=dofile(root..'/experiments/save_identity_probe.lua')
local Destination=dofile(root..'/experiments/save_destination_probe.lua')
local finished,handle,events,last=false,nil,{},nil
local started=os.time()
local registered={destination=false,notification=false}
local counts={destination=0,notification=0}
local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP destination pair '..nonce..' '..message
    print(line..'\n')
    local file=assert(io.open(root..'/destination-pair.log','a'))
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
local function receive(lane,slot,success,world)
    if finished or not registered[lane] or counts[lane]>=4 then return end
    local out
    if lane=='destination' then
        local ok,value=pcall(Destination.read,copy_arg(slot,'string'),
            copy_arg(success,'boolean'),copy_arg(world,'string'))
        out=ok and value or {state='classifier_failed',verified=false}
    else
        local value=copy_arg(success,'boolean')
        out={state='notification_only',success_status=type(value)=='boolean' and 'read' or 'unavailable',
            success=value,verified=false}
    end
    out.lane=lane
    counts[lane]=counts[lane]+1
    events[#events+1]=out
end
registered.destination=pcall(function()
    RegisterHook('/Script/Pal.PalSaveGameManager:OnFinishedWorldAsyncSaveGamePreInternal',
        function(_,slot,_,success,world) receive('destination',slot,success,world) end)
end)
registered.notification=pcall(function()
    RegisterHook('/Script/Pal.PalStaticLogCollector:OnEndedWorldAutoSave',
        function(_,success) receive('notification',nil,success,nil) end)
end)
if not pcall(report,'REGISTERED destination='..tostring(registered.destination)..' notification='..tostring(registered.notification)) then
    stop('FAIL registration report unavailable');return
end
if not registered.destination and not registered.notification then stop('HOOKS_UNAVAILABLE');return end
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
                local pending=events;events={}
                for _,event in ipairs(pending) do
                    local fields={}
                    for _,key in ipairs({'lane','state','success_status','success','slot_status',
                        'slot_candidate','world_status','world_candidate','verified'}) do
                        fields[#fields+1]=key..'='..tostring(event[key])
                    end
                    report('CALLBACK '..table.concat(fields,' | '))
                end
            end
            if counts.destination>0 and counts.notification>0 and #events==0 then
                stop('OBSERVATION_COMPLETE both lanes observed; not correlated or session-verified')
            elseif os.time()-started>=420 then
                stop('TIMEOUT destination='..tostring(counts.destination)..' notification='..tostring(counts.notification))
            end
        end)
        if not ok then stop('FAIL observation unavailable') end
    end)
end)
handle=result
if not timer_ok or not handle then handle=nil;stop('TIMER_UNAVAILABLE') end
