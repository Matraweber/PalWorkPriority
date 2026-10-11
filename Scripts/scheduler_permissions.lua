-- Plain, session-scoped evidence for distinguishing external permission edits
-- from delayed mod writes. Requests never become confirmed state by themselves.
local M = {}
-- This is a diagnostic deadline, not a claim about native delivery latency.
-- Once expired, an ambiguous request stays quarantined until readback or a
-- session reset. Never guess that a late mod write was a player's edit.
M.WAIT_SECONDS = 30

function M.new()
    return { confirmed = {}, pending = {}, sent_at = {} }
end

function M.sent(history, value, on, now)
    if history.pending[value] ~= nil then return false end
    history.pending[value] = on
    history.sent_at[value] = now or os.clock()
    return true
end

local function acknowledge(history, value, on)
    history.confirmed[value] = on
    history.pending[value], history.sent_at[value] = nil, nil
end

function M.status(history, now)
    now = now or os.clock()
    local pending, expired = 0, 0
    for value in pairs(history.pending) do
        pending = pending + 1
        local at = history.sent_at[value]
        if not at or now < at or now - at >= M.WAIT_SECONDS then expired = expired + 1 end
    end
    return pending, expired
end

function M.observe(history, off, capable)
    local changed = {}
    if type(off) ~= "table" then return changed end
    for value in pairs(capable) do
        local on = not off[value]
        local pending = history.pending[value]
        if pending ~= nil then
            if on == pending then
                acknowledge(history, value, on)
            end
        elseif history.confirmed[value] ~= nil and on ~= history.confirmed[value] then
            changed[value] = on
        end
    end
    return changed
end

function M.accept(history, value, on)
    history.confirmed[value] = on
end

function M.confirm(history, off, wanted, capable)
    if type(off) ~= "table" then return false end
    for value in pairs(capable) do
        local on = not off[value]
        local pending = history.pending[value]
        if pending ~= nil then
            if on == pending then
                acknowledge(history, value, on)
            end
        elseif on == (wanted[value] == true) then
            history.confirmed[value] = on
        end
    end
    return true
end

return M
