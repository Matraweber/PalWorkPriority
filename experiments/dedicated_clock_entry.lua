-- One-shot harness around the separately reviewed clock-only probe.
-- Its only filesystem writes are run.txt and clock.log in the supplied fixture.
local M={}
local fields={'nonce','status','reason','samples','callbacks','clock','measurement',
    'elapsed_validated','total_callback_ms','resolver_ms','verified','active',
    'storage_grant','authority_grant','coverage_grant','between_sample_ms',
    'between_sample_advanced','reads','read_intervals','work_steps','checksum',
    'read_burst_ms','mean_read_interval_ms','work_and_final_read_ms',
    'within_sample_advanced','first_to_last_read_ms','observed_samples',
    'forward_intervals','within_sample_advances','advancement_observed',
    'timer_cancelled','cancellation_attempted','clock_stage','clock_seconds_type',
    'clock_partial_type','clock_seconds_kind','clock_partial_kind'}
local function plain(v)return type(v)=='table' and getmetatable(v)==nil end
local function scalar(v)
    if type(v)=='boolean' then return tostring(v) end
    if type(v)=='number' and v==v and v>-math.huge and v<math.huge then return tostring(v) end
    if type(v)=='string' and #v<=96 and v:match('^[%w_%.%-]+$') then return v end
    error('invalid_clock_record',0)
end
function M.start(o)
    if not plain(o) or not plain(o.config) or type(o.root)~='string' or o.root=='' then
        return nil,'invalid_configuration'
    end
    local nonce=o.config.nonce
    if type(nonce)~='string' or #nonce~=32 or not nonce:match('^[0-9a-f]+$')
        or nonce==string.rep('0',32) then return nil,'invalid_nonce' end
    if not plain(o.fs) or type(o.fs.open)~='function' or not plain(o.probe)
        or type(o.probe.start)~='function' then return nil,'invalid_provider' end
    for _,key in ipairs({'resolve','schedule','cancel'})do
        if type(o[key])~='function' then return nil,'invalid_provider' end
    end
    local open,root,start=o.fs.open,o.root,o.probe.start
    local clock,resolve,schedule,cancel=o.clock_module,o.resolve,o.schedule,o.cancel
    local log_path,arm_path=root..'/clock.log',root..'/run.txt'
    local function consume()
        local f=open(arm_path,'r');if not f then return false end
        local ok,arm=pcall(f.read,f,128)
        local closed,result=pcall(f.close,f)
        if not ok or not closed or not result or arm~='PWP_DEDICATED_CLOCK '..nonce..'\n' then return false end
        f=open(arm_path,'w');if not f then return false end
        local wrote,value=pcall(f.write,f,'DISABLED\n')
        closed,result=pcall(f.close,f)
        return wrote and value~=nil and value~=false and closed and result~=nil and result~=false
    end
    local yes,armed=pcall(consume)
    if not yes or not armed then return nil,'not_armed' end
    local count,terminal=0,false
    local function emit(out)
        if terminal or count>=9 or not plain(out) or out.nonce~=nonce then error('invalid_clock_record',0) end
        for _,key in ipairs({'verified','active','storage_grant','authority_grant','coverage_grant','elapsed_validated'})do
            if out[key]~=false then error('invalid_clock_grant',0) end
        end
        if out.status~='observed' and out.status~='finished' then error('invalid_clock_status',0) end
        if out.status=='observed' and count>=8 then error('clock_record_limit',0) end
        local parts={'PWP_DEDICATED_CLOCK'}
        for _,key in ipairs(fields)do
            if out[key]~=nil then parts[#parts+1]=key..'='..scalar(out[key]) end
        end
        local line=table.concat(parts,' | ')..'\n'
        if #line>4096 then error('clock_record_limit',0) end
        count=count+1;terminal=out.status=='finished'
        local f=assert(open(log_path,'a'),'clock_log_unavailable')
        local ok,value=pcall(f.write,f,line)
        local closed,result=pcall(f.close,f)
        if not ok or not value or not closed or not result then error('clock_log_failed',0) end
    end
    local ok,control,reason=pcall(start,{enabled=true,nonce=nonce,clock_module=clock,
        resolve=resolve,schedule=schedule,cancel=cancel,emit=emit})
    if not ok then return nil,'probe_start_failed' end
    return control,reason
end
return M
