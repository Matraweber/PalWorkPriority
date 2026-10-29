-- The egg incubator's hatch timer is a work object that no Pal works
-- (GPortal server 2026-10-29: "Busy" | HatchingPalEgg_0 | PalWorkProgress).
-- It is ignored, so it neither counts as untyped nor triggers the untyped
-- warning that named it as if it were an unfinished building.
package.loaded.log = { count = function() return { ms = 0 } end, debug = function() end,
    warn = function(text) WARNED = text end }
package.loaded.palapi = nil
local api = require('palapi')

local function work(name, assign, class)
    return {
        OverrideWorkType = 0,
        AssignDefineDataId = assign,
        GetWorkName = function() return name end,
        GetFullName = function() return class .. ' /Game/Pal/Maps/Test.Work' end,
    }
end

for _, id in ipairs({ 'HatchingPalEgg_0', 'HatchingPalEgg_12' }) do
    local value, reason = api.work_suitability(work('Busy', id, 'PalWorkProgress'))
    assert(value == nil and reason == 'ignored', id .. ' was not ignored: ' .. tostring(reason))
end
assert(WARNED == nil, 'the incubator still raised the untyped warning: ' .. tostring(WARNED))

-- A really unknown work still warns, and the text does not claim to know
-- what it is.
local value, reason = api.work_suitability(work('Busy', 'SomethingNew_0', 'PalWorkProgress'))
assert(value == nil and reason == nil)
assert(type(WARNED) == 'string' and WARNED:find('SomethingNew_0', 1, true), 'unknown work did not warn')
assert(not WARNED:find('expected for Construction', 1, true), 'warning still claims Construction')
print('work typing: egg incubator ignored, unknown work warned without guessing')
