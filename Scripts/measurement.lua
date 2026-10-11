-- Inclusive scopes: child durations are already part of their parents.
local log = require('log')
local M = {}
local wrapped = setmetatable({}, {__mode='k'})
function M.callback(label, fn)
    local replacement = function(...)
        if not log.perf then log.count(label); return fn(...) end
        return log.around(label, fn, ...)
    end
    wrapped[replacement] = true
    return replacement
end
function M.bind(module, key, label)
    local fn = module[key]
    if type(fn) ~= 'function' or wrapped[fn] then return false end
    local replacement = M.callback(label, fn)
    module[key] = replacement
    return true
end
return M
