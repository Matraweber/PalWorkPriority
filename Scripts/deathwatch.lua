-- Close Production Limits when the local player dies.
--
-- On 2026-10-17 a death while editing (APalPlayerController:SelfKillPlayer)
-- left the panel and an open amount editor drawn over the DEFEAT screen: the
-- game closed the Monitoring Stand, but the panel can live without it, so it
-- stayed until the player pressed Escape twice. Nothing was stuck or saved,
-- but an editor over the death screen is a stale editor.
--
-- ClientRestart fires on respawn, which is too late, so this watches the
-- player's HP while the panel is open: Pawn -> CharacterParameterComponent ->
-- IndividualParameter -> SaveParameter.HP.Value, property reads only (seen
-- live equal to GetHP). Read afresh every check, nothing kept between calls.
-- Only a positive read of 0 counts as dead; an unreadable chain is unknown and
-- changes nothing. Throttled: the 16 ms loop calls it, it reads every 0.25 s.
local api = require('palapi')

local M = { INTERVAL = 0.25, next_at = 0 }

-- true: positively dead (HP read as 0). nil: unknown. false: alive.
function M.player_dead()
    local hp
    local ok = pcall(function()
        local pc = api.player_controller()
        if not api.valid(pc) then return end
        local pawn = api.unwrap(api.prop(pc, 'Pawn'))
        if pawn == nil or not api.valid(pawn) then return end
        local comp = api.unwrap(api.prop(pawn, 'CharacterParameterComponent'))
        if comp == nil or not api.valid(comp) then return end
        local ip = api.unwrap(api.prop(comp, 'IndividualParameter'))
        if ip == nil or not api.valid(ip) then return end
        local save = api.prop(ip, 'SaveParameter')
        hp = save and save.HP and save.HP.Value
    end)
    if not ok or type(hp) ~= 'number' then return nil end
    return hp <= 0
end

-- Called from the fast loop while the panel is open. Returns true when it
-- closed the panel. `now` is injectable for tests.
function M.check(panel, log, now)
    if not (panel and panel.open) then return false end
    now = now or os.clock()
    if now < M.next_at then return false end
    M.next_at = now + M.INTERVAL
    if M.player_dead() ~= true then return false end
    local had_edit = false
    if panel.cancel_edit then
        local ok, had = pcall(panel.cancel_edit)
        had_edit = ok and had == true
    end
    pcall(panel.close)
    if log and log.say then
        log.say('Production Limits closed: the player died' ..
            (had_edit and '; the unsaved limit edit was discarded' or ''))
    end
    return true
end

return M
