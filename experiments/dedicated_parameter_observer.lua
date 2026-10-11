-- Gate 1 only: default-off supplied-world parameter observation. No IO, writer,
-- actor enumeration, player/viewport inference, or membership/admission grant.
-- SDK PalUtility.h declares GetIndividualCharacterParameterByIstanceID(world,
-- const FPalInstanceID&). Forward ONLY the selected roster's original userdata.
-- Ordered repeated reads detect observed changes, not an atomic snapshot/ABA.
-- clock must be monotonic elapsed seconds, not a CPU-time clock. The 100ms
-- budget is checked cooperatively; it cannot interrupt a blocked native call.
local M={}
local MAX_GUILDS,MAX_IDS,MAX_SAMPLES=128,4096,60
local function plain(t)return type(t)=='table' and getmetatable(t)==nil end
local function integer(n)return math.type(n)=='integer' end
local function canonical(s)
    return type(s)=='string' and #s==32 and s:match('^[0-9a-f]+$') and s~=string.rep('0',32)
end
local function equal(a,b)
    if type(a)~=type(b)then return false end
    if type(a)~='table'then return a==b end
    for k,v in pairs(a)do if not equal(v,b[k])then return false end end
    for k in pairs(b)do if a[k]==nil then return false end end
    return true
end
local function result(status,reason)
    return {status=status,reason=reason,complete=false,membership='unknown',pal_kind='unknown',
        roster_count='unknown',lookup_attempts=0,verified=false,active=false,
        storage_grant=false,authority_grant=false,coverage_grant=false}
end
function M.new(o)
    if not plain(o) or o.enabled~=true then return nil,'disabled' end
    if not canonical(o.directory) or not canonical(o.guild)then return nil,'invalid_target' end
    local api={}
    for _,k in ipairs({'get_engine','get_state','get_instance','get_utility','unwrap','clock'})do
        if type(o[k])~='function'then return nil,'invalid_provider' end
        api[k]=o[k]
    end
    local directory,wanted=o.directory,o.guild
    local open_clock,finish_clock,revoke_clock=o.open_clock,o.finish_clock,o.revoke_clock
    if open_clock~=nil or finish_clock~=nil or revoke_clock~=nil then
        if type(open_clock)~='function' or type(finish_clock)~='function'
            or type(revoke_clock)~='function'then return nil,'invalid_provider'end
    end
    local busy,closed,samples,last,started=false,false,0,nil,nil
    local observer={}
    function observer.close()closed=true;if revoke_clock then pcall(revoke_clock)end end
    function observer.sample()
        if busy then observer.close();return result('unavailable','reentrant')end
        if closed or samples>=MAX_SAMPLES then closed=true;return result('closed','sample_limit_or_closed')end
        busy=true
        local stage,attempts,began='clock',0,nil
        local ok,out=pcall(function()
            if open_clock then open_clock()end
            local function now()
                local n=api.clock();assert(type(n)=='number' and n==n and n>=0 and n<math.huge)
                return n
            end
            began=now()
            if started and (began<started or began-started>=60)then closed=true;return result('closed','time_limit')end
            if last and began<last then closed=true;return result('closed','clock_reversed')end
            if last and began-last<1 then return result('deferred','sample_spacing')end
            started=started or began;last=began;samples=samples+1
            local function guard()
                assert(not closed,'revoked')
                local n=now();assert(n>=began and n-began<=0.1,'callback_budget')
            end
            local function address(v)
                guard();assert(v and v:IsValid()==true)
                local n=v:GetAddress();assert(integer(n) and n>0);guard();return n
            end
            local function guid(raw,zero)
                local words={}
                for _,k in ipairs({'A','B','C','D'})do
                    local n=api.unwrap(raw[k]);assert(integer(n) and n>=-2147483648 and n<=4294967295)
                    words[#words+1]=string.format('%08x',n%4294967296);guard()
                end
                local s=table.concat(words);assert(zero or s~=string.rep('0',32));return s
            end
            local function key(id)return (guid(id.PlayerUId,true)..guid(id.InstanceId)):upper()end
            local function context(expected,checked_manager,checked_utility)
                stage='context'
                local engine=api.get_engine();local eid=address(engine)
                assert(not expected or eid==expected.engine)
                local instance=engine.GameInstance;local iid=address(instance)
                assert(not expected or iid==expected.instance)
                local state=api.get_state(instance);local sid=address(state)
                assert(not expected or sid==expected.state)
                assert(address(api.get_instance(state))==iid)
                local level=state:GetLevel();address(level)
                local world=level.OwningWorld;local wid=address(world)
                assert(not expected or wid==expected.world)
                assert(address(world.OwningGameInstance)==iid and address(world.GameState)==sid)
                local dir=state.WorldSaveDirectoryName
                if type(dir)~='string'then dir=dir:ToString()end
                assert(type(dir)=='string' and dir:lower()==directory
                    and state.Role==3 and state.bIsDedicatedServer==true)
                local save=instance.SaveGameManager;local saveid=address(save)
                assert(not expected or saveid==expected.save)
                assert(address(save:GetOuter())==iid and save.bIsLoadedWorldSaveData==true)
                stage='group_manager'
                local utility=checked_utility or api.get_utility();local uid=address(utility)
                assert(not expected or uid==expected.utility)
                local manager=checked_manager or utility:GetGroupManager(world);local mid=address(manager)
                assert(not expected or mid==expected.manager)
                assert(address(manager:GetOuter())==wid)
                -- Reprove root/state and owners after the group resolver.
                stage='context_recheck'
                assert(address(api.get_engine())==eid and address(engine.GameInstance)==iid
                    and address(api.get_state(instance))==sid and address(api.get_instance(state))==iid)
                local finallevel=state:GetLevel();address(finallevel)
                local finaldir=state.WorldSaveDirectoryName
                if type(finaldir)~='string'then finaldir=finaldir:ToString()end
                assert(type(finaldir)=='string' and finaldir:lower()==directory
                    and state.Role==3 and state.bIsDedicatedServer==true
                    and address(finallevel.OwningWorld)==wid and address(world.GameState)==sid
                    and address(world.OwningGameInstance)==iid and address(instance.SaveGameManager)==saveid
                    and address(save:GetOuter())==iid and save.bIsLoadedWorldSaveData==true
                    and address(manager:GetOuter())==wid)
                guard()
                return {engine=eid,instance=iid,state=sid,world=wid,save=saveid,manager=mid,utility=uid},
                    world,manager,utility
            end
            local function roster(manager,selected)
                stage='guild_map'
                local map=manager.GuildMap;assert(map and map:type()=='TMap')
                local count=#map;assert(integer(count) and count>=0 and count<=MAX_GUILDS)
                local signature,seen,found,n={},{},nil,0
                map:ForEach(function(k,v)
                    guard();n=n+1;assert(n<=count and n<=MAX_GUILDS and #map==count)
                    local id=guid(api.unwrap(k));assert(not seen[id]);seen[id]=true
                    local guild=api.unwrap(v);signature[id]=address(guild)
                    assert(guid(guild:GetId())==id)
                    if id==wanted then found=guild end
                    if n==count then return true end
                end)
                assert(n==count and #map==count and found)
                local gid=address(found)
                stage='roster'
                local array=found.IndividualIdArray;local aid=address(array)
                local items=array.IndividualCharacterHandleIds.Items
                assert(type(items)=='table' or type(items)=='userdata')
                local size=#items;assert(integer(size) and size>=0 and size<=MAX_IDS)
                if plain(items)then
                    local total=0
                    for i in next,items do total=total+1;assert(total<=MAX_IDS and integer(i) and i>=1 and i<=size)end
                    assert(total==size)
                end
                local keys,ids,native={},{},nil
                for i=1,size do
                    guard();assert(#items==size)
                    local id=api.unwrap(items[i]).HandleId
                    local k=key(id);assert(not ids[k]);ids[k]=true;keys[#keys+1]=k
                    if k==selected then
                        assert(type(id)=='userdata','original reflected HandleId required')
                        native=id
                    end
                end
                assert(#items==size and #map==count and guid(found:GetId())==wanted
                    and address(found.IndividualIdArray)==aid)
                table.sort(keys);guard()
                return {map=signature,guild=gid,array=aid,count=size,keys=keys},native
            end
            local before,_,manager=context()
            local first=roster(manager)
            local selected=first.keys[(samples-1)%math.max(1,first.count)+1]
            local current,world,fresh,utility=context(before)
            assert(equal(before,current))
            local second,native=roster(fresh,selected)
            assert(equal(first,second))
            -- Final fresh context after selection, before the sole native lookup.
            local check,lookup_world,_,lookup_utility=context(before);assert(equal(before,check))
            local parameter
            if selected then
                stage='parameter_lookup';assert(native and key(native)==selected);guard()
                attempts=1
                parameter=api.unwrap(lookup_utility:GetIndividualCharacterParameterByIstanceID(lookup_world,native))
                guard()
            end
            local function parameter_read()
                stage='parameter_identity'
                local id=address(parameter)
                assert(key(parameter.IndividualId)==selected)
                local group=guid(parameter:GetGroupId())
                assert(address(parameter)==id and key(parameter.IndividualId)==selected)
                guard();return {address=id,group=group}
            end
            local observed
            if parameter~=nil then observed=parameter_read()end
            local after,_,post=context(before);assert(equal(before,after))
            local third=roster(post);assert(equal(first,third))
            local final,_,last_manager,last_utility=context(before);assert(equal(before,final))
            assert(equal(first,roster(last_manager)))
            -- Final resolver/roster callbacks can mutate the parameter. Check
            -- it after those callbacks, then reprove their ownership below.
            if observed then assert(equal(observed,parameter_read()))end
            -- Recheck the current chain and the callback-local manager's
            -- ownership without another group lookup after the final roster.
            -- Ordered reads still cannot exclude an unseen ABA change.
            assert(equal(before,context(before,last_manager,last_utility)))
            guard()
            local answer=result(observed and 'observed' or 'unavailable','parameter_unavailable')
            answer.complete=observed~=nil or not selected;answer.roster_count=first.count
            if not selected then answer.status='observed';answer.reason='empty_roster'
            elseif observed and observed.group==wanted then
                answer.reason='member_parameter';answer.membership='matched'
            elseif observed then answer.reason='foreign_group' end
            return answer
        end)
        local elapsed_ok,elapsed=pcall(api.clock)
        local finished=true
        if finish_clock then finished=pcall(finish_clock)end
        elapsed_ok=elapsed_ok and finished
        local duration=elapsed_ok and began and type(elapsed)=='number' and elapsed==elapsed
            and elapsed>=began and elapsed<math.huge and (elapsed-began)*1000 or nil
        busy=false
        if not ok or closed or not duration or duration>100 then
            closed=closed or not duration or (duration and duration>100) or stage=='clock'
            out=result(closed and 'closed' or 'unavailable',closed and 'revoked_or_budget' or stage)
        end
        out.sample_index=samples;out.lookup_attempts=attempts
        out.duration_ms=duration and math.min(duration,60000) or 'unknown'
        out.duration_clamped=duration~=nil and duration>60000
        if samples>=MAX_SAMPLES then closed=true end
        if closed and revoke_clock then pcall(revoke_clock)end
        return out
    end
    return observer
end
-- Scheduling is injected. This helper has no entrypoint, arm file, log path,
-- module auto-start or production wiring. Installer/native review is separate.
function M.start(o)
    local observer,why=M.new(o)
    if not observer then return nil,why end
    for _,k in ipairs({'schedule','cancel','emit'})do
        if type(o[k])~='function'then return nil,'invalid_runner' end
    end
    local schedule,cancel,emit=o.schedule,o.cancel,o.emit
    local handle,finished,pending,busy=nil,false,nil,false
    local samples,callbacks=0,0
    local function terminal(reason)
        local ok,yes=pcall(cancel,handle)
        local out=result('finished',reason);out.timer_cancelled=ok and yes==true;out.samples=samples;out.callbacks=callbacks
        pcall(emit,out)
    end
    local function stop(reason)
        if finished then return end
        finished=true;observer.close()
        if handle then terminal(reason)else pending=reason end
    end
    local function tick()
        if finished then return end
        if busy then stop('reentrant');return end
        busy=true;callbacks=callbacks+1
        local ok,out=pcall(observer.sample)
        if not finished then
            if not ok then stop('sample_failed')
            else
                if integer(out.sample_index) then samples=out.sample_index end
                local emitted=pcall(emit,out)
                if not emitted then stop('emit_failed')
                elseif out.status=='closed' or out.sample_index>=MAX_SAMPLES then stop('bounded_complete')
                elseif callbacks>=MAX_SAMPLES then stop('callback_limit')end
            end
        end
        busy=false
    end
    local ok,value=pcall(schedule,1000,tick)
    handle=ok and value or nil
    if not handle then
        finished=true;observer.close()
        local out=result('finished','timer_unavailable');out.timer_cancelled=false;out.samples=samples;pcall(emit,out)
    elseif pending then terminal(pending)end
    return {close=function()stop('closed')end}
end
return M
