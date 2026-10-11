local M = dofile(TEST_ROOT .. '/experiments/ue4ss-save-scratch/Scripts/metrics.lua')
local cases = 0
local function check(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ': ' .. tostring(err))
    cases = cases + 1
end
local function expect(actual, expected)
    for key, value in pairs(expected) do
        assert(actual[key] == value,
            key .. ': expected ' .. tostring(value) .. ', got ' .. tostring(actual[key]))
    end
end

check('nearest-rank percentiles on unsorted samples', function()
    local m = M.new()
    for i = 100, 1, -1 do assert(m:add('read', i)) end
    expect(m:summary('read'), {n=100, retained=100, dropped=0,
        total_ms=5050, max_ms=100, p50_ms=50, p95_ms=95, p99_ms=99,
        over_50=50, over_100=0, over_250=0,
        percentile_coverage='first_retained_samples'})
    local small = M.new()
    for _, value in ipairs({9, 1, 5, 3}) do assert(small:add('write', value)) end
    expect(small:summary('write'), {p50_ms=3, p95_ms=9, p99_ms=9})
    assert(small:add('single', 2.5))
    expect(small:summary('single'), {p50_ms=2.5, p95_ms=2.5, p99_ms=2.5})
end)

check('thresholds are strictly greater, including fractional durations', function()
    local m = M.new()
    for _, value in ipairs({0, 50, 50.5, 100, 100.5, 250, 250.5}) do
        assert(m:add('duration', value))
    end
    expect(m:summary('duration'), {n=7, total_ms=801.5, max_ms=250.5,
        over_50=5, over_100=3, over_250=1})
end)

check('first samples retained, aggregates include every accepted sample', function()
    local m = M.new(3)
    for _, value in ipairs({30, 10, 20, 1000, 0, 101}) do assert(m:add('a', value)) end
    expect(m:summary('a'), {n=6, retained=3, dropped=3, total_ms=1161,
        max_ms=1000, p50_ms=20, p95_ms=30, p99_ms=30,
        over_50=2, over_100=2, over_250=1,
        percentile_coverage='first_retained_samples'})
    local result = m:summary('a')
    result.n, result.p50_ms = -1, -1
    assert(m:add('a', 251))
    expect(m:summary('a'), {n=7, retained=3, dropped=4, total_ms=1412,
        max_ms=1000, p50_ms=20, over_50=3, over_100=3, over_250=2})
end)

check('default cap and independent per-key storage', function()
    local m = M.new()
    for i = 1, 4100 do assert(m:add('a', i)) end
    assert(m:add('b', 7))
    expect(m:summary('a'), {n=4100, retained=4096, dropped=4,
        total_ms=8407050, max_ms=4100, p50_ms=2048, p95_ms=3892, p99_ms=4056})
    expect(m:summary('b'), {n=1, retained=1, dropped=0, total_ms=7})
end)

check('sixteen keys sorted, rejected keys do not evict existing buckets', function()
    local m = M.new(1)
    for i = 16, 1, -1 do assert(m:add(string.format('key%02d', i), i)) end
    assert(m:add('overflow', 99) == false)
    local keys = m:keys()
    assert(#keys == 16)
    for i = 1, 16 do assert(keys[i] == string.format('key%02d', i)) end
    keys[1] = 'changed'
    assert(m:keys()[1] == 'key01')
    assert(m:add('key01', 300))
    expect(m:summary('key01'), {n=2, retained=1, dropped=1, total_ms=301,
        max_ms=300, p99_ms=1, over_250=1})
    assert(m:summary('overflow').n == 0)
end)

check('invalid samples do not mutate aggregates or consume key slots', function()
    local m = M.new(2)
    assert(m:add('valid', 10))
    local invalid = {-1, -0.5, math.huge, -math.huge, 0/0, '12', false, {}, function() end}
    for i, value in ipairs(invalid) do
        assert(m:add('valid', value) == false)
        assert(m:add('invalid' .. i, value) == false)
    end
    assert(m:add('nil', nil) == false)
    for _, key in ipairs({'', 42, false, {}}) do assert(m:add(key, 1) == false) end
    assert(m:add(nil, 1) == false)
    expect(m:summary('valid'), {n=1, retained=1, dropped=0, total_ms=10, max_ms=10})
    assert(#m:keys() == 1)
    for i = 1, 15 do assert(m:add('extra' .. i, 0)) end
    assert(#m:keys() == 16)
end)

check('empty summaries, zero storage, and invalid caps', function()
    local m = M.new(0)
    expect(m:summary('absent'), {n=0, retained=0, dropped=0, total_ms=0,
        max_ms=0, p50_ms=0, p95_ms=0, p99_ms=0, over_50=0, over_100=0, over_250=0})
    assert(#m:keys() == 0)
    assert(m:add('a', 251))
    expect(m:summary('a'), {n=1, retained=0, dropped=1, total_ms=251,
        max_ms=251, p50_ms=0, p95_ms=0, p99_ms=0, over_50=1, over_100=1, over_250=1})
    for _, cap in ipairs({-1, 1.5, math.huge, -math.huge, 0/0, '3', false, {}}) do
        assert(not pcall(M.new, cap))
    end
end)

print('save scratch metrics: ' .. cases .. ' deterministic cases passed')
