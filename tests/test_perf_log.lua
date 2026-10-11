local original = { print = print, open = io.open, clock = os.clock, time = os.time, date = os.date }
local console, files, closes = {}, {}, 0
local now, seconds, failure, console_failure = 0, 100, nil, false
os.clock = function() return now end
os.time = function() return seconds end
os.date = function() return "2026-09-11 12:00:00" end
print = function(line)
    now = now + 0.002
    if console_failure then error("console down") end
    console[#console + 1] = line
end
io.open = function()
    now = now + 0.001
    if failure == "open" then return nil, "permission denied" end
    local handle = {}
    function handle:write(line)
        now = now + 0.003
        if failure == "write" then return nil, "disk full" end
        if failure == "throw" then error("write exploded") end
        files[#files + 1] = line
        return self
    end
    function handle:close()
        now, closes = now + 0.005, closes + 1
        if failure == "close" then return nil, "flush failed" end
        return true
    end
    return handle
end
package.loaded.log = nil
local log = require("log")
log.file_path = "test-only"
log.set_perf(true)
log.say("first\n")
assert(console[1] == "[PalWorkPriority] first\n")
assert(files[1] == "2026-09-11 12:00:00 [PalWorkPriority] first\n", tostring(files[1]) .. "; " .. tostring(log.sinks.file.last_error))
assert(log.marks["log: console write"].timed_n == 1)
assert(log.marks["log: file write"].timed_n == 1)
assert(math.abs(log.marks["log: file write"].ms - 9) < 0.0001)
assert(math.abs(log.marks["log: console write"].ms - 2) < 0.0001)

for _, kind in ipairs({ "open", "write", "throw", "close" }) do
    failure = kind
    local previous, was_closed = log.sinks.file.failures, closes
    log.say("failure " .. kind)
    assert(log.sinks.file.failures == previous + 1 and log.sinks.file.last_error)
    assert(closes == was_closed + (kind == "open" and 0 or 1))
    seconds = seconds + 6
end
assert(log.report():find("4 failures", 1, true))
failure = nil
log.say("recovered")
assert(log.sinks.file.consecutive == 0 and log.sinks.file.failures == 4)
console_failure = true
log.say("console failure is reported to file")
assert(log.sinks.console.failures == 1)
assert(files[#files]:find("console log sink failed", 1, true))
failure = "open"
local ok = pcall(log.say, "both sinks down")
assert(ok and log.sinks.console.consecutive > 0 and log.sinks.file.consecutive > 0)
console_failure, failure = false, nil

-- Repeated errors produce one initial line plus an explicit aggregate.
local before = #console
for _ = 1, 100 do log.error("same failure") end
assert(#console == before + 1)
log.flush_repeats()
assert(#console == before + 2 and console[#console]:find("repeated 99 additional times", 1, true))
seconds = seconds + 6
log.error("same failure")
assert(#console == before + 3)
log.set_level("error")
before = #console
log.info("filtered")
assert(#console == before)
log.set_perf(false)
log.say("timing off")
assert(log.marks["log: console write"].timed_n == 0)
assert(log.report():find("unmeasured", 1, true))
print, io.open, os.clock, os.time, os.date = original.print, original.open, original.clock, original.time, original.date
