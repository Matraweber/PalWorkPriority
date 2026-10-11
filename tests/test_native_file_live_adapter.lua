local path=TEST_ROOT..'/experiments/native-file-probe/main.lua'
local function trial(mode)
    local now,thread,seq=0,1,0
    local queue,logs,files,calls={}, {}, {['/probe/run.txt']='PWP_FILE_PROBE test\n'},0
    local env=setmetatable({}, {__index=_G});env._G=env
    env.debug={getinfo=function() return {source='@/probe/main.lua'} end};env.print=function() end
    env.io={open=function(name,access)
        if access=='r' and not files[name] then return end
        if access=='w' then files[name]='' end
        if access=='a' and not files[name] then files[name]='' end
        local pos=1
        return {read=function(_,count)
            if pos>#files[name] then return end
            local s=files[name]:sub(pos,pos+count-1);pos=pos+#s;return s
        end,write=function(_,s) files[name]=files[name]..s;if name:match('file.log$') then logs[#logs+1]=s end;return true end,
        close=function() return true end}
    end}
    local function schedule(ms,tid,fn) seq=seq+1;queue[#queue+1]={at=now+ms,tid=tid,fn=fn,seq=seq} end
    env.ExecuteInGameThreadWithDelay=function(ms,fn) schedule(ms,1,fn) end
    env.ExecuteInGameThread=function(fn) schedule(0,1,fn) end
    env.ExecuteAsync=function(fn) if mode~='no worker' then schedule(0,2,fn) end end
    env.package={loadlib=function(_,symbol)
        assert(now>=90000 and files['/probe/run.txt']=='DISABLED\n')
        if symbol:match('identity$') then return function() return thread,now*10000,10000000 end end
        return function() error('mock driver must not execute native') end
    end}
    env.dofile=function() return {invoke=function(_,payload)
        calls=calls+1;assert(thread==2)
        if mode=='throw' then error('uncertain operation') end
        if mode=='stale' then env.PWP_FILE_GENERATION.active=false end
        local status=calls==1 and 0 or 2
        if mode=='unexpected' then status=4 end
        return {status,status==0 and 0 or 183,mode=='same thread' and 1 or 2,now*10000,now*10000,1,10000000,n=7}
    end} end
    assert(loadfile(path,'t',env))();assert(loadfile(path,'t',env))()
    assert(calls==0 and #queue==1,'not disarmed or early native operation')
    local steps=0
    while #queue>0 do
        table.sort(queue,function(a,b) return a.at==b.at and a.seq<b.seq or a.at<b.at end)
        local e=table.remove(queue,1);now,thread=e.at,e.tid;e.fn();steps=steps+1;assert(steps<20)
    end
    local text=table.concat(logs)
    if mode=='pass' then assert(calls==2 and not text:find(' FAIL ',1,true));assert(text:find('COMPLETE phase=conflict',1,true))
    else assert(calls<=1 and text:find(' FAIL ',1,true) and not text:find('COMPLETE phase=conflict',1,true),mode) end
end
for _,mode in ipairs({'pass','no worker','throw','stale','unexpected','same thread'}) do trial(mode) end
print('file adapter: delayed two-phase success; timeout, exception, stale, status and thread failures stop without retry')
