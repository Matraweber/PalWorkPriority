-- Input ownership is explicit. Relinquishing to a vanilla menu is final;
-- a later watchdog must not reinterpret that handoff as a leaked mod route.
local M = { owners = {} }
function M.new()
    return { phase = "closed", generation = 0, route = nil }
end
function M.open(state)
    state.phase = "open"
end
function M.close(state, vanilla)
    if state.phase == "closed" or state.phase == "handoff" then return false end
    -- Only a definite gameplay state permits returning input to gameplay.
    -- Unknown is relinquished too; the watchdog must not reinterpret it later.
    state.phase = vanilla == false and "closed" or "handoff"
    state.route = nil
    state.generation = state.generation + 1
    return true
end
function M.recover(state, vanilla)
    return state.phase ~= "open" and state.phase ~= "handoff"
        and state.route ~= nil and vanilla == false
end
return M
