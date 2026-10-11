local path=TEST_ROOT..'/experiments/ue4ss-save-distinct-worlds/Scripts/main.lua'
local function trial(variant)
    local logs,now,callback,disabled,cancelled={},0,nil,false,false
    local w,i={},{}
    local env=setmetatable({},{__index=_G})
    env.os={time=function() return now end,date=function() return 'time' end}
    env.io={open=function(_,mode)
        if mode=='r' then local once=false;return {read=function() if once then return nil end;once=true;return 'PWP_DISTINCT_WORLDS fixture' end,close=function() return true end} end
        return {write=function(_,text) if mode=='w' then disabled=text=='DISABLED\n' else logs[#logs+1]=text end;return true end,close=function() return true end}
    end}
    env.dofile=function(p) return {read=function() if p:find('save_world_identity_probe',1,true) then return w else return i end end} end
    env.require=function() return {GetEngine=function() return {} end} end
    env.LoopInGameThreadWithDelay=function(_,fn) callback=fn;return 9 end
    env.CancelDelayedAction=function(h) assert(h==9);cancelled=true;return true end
    assert(loadfile(path,'t',env))();assert(disabled and callback)
    local function host(id)
        w={world='same map',directory=id,status='observed',directory_status='format_valid',role_status='read',role=3,dedicated_status='read',dedicated=false}
        i={world=w.world,selected=id,selected_status='format_valid',loaded_status='read',loaded_world=true,context_status='context_agrees',world_address=1,instance_address=2,manager_address=3}
        if variant=='untrusted' then i.context_status='owner_unestablished' end
        for _=1,7 do now=now+1;callback() end
    end
    local function title()
        w={world='World /Game/Pal/Maps/Title/PL_Title.PL_Title'};i={world=w.world,loaded_status='read',loaded_world=false};now=now+1;callback()
    end
    host('a');if variant~='no-title' then title() end
    host(variant=='same-world' and 'a' or 'b');title();host('a')
    local text=table.concat(logs)
    local complete=text:find('OBSERVATIONS_COMPLETE',1,true)~=nil
    assert(complete==(variant=='valid'),variant..' wrong completion')
    if complete then assert(cancelled) else now=1801;callback();assert(cancelled and table.concat(logs):find('TIMEOUT',1,true)) end
end
for _,v in ipairs({'valid','untrusted','same-world','no-title'}) do trial(v) end
print('distinct-world observer: complete route, absent boundary, same-world and untrusted refusals')
