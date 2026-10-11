-- Callback-thread-only migration fence shared by both legacy settings writers.
-- Dormant until explicitly acquired. The opaque token belongs to one startup;
-- wrong/stale tokens cannot release another owner's fence. No authority or IO.
local M={}
local holder
local restart_required=false
function M.acquire()
    if holder then return nil,'settings recovery already in progress' end
    holder=function()end
    restart_required=false
    return holder
end
function M.held(token)return token~=nil and token==holder end
function M.blocked()return holder~=nil end
-- Presentation only; marking a fence never grants or releases admission.
function M.require_restart(token)
    if not M.held(token) then return false end
    restart_required=true;return true
end
function M.status()
    if not holder then return 'ready' end
    return restart_required and 'restart_required' or 'recovering'
end
function M.release(token)
    if not M.held(token) then return false end
    holder=nil;restart_required=false;return true
end
return M
