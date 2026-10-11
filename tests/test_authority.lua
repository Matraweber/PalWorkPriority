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
