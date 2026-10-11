local path=TEST_ROOT..'/experiments/native-journal-probe/main.lua'
local function trial(fault)
    local f={now=0,thread=1,qpc=0,queue={},commands={},logs={},arm='PWP_JOURNAL_PROBE test\n',
        engine_reads=0,cdo_reads=0,pair_reads=0,loads=0,requires=0,native_loads=0,
        tickets={},io_tickets={},async_calls=0,native_phase=0,native_consumed=false,native_started=false,
        weak=setmetatable({}, {__mode='v'})}
    if fault=='bad_arm' then f.arm='PWP_WRONG test\n' end
    if fault=='long_nonce' then f.arm='PWP_JOURNAL_PROBE '..string.rep('x',65) end
    local env=setmetatable({},{__index=_G})
    env.io={open=function(p,mode)
        if mode=='r' then
            local read=false
            if fault=='unarmed' then return nil end
            return {read=function()
                if not read then read=true;return f.arm end
                if fault=='extra_arm' then return 'x' end
            end,close=function()return true end}
        end
        return {write=function(_,s)
            if mode=='w' then f.arm=s else f.logs[#f.logs+1]=s end
            return true
        end,close=function()return true end}
    end}
    local function schedule(delay,thread,fn)
        f.queue[#f.queue+1]={at=f.now+delay,thread=thread,fn=fn}
    end
    env.ExecuteInGameThreadWithDelay=function(delay,fn)
        local thread=fault=='admit_thread' and delay==15000 and 2 or 1
        schedule(delay,thread,fn)
        if fault=='duplicate_admit' and delay==15000 then schedule(delay+1,thread,fn) end
    end
    env.ExecuteInGameThread=function(fn)schedule(0,fault=='completion_thread' and 2 or 1,fn)end
    env.ExecuteAsync=function(fn)
        f.async_calls=f.async_calls+1
        if fault=='timeout' then schedule(11000,2,fn)
        elseif fault=='stale_worker' and f.async_calls==2 then schedule(1000,2,fn)
        else schedule(0,fault=='thread' and 1 or 2,fn) end
        if f.async_calls==1 then
            if fault=='duplicate_worker' then schedule(1,2,fn) end
            if fault=='stale_worker' then schedule(15500,2,fn) end
        end
    end
    local function game_read()
        assert(f.thread==1 and f.now==90000, 'world read outside delayed game-thread entry')
        assert(f.arm=='DISABLED\n' and #f.commands==0, 'query must follow disarm and precede native admission')
    end
    local function wrapper(t)
        local w=setmetatable(t,{__tostring=function() error('wrapper stringified') end,
            __index=function() error('unexpected wrapper access') end})
        f.weak[#f.weak+1]=w;return w
    end
    env.require=function(name)
        game_read();assert(name=='UEHelpers');f.requires=f.requires+1
        if fault=='helper_throw' then error('helper unavailable') end
        return {
            GetEngine=function()
                game_read();f.engine_reads=f.engine_reads+1
                if fault=='engine_throw' then error('engine read failed') end
                return wrapper{IsValid=function() game_read();return true end}
            end,
            GetGameplayStatics=function(force)
                game_read();assert(force==true,'CDO cache must be invalidated');f.cdo_reads=f.cdo_reads+1
                if fault=='cdo_throw' then error('CDO read failed') end
                if fault=='cdo_nil' then return nil end
                local cdo
                cdo=wrapper{
                    IsValid=function() game_read();return fault~='cdo_invalid' end,
                    GetGameState=function(self,ctx) game_read();assert(self==cdo);return ctx end,
                    GetGameInstance=function(self,ctx) game_read();assert(self==cdo);return ctx end}
                return cdo
            end}
    end
    env.dofile=function(p)
        game_read();assert(p==TEST_ROOT..'/experiments/native-journal-probe/experiments/save_context_pair_probe.lua')
        f.loads=f.loads+1
        if fault=='pair_load_throw' then error('pair unavailable') end
        return {read=function(engine,get_state,get_instance)
            game_read();f.pair_reads=f.pair_reads+1;assert(engine:IsValid())
            local absent=fault=='cdo_nil' or fault=='cdo_invalid'
            if absent then assert(get_state==nil and get_instance==nil)
            else
                local ctx=wrapper{}
                assert(get_state(ctx)==ctx and get_instance(ctx)==ctx,'CDO colon/context routing')
            end
            if fault=='pair_throw' then error('pair read failed') end
            if fault=='pair_shape' then return false end
            local agrees=not absent and fault~='pair_disagrees'
            local out={status=agrees and 'context_agrees' or 'context_mismatch',agrees=agrees,
                active=false,verified=false,storage_grant=false,world='World test',role=3,
                world_address=101,state_address=102,instance_address=103,manager_address=104,
                identity_selected_status='unavailable',identity_loaded_world=false}
            if fault=='pair_grant' then out.storage_grant=true end
            if fault=='pair_wrapper' then out.world=engine end
            if fault=='pair_nan' then out.world_address=0/0 end
            if fault=='pair_long' then out.world='World\n|storage_grant=true'..string.rep('x',20000) end
            out.unknown=engine -- unapproved fields must not be visited or retained
            return out
        end}
    end
    env.package={loadlib=function()
        assert(f.arm=='DISABLED\n','native load before self-disarm')
        assert(f.thread==1 and f.pair_reads==1 and table.concat(f.logs):find('CONTEXT_PAIR',1,true),
            'context diagnostic must precede native load')
        f.native_loads=f.native_loads+1
        return function(...)
            assert(select('#',...)==2,'native contract requires command AND immutable ticket')
            local command,ticket=...
            assert(math.type(command)=='integer' and math.type(ticket)=='integer')
            f.commands[#f.commands+1]=command;f.qpc=f.qpc+10
            f.tickets[#f.tickets+1]=command..':'..ticket
            local status=0
            if command==0 then
                if ticket==0 and (not f.native_thread or f.native_thread==f.thread) then
                    f.native_thread=f.thread;status=1
                end
            elseif f.native_thread and (command==2 and f.thread~=f.native_thread
                or command~=2 and f.thread==f.native_thread) then
                if command==1 or command==5 then
                    if ticket==f.native_phase+1 and ticket<=3
                        and (command==1 and f.native_phase==0 or command==5 and f.native_consumed)
                        and fault~='admission' then
                        f.native_phase=ticket;f.native_started=false;f.native_consumed=false;f.done=false;status=1
                    end
                elseif ticket==f.native_phase and ticket>0 then
                    if command==2 and not f.native_started and not f.native_consumed then
                        -- Model the observable IO boundary only after native fences.
                        f.native_started=true;f.done=true;f.io_tickets[#f.io_tickets+1]=ticket;status=1
                    elseif command==3 and not f.native_consumed and f.done then
                        status=fault=='uncertain' and -2 or 1
                    elseif command==4 and not f.native_consumed and f.done and fault~='uncertain' then
                        f.native_consumed=true;status=1
                    elseif command==6 and ticket==3 and f.native_consumed then status=1 end
                else
                    f.stale_rejected=true
                end
            else
                f.thread_rejected=true
            end
            if fault=='shape' and command==2 then return 1 end
            return status,f.thread,f.qpc,f.qpc+1,10000000
        end
    end}
    assert(loadfile(path,'t',env))()
    assert(f.loads==0 and f.requires==0 and f.engine_reads==0 and f.cdo_reads==0 and f.pair_reads==0,
        'context queried eagerly before delayed callback')
    local steps=0
    while #f.queue>0 do
        table.sort(f.queue,function(a,b)return a.at<b.at end)
        local v=table.remove(f.queue,1);f.now=v.at;f.thread=v.thread
        v.fn();steps=steps+1;assert(steps<100,'unbounded callbacks')
    end
    f.log=table.concat(f.logs)
    collectgarbage('collect');collectgarbage('collect')
    assert(next(f.weak)==nil,'diagnostic retained engine/CDO/context wrappers')
    return f
end
local good=trial()
assert(good.log:find('COMPLETE native phases=3',1,true))
assert(table.concat(good.commands,',')=='0,1,2,3,4,5,2,3,4,5,2,3,4,6')
assert(table.concat(good.tickets,',')=='0:0,1:1,2:1,3:1,4:1,5:2,2:2,3:2,4:2,5:3,2:3,3:3,4:3,6:3')
assert(table.concat(good.io_tickets,',')=='1,2,3')
assert(good.engine_reads==1 and good.cdo_reads==1 and good.pair_reads==1 and good.native_loads==1)
local diagnostic=assert(good.log:match('CONTEXT_PAIR diagnostic_only=true storage_grant=false ([^\n]*)'))
local previous,count='',0
for key in diagnostic:gmatch('([%w_]+)=') do
    assert(key>previous,'diagnostic fields must be sorted');previous=key;count=count+1
end
local wrong_worker=trial('thread')
assert(wrong_worker.thread_rejected and #wrong_worker.io_tickets==0,'wrong-thread IO was not rejected before effect')
local wrong_completion=trial('completion_thread')
assert(wrong_completion.thread_rejected and #wrong_completion.io_tickets==1 and not wrong_completion.native_consumed)
local wrong_admit=trial('admit_thread')
assert(wrong_admit.thread_rejected and wrong_admit.native_phase==1 and #wrong_admit.io_tickets==1)
local stale=trial('stale_worker')
assert(stale.stale_rejected and stale.native_phase==2 and table.concat(stale.io_tickets,',')=='1',
    'late phase-1 closure executed phase 2')
assert(stale.log:find('FAIL',1,true) and not stale.log:find('COMPLETE',1,true))
local duplicate=trial('duplicate_worker')
assert(#duplicate.io_tickets==1 and duplicate.log:find('FAIL',1,true))
local duplicate_admit=trial('duplicate_admit')
assert(duplicate_admit.native_phase==2 and table.concat(duplicate_admit.io_tickets,',')=='1,2'
    and duplicate_admit.log:find('FAIL',1,true),'duplicate delayed closure advanced to phase 3')
assert(count==19 and diagnostic:find('identity_loaded_world=false',1,true))
for _,fault in ipairs({'shape','uncertain','admission','thread','timeout'}) do
    local f=trial(fault)
    assert(f.log:find('FAIL',1,true) and not f.log:find('COMPLETE',1,true),fault)
    for _,cmd in ipairs(f.commands) do assert(cmd~=4 and cmd~=5 and cmd~=6,'failure consumed or retried') end
end
for _,fault in ipairs({'unarmed','bad_arm','long_nonce','extra_arm'}) do
    local f=trial(fault)
    assert(#f.commands==0 and f.loads==0 and f.requires==0 and f.engine_reads==0
        and f.cdo_reads==0 and f.pair_reads==0 and f.native_loads==0 and #f.logs==0)
end
for _,fault in ipairs({'helper_throw','engine_throw','cdo_throw','pair_load_throw','pair_throw',
    'pair_shape','pair_grant','pair_wrapper','pair_nan'}) do
    local f=trial(fault)
    assert(f.log:find('FAIL',1,true) and #f.commands==0 and f.native_loads==0, fault)
end
for _,fault in ipairs({'pair_disagrees','cdo_nil','cdo_invalid'}) do
    local f=trial(fault)
    assert(f.log:find('agrees=false',1,true) and f.log:find('status=context_mismatch',1,true))
    assert(f.log:find('COMPLETE native phases=3',1,true) and f.pair_reads==1,
        'diagnostic disagreement must not select/veto synthetic storage')
end
local bounded=trial('pair_long')
local line=assert(bounded.log:match('CONTEXT_PAIR[^\n]*'))
assert(#line<8192 and not line:find('storage_grant=true',1,true) and line:find('storage_grant=false',1,true))
assert(bounded.log:find('COMPLETE native phases=3',1,true))
print('native journal driver: immutable tickets, stale/duplicate closures, pre-IO wrong-thread denial, game-only routes, uncertainty and diagnostic/arm failures')
