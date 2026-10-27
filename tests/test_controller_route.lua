-- Controller route in overlay.lua (WorkRules contract 4, 2026-10-22): the
-- release check that keeps B's release on the panel, and the PWP_PadDispatch
-- hook that hands controller codes to the panel on the next beat.
package.loaded.palapi = { cdo = function() return nil end, player_controller = function() return nil end }
package.loaded.trace = { around = function(_, fn) return fn() end }
package.loaded.log = { say = function() end, warn = function() end, debug = function() end }
local queued = {}
package.loaded.session = { enqueue = function(fn) queued[#queued + 1] = fn; return true end, epoch = 1, ui_epoch = 1 }
local hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn; return 1, 2 end
local overlay = require("overlay")

-- take_release: once per release, cleared after reading; nil for older shells.
local shell = { PWP_InputContract = 4, PWP_CancelReleased = false }
assert(overlay.take_release(shell) == false, 'reported a release that did not happen')
shell.PWP_CancelReleased = true
assert(overlay.take_release(shell) == true and shell.PWP_CancelReleased == false, 'release not taken once')
assert(overlay.take_release(shell) == false, 'release reported twice')
assert(overlay.take_release({ PWP_InputContract = 3 }) == nil, 'contract 3 shell claimed to know releases')
assert(overlay.take_release({ PWP_InputContract = 4 }) == nil, 'missing field read as a release state')

-- hook_pad: registers once on the shell class, reads the code from the widget
-- that fired, and calls the panel only while it is open.
assert(overlay.hook_pad() == true and overlay.pad_hooked == true)
local path = "/Game/Mods/PalWorkPriority/UI/WBP_WorkRules.WBP_WorkRules_C:PWP_PadDispatch"
assert(hooks[path], 'hook path changed')
local seen = {}
overlay.on_pad = function(code) seen[#seen + 1] = code end
local function fire(widget)
    hooks[path]({ get = function() return widget end })
    for _, fn in ipairs(queued) do fn() end
    queued = {}
end
overlay.open = true
fire({ PWP_InputContract = 4, PWP_PadKey = 2 })
fire({ PWP_InputContract = 4, PWP_PadKey = 9 })
fire({ PWP_InputContract = 3, PWP_PadKey = 2 }) -- older shell: ignored
fire({ PWP_InputContract = 4, PWP_PadKey = 12 }) -- out of range: ignored
fire({ PWP_InputContract = 4, PWP_PadKey = 1.5 }) -- not an integer: ignored
overlay.open = false
fire({ PWP_InputContract = 4, PWP_PadKey = 1 }) -- panel closed: dropped
assert(#seen == 2 and seen[1] == 2 and seen[2] == 9, 'unexpected codes: ' .. table.concat(seen, ','))
assert(overlay.hook_pad() == true, 'second registration not idempotent')
print('controller route: release taken once, contract-4 codes 1-11 reach an open panel only')
