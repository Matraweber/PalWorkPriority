-- UE 5.1 GameplayStatics.cpp:2539: FPlatformTime::Seconds() - GStartTime.
-- Unlike GetRealTimeSeconds, this is sampled at the call, not once per frame.
-- Scalar UE4SS out-param tables use reflected names (Seconds/PartialSeconds):
-- https://github.com/UE4SS-RE/RE-UE4SS/issues/920
-- No CPU-time, world-time, guessed output shape, or cached-wrapper fallback.
local M={}
function M.new(resolve)
    assert(type(resolve)=='function')
    local last,failed,held,active,busy=nil,false,nil,false,false
    local function fresh(stage)
        return {stage=stage or 'unknown',seconds_type='unknown',partial_type='unknown',
            seconds_kind='unknown',partial_kind='unknown'}
    end
    local diagnostic=fresh()
    local clock={}
    -- Fixed keys/type labels only; never retain native values or exceptions.
    -- A fresh copy remains readable after finish/close without touching engine.
    function clock.diagnostics()
        local out={};for k,v in pairs(diagnostic)do out[k]=v end;return out
    end
    function clock.close()failed=true;held=nil;active=false end
    function clock.finish()
        if busy then clock.close()else held=nil;active=false end
    end
    local function check()assert(not failed and active,'elapsed_clock_revoked')end
    function clock.begin()
        if failed or active or busy then clock.close();error('elapsed_clock_revoked',0)end
        diagnostic=fresh('resolve')
        active=true;busy=true
        local ok,value=pcall(resolve)
        busy=false
        if not ok or failed or not active or not value then
            clock.close();error('elapsed_clock_unavailable',0)
        end
        held=value
    end
    function clock.read()
        if failed or not active or busy then clock.close();error('elapsed_clock_revoked',0)end
        diagnostic=fresh('validity')
        busy=true
        local ok,value=pcall(function()
            check();local cdo=held
            assert(cdo and cdo:IsValid()==true);check()
            -- Pinned UE4SS 2281fa31 keeps scalar out-parameter refs at Lua slot 1.
            -- Explicitly share the table for both named outputs. This also works
            -- with bindings that consume each argument correctly; no layout fallback.
            local seconds={}
            local partial=seconds
            diagnostic.stage='call'
            cdo:GetAccurateRealTime(seconds,partial)
            check()
            diagnostic.stage='outputs'
            assert(getmetatable(seconds)==nil and getmetatable(partial)==nil)
            local s,p=rawget(seconds,'Seconds'),rawget(partial,'PartialSeconds')
            diagnostic.seconds_type,diagnostic.partial_type=type(s),type(p)
            diagnostic.seconds_kind,diagnostic.partial_kind=math.type(s) or 'none',math.type(p) or 'none'
            diagnostic.stage='seconds'
            assert(math.type(s)=='integer' and s>=0 and s<=2147483647)
            diagnostic.stage='fraction'
            assert(type(p)=='number' and p==p and p>=0 and p<1)
            diagnostic.stage='monotonic'
            local t=s+p;assert(not last or t>=last)
            return t
        end)
        busy=false
        if not ok then clock.close();error('elapsed_clock_unavailable',0)end
        last=value;return value
    end
    return clock
end
return M
