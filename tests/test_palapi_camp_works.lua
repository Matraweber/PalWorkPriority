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
local real_wpm = api.work_progress_manager
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

-- A headless dedicated server with nobody online (GPortal 2026-10-29): no
-- viewport, no player controller. The manager's world context came from the
-- controller walk, which found nothing every pass, so camp_works returned an
-- error and no works. The game instance is the context now: a manager, and
-- no walk at all.
throws, missing = {}, {}
api.work_progress_manager = real_wpm
local walks = 0
FindFirstOf = function() walks = walks + 1; return nil end
local gi = live({ world_context = true, GetFullName = function()
    return 'PalGameInstance /Engine/Transient.GameEngine_0:PalGameInstance_0' end })
local engine = live({ GameViewport = nil, GameInstance = gi })
package.loaded.UEHelpers = { GetEngine = function() return engine end }
local util = live({ GetWorkProgressManager = function(_, ctx)
    -- Like the engine: an object with no world gives no manager.
    if ctx ~= nil and ctx.world_context == true then return wpm end
    return nil
end })
api.cdo = function(path) if path == '/Script/Pal.Default__PalUtility' then return util end end
api.reset()
works, err = api.camp_works(camp)
assert(err == nil and #works == 3, 'empty server had no work manager: ' .. tostring(err))
assert(walks == 0, 'the work manager walked for a player controller: ' .. walks)
print('palapi camp_works: skipped entries counted, gone works are not skips, headless server has works')
