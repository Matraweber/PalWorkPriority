local M = {}
function M.checksum(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return h
end
local function capture(native, input, delay)
    assert(type(input) == 'string' and #input <= 512 * 1024 and #input % 2 == 0
        and not input:find('[^0-9a-f]'), 'hex input/length')
    local r = table.pack(native(input, delay, #input))
    return r
end
local function validate(r)
    assert(r.n == 5, 'native result count')
    for i = 1, 5 do assert(math.type(r[i]) == 'integer', 'native result type') end
    assert(r[2] > 0 and r[3] >= 0 and r[4] >= r[3], 'native metadata')
    assert(r[5] >= 1000000 and r[5] <= 9223372036854, 'QPC frequency bound')
    return r
end
local function invoke(native, input, delay) return validate(capture(native, input, delay)) end
local function describe(r)
    if type(r) ~= 'table' then return tostring(r) end
    local elapsed = type(r[3]) == 'number' and type(r[4]) == 'number' and r[4]-r[3] or 'unknown'
    return string.format('n=%s checksum=%s tid=%s start_us=%s end_us=%s elapsed_us=%s frequency_hz=%s',
        tostring(r.n), tostring(r[1]), tostring(r[2]), tostring(r[3]), tostring(r[4]), tostring(elapsed), tostring(r[5]))
end
function M.run(d, generation, original)
    assert(type(original) == 'string' and #original <= 512 * 1024 and #original % 2 == 0
        and not original:find('[^0-9a-f]'), 'hex input/length')
    local decoded = original:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)
    local expected = M.checksum(decoded)
    decoded = nil
    local done, beats = false, {}
    local last_diagnostic
    local function finish(ok, message)
        if done then return end
        done = true
        d.report(ok, not ok and last_diagnostic and (message .. ' | ' .. last_diagnostic) or message)
    end
    local function current()
        if not generation.active then finish(false, 'stale generation'); return false end
        return not done
    end
    local function guarded(fn)
        local ok, err = pcall(fn)
        if not ok then finish(false, tostring(err)) end
    end
    d.game(function() guarded(function()
        if not current() then return end
        local base = invoke(d.native, '', 0)
        assert(base[1] == M.checksum(''), 'metadata checksum')
        local function beat()
            guarded(function()
                if not current() then return end
                local r = invoke(d.native, '', 0)
                assert(r[1] == M.checksum('') and r[2] == base[2], 'heartbeat thread/checksum')
                beats[#beats + 1] = r
                d.delay(25, beat)
            end)
        end
        d.delay(25, beat)
        d.delay(1000, function() if not done then finish(false, 'timeout/no completion') end end)
        local payload = original
        original = nil
        collectgarbage('collect')
        d.async(function()
            if not generation.active then
                d.game(function() finish(false, 'stale generation') end)
                return
            end
            local ok, result = pcall(capture, d.native, payload, 200)
            payload = nil
            d.game(function() guarded(function()
                -- Persist raw data BEFORE any completion assertions, including
                -- native shape/clock/generation failures. Never infer overlap.
                local complete_ok, completion = pcall(capture, d.native, '', 0)
                local diagnostic = {'version=2 clock=QPC_us request_ms=200 expected_checksum=' .. expected,
                    'generation_active=' .. tostring(generation.active),
                    'worker_ok=' .. tostring(ok) .. ' ' .. describe(result),
                    'baseline ' .. describe(base),
                    'completion_ok=' .. tostring(complete_ok) .. ' ' .. describe(completion)}
                for i, b in ipairs(beats) do diagnostic[#diagnostic+1] = 'beat[' .. i .. '] ' .. describe(b) end
                last_diagnostic = table.concat(diagnostic, ' | ')
                d.diagnostic(last_diagnostic)
                if not current() then return end
                assert(ok, tostring(result))
                validate(result)
                assert(result[1] == expected, 'bad checksum')
                assert(result[2] ~= base[2], 'same thread')
                assert(complete_ok, tostring(completion))
                validate(completion)
                assert(completion[2] == base[2], 'completion not on game thread')
                assert(result[5] == base[5] and completion[5] == base[5], 'QPC frequency mismatch')
                assert(result[4] - result[3] >= 200000, 'delay too short')
                local overlap
                for _, b in ipairs(beats) do
                    assert(b[5] == base[5], 'QPC beat frequency mismatch')
                    -- <=1 us cross-thread tick ambiguity + <1 us conversion
                    -- uncertainty; >3 us at each edge is a conservative margin.
                    if b[3] - result[3] > 3 and result[4] - b[4] > 3 then overlap = b; break end
                end
                assert(overlap, 'no heartbeat inside native interval')
                finish(true, string.format('handoff version=2 clock=QPC_us checksum=%d worker=%d game=%d start_us=%d end_us=%d beat_start_us=%d beat_end_us=%d beats=%d frequency_hz=%d; NOT A SAVE TEST',
                    result[1], result[2], base[2], result[3], result[4], overlap[3], overlap[4], #beats, result[5]))
            end) end)
        end)
    end) end)
end
return M
