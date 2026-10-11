-- One-shot runtime root observation. Enable this diagnostic only for the trial.
-- No trigger, disk reads, save/load calls, enumeration, or production binding.
-- Only IO is append-only root.log. The path below is DERIVED, never opened.
-- UE5.1 KismetSystemLibrary.cpp: GetProjectSavedDirectory returns
-- ConvertRelativePathToFull(FPaths::ProjectSavedDir()). Backend overrides remain
-- unproven; this observation never grants authority or proves file absence.
local source=debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
local root=assert(source:match('^(.*)/Scripts/main.lua$'))
local slot='PWP_AsyncDev_v1_88888888888888888888888888888888_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee_p_B'
local cdo_path='/Script/Engine.Default__KismetSystemLibrary'
local handle,finished,running,pending=nil,false,false,nil
local attempts=0

local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP saved-root '..message..'\n'
    local f=assert(io.open(root..'/root.log','a'))
    local wrote,ok=pcall(function() return f:write(line) end)
    local closed,done=pcall(function() return f:close() end)
    assert(wrote and ok and closed and done,'log failed')
    print(line)
end
local function emit_terminal(reason)
    local ok,cancelled=pcall(CancelDelayedAction,handle)
    local cancelled_ok=ok and cancelled==true
    local message=(cancelled_ok and reason or 'FAIL cancellation')
        ..' timer_cancelled='..tostring(cancelled_ok)..' verified=false'
    if not pcall(report,message) then
        pcall(print,'PWP saved-root FAIL terminal_log verified=false\n')
    end
end
local function stop(reason)
    finished=true
    if handle then emit_terminal(reason) else pending=reason end
end
local function safe_slot(value)
    if type(value)~='string' then return false end
    local storage,guild=value:match('^PWP_AsyncDev_v1_([0-9a-f]+)_([0-9a-f]+)_[pl]_[AB]$')
    return storage~=nil and #storage==32 and #guild==32
        and storage~=string.rep('0',32) and guild~=string.rep('0',32)
end
local function copied_root(value)
    if type(value)~='string' then value=value:ToString() end
    if type(value)~='string' or #value==0 or #value>2048 then return end
    value=value:gsub('\\','/')
    -- Deliberately narrow Windows drive-absolute grammar. UNC/device roots are
    -- unsupported, not missing. Reject aliases/traversal and log delimiters.
    if not value:match('^[A-Za-z]:/') or value:find('//',1,true) then return end
    local tail=value:sub(4)
    if tail=='' or tail:find('[%c<>:"|?*]') then return end
    for component in tail:gmatch('[^/]+') do
        if component=='.' or component=='..' or component:find('[ .]$') then return end
    end
    return value:gsub('/$','')..'/'
end
local function sample()
    attempts=attempts+1
    -- Resolve anew each callback; retain only copied strings and counters.
    local cdo=StaticFindObject(cdo_path)
    if cdo==nil or not cdo:IsValid() then
        if attempts>=30 then stop('FAIL cdo_unavailable attempts=30') end
        return
    end
    assert(cdo:GetFullName()=='KismetSystemLibrary '..cdo_path,'unexpected CDO')
    local saved=copied_root(cdo:GetProjectSavedDirectory())
    if not saved then stop('FAIL unsupported_root');return end
    local destination=saved..'SaveGames/'..slot..'.sav'
    report('ROOT_OBSERVED attempt='..attempts..' project_saved='..saved
        ..' | slot='..slot..' | derived_file='..destination
        ..' | file_checked=false | mapping_verified=false | verified=false')
    stop('OBSERVATION_COMPLETE')
end

assert(safe_slot(slot),'invalid development slot')
if not pcall(report,'START observation_only=true verified=false') then return end
local ok,result=pcall(function()
    assert(type(LoopInGameThreadWithDelay)=='function' and type(CancelDelayedAction)=='function')
    return LoopInGameThreadWithDelay(1000,function()
        if finished or running then return end
        running=true
        local success=pcall(sample)
        running=false
        if not success then stop('FAIL observation_or_log') end
    end)
end)
handle=ok and result or nil
if not handle then
    finished=true
    if not pcall(report,'FAIL timer_unavailable timer_cancelled=false verified=false') then
        pcall(print,'PWP saved-root FAIL timer_unavailable verified=false\n')
    end
elseif pending then emit_terminal(pending) end
