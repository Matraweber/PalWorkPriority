-- Opt-in diagnostic driver. Loading this file does not register anything.
-- Manually invoke start(_G, logger) from an isolated dev harness next restart.
-- No admission, scheduling, save IO, engine-wrapper access or production setup.
local directory = debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/save_lifecycle_epoch_observer.lua$')
local Epoch = dofile(directory .. '/save_lifecycle_epoch.lua')
local M = {}
function M.start(api, logger, max_events)
    assert(type(logger) == 'function', 'scalar-string logger required')
    max_events = max_events or 256
    assert(math.type(max_events) == 'integer' and max_events >= 1 and max_events <= 4096)
    local lines = 0
    local c = Epoch.new{enabled=true, observe=function(event, s)
        if lines >= max_events then return end
        lines = lines + 1
        logger(string.format('[save-lifecycle] seq=%d event=%s epoch=%d ready=%s load=%d init=%d terminal=%s reason=%s%s',
            lines, event, s.epoch, tostring(s.ready), s.load_depth, s.init_depth,
            tostring(s.terminal), s.reason, lines == max_events and ' log_limit_reached' or ''))
    end}
    local installed = c:install(api)
    -- Do not return the controller: this observer must never authorize admission.
    pcall(logger, '[save-lifecycle] install=' .. tostring(installed) .. ' reason=' .. c:status().reason)
    return {installed=installed, status=function() return c:status() end}
end
return M
