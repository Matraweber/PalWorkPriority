-- Isolated, manually installed observer. No storage grant, writes or native IO.
-- Only run.txt (self-disarm) and lifecycle.log (diagnostics) are written.
local root = assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/Scripts/main.lua$'))
local function console(message) pcall(print, '[save-lifecycle] ' .. message .. '\n') end
local function read_arm()
    local f = io.open(root .. '/run.txt', 'r')
    if not f then return end
    local ok, request, extra = pcall(function() return f:read(128), f:read(1) end)
    local closed, result = pcall(function() return f:close() end)
    if not ok or not closed or not result then error('arm_read_failed') end
    local nonce = not extra and request and request:match('^PWP_LIFECYCLE ([%w%-]+)%s*$')
    if nonce and #nonce <= 64 then return nonce end
end
local armed, nonce = pcall(read_arm)
if not armed then console('FAIL arm_read'); return end
if not nonce then return end
-- Consume authorization BEFORE loading modules, registering hooks or scheduling.
local disarmed = pcall(function()
    local f = assert(io.open(root .. '/run.txt', 'w'))
    local ok, written = pcall(function() return f:write('DISABLED\n') end)
    local closed, result = pcall(function() return f:close() end)
    assert(ok and written and closed and result, 'self_disarm_failed')
end)
if not disarmed then console('FAIL self_disarm'); return end
-- One installation attempt per Lua environment, including partial failures.
if rawget(_G, 'PWP_LIFECYCLE_OBSERVER_STARTED') then return end
_G.PWP_LIFECYCLE_OBSERVER_STARTED = true

local MAX_LINES, MAX_TICKS, SECONDS = 4096, 1800, 1800
local lines, ticks, finished = 0, 0, false
local handle, cancel, started, last_time, last_sample, observer
local stop
local function scalar(value)
    local kind = type(value)
    if kind == 'string' then return (value:sub(1,512):gsub('%c','?')) end
    if kind == 'number' or kind == 'boolean' or kind == 'nil' then return tostring(value) end
    return '<non-scalar>' -- never stringify/access an engine wrapper
end
local function append(message)
    if lines >= MAX_LINES then return false end
    lines = lines + 1 -- attempts are bounded even if the sink fails
    local f
    local ok = pcall(function()
        local stamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
        f = assert(io.open(root .. '/lifecycle.log', 'a'))
        assert(f:write(stamp .. ' ' .. nonce .. ' seq=' .. lines .. ' ' ..
            message:sub(1,8192):gsub('[\r\n]','?') .. ' verified=false storage_grant=false\n'))
    end)
    local closed, result = true, true
    if f then closed, result = pcall(function() return f:close() end) end
    return ok and closed and result and true or false
end
local function cancel_timer()
    if handle == nil then return 'no_handle' end
    local h = handle; handle = nil
    local ok, result = pcall(cancel, h)
    return ok and result == true and 'true' or 'false'
end
stop = function(reason)
    if finished then return end
    finished = true -- all retained callbacks become inert before cancellation
    local cancelled = cancel_timer()
    if not append(reason .. ' timer_cancelled=' .. cancelled) then
        console('STOP log_unavailable timer_cancelled=' .. cancelled)
    end
end
local function log(message)
    if finished then return end
    -- Reserve one line for a truthful stop/cancellation result.
    if lines >= MAX_LINES - 1 then stop('LINE_LIMIT'); return end
    if not append(message) then stop('FAIL log_io') end
end
local function active()
    if finished then return false end
    local now = os.time()
    assert(math.type(now) == 'integer', 'clock_unavailable')
    if now < last_time then stop('CLOCK_REVERSED'); return false end
    last_time = now
    if now - started >= SECONDS then stop('TIMEOUT'); return false end
    return true
end
local function guarded(fn)
    if finished then return end
    local ok = pcall(function() if active() then fn() end end)
    if not ok then stop('FAIL callback') end
end

local ok = pcall(function()
    started = os.time(); assert(math.type(started) == 'integer', 'clock_unavailable')
    last_time = started
    cancel = rawget(_G, 'CancelDelayedAction')
    local loop = rawget(_G, 'LoopInGameThreadWithDelay')
    assert(type(cancel) == 'function' and type(loop) == 'function', 'timer_unavailable')
    local Observer = dofile(root .. '/experiments/save_lifecycle_epoch_observer.lua')
    local World = dofile(root .. '/experiments/save_world_identity_probe.lua')
    local Identity = dofile(root .. '/experiments/save_identity_probe.lua')
    local get_engine = require('UEHelpers').GetEngine
    assert(type(get_engine) == 'function', 'engine_query_unavailable')
    log('ARMED diagnostic_only timeout_seconds=1800 max_lines=4096')
    if finished then return end
    local api = {}
    for _,name in ipairs({'RegisterLoadMapPreHook','RegisterLoadMapPostHook',
        'RegisterInitGameStatePreHook','RegisterInitGameStatePostHook'}) do
        local register = rawget(_G, name)
        if type(register) == 'function' then
            api[name] = function(cb)
                return register(function()
                    -- Ignore all engine arguments; no querying during transitions.
                    guarded(cb)
                    return nil -- never override LoadMap, including error/stop paths
                end)
            end
        end
    end
    observer = Observer.start(api, log, 4096)
    if not observer.installed then stop('FAIL hooks_unavailable'); return end
    if finished then return end
    local function sample()
        ticks = ticks + 1
        if ticks >= MAX_TICKS then stop('TICK_LIMIT'); return end
        -- Same fresh, current-chain query as the distinct-world driver. Neither
        -- engine nor returned tables escape this callback; only text is retained.
        local engine = get_engine()
        local w, i = World.read(engine), Identity.read(engine)
        local parts = {'epoch=' .. observer.status().epoch}
        for _,key in ipairs({'status','world','directory','directory_status','role',
            'role_status','dedicated','dedicated_status'}) do
            parts[#parts+1] = 'world.' .. key .. '=' .. scalar(rawget(w,key))
        end
        for _,key in ipairs({'state','world','selected','selected_status','autosave',
            'autosave_status','loaded_world','loaded_status','context_status',
            'world_address','instance_address','manager_address'}) do
            parts[#parts+1] = 'identity.' .. key .. '=' .. scalar(rawget(i,key))
        end
        local text = table.concat(parts, ' | ')
        if text ~= last_sample then
            last_sample = text
            log('SAMPLE_EDGE tick=' .. ticks .. ' ' .. text)
        end
    end
    local scheduled, result = pcall(loop, 1000, function() guarded(sample) end)
    if not scheduled or math.type(result) ~= 'integer' or result < 0 then
        stop('FAIL timer_registration'); return
    end
    handle = result
    -- Also handle a scheduler invoking the callback inline before returning its
    -- handle. A throw after scheduling yields no cancellable handle; guard stays off.
    if finished then
        console('late_handle timer_cancelled=' .. cancel_timer())
    end
end)
if not ok then stop('FAIL setup') end
