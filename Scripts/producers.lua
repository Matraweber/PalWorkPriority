-- Output admission contract. Suitability toggles cannot implement item limits.
-- No native producer is enabled until its control, scope and overshoot behavior
-- has been measured against a supported game/runtime fingerprint.
local M = {}
local adapters = {}

local function finite(n, minimum)
    return type(n) == 'number' and n == n and n < math.huge and n >= minimum
end

local function named(value)
    return type(value) == 'string' and value ~= ''
end

local function scoped(scope)
    return type(scope) == 'table' and type(scope.guild) == 'string' and scope.guild ~= ''
        and type(scope.camp) == 'string' and scope.camp ~= ''
end

function M.register(id, adapter)
    if type(id) ~= 'string' or type(adapter) ~= 'table'
        or type(adapter.supports) ~= 'function' or type(adapter.admit) ~= 'function'
        or type(adapter.evidence) ~= 'string' or adapter.evidence == ''
        or not finite(adapter.max_inflight, 0) then
        return false
    end
    -- Capture the validated contract, not the caller's mutable registration.
    adapters[id] = { supports=adapter.supports, admit=adapter.admit,
        evidence=adapter.evidence, max_inflight=adapter.max_inflight }
    return true
end

function M.support(work, item)
    if named(work) and named(item) then
        for id, adapter in pairs(adapters) do
            local ok, supported = pcall(adapter.supports, work, item)
            if ok and supported == true then return true, id end
        end
    end
    return false, 'Unsupported item limit: no verified output control for this producer. Existing legacy group limits can still be edited or removed.'
end

-- Stock and scope must be known. Started work may finish; no cancellation API
-- is guessed. An adapter only admits a new output, leaving unrelated jobs alone.
-- Work is explicit: never infer it from an opaque native producer or item ID.
function M.admit(id, producer, output, stock, ceiling, scope, started, work)
    local a = adapters[id]
    if not a or not finite(stock, 0) or not finite(ceiling, 1) or not scoped(scope)
        or type(started) ~= 'boolean' or not named(work) or not named(output) then
        return nil, 'unavailable producer or storage scope'
    end
    local supported_ok, supported = pcall(a.supports, work, output)
    if not supported_ok or supported ~= true then return nil, 'unsupported producer output' end
    if started then return true, a.max_inflight end
    local allow = stock < ceiling
    local ok, accepted = pcall(a.admit, producer, output, allow, scope)
    if not ok or accepted ~= true then return nil, 'producer control unconfirmed' end
    return allow, a.max_inflight
end

return M
