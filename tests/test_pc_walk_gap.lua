-- The player controller walk backs off further on every miss (2026-10-29).
-- A fixed 10 s gap never engaged on the GPortal server: its passes are
-- 11.5 s apart, so all 117 passes in the measurement walked the whole object
-- array for a controller that an empty server does not have.
package.loaded.log = { count = function() return { ms = 0 } end }
package.loaded.palapi = nil
local api = require('palapi')

local function live(o) o.IsValid = function() return true end; return o end
local now = 0
local clock = os.clock
os.clock = function() return now end
local found = nil
local walks = 0
FindFirstOf = function() walks = walks + 1; return found end
-- Headless: no viewport, so the engine chain never answers.
package.loaded.UEHelpers = { GetEngine = function() return live({ GameViewport = nil }) end }

local ok, err = pcall(function()
    api.reset()
    -- 40 passes, 11.5 s apart: about 7.5 minutes with nobody online.
    for _ = 1, 40 do
        assert(api.player_controller() == nil)
        now = now + 11.5
    end
    assert(walks <= 18, 'the walk did not back off: ' .. walks .. ' walks in 40 passes')
    -- The gap stops growing at 30 s (it was two minutes until round 4, Gap 3),
    -- so a player who joins an empty server is found within half a minute:
    -- every third pass at 11.5 s apart.
    walks = 0
    for _ = 1, 40 do api.player_controller(); now = now + 11.5 end
    assert(walks >= 12 and walks <= 15, 'the gap did not settle at 30 s: ' .. walks)

    -- A hit resets it: the next misses walk on every call again.
    found = live({})
    now = now + 121
    assert(api.player_controller() == found)
    found, walks = nil, 0
    for _ = 1, 5 do api.player_controller(); now = now + 11.5 end
    assert(walks == 5, 'a hit did not reset the backoff')

    -- So does a remote player's spawn (main.lua ClientRestart on a server):
    -- the first player after a long empty spell is found on the next call.
    for _ = 1, 30 do api.player_controller(); now = now + 11.5 end
    walks = 0
    api.player_controller()
    assert(walks == 0, 'expected the backoff to hold here')
    api.pc_walk_retry()
    found = live({})
    assert(api.player_controller() == found and walks == 1, 'a spawn did not lift the backoff')
    found = nil

    -- So does a world change.
    for _ = 1, 30 do api.player_controller(); now = now + 11.5 end
    api.reset()
    walks = 0
    api.player_controller()
    assert(walks == 1, 'a new world served out the old backoff')
end)
os.clock = clock
assert(ok, err)
print('palapi: player controller walk backs off to 30 s, resets on a hit')
