local f=assert(io.open(TEST_ROOT..'/tests/test_overlay_native_adapter.lua','r'))
local source=f:read('*a');f:close()
local start=assert(source:find('\noverlay.prepare%(%)'))
assert(load(source:sub(1,start-1)..'\n'..[=[
overlay.prepare();assert(overlay.show())
local original=lib.SetInputMode_GameOnly
lib.SetInputMode_GameOnly=function() error('restore failure') end
overlay.hide()
lib.SetInputMode_GameOnly=original
assert(overlay.watch_input() and game_only==1,'failed route restoration forgotten')
assert(not overlay.watch_input(),'successful restoration repeated')
-- A later menu or an unknown observation permanently cancels our retry.
for _,state in ipairs({'menu','unknown','owner','generation'}) do
 api.game_ui_active=false
 assert(overlay.show())
 lib.SetInputMode_GameOnly=function() return false end
 overlay.hide()
 lib.SetInputMode_GameOnly=original
 local before=game_only
 if state=='menu' then api.game_ui_active=true
 elseif state=='unknown' then api.game_ui_active=nil
 elseif state=='owner' then pc.path=pc.path..'replacement'
 else overlay.generation=overlay.generation+1 end
 assert(not overlay.watch_input() and game_only==before,'unsafe retry: '..state)
 api.game_ui_active=false
 assert(not overlay.watch_input() and game_only==before,'cancelled authority revived: '..state)
end
-- Same name is not sufficient identity; session transitions also revoke it.
for _,change in ipairs({'same-name','session','library-menu','mode-menu','missing-address'}) do
 assert(overlay.show())
 lib.SetInputMode_GameOnly=function() return false end
 overlay.hide()
 lib.SetInputMode_GameOnly=original
 local before_only,before_focus=game_only,game_focus
 local cdo=api.cdo
 if change=='same-name' then
  local old=pc;pc=make('PalPlayerController')
  for k,v in pairs(old) do pc[k]=v end
 elseif change=='session' then require('session').begin('replacement')
 elseif change=='library-menu' then api.cdo=function(path) api.game_ui_active=true;return cdo(path) end
 elseif change=='mode-menu' then lib.SetInputMode_GameOnly=function(...) original(...);api.game_ui_active=true end
 else pc.GetAddress=function() return nil end end
 assert(not overlay.watch_input(),'revoked recovery succeeded: '..change)
 assert(game_focus==before_focus,'later menu received viewport focus: '..change)
 assert(game_only==before_only+(change=='mode-menu' and 1 or 0),'unauthorized mode write: '..change)
 api.game_ui_active=false;api.cdo=cdo;lib.SetInputMode_GameOnly=original;pc.GetAddress=nil
 assert(not overlay.watch_input(),'revoked recovery returned: '..change)
end
-- Persistent refusal has three retry opportunities, then no further calls.
assert(overlay.show())
local attempts=0
lib.SetInputMode_GameOnly=function() attempts=attempts+1;return false end
overlay.hide()
for i=1,10 do overlay.watch_input() end
assert(attempts==4,'unbounded recovery: '..attempts)
lib.SetInputMode_GameOnly=original
assert(not overlay.watch_input(),'exhausted retry revived')
-- An old callback cannot erase recovery created by a reentrant new close.
assert(overlay.show())
lib.SetInputMode_GameOnly=function() return false end
overlay.hide();lib.SetInputMode_GameOnly=original
local focus=lib.SetFocusToGameViewport
local once=false
lib.SetFocusToGameViewport=function(...)
 focus(...)
 if not once then
  once=true;assert(overlay.show())
  lib.SetInputMode_GameOnly=function() return false end
  overlay.hide();lib.SetInputMode_GameOnly=original
 end
end
overlay.watch_input()
lib.SetFocusToGameViewport=focus
local recovered_before=game_only
assert(overlay.watch_input() and game_only==recovered_before+1,'old callback erased newer recovery')
-- Reopening invalidates pending cleanup from the previous generation.
assert(overlay.show())
lib.SetInputMode_GameOnly=function() return false end
overlay.hide()
lib.SetInputMode_GameOnly=original
assert(overlay.show())
local before=game_only
assert(not overlay.watch_input() and game_only==before,'old close affected reopened panel')
overlay.hide()
]=], '@input-recovery'))()
