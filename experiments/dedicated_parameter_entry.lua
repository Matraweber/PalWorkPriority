-- Explicit Gate 1 entry, called only after main consumes its one-shot arm.
-- Only the observer evidence log is writable; no saves, native DLL or writer.
local M={}
function M.start(root,config)
    assert(type(config)=='table' and getmetatable(config)==nil and config.parameters==true)
    for _,name in ipairs({'nonce','directory','guild'})do
        local v=config[name]
        assert(type(v)=='string' and #v==32 and v:match('^[0-9a-f]+$')
            and v~=string.rep('0',32),'invalid_parameter_configuration')
    end
    local nonce,directory,guild=config.nonce,config.directory,config.guild
    local Observer=dofile(root..'/dedicated_parameter_observer.lua')
    local Clock=dofile(root..'/dedicated_parameter_clock.lua')
    local function gameplay()return StaticFindObject('/Script/Engine.Default__GameplayStatics')end
    local clock=Clock.new(gameplay)
    local strings={status={observed=true,unavailable=true,closed=true,deferred=true,finished=true},
        reason={member_parameter=true,parameter_unavailable=true,empty_roster=true,foreign_group=true,
            reentrant=true,sample_limit_or_closed=true,time_limit=true,clock_reversed=true,
            sample_spacing=true,revoked_or_budget=true,clock=true,context=true,context_recheck=true,
            group_manager=true,guild_map=true,roster=true,parameter_lookup=true,parameter_identity=true,
            sample_failed=true,emit_failed=true,bounded_complete=true,callback_limit=true,
            closed=true,timer_unavailable=true,clock_unavailable=true},
        membership={unknown=true,matched=true},pal_kind={unknown=true}}
    local counts={sample_index=60,samples=60,callbacks=60,lookup_attempts=1,roster_count=4096,duration_ms=60000}
    local function emit(out)
        assert(type(out)=='table' and getmetatable(out)==nil)
        local parts={'PWP_DEDICATED_PARAMETER',nonce,'clock=GameplayStatics_GetAccurateRealTime'}
        for _,k in ipairs({'status','reason','membership','pal_kind'})do
            local v=rawget(out,k);assert(type(v)=='string' and strings[k][v]);parts[#parts+1]=k..'='..v
        end
        for _,k in ipairs({'sample_index','samples','callbacks','lookup_attempts','roster_count','duration_ms'})do
            local v=rawget(out,k)
            if v~=nil then
                assert((v=='unknown' and (k=='roster_count' or k=='duration_ms'))
                    or (type(v)=='number' and v==v and v>=0 and v<=counts[k]
                        and (k=='duration_ms' or math.type(v)=='integer')))
                parts[#parts+1]=k..'='..tostring(v)
            end
        end
        for _,k in ipairs({'timer_cancelled','duration_clamped','complete'})do
            local v=rawget(out,k)
            if v~=nil then assert(type(v)=='boolean');parts[#parts+1]=k..'='..tostring(v)end
        end
        for _,k in ipairs({'verified','active','storage_grant','authority_grant','coverage_grant'})do
            assert(rawget(out,k)==false);parts[#parts+1]=k..'=false'
        end
        local line=table.concat(parts,' | ')..'\n';assert(#line<=1400)
        local file=assert(io.open(root..'/parameter.log','a'))
        local ok=pcall(function()assert(file:write(line))end)
        local closed=file:close();assert(ok and closed,'parameter_log_failed')
    end
    -- A missing or unsupported clock refuses before any timer/parameter call.
    local clock_ok=pcall(function()clock.begin();clock.read()end)
    clock.finish()
    if not clock_ok then
        emit{status='finished',reason='clock_unavailable',membership='unknown',pal_kind='unknown',
            lookup_attempts=0,samples=0,timer_cancelled=false,complete=false,verified=false,active=false,
            storage_grant=false,authority_grant=false,coverage_grant=false}
        return nil,'clock_unavailable'
    end
    return Observer.start{enabled=true,directory=directory,guild=guild,clock=clock.read,
        open_clock=clock.begin,finish_clock=clock.finish,revoke_clock=clock.close,
        get_engine=function()return FindFirstOf('GameEngine')end,
        get_state=function(c)return gameplay():GetGameState(c)end,
        get_instance=function(c)return gameplay():GetGameInstance(c)end,
        get_utility=function()return StaticFindObject('/Script/Pal.Default__PalUtility')end,
        unwrap=function(v)
            if type(v)~='userdata'then return v end
            local ok,inner=pcall(function()if v.get then return v:get()end end)
            return ok and inner~=nil and inner or v
        end,
        schedule=LoopInGameThreadWithDelay,cancel=CancelDelayedAction,emit=emit}
end
return M
