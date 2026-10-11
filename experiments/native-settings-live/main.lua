-- One-shot disposable typed-settings trial. Does not read player settings.
local dir=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/'):match('^(.*)/main.lua$'))
local f=io.open(dir..'/run.txt','r');if not f then return end
local marker,extra=f:read(160),f:read(1);assert(f:close())
local mode,nonce
if not extra and marker then mode,nonce=marker:match('^(PWP_SETTINGS_%u+) ([%w%-]+)%s*$') end
if mode~='PWP_SETTINGS_TRIAL' and mode~='PWP_SETTINGS_RECOVERY' then return end
if not nonce or #nonce>64 then return end
f=assert(io.open(dir..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
package.path=dir..'/?.lua;'..package.path
local function json(value,depth)
    depth=depth or 0;assert(depth<12,'log nesting')
    local kind=type(value)
    if kind=='boolean' then return tostring(value) end
    if kind=='number' then assert(value==value and value>-math.huge and value<math.huge);return tostring(value) end
    if kind=='string' then
        return '"'..value:gsub('[%z\1-\31\\"]',function(c)return string.format('\\u%04x',c:byte())end)..'"'
    end
    assert(kind=='table' and getmetatable(value)==nil,'log scalar/table only')
    local out={}
    if #value>0 then
        for i,v in ipairs(value) do out[i]=json(v,depth+1) end
        return '['..table.concat(out,',')..']'
    end
    local keys={};for k in pairs(value) do assert(type(k)=='string');keys[#keys+1]=k end
    table.sort(keys)
    for _,k in ipairs(keys) do out[#out+1]=json(k,depth+1)..':'..json(value[k],depth+1) end
    return '{'..table.concat(out,',')..'}'
end
local stopped=false
local function report(event)
    local row=json({nonce=nonce,utc=os.date('!%Y-%m-%dT%H:%M:%SZ'),data=event})
    assert(#row<=600000,'log bound')
    local out=assert(io.open(dir..'/settings-trial.jsonl','a'))
    assert(out:write(row..'\n'));assert(out:close())
end
local function safe(fn)
    return function()
        if stopped then return end
        local ok,err=pcall(fn)
        if not ok then
            stopped=true
            pcall(report,{event='bootstrap-failed',reason=tostring(err):sub(1,1000),owners_retained=true})
        end
    end
end
report{event='armed',delay_ms=90000,synthetic=true,production_modified=false,recovery_only=mode=='PWP_SETTINGS_RECOVERY'}
ExecuteInGameThreadWithDelay(90000,safe(function()
    local Adapter=dofile(dir..'/experiments/save_native_backend.lua')
    local Trial=dofile(dir..'/experiments/native_settings_trial.lua')
    local native=assert(package.loadlib(dir..'/pwp_settings_bridge.dll','luaopen_pwp_settings_bridge'))
    local configured=Adapter.call(native,0,0,0,{})
    assert(configured[1]==1 and Adapter.unpack(configured[2],1)[1]=='1','fixed root configuration')
    report{event='configured',game=configured[3],start=configured[4],finish=configured[5],frequency=configured[6]}
    local trial=Trial.new{native=native,game_thread=configured[3],boot=nonce,clock=os.clock,report=report,
        recovery_only=mode=='PWP_SETTINGS_RECOVERY',
        schedule=function(fn) ExecuteAsync(fn) end,
        resume=function(fn) ExecuteInGameThread(fn) end}
    assert(trial:start(),'trial start')
    local poll
    poll=safe(function()
        trial:poll()
        local state=trial:status()
        if state.state=='passed' or state.state=='failed' then
            report{event='stopped',state=state.state,phase=state.phase,reason=state.reason}
            stopped=true;return
        end
        ExecuteInGameThreadWithDelay(100,poll)
    end)
    ExecuteInGameThreadWithDelay(100,poll)
end))
