-- deathwatch: closes Production Limits (dropping any draft) only on a positive
-- read of 0 HP for the local player; unknown reads change nothing; throttled.
local hp, chain_ok = 1250000, true
local pc = {}
package.loaded.palapi = {
    player_controller = function() return chain_ok and pc or nil end,
    valid = function(o) return o ~= nil end,
    unwrap = function(v) return v end,
    prop = function(o, n)
        if o == pc and n == 'Pawn' then return { comp = true } end
        if type(o) == 'table' and o.comp and n == 'CharacterParameterComponent' then return { ip = true } end
        if type(o) == 'table' and o.ip and n == 'IndividualParameter' then return { save = true } end
        if type(o) == 'table' and o.save and n == 'SaveParameter' then
            if hp == nil then return {} end
            return { HP = { Value = hp } }
        end
    end,
}
package.loaded.deathwatch = nil
local dw = require('deathwatch')

local said = {}
local log = { say = function(m) said[#said + 1] = m end }
local function new_panel(editing)
    local p = { open = true, editing = editing, closed = 0 }
    p.cancel_edit = function() local had = p.editing; p.editing = nil; return had end
    p.close = function() p.open = false; p.closed = p.closed + 1; p.editing = nil; return true end
    return p
end

-- Alive: nothing happens.
assert(dw.player_dead() == false)
dw.next_at = 0
local p = new_panel(true)
assert(dw.check(p, log, 1.0) == false and p.open and p.editing, 'alive player closed the panel')

-- Unknown chain or unreadable HP: nothing happens.
chain_ok = false
assert(dw.player_dead() == nil)
dw.next_at = 0
assert(dw.check(p, log, 2.0) == false and p.open, 'unknown read closed the panel')
chain_ok, hp = true, nil
assert(dw.player_dead() == nil)
dw.next_at = 0
assert(dw.check(p, log, 3.0) == false and p.open, 'unreadable HP closed the panel')

-- Dead with a draft open: draft discarded, panel closed, said so.
hp = 0
dw.next_at = 0
assert(dw.check(p, log, 4.0) == true, 'death did not close the panel')
assert(not p.open and p.editing == nil and p.closed == 1)
assert(said[#said]:find('player died', 1, true) and said[#said]:find('discarded', 1, true), said[#said])

-- Dead without a draft: closes, no "discarded" wording.
local q = new_panel(nil)
dw.next_at = 0
assert(dw.check(q, log, 5.0) == true and not q.open)
assert(not said[#said]:find('discarded', 1, true), said[#said])

-- Throttle: a second check inside INTERVAL does not read again.
local r = new_panel(true)
dw.next_at = 0
hp = 1250000
assert(dw.check(r, log, 10.0) == false)
hp = 0
assert(dw.check(r, log, 10.0 + dw.INTERVAL / 2) == false and r.open, 'throttle ignored')
assert(dw.check(r, log, 10.0 + dw.INTERVAL) == true and not r.open)

-- Closed panel: never reads.
local s = new_panel(nil); s.open = false
dw.next_at = 0
assert(dw.check(s, log, 20.0) == false and s.closed == 0)

print('deathwatch checks passed')
