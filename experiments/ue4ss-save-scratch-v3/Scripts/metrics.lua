-- Pure Lua, bounded duration measurements. No clock or native dependencies.
local M = {}

local function finite_nonnegative(value)
    return type(value) == 'number' and value == value
        and value >= 0 and value < math.huge
end

-- cap is per bucket; zero keeps aggregate measurements without samples.
function M.new(cap)
    if cap == nil then cap = 4096 end
    assert(finite_nonnegative(cap) and cap % 1 == 0,
        'cap must be a finite nonnegative integer')
    local buckets, key_count = {}, 0
    local object = {}

    -- Returns false, reason on rejection, without modifying any bucket.
    -- Samples beyond cap are accepted into aggregates but not retained.
    function object:add(key, milliseconds)
        if type(key) ~= 'string' or key == '' then
            return false, 'key must be a nonempty string'
        end
        if not finite_nonnegative(milliseconds) then
            return false, 'milliseconds must be finite and nonnegative'
        end
        local bucket = buckets[key]
        if not bucket then
            if key_count >= 16 then return false, 'unique key limit reached' end
            bucket = {samples={}, n=0, total_ms=0, max_ms=0,
                over_50=0, over_100=0, over_250=0}
            buckets[key], key_count = bucket, key_count + 1
        end
        bucket.n = bucket.n + 1
        bucket.total_ms = bucket.total_ms + milliseconds
        bucket.max_ms = math.max(bucket.max_ms, milliseconds)
        if milliseconds > 50 then bucket.over_50 = bucket.over_50 + 1 end
        if milliseconds > 100 then bucket.over_100 = bucket.over_100 + 1 end
        if milliseconds > 250 then bucket.over_250 = bucket.over_250 + 1 end
        if #bucket.samples < cap then
            bucket.samples[#bucket.samples + 1] = milliseconds
        end
        return true
    end

    -- Percentiles use nearest rank (ceil(p * retained)), exclusively over
    -- the FIRST retained samples, not an estimate over all accepted samples.
    -- Missing buckets/empty retained subsets report zero-valued measurements.
    function object:summary(key)
        local bucket = buckets[key]
        local sorted = {}
        if bucket then
            for i, value in ipairs(bucket.samples) do sorted[i] = value end
        end
        table.sort(sorted)
        local retained = #sorted
        local function percentile(p)
            if retained == 0 then return 0 end
            return sorted[math.ceil(p * retained)]
        end
        local n = bucket and bucket.n or 0
        return {
            n=n, retained=retained, dropped=n-retained,
            total_ms=bucket and bucket.total_ms or 0,
            max_ms=bucket and bucket.max_ms or 0,
            p50_ms=percentile(0.50), p95_ms=percentile(0.95),
            p99_ms=percentile(0.99),
            over_50=bucket and bucket.over_50 or 0,
            over_100=bucket and bucket.over_100 or 0,
            over_250=bucket and bucket.over_250 or 0,
            percentile_coverage='first_retained_samples',
        }
    end

    function object:keys()
        local keys = {}
        for key in pairs(buckets) do keys[#keys + 1] = key end
        table.sort(keys)
        return keys
    end
    return object
end

return M
