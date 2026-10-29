-- palapi.camp_works reports entries it had to skip (review 2026-10-29,
-- engine P2-3). A throw on one entry used to be swallowed and the list
-- returned as complete, so a held rock among the skipped entries read as
-- gone while it still stood NotWorkable.
package.loaded.log = { warn = function() end, debug = function() end, say = function() end,
    count = function() return { ms = 0 } end }
package.loaded.palapi = nil
local api = require('palapi')

local function live(o) o.IsValid = function() return true end; return o end
local function guid(n) return { A = 1, B = 2, C = 3, D = n } end
local throws, missing = {}, {}
local wpm = live({ GetWork = function(_, id)
    if throws[id.D] then error('GetWork threw') end
    if missing[id.D] then return nil end
    return live({ id = id.D })
end })
api.work_progress_manager = function() return wpm end
local ids = { guid(1), guid(2), guid(3) }
local camp = { WorkCollection = live({ WorkIds = { ForEach = function(_, fn)
    for i, id in ipairs(ids) do fn(i, id) end
end } }) }

local works, err, keys, skipped = api.camp_works(camp)
assert(#works == 3 and err == nil and keys[3] == '1-2-3-3' and skipped == 0, 'clean list')

throws[2] = true
works, err, keys, skipped = api.camp_works(camp)
assert(#works == 2 and err == nil, 'one bad entry must not fail the whole list')
assert(skipped == 1, 'a skipped entry was not reported: ' .. tostring(skipped))
assert(keys[1] == '1-2-3-1' and keys[2] == '1-2-3-3')

-- An id that resolves to no work is a work that is gone, not a skip.
throws[2], missing[2] = nil, true
works, err, keys, skipped = api.camp_works(camp)
assert(#works == 2 and err == nil and skipped == 0, 'a gone work counted as skipped')
print('palapi camp_works: skipped entries counted, gone works are not skips')
