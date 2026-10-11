-- Both sinks receive complete lines. Sink failures are data, not recursive logs.
local M = {}
local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local TAG = "[PalWorkPriority] "
local measurements = require("perf")
local frame_trace = require('frame_trace').new()
local profiler = measurements.new({on_finish=function(name,first,last) frame_trace:record(name,first,last) end})
local repeats = {}
local repeat_count = 0
local REPEAT_SECONDS, MAX_REPEATS = 5, 128

M.threshold = LEVELS.info
M.file_path = nil
M.perf = false
M.marks = profiler.marks
M.marks_since = profiler.since
M.sinks = {
    console = { attempts = 0, failures = 0, consecutive = 0 },
    file = { attempts = 0, failures = 0, consecutive = 0 },
}

local function sync_mode()
    profiler:set_enabled(M.perf)
    M.marks, M.marks_since = profiler.marks, profiler.since
end

function M.set_level(name) M.threshold = LEVELS[name] or LEVELS.info end
function M.set_perf(enabled) M.perf = enabled == true; sync_mode() end
function M.count(name) sync_mode(); return profiler:count(name) end
function M.begin(name) sync_mode(); return profiler:begin(name) end
function M.finish(token, detail) sync_mode(); profiler:finish(token, detail) end
function M.observe(name, ms, detail) sync_mode(); profiler:observe(name, ms, detail) end
function M.around(name, fn, ...) sync_mode(); return profiler:around(name, fn, ...) end

function M.reset_marks()
    sync_mode()
    profiler:reset()
    M.marks, M.marks_since = profiler.marks, profiler.since
end

function M.snapshot() sync_mode(); return profiler:snapshot() end

function M.start_frame_events() M.set_perf(true); M.reset_marks(); frame_trace:start() end
function M.stop_frame_events() frame_trace:stop() end
function M.frame_anchor(path,id) return frame_trace:anchor(path,id) end
function M.export_frame_events(path) return frame_trace:export(path) end

local function sink_result(name, ok, err)
    local s = M.sinks[name]
    s.attempts = s.attempts + 1
    if not ok then
        s.failures, s.consecutive = s.failures + 1, s.consecutive + 1
        s.last_error, s.last_failed_at = tostring(err):sub(1, 400), os.time()
    else
        s.consecutive = 0
    end
    return ok
end

local function console_write(line)
    local token = M.begin("log: console write")
    local ok, err = pcall(print, line .. "\n")
    M.finish(token, (not ok) and "sink failed" or nil)
    return sink_result("console", ok, err)
end

local function file_write(line)
    if not M.file_path then return true end
    local token = M.begin("log: file write")
    local handle
    local ok, err = pcall(function()
        local reason
        handle, reason = io.open(M.file_path, "a")
        if not handle then error("open: " .. tostring(reason), 0) end
        local written
        written, reason = handle:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. line .. "\n")
        if not written then error("write: " .. tostring(reason), 0) end
    end)
    -- close can return nil without throwing, and must run after a failed write.
    if handle then
        local close_ok, closed, close_err = pcall(function() return handle:close() end)
        if not close_ok or not closed then
            local detail = "close: " .. tostring(close_ok and close_err or closed)
            err = ok and detail or (tostring(err) .. "; " .. detail)
            ok = false
        end
    end
    M.finish(token, (not ok) and "sink failed" or nil)
    return sink_result("file", ok, err)
end

local function write_line(line)
    line = line:gsub("\r\n", "\n"):gsub("[\r\n]+$", "")
    local console_ok = console_write(line)
    local file_ok = file_write(line)
    -- Notify through the surviving sink at most once per five seconds.
    -- When both fail, report()/sinks still retain the evidence.
    local now = os.time()
    for _, name in ipairs({ "console", "file" }) do
        local s = M.sinks[name]
        if s.consecutive > 0 and (not s.notified_at or now - s.notified_at >= REPEAT_SECONDS) then
            s.notified_at = now
            local notice = TAG .. "ERROR " .. name .. " log sink failed: " .. tostring(s.last_error)
            if name == "console" and file_ok then file_write(notice)
            elseif name == "file" and console_ok then console_write(notice) end
        end
    end
end

local function repeated_line(entry)
    if entry.suppressed > 0 then
        write_line(entry.line .. string.format(" [repeated %d additional times]", entry.suppressed))
        entry.suppressed = 0
    end
end

function M.flush_repeats()
    for _, entry in pairs(repeats) do repeated_line(entry) end
end

local function emit(level, msg)
    if (LEVELS[level] or LEVELS.info) < M.threshold then return end
    local line = TAG .. string.upper(level) .. " " .. tostring(msg)
    if (level == "warn" or level == "error") and #line <= 2048 then
        local now, entry = os.time(), repeats[line]
        if entry and now - entry.at < REPEAT_SECONDS then
            entry.suppressed = entry.suppressed + 1
            return
        end
        if entry then
            if entry.suppressed > 0 then
                entry.suppressed = entry.suppressed + 1
                repeated_line(entry)
                entry.at = now
                return
            end
        elseif repeat_count >= MAX_REPEATS then
            local oldest_key, oldest
            for key, value in pairs(repeats) do
                if not oldest or value.at < oldest.at then oldest_key, oldest = key, value end
            end
            repeated_line(oldest)
            repeats[oldest_key] = nil
            repeat_count = repeat_count - 1
        end
        if not entry then repeat_count = repeat_count + 1 end
        repeats[line] = { at = now, suppressed = 0, line = line }
    end
    write_line(line)
end

function M.debug(msg) emit("debug", msg) end
function M.info(msg) emit("info", msg) end
function M.warn(msg) emit("warn", msg) end
function M.error(msg) emit("error", msg) end
function M.say(msg) write_line(TAG .. tostring(msg)) end

-- One report string, so main can log.say(log.report()) once, after the snapshot.
function M.report()
    sync_mode()
    local report = profiler:report()
    local lines = { report }
    for _, name in ipairs({ "console", "file" }) do
        local s = M.sinks[name]
        lines[#lines + 1] = string.format("%s sink (session): %d attempts, %d failures%s", name,
            s.attempts, s.failures, s.last_error and ("; last failure: " .. s.last_error) or "")
    end
    return table.concat(lines, "\n")
end

return M
