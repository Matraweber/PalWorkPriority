package.loaded.log={count=function() return {ms=0} end}
local api=require('palapi')
local gm=nil
FindFirstOf=function() return gm end
local function live(fields) fields.IsValid=function() return true end; return fields end
local pc=live({Role=2})
local world=live({OwningGameInstance={LocalPlayers={{PlayerController=pc}}}})
local viewport=live({World=world})
package.loaded.UEHelpers={GetEngine=function() return {GameViewport=viewport} end}
api.cdo=function() return nil end
assert(api.has_viewport()==true)
assert(api.latch_authority()==false,'autonomous local proxy did not prove client')
pc.Role=nil
api.reset()
assert(api.latch_authority()==nil,'missing reflection became definite client')
gm=live({GetFullName=function() return 'PalGameMode host' end})
assert(api.latch_authority()==true)
gm=nil
api.reset()
assert(api.has_authority()==nil,'authority leaked across session reset')
package.loaded.UEHelpers.GetEngine=function() return {GameViewport=nil} end
FindFirstOf=function() return pc end -- finding a remote player does not prove viewport
assert(api.has_viewport()==false)
local broken=live({GetWorkSuitabilityRankWithCharacterRank=function() error('unavailable') end})
assert(api.suitability_rank(broken,1)==nil,'unreadable skill became zero')

-- A headless dedicated server (GPortal 2026-10-29): no GameViewport, no
-- player, no pulse hint. The probe walked FindFirstOf("PalGameMode") on every
-- pass (20.5 ms there). The game instance is the world context now, and the
-- answer is still asked fresh on every call.
local walks = {}
FindFirstOf = function(class)
    walks[class] = (walks[class] or 0) + 1
    return nil
end
local server_gm = live({GetFullName = function()
    return 'BP_PalGamemode_C /Game/Maps/MainWorld.PersistentLevel.BP_PalGamemode_C_0' end})
local gm_answer = server_gm
local asked_with = {}
local util = live({GetPalGameMode = function(_, ctx)
    asked_with[#asked_with + 1] = ctx
    -- Like the engine: a context that has no world answers no GameMode.
    if ctx == nil or ctx.world_context ~= true then return nil end
    return gm_answer
end})
api.cdo = function(path) if path == '/Script/Pal.Default__PalUtility' then return util end end
local gi = live({world_context = true, GetFullName = function()
    return 'PalGameInstance /Engine/Transient.GameEngine_0:PalGameInstance_0' end})
local engine = live({GameViewport = nil, GameInstance = gi})
package.loaded.UEHelpers = {GetEngine = function() return engine end,
    GetGameInstance = function() walks.GameInstance = (walks.GameInstance or 0) + 1; return nil end}
api.reset()
for i = 1, 3 do
    assert(api.latch_authority() == true, 'headless server was not the authority on call ' .. i)
end
assert(next(walks) == nil, 'headless authority still walked: PalGameMode ' .. tostring(walks.PalGameMode))
assert(#asked_with == 3 and asked_with[1] == gi, 'game instance was not the world context, or the answer was cached')

-- The route gives nothing: today's walk, plus one first-time search.
gm_answer = nil
walks = {}
assert(api.latch_authority() == nil)
assert(walks.PalGameMode == 1, 'a failing route must fall back to exactly one walk')
walks = {}
assert(api.latch_authority() == nil and walks.PalGameMode == 1 and walks.GameInstance == nil)

-- Engine field unreadable: UEHelpers' own (kept) search is the second route,
-- asked once; after a miss it is not asked again in this world.
gm_answer = server_gm
engine.GameInstance = nil
api.reset()
walks = {}
assert(api.latch_authority() == nil and walks.GameInstance == 1 and walks.PalGameMode == 1)
walks = {}
assert(api.latch_authority() == nil and walks.GameInstance == nil, 'the game instance search repeated after a miss')
package.loaded.UEHelpers.GetGameInstance = function() walks.GameInstance = (walks.GameInstance or 0) + 1; return gi end
api.reset()
walks = {}
assert(api.latch_authority() == true and walks.PalGameMode == nil and walks.GameInstance == 1)

-- A wrapper that will not name itself a game instance is no context.
engine.GameInstance = live({world_context = true, GetFullName = function() return '' end})
package.loaded.UEHelpers.GetGameInstance = nil
api.reset()
walks = {}
assert(api.latch_authority() == nil and walks.PalGameMode == 1, 'an unnamed wrapper became a world context')

-- A client (screen, local Role-2 proxy) still answers false and never asks
-- the game instance, even with a GameMode-shaped answer on offer.
engine.GameInstance = gi
local client_pc = live({Role = 2})
local client_world = live({OwningGameInstance = {LocalPlayers = {{PlayerController = client_pc}}}})
engine.GameViewport = live({World = client_world})
asked_with, walks = {}, {}
api.reset()
assert(api.latch_authority() == false, 'a client became the authority')
assert(#asked_with == 0 and next(walks) == nil, 'a client asked the game instance or walked')
print('authority: local proxy, reset, headless server via the game instance')
