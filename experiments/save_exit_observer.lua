-- Experimental observation ONLY. No save/drain/authority/IO/actor queries.
-- Pinned UE4SS 2281fa311e417b1dfddedbcd49972d764fddb244:
-- UE4SS/src/Mod/LuaMod.cpp:2583-2610 registration returns ZERO values (nil).
-- :6575-6588 invokes callback(Context, EndPlayReason), both RemoteUnrealParam;
-- reason wraps the address of a callback-local enum as IntProperty. Read :get()
-- NOW, never retain the wrapper, call :set(), or schedule deferred extraction.
-- LuaType/LuaUObject.cpp:2277-2280 implements get via Operation::Get.
-- Local enum evidence (implicit consecutive values from zero):
-- D:/Program Files (x86)/Epic Games/UE_5.1/Engine/Source/Runtime/Engine/Classes/
-- Engine/EngineTypes.h:2825-2839: Destroyed=0, LevelTransition=1,
-- EndPlayInEditor=2, RemovedFromWorld=3, Quit=4. This is local engine source,
-- NOT a live runtime enum/quit-route verification or the unavailable UEPseudo.
-- Actor EndPlay may fire many times and for unrelated worlds. We report only
-- the FIRST LevelTransition and FIRST Quit across this observer's lifetime.
-- Reports prove neither process exit, current-world membership, loader-lock
-- absence nor safety of draining here. No automatic rearm/per-actor logging.
-- new{enabled=true,register=RegisterEndPlayPreHook,report=function(plain_event),
--     clock=optional scalar clock} is inert; :install() is one-shot.
-- Injected functions must be synchronous/non-yielding and must not retain engine
-- wrappers. clock has caller-defined units/meaning; it is not a wall-time claim.
local M={}
local names={[1]='LevelTransition',[4]='Quit'}
local function finite(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
function M.new(o)
    assert(type(o)=='table' and getmetatable(o)==nil,'plain observer options required')
    local enabled,register,report,clock=o.enabled==true,o.register,o.report,o.clock
    assert(type(report)=='function' and (clock==nil or type(clock)=='function'),'report/clock functions required')
    local attempted,installed,terminal,busy=false,false,false,false
    local why=enabled and 'uninstalled' or 'disabled'
    local seen,attempts,reported,ignored={},0,0,0
    local c={}
    local function stop(reason) terminal=true;why=reason end
    local function callback(_,param)
        if not installed or terminal then return nil end
        if busy then stop('reentrant_callback');return nil end
        busy=true
        -- A table-shaped wrapper is allowed for dependency-injected tests; the
        -- pinned native hook supplies userdata. Never inspect the actor argument.
        local ok,reason=pcall(function()
            assert(type(param)=='userdata' or type(param)=='table')
            return param:get()
        end)
        if terminal then busy=false;return nil end
        if not ok or not finite(reason) or math.tointeger(reason)==nil or reason<0 or reason>4 then
            stop('reason_unavailable');busy=false;return nil
        end
        reason=math.tointeger(reason)
        local name=names[reason]
        if not name or seen[reason] then
            ignored=math.min(2147483647,ignored+1);busy=false;return nil
        end
        seen[reason]=true -- claim BEFORE invoking any injected code; never retry
        local event={event='end_play_pre',contract='PWP-EXIT-OBSERVE-1',
            reason=reason,reason_name=name,sequence=attempts+1,
            scope_verified=false,drain_performed=false}
        if clock then
            local good,value=pcall(clock)
            if terminal then busy=false;return nil end
            if not good or not finite(value) then stop('clock_unavailable');busy=false;return nil end
            event.clock=value
        end
        attempts=attempts+1
        local good,result=pcall(report,event)
        if not good or result==false then stop('report_failed')
        else
            reported=reported+1
            if not terminal and seen[1] and seen[4] then stop('complete') end
        end
        busy=false
        return nil -- pinned callback requests zero results; never override engine
    end
    function c:install()
        if attempted or not enabled or terminal then return false end
        attempted=true
        if type(register)~='function' then stop('hook_unavailable');return false end
        local good,result=pcall(register,callback)
        if not good or result==false then stop('registration_failed');return false end
        if terminal then return false end
        installed=true;why='observing';return true
    end
    function c:status()
        return {attempted=attempted,installed=installed,terminal=terminal,reason=why,
            quit_seen=seen[4]==true,level_transition_seen=seen[1]==true,
            report_attempts=attempts,reported=reported,ignored=ignored}
    end
    function c:stop() stop('explicit_stop') end
    return c
end
return M
