-- One-shot, property-only identity observation. No save/load or storage binding.
local source=debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
local root=assert(source:match('^(.*)/Scripts/main.lua$'))
local f=io.open(root..'/run.txt','r');if not f then return end
local request=f:read('*a');f:close()
local nonce=request and request:match('^PWP_IDENTITY_RUN ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
f=assert(io.open(root..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local Probe=dofile(root..'/experiments/save_identity_probe.lua')
local started,handle,finished,last,gameplay=os.time(),nil,false,nil,nil
local target='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP identity '..nonce..' '..message
    print(line..'\n')
    local file=assert(io.open(root..'/identity.log','a'))
    assert(file:write(line..'\n'));assert(file:close())
end
local function stop(reason)
    finished=true
    local cancelled=handle and CancelDelayedAction(handle)==true
    report(reason..' timer_cancelled='..tostring(cancelled))
end
report('ARM_CONSUMED observation only; no persistence calls')
handle=LoopInGameThreadWithDelay(1000,function()
    if finished then return end
    local ok,err=pcall(function()
        local elapsed=os.time()-started
        if elapsed>240 then stop('TIMEOUT observations incomplete');return end
        local out=Probe.read(require('UEHelpers').GetEngine())
        local parts={}
        for _,key in ipairs({'world','state','selected_status','selected','autosave_status','autosave','loaded_status','loaded_world','verified'}) do
            parts[#parts+1]=key..'='..tostring(out[key])
        end
        local observation=table.concat(parts,' | ')
        if observation~=last then report('SAMPLE '..observation);last=observation end
        if out.world==target then
            gameplay=gameplay or os.time()
            if os.time()-gameplay>=10 then
                report('FINAL '..observation)
                stop('OBSERVATION_COMPLETE identity remains unverified')
            end
        else gameplay=nil end
    end)
    if not ok then stop('FAIL '..tostring(err)) end
end)
assert(handle,'timer unavailable')
