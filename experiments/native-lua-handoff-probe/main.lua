-- Inert until a separate, explicitly authorized deployment and one-shot arm.
local path = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local dir = assert(path:match('^(.*)/main.lua$'))
local arm = io.open(dir .. '/run.txt', 'r')
if not arm then return end
local request = arm:read('*a'); assert(arm:close())
local nonce = request:match('^PWP_HANDOFF_PROBE ([%w%-]+)%s*$')
if not nonce or #nonce > 64 then return end
local out = assert(io.open(dir .. '/run.txt', 'w'))
assert(out:write('DISABLED\n')); assert(out:close())
local function log(kind, message)
    local f = assert(io.open(dir .. '/handoff.log', 'a'))
    local line = os.date('!%Y-%m-%dT%H:%M:%SZ ') .. nonce .. ' ' .. kind .. ' ' .. message
    assert(f:write(line .. '\n')); assert(f:close()); print(line .. '\n')
end
local function report(ok, message) log(ok and 'PASS' or 'FAIL', message) end
local ok, err = pcall(function()
    local previous = rawget(_G, 'PWP_HANDOFF_GENERATION')
    if previous then previous.active = false end
    local generation = {active = true, nonce = nonce}
    _G.PWP_HANDOFF_GENERATION = generation
    local native = assert(package.loadlib(dir .. '/pwp_handoff_probe_v2.dll', 'luaopen_pwp_handoff_probe'))
    local driver = dofile(dir .. '/driver.lua')
    assert(type(ExecuteAsync) == 'function' and type(ExecuteInGameThread) == 'function'
        and type(ExecuteInGameThreadWithDelay) == 'function', 'required scheduling APIs unavailable')
    local bytes = {}
    for i = 0, 255 do bytes[#bytes + 1] = string.format('%02x', i) end
    local input = table.concat(bytes):rep(1024)
    driver.run({native = native, game = ExecuteInGameThread, async = ExecuteAsync,
        delay = ExecuteInGameThreadWithDelay, report = report,
        diagnostic = function(message) log('DIAG', message) end}, generation, input)
    input = nil; collectgarbage('collect')
end)
if not ok then report(false, tostring(err)) end
