-- Disposable native-drain trial, plus a bounded READ-ONLY exit observer.
local dir=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/'):match('^(.*)/main.lua$'))
local f=io.open(dir..'/run.txt','r');if not f then return end
local marker,extra=f:read(160),f:read(1);assert(f:close())
local nonce=not extra and marker and marker:match('^PWP_DRAIN_TRIAL ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
f=assert(io.open(dir..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
package.path=dir..'/?.lua;'..package.path
local function json(value,depth)
    depth=depth or 0;assert(depth<12)
    local t=type(value)
    if t=='boolean' then return tostring(value) end
    if t=='number' then assert(value==value and value>-math.huge and value<math.huge);return tostring(value) end
    if t=='string' then return '"'..value:gsub('[%z\1-\31\\"]',function(c)return string.format('\\u%04x',c:byte())end)..'"' end
    assert(t=='table' and getmetatable(value)==nil)
    local out={}
    if #value>0 then for _,v in ipairs(value)do out[#out+1]=json(v,depth+1)end;return '['..table.concat(out,',')..']' end
    local keys={};for k in pairs(value)do assert(type(k)=='string');keys[#keys+1]=k end;table.sort(keys)
    for _,k in ipairs(keys)do out[#out+1]=json(k,depth+1)..':'..json(value[k],depth+1)end
    return '{'..table.concat(out,',')..'}'
end
local function report(event)
    local line=json{nonce=nonce,utc=os.date('!%Y-%m-%dT%H:%M:%SZ'),data=event}
    assert(#line<=600000)
    local out=assert(io.open(dir..'/drain-trial.jsonl','a'))
    assert(out:write(line..'\n'));assert(out:close())
end
local Observer=dofile(dir..'/experiments/save_exit_observer.lua')
local observer=Observer.new{enabled=true,register=RegisterEndPlayPreHook,clock=os.clock,
    report=function(event)report{event='exit-observation',observation=event,drain_called=false}end}
local installed=observer:install()
report{event='armed',synthetic=true,delay_ms=90000,exit_observer_installed=installed==true}
local stopped=false
local function safe(fn)
    return function()
        if stopped then return end
        local ok,why=pcall(fn)
        if not ok then stopped=true;pcall(report,{event='bootstrap-failed',reason=tostring(why):sub(1,1000),owners_retained=true}) end
    end
end
ExecuteInGameThreadWithDelay(90000,safe(function()
    local Wire=dofile(dir..'/experiments/save_native_backend.lua')
    local Trial=dofile(dir..'/experiments/native_draining_trial.lua')
    local native=assert(package.loadlib(dir..'/pwp_draining_bridge.dll','luaopen_pwp_draining_bridge'))
    local r=Wire.call(native,0,0,0,{})
    assert(r[1]==1 and Wire.unpack(r[2],1)[1]=='1','root configuration failed')
    report{event='configured',game=r[3],frequency=r[6]}
    local trial=Trial.new{native=native,game_thread=r[3],boot=nonce,report=report,clock=os.clock}
    assert(trial:start(),'trial start failed')
    local poll
    poll=safe(function()
        trial:poll();local state=trial:status()
        if state.state=='passed' or state.state=='failed' then
            stopped=true;report{event='stopped',state=state.state,phase=state.phase,reason=state.reason};return
        end
        ExecuteInGameThreadWithDelay(100,poll)
    end)
    ExecuteInGameThreadWithDelay(100,poll)
end))
