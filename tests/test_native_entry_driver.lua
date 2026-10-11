local p=TEST_ROOT..'/experiments/native-lua-entry-probe/Scripts/main.lua'
local f=assert(io.open(p));local code=f:read('*a');f:close()
local function trial(mode)
    local armed='PWP_ENTRY_PROBE test-nonce\n'
    local logs,calls,loaded={},0,0
    local env=setmetatable({}, {__index=_G})
    env.debug={getinfo=function() return {source='@C:/probe/Scripts/main.lua'} end}
    env.io={open=function(path,how)
        if path:match('run.txt$') then
            if how=='r' then return {read=function() return mode=='disabled' and 'DISABLED' or armed end,close=function() return true end} end
            return {write=function(_,v) if mode=='disarm' then return nil end;armed=v;return true end,close=function() return true end}
        end
        assert(path=='C:/probe/entry.log' and how=='a')
        return {write=function(_,v) logs[#logs+1]=v;return true end,close=function() return true end}
    end}
    env.print=function() end
    env.package={loadlib=function(path,symbol)
        assert(armed=='DISABLED\n');assert(path=='C:/probe/Scripts/pwp_entry_probe.dll');assert(symbol=='luaopen_pwp_entry_probe')
        loaded=loaded+1
        if mode=='loader' then return nil,'blocked' end
        return function()
            calls=calls+1
            if mode=='extra' then return 2281,1 end
            if mode=='wrong' then return 99 end
            if mode=='throw' then error('native simulated exception') end
            return 2281
        end
    end}
    local ran=pcall(assert(load(code,'@driver','t',env)))
    local output=table.concat(logs)
    if mode=='disabled' then assert(loaded==0 and #logs==0)
    elseif mode=='disarm' then assert(not ran and loaded==0)
    elseif mode=='ok' then assert(ran and calls==1000 and output:find('PASS calls=1000',1,true))
    else assert(ran and output:find('FAIL',1,true) and not output:find('PASS',1,true)) end
end
for _,mode in ipairs({'disabled','disarm','loader','extra','wrong','throw','ok'}) do trial(mode) end
print('native entry driver: 7 mock cases passed; no DLL loaded')
