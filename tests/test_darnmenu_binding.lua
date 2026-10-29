-- darnmenu.binding resolves a saved DarnMenu keychord (review round 2,
-- 2026-10-29). The default is Alt+Fn; a bad saved key or modifier falls back
-- to it with a warning, and never to a plain Fn that other mods own.
local log = require('log')
local darnmenu = require('darnmenu')

local saved_key, saved_mods = Key, ModifierKey
local original_warn = log.warn
local warnings = {}
log.warn = function(message) warnings[#warnings + 1] = tostring(message) end

-- Names UE4SS really has. ALT is a ModifierKey, not a Key.
Key = setmetatable({}, { __index = function(_, key)
    if type(key) == 'string' and (key:match('^F%d+$') or key == 'ESCAPE' or key == 'RETURN') then
        return 'key:' .. key
    end
end })
ModifierKey = { ALT = 'mod:ALT', CONTROL = 'mod:CONTROL', SHIFT = 'mod:SHIFT' }

local function resolve(user)
    warnings = {}
    darnmenu.user_settings = function() return user end
    return darnmenu.binding('key_panel', 'F1', { 'ALT' })
end

local ok, why = pcall(function()
    -- No saved file: Alt+F1.
    local key, mods, changed, label = resolve(nil)
    assert(key == 'key:F1' and mods and #mods == 1 and mods[1] == 'mod:ALT', 'default is not Alt+F1')
    assert(changed == false and label == 'ALT+F1' and #warnings == 0)

    -- A valid rebinding.
    key, mods, changed, label = resolve({ key_panel = { key = 'F7', modifiers = { 'SHIFT' } } })
    assert(key == 'key:F7' and mods[1] == 'mod:SHIFT' and changed == true and label == 'SHIFT+F7')

    -- A key this UE4SS has no entry for: default, with a warning.
    key, mods, changed, label = resolve({ key_panel = { key = 'NOPE', modifiers = { 'ALT' } } })
    assert(key == 'key:F1' and mods[1] == 'mod:ALT' and changed == false and label == 'ALT+F1')
    assert(#warnings == 1 and warnings[1]:find('NOPE', 1, true), 'unknown key did not warn')

    -- An unknown modifier must not quietly become a plain key.
    for _, bad in ipairs({ { 'HYPER' }, { 'ALT', 'META' }, { 42 }, 'ALT' }) do
        key, mods, changed, label = resolve({ key_panel = { key = 'F7', modifiers = bad } })
        assert(key == 'key:F1' and mods and #mods == 1 and mods[1] == 'mod:ALT',
            'unknown modifier produced ' .. tostring(label))
        assert(changed == false and label == 'ALT+F1')
        assert(#warnings == 1 and warnings[1]:find('modifier', 1, true), 'unknown modifier did not warn')
    end

    -- A modifier this UE4SS build lacks binds nothing, not a plain key.
    ModifierKey = { CONTROL = 'mod:CONTROL' }
    key, mods = resolve(nil)
    assert(key == nil and mods == nil, 'missing ALT produced a plain F1')
    key, mods = resolve({ key_panel = { key = 'F7', modifiers = { 'ALT' } } })
    assert(key == nil and #warnings == 1, 'a saved ALT without ModifierKey.ALT bound a plain key')
end)

Key, ModifierKey = saved_key, saved_mods
log.warn = original_warn
assert(ok, why)
print('darnmenu binding: Alt+F1 default, bad keys and modifiers fall back with a warning')
