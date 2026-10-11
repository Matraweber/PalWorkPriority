local driver = dofile(TEST_ROOT .. '/experiments/native-lua-handoff-probe/driver.lua')
local function scenario(mode)
    local queue, reports, diagnostics, seq = {}, {}, {}, 0
    local now, thread = 0, 1
    local generation = {active = true}
    local function schedule(at, tid, fn)
        seq = seq + 1
        queue[#queue + 1] = {at=at, tid=tid, fn=fn, seq=seq}
    end
    local function pump(limit)
        while true do
            table.sort(queue, function(a,b) return a.at == b.at and a.seq < b.seq or a.at < b.at end)
            local event = queue[1]
            if not event or event.at > limit then break end
            table.remove(queue, 1)
            local before = thread
            now, thread = math.max(now, event.at), event.tid
            event.fn()
            thread = before
        end
    end
    local d = {}
    function d.game(fn) schedule(now, 1, fn) end
    function d.async(fn) schedule(now, mode == 'same thread' and 1 or 2, fn) end
    function d.delay(ms, fn)
        if mode ~= 'no heartbeat' or ms ~= 25 then schedule(now + ms, 1, fn) end
    end
    function d.report(ok, message) reports[#reports+1] = {ok, message} end
    function d.diagnostic(message) diagnostics[#diagnostics+1] = message end
    function d.native(hex, delay, length)
        assert(length == #hex and not hex:find('[^0-9a-f]'))
        local decoded = hex:gsub('..', function(pair) return string.char(tonumber(pair,16)) end)
        local start, tid = now, thread
        if mode == 'native result count' and delay > 0 then return end
        if delay > 0 then
            collectgarbage('collect')
            if mode == 'stale generation' then generation.active = false end
            pump(start + delay)
            now = start + delay
        end
        local checksum = driver.checksum(decoded)
        if mode == 'bad checksum' and delay > 0 then checksum = checksum + 1 end
        local frequency = mode == 'frequency mismatch' and delay > 0 and 2000000 or 1000000
        if mode == 'edge ambiguity' and delay == 0 and start > 0 then
            return checksum, tid, 2, 2, frequency
        end
        return checksum, tid, start * 1000,
            mode == 'delay too short' and delay > 0 and (start*1000+199999) or now*1000, frequency
    end
    local input = '00017f80ff6162'
    driver.run(d, generation, input)
    input = nil; collectgarbage('collect')
    pump(2000)
    assert(#reports == 1, 'must report exactly once: ' .. mode)
    assert(#diagnostics == 1 and diagnostics[1]:find('elapsed_us=',1,true)
        and diagnostics[1]:find('frequency_hz=',1,true)
        and diagnostics[1]:find('expected_checksum=',1,true), 'raw diagnostic missing: ' .. mode)
    if mode == 'delay too short' then
        assert(reports[1][2]:find('elapsed_us=199999',1,true)
            and reports[1][2]:find('beat[1]',1,true), 'failure lost measurements')
    end
    return reports[1]
end
assert(driver.checksum('') == 5381)
assert(driver.checksum(string.char(0,1,255)) == 193377285)
local pass = scenario('pass')
assert(pass[1] and pass[2]:find('NOT A SAVE TEST',1,true))
for _, mode in ipairs({'bad checksum','same thread','no heartbeat','stale generation','delay too short','frequency mismatch','native result count'}) do
    local result = scenario(mode)
    assert(not result[1] and result[2]:find(mode,1,true), mode .. ': ' .. result[2])
end
local edge = scenario('edge ambiguity')
assert(not edge[1] and edge[2]:find('no heartbeat',1,true), 'ambiguous edge accepted')
for _, bad in ipairs({'00\0ff', 'xx', '0', string.rep('00',256*1024+1)}) do
    assert(not pcall(driver.run, {}, {active=true}, bad), 'invalid hex accepted')
end
-- An in-memory mock exercises the actual one-shot driver adapter, never loadlib.
local files = {['/probe/run.txt']='PWP_HANDOFF_PROBE offline-nonce\n'}
local loads = 0
local env = setmetatable({}, {__index=_G})
env._G = env
env.debug = {getinfo=function() return {source='@/probe/main.lua'} end}
env.io = {open=function(path, mode)
    if mode == 'r' and not files[path] then return nil end
    if mode == 'w' then files[path] = '' end
    return {read=function() return files[path] end, close=function() return true end,
        write=function(_, value) files[path]=(files[path] or '') .. value; return true end}
end}
env.print=function() end
env.package={loadlib=function()
    assert(files['/probe/run.txt']=='DISABLED\n', 'must disarm before loading')
    loads=loads+1; return function() end
end}
env.dofile=function() return {run=function(_, _, input)
    assert(#input==512*1024 and not input:find('[^0-9a-f]'))
end} end
env.ExecuteAsync=function() end
env.ExecuteInGameThread=function() end
env.ExecuteInGameThreadWithDelay=function() end
local adapter = assert(loadfile(TEST_ROOT .. '/experiments/native-lua-handoff-probe/main.lua','t',env))
adapter(); adapter()
assert(loads==1, 'arm was reusable')
print('native handoff V2: success, eight failure gates, raw diagnostics, invalid hex, GC, and one-shot disarm passed')
