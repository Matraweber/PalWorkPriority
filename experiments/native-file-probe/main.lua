-- Disposable fixed-root publication only. No production settings or UObject calls.
local source=debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
local dir=assert(source:match('^(.*)/main.lua$'))
local f=io.open(dir..'/run.txt','r'); if not f then return end
local request,extra=f:read(128),f:read(1); assert(f:close())
local nonce=not extra and request and request:match('^PWP_FILE_PROBE ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
local stopped,generation=false,nil
local function log(kind,message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..nonce..' '..kind..' '..message
    local out=assert(io.open(dir..'/file.log','a'))
    assert(out:write(line..'\n'));assert(out:close()); print(line..'\n')
end
local function fail(message)
    if stopped then return end
    stopped=true
    if generation then generation.active=false end
    local ok,err=pcall(log,'FAIL',tostring(message))
    if not ok then print(nonce..' FAIL log error '..tostring(err)..'\n') end
end
local function current()
    if stopped then return false end
    if not generation or not generation.active or _G.PWP_FILE_GENERATION~=generation then
        fail('stale generation; no retry');return false
    end
    return true
end
local function guarded(fn)
    return function(...)
        if not current() then return end
        local ok,err=pcall(fn,...);if not ok then fail(err) end
    end
end
local function identity(fn)
    local r=table.pack(fn());assert(r.n==3,'identity shape')
    for i=1,3 do assert(math.type(r[i])=='integer','identity type') end
    assert(r[1]>0 and r[2]>=0 and r[3]>0,'identity metadata');return r
end
local ok,err=pcall(function()
    local arm=assert(io.open(dir..'/run.txt','w'));assert(arm:write('DISABLED\n'));assert(arm:close())
    assert(type(ExecuteAsync)=='function' and type(ExecuteInGameThread)=='function'
        and type(ExecuteInGameThreadWithDelay)=='function','scheduling unavailable')
    local previous=rawget(_G,'PWP_FILE_GENERATION');if previous then previous.active=false end
    generation={active=true,nonce=nonce};_G.PWP_FILE_GENERATION=generation
    log('ARMED','delay_ms=90000 phases=initial,conflict; DISPOSABLE FILES ONLY')
    ExecuteInGameThreadWithDelay(90000,guarded(function()
        local dll=dir..'/pwp_file_probe.dll'
        local native=assert(package.loadlib(dll,'luaopen_pwp_file_probe'))
        local info=assert(package.loadlib(dll,'luaopen_pwp_file_probe_identity'))
        local driver=dofile(dir..'/driver.lua')
        local base=identity(info)
        local bytes={};for i=0,255 do bytes[#bytes+1]=string.format('%02x',i) end
        local first=table.concat(bytes):rep(1024)
        local second=('file-probe-conflict-DIFFERENT-BYTES'):gsub('.',function(c) return string.format('%02x',c:byte()) end)
        local phase,pending=0,false
        local function run()
            assert(not pending,'overlapping operation');pending=true
            phase=phase+1;assert(phase<=2,'phase bound')
            local this=phase
            local name=this==1 and 'initial' or 'conflict'
            local payload=this==1 and first or second
            log('START','phase='..name..' game='..base[1])
            ExecuteInGameThreadWithDelay(10000,guarded(function()
                if pending and phase==this then fail('phase='..name..' timeout; publication uncertain; do not retry') end
            end))
            ExecuteAsync(guarded(function()
                local success,result=pcall(driver.invoke,native,payload)
                ExecuteInGameThread(guarded(function()
                    assert(phase==this,'late completion')
                    assert(success,tostring(result))
                    local completed=identity(info)
                    log('RESULT','phase='..name..' values='..table.concat(result,',',1,result.n)
                        ..' game='..base[1]..' completion='..completed[1]..' completion_tick='..completed[2])
                    assert(result[3]~=base[1] and completed[1]==base[1],'thread identity')
                    assert(result[7]==base[3] and completed[3]==base[3],'clock frequency')
                    assert(base[2]<=result[4] and completed[2]>=result[5],'clock order')
                    assert(result[1]==(this==1 and 0 or 2),'unexpected publication/conflict; do not retry')
                    pending=false
                    log('COMPLETE','phase='..name..'; external whole-byte readback still required; NOT DURABLE ACK')
                    if this==1 then
                        ExecuteInGameThreadWithDelay(15000,guarded(run))
                    else stopped=true end
                end))
            end))
        end
        run()
    end))
end)
if not ok then fail(err) end
