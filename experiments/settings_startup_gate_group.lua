-- Default-off two-stream startup barrier. Children use this instead of acquiring
-- the shared gate independently. Child release marks recovery complete; only
-- commit releases the global fence, after both fresh readiness checks succeed.
-- No native owners, IO, activation or permission to retry uncertain recovery.
local Gate=require('settings_gate')
local M={}
function M.new(o)
    if type(o)~='table' or o.enabled~=true then return nil,'disabled' end
    local token,why=Gate.acquire();if not token then return nil,why end
    local states={limits={},priorities={}}
    local terminal,busy,committed=false,false,false
    local group={}
    local function fence()
        terminal=true
        if not Gate.held(token)then
            -- Do not release or impersonate another owner's existing barrier.
            local fresh=Gate.acquire();if fresh then token=fresh end
        end
        if Gate.held(token) then Gate.require_restart(token) end
        return Gate.held(token)
    end
    function group:child(name)
        local s=states[name]
        if not s or s.facade or terminal or committed then return nil end
        local claim=function()end
        s.facade={
            acquire=function()
                if terminal or committed or s.acquired or not Gate.held(token)then return nil end
                s.acquired=true;return claim
            end,
            held=function(t)return not terminal and t==claim and s.acquired==true and not s.released and Gate.held(token) end,
            release=function(t)
                if t~=claim or not s.acquired or s.released or not Gate.held(token)then return false end
                s.released=true;return true
            end}
        return s.facade
    end
    function group:commit(ready)
        if busy then fence();return false end
        if terminal or committed or type(ready)~='function' then return false end
        busy=true
        local ok,yes=pcall(function()
            -- Recheck the first stream after consulting the second. Providers
            -- are trusted synchronous readiness reads, not mutating admission
            -- callbacks; lifecycle invalidation must also call fence().
            for _=1,2 do
                for _,name in ipairs({'limits','priorities'})do
                    local s=states[name]
                    if terminal or not Gate.held(token) or not s.acquired or not s.released
                        or ready(name)~=true or terminal or not Gate.held(token)then return false end
                end
            end
            return Gate.release(token)
        end)
        busy=false
        if not ok or yes~=true then fence();return false end
        committed=true;return true
    end
    function group:fence()return fence()end
    -- A never-admitted client may abandon its unused barrier, not commit it.
    -- Terminal forever; a subsequent session transition can still fence it.
    function group:opt_out()
        if terminal or busy or committed or not Gate.held(token)then return false end
        for _,s in pairs(states)do if s.facade then return false end end
        terminal=true
        return Gate.release(token)
    end
    function group:status()
        return {committed=committed,terminal=terminal,blocked=Gate.blocked(),owned=Gate.held(token)}
    end
    return group
end
return M
