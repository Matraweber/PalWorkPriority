-- Actual pad reader: all engine reads finish within this call, before actions
-- can close UI or replace a local controller. No native process is involved.
local viewport, lookups, checks, reads = true, 0, 0, 0
local buttons, retired, fail_key = {}, false, nil
local pc = {}
function pc:IsInputKeyDown(key)
    assert(not retired, 'controller read after an action replaced it')
    reads = reads + 1
    if key.KeyName == fail_key then error('unreadable key') end
    return buttons[key.KeyName] == true
end
package.loaded.palapi = {
    has_viewport = function() checks = checks + 1; return viewport end,
    local_player_controller = function() lookups = lookups + 1; return pc end,
    player_controller = function() error('remote-controller fallback is forbidden') end,
}
package.loaded.clock = {every = function() end, cancel = function() end}
package.loaded.log = {count = function() return {ms=0} end, say = function() end}
FName = function(name) return name end
local pad = require('pad')
pad.tick_ms = 16
local events = {}
local actions = {nav = function(verb) events[#events+1] = verb end}

buttons.Gamepad_DPad_Right = true
pad.drive(actions)
assert(lookups == 1 and checks == 1 and reads == 11,
    'one pad sample repeated the local controller/viewport lookup')
assert(#events == 1 and events[1] == 'right')
for _=1,4 do pad.drive(actions) end
assert(#events == 1, 'short hold repeated at poll speed')
buttons.Gamepad_DPad_Right = false; pad.drive(actions)
buttons.Gamepad_DPad_Right = true; pad.drive(actions)
assert(#events == 2, 'release/repress was lost')

-- A navigation callback may close UI or change worlds. No remaining key read
-- in this sample may use its earlier controller after the callback returns.
pad.forget(); reads = 0
pad.drive({nav = function() retired = true end})
assert(reads == 11, 'key reads interleaved with UI callbacks')
pc = {IsInputKeyDown = function(_, key) return buttons[key.KeyName] == true end}
pad.forget(); pad.drive(actions)
assert(#events == 3, 'next call did not resolve the new controller')

-- No viewport means no controller resolution or key reads, including on a
-- populated dedicated server. Returning to a viewport must work immediately.
viewport = false
local prior = lookups
pad.drive(actions)
assert(pad.down('Gamepad_DPad_Right') == nil)
assert(lookups == prior, 'headless sample resolved a controller')
viewport = true; pad.drive(actions)
assert(#events == 4, 'viewport return left held state stuck')
pc = nil
assert(pad.down('Gamepad_DPad_Right') == nil)
pad.drive(actions)

-- An unavailable button remains unknown and cannot synthesize a press.
pc = {IsInputKeyDown = function() error('input unavailable') end}
assert(pad.down('Gamepad_DPad_Right') == nil)
local prior_events = #events; pad.drive(actions)
assert(#events == prior_events)

pc = {IsInputKeyDown = function(_, key) return buttons[key.KeyName] == true end}
-- RB + View opened the game's map as well as the panel and was rejected on
-- 2026-10-22 (DECISIONS). The shut-panel poll is gone: no lookup, no read, no
-- open, and RB is a plain tab press again once the panel is open.
buttons = {Gamepad_RightShoulder=true, Gamepad_Special_Left=true}
prior = lookups; local prior_reads = reads
assert(pad.open_asked() == false, 'RB + View still opens the panel')
assert(lookups == prior and reads == prior_reads, 'the shut panel still polls the pad')
assert(#pad.OPEN_CHORD == 0)
local tabs = 0
buttons = {}; pad.drive({})
buttons.Gamepad_RightShoulder = true
pad.drive({tab_next = function() tabs = tabs + 1 end})
assert(tabs == 1)

-- A callback that replaces the controller and forgets held input invalidates
-- the rest of that earlier sample, even though those states are plain data.
pc = {IsInputKeyDown = function(_, key)
    return key.KeyName == 'Gamepad_DPad_Right' or key.KeyName == 'Gamepad_FaceButton_Left'
end}
pad.forget()
local removed = 0
pad.drive({
    nav = function()
        pc = {IsInputKeyDown = function() return false end}
        pad.forget()
    end,
    remove = function() removed = removed + 1 end,
})
assert(removed == 0, 'controller replacement dispatched an old sampled Remove')
pad.drive({remove = function() removed = removed + 1 end})
assert(removed == 0)

-- Cancelling from one tap must also cancel later taps in the same sample.
pc = {IsInputKeyDown = function(_, key)
    return key.KeyName == 'Gamepad_FaceButton_Right' or key.KeyName == 'Gamepad_FaceButton_Left'
end}
pad.forget()
pad.drive({close = pad.forget, remove = function() removed = removed + 1 end})
assert(removed == 0, 'close dispatched another sampled tap')

-- Cancel must win over Confirm, movement and destructive taps in one sample.
pc = {IsInputKeyDown = function() return false end}
pad.drive({}) -- Release the previous test's Cancel before the next press.
buttons = {Gamepad_FaceButton_Right=true, Gamepad_FaceButton_Bottom=true,
    Gamepad_FaceButton_Left=true, Gamepad_RightShoulder=true}
pc = {IsInputKeyDown = function(_, key) return buttons[key.KeyName] == true end}
pad.forget()
local cancelled, confirmed, changed = 0, 0, 0
local cancel_actions = {
    close = function() cancelled = cancelled + 1 end,
    nav = function() confirmed = confirmed + 1 end,
    remove = function() changed = changed + 1 end,
    tab_next = function() changed = changed + 1 end,
}
pad.drive(cancel_actions)
assert(cancelled == 1 and confirmed == 0 and changed == 0,
    'Cancel allowed Confirm or another action from the same sample')
for _=1,30 do pad.drive(cancel_actions) end
assert(cancelled == 1 and confirmed == 0 and changed == 0,
    'held Cancel repeated or allowed another action')
buttons.Gamepad_FaceButton_Right = false
for _=1,30 do pad.drive(cancel_actions) end
assert(confirmed == 0 and changed == 0, 'releasing Cancel dispatched a still-held action')
buttons = {}; pad.drive(cancel_actions)
buttons.Gamepad_FaceButton_Bottom = true; pad.drive(cancel_actions)
assert(confirmed == 1, 'fresh Confirm after releasing all buttons was lost')

-- A reset is not a button release. Unknown reads of a previously held key
-- retain the barrier, but an unsupported unrelated key does not extend it.
buttons = {Gamepad_FaceButton_Right=true}
pad.drive(cancel_actions)
assert(cancelled == 2)
pad.forget()
pc = {IsInputKeyDown = function(_, key)
    if key.KeyName == 'Gamepad_FaceButton_Right' then error('temporarily unreadable') end
    return false
end}
pad.drive(cancel_actions)
pc = {IsInputKeyDown = function(_, key)
    if key.KeyName == 'Gamepad_FaceButton_Right' then return nil end
    return false
end}
assert(pad.down('Gamepad_FaceButton_Right') == nil, 'nil native state became a release')
pad.drive(cancel_actions)
pc = {IsInputKeyDown = function() return 0 end}
assert(pad.down('Gamepad_FaceButton_Right') == nil, 'non-boolean native state became a release')
pad.drive(cancel_actions)
pc = {IsInputKeyDown = function(_, key)
    if key.KeyName == 'Gamepad_RightTrigger' then error('unsupported unrelated key') end
    return buttons[key.KeyName] == true
end}
pad.drive(cancel_actions)
assert(cancelled == 2, 'reset or unknown read treated held Cancel as a new press')
buttons = {}; pad.drive(cancel_actions)
buttons.Gamepad_FaceButton_Bottom = true; pad.drive(cancel_actions)
assert(confirmed == 2, 'unsupported unrelated key prevented confirmed release')

-- Consumers without a Cancel action (the stand) keep their navigation.
buttons = {Gamepad_FaceButton_Right=true, Gamepad_DPad_Left=true}
pad.forget()
pad.drive({nav=function() confirmed=confirmed+1 end})
assert(confirmed == 3, 'unbound Cancel swallowed stand navigation')
