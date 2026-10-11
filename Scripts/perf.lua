-- Bounded, opt-in measurements. Durations are inclusive; nested rows overlap.
-- os.clock is the Lua runtime's clock, not an independent game frame timer.
local M = {}
local LIMITS = { 0, 0.05, 0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 33, 50, 100, 250, 500, 1000, math.huge }

local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

function M.new(options)
    options = options or {}
    local clock = options.clock or os.clock
    local wall = options.wall_clock or os.time
    local self = {
        enabled = false, marks = {}, since = wall(), clock_since = clock(), epoch = 0,
        resolution_ms = options.resolution_ms, worst = {}, discarded = 0,
        max_labels = options.max_labels or 128, max_events = options.max_events or 8,
        clock_source = options.clock_source or "Lua os.clock (runtime-dependent CPU/elapsed clock; not frame time)",
        label_count = 0,
    }

    local function record(b, ms, detail)
        if not self.enabled or b.epoch ~= self.epoch then return end
        if not finite(ms) or ms < 0 then
            self.discarded = self.discarded + 1
            return
        end
        b.timed_n = b.timed_n + 1
        b._ms = b._ms + ms
        b.min_ms = math.min(b.min_ms or ms, ms)
        b.max_ms = math.max(b.max_ms or ms, ms)
        for i, upper in ipairs(LIMITS) do
            if ms <= upper then
                b.histogram[i] = (b.histogram[i] or 0) + 1
                break
            end
        end
        if #self.worst < self.max_events or ms > self.worst[#self.worst].ms then
            self.worst[#self.worst + 1] = {
                name = b.name, ms = ms, at_seconds = math.max(0, wall() - self.since),
                at_clock_seconds = clock() - self.clock_since,
                detail = detail and tostring(detail):sub(1, 160) or nil,
            }
            table.sort(self.worst, function(a, z) return a.ms > z.ms end)
            if #self.worst > self.max_events then table.remove(self.worst) end
        end
    end

    function self:reset()
        self.marks, self.worst = {}, {}
        self.since, self.clock_since, self.epoch = wall(), clock(), self.epoch + 1
        self.label_count, self.discarded = 0, 0
    end

    function self:set_enabled(enabled)
        enabled = enabled == true
        if enabled == self.enabled then return end
        self.enabled = enabled
        self:reset() -- Never divide old timings by a window of untimed calls.
        if enabled and not self.resolution_ms then
            local previous = clock()
            for _ = 1, 4096 do
                local now = clock()
                local delta = (now - previous) * 1000
                if delta > 0 and finite(delta) then
                    self.resolution_ms = math.min(self.resolution_ms or delta, delta)
                end
                previous = now
            end
        end
    end

    function self:count(name)
        name = tostring(name):sub(1, 160)
        local b = self.marks[name]
        if not b then
            if self.label_count >= self.max_labels then name = "[other labels]" end
            b = self.marks[name]
            if not b then
                b = { name = name, n = 0, _ms = 0, timed_n = 0, histogram = {}, epoch = self.epoch }
                -- Keep b.ms = b.ms + elapsed compatible, including measured
                -- zero-duration samples. Count-only buckets never get a sample.
                setmetatable(b, {
                    __index = function(t, k) if k == "ms" then return t._ms end end,
                    __newindex = function(t, k, v)
                        if k == "ms" then
                            record(t, finite(v) and (v - t._ms) or (0 / 0))
                        else
                            rawset(t, k, v)
                        end
                    end,
                })
                self.marks[name] = b
                self.label_count = self.label_count + 1
            end
        end
        b.n = b.n + 1
        return b
    end

    function self:begin(name)
        local b = self:count(name)
        if not self.enabled then return nil end
        return { bucket = b, started = clock(), epoch = self.epoch }
    end

    function self:finish(token, detail)
        if not token or token.finished then return end
        token.finished = true
        if token.epoch ~= self.epoch then return end
        local ended=clock()
        record(token.bucket, (ended - token.started) * 1000, detail)
        if options.on_finish then options.on_finish(token.bucket.name, token.started, ended) end
    end

    function self:observe(name, ms, detail)
        record(self:count(name), ms, detail)
    end

    function self:around(name, fn, ...)
        local token = self:begin(name)
        local result = table.pack(pcall(fn, ...))
        self:finish(token, (not result[1]) and "callback failed" or nil)
        if not result[1] then error(result[2], 0) end
        return table.unpack(result, 2, result.n)
    end

    local function percentile(b, fraction)
        if b.timed_n == 0 then return nil end
        local target, seen = math.ceil(b.timed_n * fraction), 0
        for i, upper in ipairs(LIMITS) do
            seen = seen + (b.histogram[i] or 0)
            if seen >= target then return math.min(upper, b.max_ms) end
        end
    end

    function self:snapshot()
        local result = {
            enabled = self.enabled, window_seconds = math.max(0, wall() - self.since),
            wall_started_at = self.since, clock_started_at = self.clock_since,
            window_clock = "os.time wall clock (1 second granularity) unless explicitly injected",
            clock_source = self.clock_source, resolution_ms = self.resolution_ms,
            resolution_kind = "smallest observed positive clock step; zero does not mean free",
            timing_kind = "inclusive; nested rows overlap and must not be summed",
            discarded = self.discarded, rows = {}, worst = {},
        }
        for name, b in pairs(self.marks) do
            local histogram = {}
            for i, upper in ipairs(LIMITS) do
                histogram[i] = { upper_ms = upper, samples = b.histogram[i] or 0 }
            end
            result.rows[#result.rows + 1] = {
                name = name, calls = b.n, timed_samples = b.timed_n,
                unmeasured_calls = math.max(0, b.n - b.timed_n),
                total_ms = b.timed_n > 0 and b.ms or nil,
                mean_ms = b.timed_n > 0 and b.ms / b.timed_n or nil,
                min_ms = b.min_ms, max_ms = b.max_ms,
                p50_upper_ms = percentile(b, 0.50), p95_upper_ms = percentile(b, 0.95),
                p99_upper_ms = percentile(b, 0.99),
                histogram = histogram,
                calls_per_second = result.window_seconds > 0 and b.n / result.window_seconds or nil,
                measured_ms_per_second = b.timed_n > 0 and result.window_seconds > 0 and b.ms / result.window_seconds or nil,
            }
        end
        table.sort(result.rows, function(a, b)
            if (a.total_ms or -1) ~= (b.total_ms or -1) then
                return (a.total_ms or -1) > (b.total_ms or -1)
            end
            return a.name < b.name
        end)
        for i, event in ipairs(self.worst) do
            result.worst[i] = { name = event.name, ms = event.ms, at_seconds = event.at_seconds,
                at_clock_seconds = event.at_clock_seconds, detail = event.detail }
        end
        return result
    end

    function self:report()
        local s = self:snapshot()
        local lines = {
            string.format("perf: timing %s; %.1fs measurement window", s.enabled and "on" or "off", s.window_seconds),
            "clock: " .. s.clock_source,
            "resolution: " .. (s.resolution_ms and string.format("%.6gms observed step", s.resolution_ms) or "unmeasured") ..
                "; zero durations may be below resolution",
            "window: " .. s.window_clock,
            "durations: " .. s.timing_kind,
            "calls / timed samples / inclusive total / mean / worst / p95 upper bound / measured ms per wall second",
        }
        for _, row in ipairs(s.rows) do
            local timing = "unmeasured"
            if row.total_ms ~= nil then
                timing = string.format("%.3fms / %.3fms / %.3fms / <=%.3fms",
                    row.total_ms, row.mean_ms, row.max_ms, row.p95_upper_ms)
                timing = timing .. " / " .. (row.measured_ms_per_second and
                    string.format("%.3fms/s", row.measured_ms_per_second) or "window too short")
            end
            lines[#lines + 1] = string.format("%s: %d / %d / %s", row.name, row.calls, row.timed_samples, timing)
        end
        for _, event in ipairs(s.worst) do
            lines[#lines + 1] = string.format("worst event +%.1fs wall / +%.6fs runtime clock: %s %.3fms%s", event.at_seconds,
                event.at_clock_seconds, event.name, event.ms, event.detail and (" (" .. event.detail .. ")") or "")
        end
        if s.discarded > 0 then lines[#lines + 1] = "invalid clock samples discarded: " .. s.discarded end
        return table.concat(lines, "\n"), s
    end

    return self
end

return M
