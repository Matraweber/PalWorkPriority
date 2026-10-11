local perf = require("perf")
local now, seconds = 0, 100
local p = perf.new({ clock = function() return now end, wall_clock = function() return seconds end,
    resolution_ms = 1, max_labels = 4, max_events = 3 })
local function row(name)
    for _, r in ipairs(p:snapshot().rows) do if r.name == name then return r end end
end
local function close(a, b) assert(math.abs(a - b) < 0.00001, tostring(a) .. " ~= " .. tostring(b)) end

-- A count without a clock pair must never be presented as a zero-cost reading.
p:count("counted")
assert(row("counted").total_ms == nil and row("counted").timed_samples == 0)
assert(p:report():find("unmeasured", 1, true))
p:set_enabled(true)
p:count("untimed route")
local legacy = p:count("legacy")
legacy.ms = legacy.ms + 0
assert(row("legacy").timed_samples == 1 and row("legacy").total_ms == 0)
assert(row("untimed route").total_ms == nil)
legacy = p:count("legacy")
legacy.ms = legacy.ms + 7
assert(row("legacy").calls == 2 and row("legacy").timed_samples == 2)
assert(row("legacy").total_ms == 7 and row("legacy").mean_ms == 3.5)

-- Nested measurements are inclusive, are reported separately, and preserve time.
p:reset()
local parent = p:begin("parent")
now = 0.002
local child = p:begin("child")
now = 0.005
p:finish(child)
now = 0.010
p:finish(parent)
p:finish(parent) -- duplicate unwind cannot double count
close(row("parent").total_ms, 10)
close(row("child").total_ms, 3)
assert(row("parent").timed_samples == 1)
assert(p:report():find("must not be summed", 1, true))
assert(p:snapshot().window_seconds == 0 and row("parent").measured_ms_per_second == nil)
seconds = seconds + 10
close(row("parent").measured_ms_per_second, 1)

-- Mode changes and resets invalidate outstanding samples and measurement windows.
local stale = p:begin("stale")
p:set_enabled(false)
p:finish(stale)
p:count("off")
assert(#p:snapshot().rows == 1 and row("off").total_ms == nil)
p:set_enabled(true)
assert(#p:snapshot().rows == 0 and p:snapshot().window_seconds == 0)

-- Exceptions still close the inclusive sample; nil return values are preserved.
local ok, err = pcall(function() p:around("throw", function() now = now + 0.02; error("intentional") end) end)
assert(not ok and tostring(err):find("intentional", 1, true))
close(row("throw").total_ms, 20)
local a, b, c = p:around("nil result", function() return 1, nil, 3 end)
assert(a == 1 and b == nil and c == 3)

-- Histograms/events/label cardinality are bounded even during long sessions.
p:reset()
for i = 1, 1000 do p:observe("load", i % 50) end
local total = 0
for _, bin in ipairs(row("load").histogram) do total = total + bin.samples end
assert(total == 1000 and row("load").p95_upper_ms >= 47)
assert(#p:snapshot().worst == 3)
for i = 1, 1000 do p:count("dynamic pal " .. i) end
assert(#p:snapshot().rows <= 5)
local snapshot = p:snapshot()
snapshot.worst[1].ms = -1
assert(p:snapshot().worst[1].ms >= 0)

p:reset()
p:observe("bad", -1)
p:observe("bad", 0 / 0)
p:observe("bad", math.huge)
assert(row("bad").total_ms == nil and p:snapshot().discarded == 3)

local ticks = 0
local calibrated = perf.new({ clock = function() ticks = ticks + 0.001; return ticks end })
calibrated:set_enabled(true)
assert(calibrated:snapshot().resolution_ms > 0.9 and calibrated:snapshot().resolution_ms < 1.1)
