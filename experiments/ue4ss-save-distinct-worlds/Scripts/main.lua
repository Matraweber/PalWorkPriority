-- Property-only observation. NEVER a storage authorization or save writer.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/'):match('^(.*)/Scripts/main.lua$'))
local f=io.open(root..'/run.txt','r');if not f then return end
local request=f:read(128);local extra=f:read(1);assert(f:close())
local nonce=not extra and request and request:match('^PWP_DISTINCT_WORLDS ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
f=assert(io.open(root..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local World=dofile(root..'/experiments/save_world_identity_probe.lua')
local Identity=dofile(root..'/experiments/save_identity_probe.lua')
local started,phase,stable,last,first=os.time(),1,nil,nil,nil
local handle,finished
local function log(text)
    local file=assert(io.open(root..'/distinct.log','a'))
    assert(file:write(os.date('!%Y-%m-%dT%H:%M:%SZ ')..nonce..' '..text..'\n'));assert(file:close())
end
local function stop(text)
    if finished then return end;finished=true
    local ok,result=pcall(function() return handle and CancelDelayedAction(handle) end)
    log(text..' timer_cancelled='..tostring(ok and result==true)..' verified=false')
end
log('ARMED property-only A-title-B-title-A; no storage grant')
handle=LoopInGameThreadWithDelay(1000,function()
    if finished then return end
    local ok,err=pcall(function()
        if os.time()-started>1800 then stop('TIMEOUT incomplete');return end
        local engine=require('UEHelpers').GetEngine()
        local w,i=World.read(engine),Identity.read(engine)
        local parts={}
        for _,key in ipairs({'world','directory','role','dedicated'}) do parts[#parts+1]=key..'='..tostring(w[key]) end
        for _,key in ipairs({'selected','loaded_world','context_status','world_address','instance_address','manager_address'}) do parts[#parts+1]=key..'='..tostring(i[key]) end
        local sample=table.concat(parts,' | ')
        if sample~=last then log('SAMPLE '..sample);last=sample;stable=nil end
        local title=w.world=='World /Game/Pal/Maps/Title/PL_Title.PL_Title' and i.world==w.world
            and i.loaded_status=='read' and i.loaded_world==false
        local host=w.status=='observed' and w.directory_status=='format_valid' and w.role_status=='read'
            and w.role==3 and w.dedicated_status=='read' and w.dedicated==false
            and i.world==w.world and i.loaded_status=='read' and i.loaded_world==true
            and i.selected_status=='format_valid' and i.selected==w.directory
            and i.context_status=='context_agrees'
        if phase==2 or phase==4 then
            if title then log('TITLE boundary='..phase);phase=phase+1;stable=nil end
        elseif host then
            local expected=phase==1 or (phase==3 and w.directory~=first) or (phase==5 and w.directory==first)
            if not expected then stable=nil;return end
            stable=stable or os.time()
            if os.time()-stable>=5 then
                if phase==1 then first=w.directory end
                log('HOST phase='..phase..' directory='..w.directory..' world_address='..tostring(i.world_address)..' verified=false')
                if phase==5 then stop('OBSERVATIONS_COMPLETE distinct local return');return end
                phase=phase+1;stable=nil
            end
        else stable=nil end
    end)
    if not ok then pcall(stop,'FAIL '..tostring(err)) end
end)
if not handle then stop('FAIL timer unavailable') end
