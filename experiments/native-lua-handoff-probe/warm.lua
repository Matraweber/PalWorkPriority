-- Independent adapter: run this file from a separately installed probe's entry.
-- warm-run.txt: PWP_HANDOFF_WARM <nonce>. Never a save test.
local source = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local dir = assert(source:match('^(.*)/[^/]+%.lua$'))
local arm = io.open(dir .. '/warm-run.txt', 'r')
if not arm then return end
local request = arm:read(128)
local extra = arm:read(1)
assert(arm:close())
local nonce = not extra and request and request:match('^PWP_HANDOFF_WARM ([%w%-]+)%s*$')
if not nonce or #nonce > 64 then return end

local stopped, trial = false, 0
local native, driver, generation
local function log(kind, message)
    local line = os.date('!%Y-%m-%dT%H:%M:%SZ ') .. nonce .. ' trial=' .. trial .. ' ' .. kind .. ' ' .. message
    local f = assert(io.open(dir .. '/warm.log', 'a'))
    assert(f:write(line .. '\n')); assert(f:close())
    print(line .. '\n')
end
local function fail(message)
    if stopped then return end
    stopped = true
    if generation then generation.active = false end
    local ok, err = pcall(log, 'FAIL', tostring(message))
    if not ok then print(nonce .. ' trial=' .. trial .. ' FAIL logging error: ' .. tostring(err) .. '; ' .. tostring(message)) end
end
local function current()
    if stopped then return false end
    if not generation.active or rawget(_G, 'PWP_HANDOFF_WARM_GENERATION') ~= generation then
        fail('stale generation'); return false
    end
    return true
end
local function guarded(fn)
    return function(...)
        if not current() then return end
        local ok, err = pcall(fn, ...)
        if not ok then fail(err) end
    end
end
local function delayed(ms, fn)
    assert(math.type(ms) == 'integer' and ms >= 0 and ms <= 90000, 'timer bound')
    ExecuteInGameThreadWithDelay(ms, guarded(fn))
end
local start_trial
start_trial = function()
    assert(trial < 3, 'trial bound')
    trial = trial + 1
    log('START', 'warm handoff V2; NOT A SAVE TEST')
    if not native then
        native = assert(package.loadlib(dir .. '/pwp_handoff_probe_v2.dll', 'luaopen_pwp_handoff_probe'))
        driver = dofile(dir .. '/driver.lua')
        assert(type(driver.run) == 'function', 'driver unavailable')
    end
    local this_trial, finished = trial, false
    local function callback(fn)
        return guarded(function(...)
            if finished or trial ~= this_trial then return end
            return fn(...)
        end)
    end
    local dependencies = {
        native = native,
        game = function(fn) ExecuteInGameThread(callback(fn)) end,
        async = function(fn) ExecuteAsync(callback(fn)) end,
        delay = function(ms, fn) delayed(ms, callback(fn)) end,
        diagnostic = function(message)
            if not finished and current() then log('DIAG', message) end
        end,
        report = function(ok, message)
            if finished or not current() then return end
            finished = true
            if not ok then fail(message); return end
            log('PASS', message)
            if trial < 3 then delayed(10000, start_trial) else stopped = true end
        end,
    }
    local bytes = {}
    for i = 0, 255 do bytes[#bytes + 1] = string.format('%02x', i) end
    local input = table.concat(bytes):rep(1024)
    driver.run(dependencies, generation, input)
    input = nil; collectgarbage('collect')
end

local ok, err = pcall(function()
    local f = assert(io.open(dir .. '/warm-run.txt', 'w'))
    assert(f:write('DISABLED\n')); assert(f:close())
    assert(type(ExecuteAsync) == 'function' and type(ExecuteInGameThread) == 'function'
        and type(ExecuteInGameThreadWithDelay) == 'function', 'required scheduling APIs unavailable')
    local previous = rawget(_G, 'PWP_HANDOFF_WARM_GENERATION')
    if previous then previous.active = false end
    generation = {active = true, nonce = nonce}
    _G.PWP_HANDOFF_WARM_GENERATION = generation
    log('ARMED', 'first_delay_ms=90000 trials=3 gap_after_pass_ms=10000; NOT A SAVE TEST')
    delayed(90000, start_trial)
end)
if not ok then fail(err) end
