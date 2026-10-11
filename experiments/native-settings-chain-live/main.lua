-- One-shot full settings-chain test. No player settings are attached.
local dir=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/'):match('^(.*)/main.lua$'))
local f=io.open(dir..'/run.txt','r');if not f then return end
local marker,extra=f:read(160),f:read(1);assert(f:close())
local mode,nonce
if not extra and marker then mode,nonce=marker:match('^PWP_SETTINGS_CHAIN (WRITE) ([%w%-]+)%s*$')
    if not mode then mode,nonce=marker:match('^PWP_SETTINGS_CHAIN (RECOVER) ([%w%-]+)%s*$') end
end
local recovery_only=mode=='RECOVER'
if not nonce or #nonce>64 then return end
f=assert(io.open(dir..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
package.path=dir..'/?.lua;'..package.path
local function json(v,depth)
    depth=depth or 0;assert(depth<12)
    local t=type(v)
    if t=='boolean' then return tostring(v) end
    if t=='number' then assert(v==v and v>-math.huge and v<math.huge);return tostring(v) end
    if t=='string' then return '"'..v:gsub('[%z\1-\31\\"]',function(c)return string.format('\\u%04x',c:byte())end)..'"' end
    assert(t=='table' and getmetatable(v)==nil)
    local out={}
    if #v>0 then for _,x in ipairs(v)do out[#out+1]=json(x,depth+1)end;return '['..table.concat(out,',')..']' end
    local keys={};for k in pairs(v)do assert(type(k)=='string');keys[#keys+1]=k end;table.sort(keys)
    for _,k in ipairs(keys)do out[#out+1]=json(k,depth+1)..':'..json(v[k],depth+1)end
    return '{'..table.concat(out,',')..'}'
end
local function report(event)
    local line=json{nonce=nonce,utc=os.date('!%Y-%m-%dT%H:%M:%SZ'),data=event}
    assert(#line<=600000)
    local out=assert(io.open(dir..'/settings-chain-trial.jsonl','a'))
    assert(out:write(line..'\n'));assert(out:close())
end
local stopped,quit_seen,trial=false,false,nil
local function fail(why)
    stopped=true
    pcall(report,{event='bootstrap-failed',reason=tostring(why):sub(1,1000),owners_retained=true})
end
local function safe(fn)
    return function()
        if stopped then return end
        local ok,why=pcall(fn);if not ok then fail(why) end
    end
end
-- Registration may retain a callback before throwing. Poison all captured
-- callbacks on startup failure, including a scheduler that queues then fails.
safe(function()
assert(type(RegisterEndPlayPreHook)=='function','Quit hook unavailable')
local registration=RegisterEndPlayPreHook(function(_,param)
    if stopped or quit_seen then return end
    local ok,reason=pcall(function()return param:get()end)
    if not ok or math.type(reason)~='integer' or reason<0 or reason>4 then fail('invalid EndPlay reason');return end
    if reason~=4 then return end
    quit_seen=true -- one attempt; never retain the actor or reason wrapper
    safe(function()
        assert(trial,'Quit before trial initialized')
        trial:quit(reason)
        local s=trial:status()
        report{event='stopped',state=s.state,phase=s.phase,reason=s.reason}
        stopped=true
    end)()
end)
assert(registration~=false,'Quit hook registration refused') -- pinned API normally returns nil
report{event='armed',synthetic=true,recovery_only=recovery_only,delay_ms=90000,exit_hook_installed=true}
assert(ExecuteInGameThreadWithDelay(90000,safe(function()
    local Wire=dofile(dir..'/experiments/save_native_backend.lua')
    local Trial=dofile(dir..'/experiments/native_settings_chain_trial.lua')
    local native=assert(package.loadlib(dir..'/pwp_draining_bridge.dll','luaopen_pwp_draining_bridge'))
    local r=Wire.call(native,0,0,0,{})
    assert(r[1]==1 and Wire.unpack(r[2],1)[1]=='1','root configuration failed')
    report{event='configured',game=r[3],frequency=r[6]}
    trial=Trial.new{native=native,game_thread=r[3],boot=nonce,report=report,clock=os.clock,recovery_only=recovery_only}
    assert(trial:start(),'trial start failed')
    local poll
    poll=safe(function()
        trial:poll();local s=trial:status()
        if s.state=='ready' then return end
        if s.state=='failed' or s.state=='passed' then stopped=true;report{event='stopped',state=s.state,phase=s.phase,reason=s.reason};return end
        assert(ExecuteInGameThreadWithDelay(100,poll)~=false,'poll scheduling refused')
    end)
    assert(ExecuteInGameThreadWithDelay(100,poll)~=false,'poll scheduling refused')
end))~=false,'startup scheduling refused')
end)()
