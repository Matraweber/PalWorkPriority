-- Isolated, armed once; property reads only, no save/load invocation.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/Scripts/main.lua$'))
local f=io.open(root..'/run.txt','r');if not f then return end
local request=f:read('*a');f:close()
local nonce=request and request:match('^PWP_PROCESS_RUN ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
f=assert(io.open(root..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local Probe=dofile(root..'/experiments/save_process_probe.lua')
local Identity=dofile(root..'/experiments/save_identity_probe.lua')
local finished,handle,last=false,nil,nil
local started,samples=os.time(),0
local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP process '..nonce..' '..message
    print(line..'\n')
    local file=assert(io.open(root..'/process.log','a'))
    assert(file:write(line..'\n'));assert(file:close())
end
local function stop(reason)
    if finished then return end
    finished=true
    local ok,result=pcall(function() return handle and CancelDelayedAction(handle) end)
    pcall(report,reason..' samples='..samples..' timer_cancelled='..tostring(ok and result==true))
end
if not pcall(report,'ARM_CONSUMED property-only; interval=1000ms max_entries=16; verified=false') then return end
local ok,result=pcall(function()
    return LoopInGameThreadWithDelay(1000,function()
        if finished then return end
        local success=pcall(function()
            if os.time()-started>=240 or samples>=240 then stop('COMPLETE');return end
            local engine=require('UEHelpers').GetEngine()
            local before=os.clock()
            local out=Probe.read(engine)
            local elapsed=(os.clock()-before)*1000
            local identity=Identity.read(engine)
            samples=samples+1
            local parts={'status='..out.status,'count='..tostring(out.count),
                'world='..tostring(identity.world),'loaded='..tostring(identity.loaded_world),
                'selected='..tostring(identity.selected),'verified=false'}
            local entries={}
            for _,entry in ipairs(out.entries) do
                local fields={}
                for _,key in ipairs({'key_status','candidate','state_status','state','pre_status','pre_success'}) do
                    fields[#fields+1]=key..'='..tostring(entry[key])
                end
                entries[#entries+1]=table.concat(fields,',')
            end
            table.sort(entries)
            parts[#parts+1]='entries={'..table.concat(entries,';')..'}'
            local current=table.concat(parts,' | ')
            if current~=last then report('SAMPLE '..current);last=current end
            if out.status=='read_failed' or out.status=='invalid_count' or out.status=='oversize' then
                stop('UNSUPPORTED '..out.status)
            elseif elapsed>10 then
                stop('SLOW_READ elapsed_ms='..tostring(elapsed))
            end
        end)
        if not success then stop('FAIL observation unavailable') end
    end)
end)
handle=result
if not ok or not handle then handle=nil;stop('TIMER_UNAVAILABLE') end
