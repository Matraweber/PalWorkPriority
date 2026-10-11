-- Synchronous fixture observation only; no acceptance decision or write grant.
local M={}
local used=false
local MAX_BODY=262144
local function token(v,n)
    return type(v)=='string' and #v>0 and #v<=n and v:match('^[A-Za-z0-9_-]+$')~=nil
end
local function valid(o)
    if type(o)~='table' or getmetatable(o)~=nil then return false end
    if not token(o.nonce,64) or (o.phase~='fenced' and o.phase~='recovered') then return false end
    local root=o.root
    if type(root)~='string' or #root>1024 or root:sub(-1)~='/'
        or root:find('[%c\\]') or not (root:match('^[A-Za-z]:/') or root:sub(1,1)=='/')
        or root:find('//',1,true) then return false end
    for part in root:gmatch('[^/]+') do if part=='.' or part=='..' then return false end end
    return o.production==root..'Scripts/production_main.lua'
end
local function hex(s)
    return (s:gsub('.',function(c)return string.format('%02x',string.byte(c))end))
end
function M.run(o)
    if not valid(o) then return nil,'invalid_options' end
    if used then return nil,'already_invoked' end
    used=true -- Includes failed and reentrant attempts; never replay production.
    local original_io,open,emit,entry=io,io.open,print,dofile
    local settings,trial={},{}
    for _,name in ipairs({'priorities.txt','caps.txt'}) do
        for _,suffix in ipairs({'','.tmp','.pending','.bak'}) do settings[o.root..name..suffix]=true end
    end
    trial[o.root..'async-trial/launch.lua']=true
    trial[o.root..'async-trial/receipt.lua']=true
    local settings_opens,trial_opens=0,0
    original_io.open=function(path,...)
        if type(path)=='string' then
            if settings[path] then settings_opens=settings_opens+1 end
            if trial[path] then trial_opens=trial_opens+1 end
        end
        return open(path,...)
    end
    local loaded=pcall(entry,o.production)
    original_io.open=open -- Restore before inspecting modules, even if entry threw.
    local out={nonce=o.nonce,phase=o.phase,loaded=loaded,gate='unknown',gate_blocked='unknown',
        priority_state='unknown',limit_state='unknown',settings_opens=settings_opens,
        trial_opens=trial_opens,priority_hex='',limit_hex='',error='none'}
    local ok=pcall(function()
        local gate=package.loaded.settings_gate
        if type(gate)=='table' then
            local status,blocked=gate.status(),gate.blocked()
            if token(status,32) then out.gate=status end
            if type(blocked)=='boolean' then out.gate_blocked=blocked end
        end
        local store,caps=package.loaded.store,package.loaded.caps
        if type(store)=='table' and token(store.state,32) then out.priority_state=store.state end
        if type(caps)=='table' and token(caps.state,32) then out.limit_state=caps.state end
        if not loaded then return end
        if type(store)~='table' or type(caps)~='table' then error('missing_modules',0) end
        local priority,limit=store.serialize(),caps.serialize()
        if type(priority)~='string' or type(limit)~='string'
            or #priority>MAX_BODY or #limit>MAX_BODY then error('invalid_body',0) end
        out.priority_hex,out.limit_hex=hex(priority),hex(limit)
    end)
    if not loaded then out.error='entry_failed'
    elseif not ok then out.error='observation_failed' end
    if not loaded or not ok then out.priority_hex='';out.limit_hex='' end
    local fields={'nonce','phase','loaded','gate','gate_blocked','priority_state','limit_state',
        'settings_opens','trial_opens','priority_hex','limit_hex','error'}
    local line={'PWP_CUTOVER_NATIVE'}
    for _,key in ipairs(fields)do line[#line+1]=key..'='..tostring(out[key])end
    emit(table.concat(line,'\t')..'\n')
    return out
end
return M
