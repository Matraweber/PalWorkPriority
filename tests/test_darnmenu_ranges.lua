-- DarnMenu options page against configuration.validate (review A1, 2026-10-28).
-- The page offered "Seconds between passes" from 2 while validate wanted 5, so a
-- saved 2 stopped the whole mod on every launch. Every value the page can offer
-- must pass, and a value it cannot offer must be skipped with a warning.
local configuration = require('configuration')
local log = require('log')
local darnmenu = require('darnmenu')

local warnings = {}
local original_warn, original_say = log.warn, log.say
log.warn = function(message) warnings[#warnings + 1] = tostring(message) end
log.say = function() end

local function base()
    -- The shipped defaults, as configuration.load would hand them over.
    local cfg = assert(loadfile(TEST_ROOT .. '/Scripts/config.lua', 't', {}))()
    assert(configuration.validate(cfg), 'shipped config.lua does not validate')
    return cfg
end

local function apply(user)
    local cfg = base()
    warnings = {}
    darnmenu.user_settings = function() return user end
    local n = darnmenu.apply(cfg)
    local ok, why = configuration.validate(cfg)
    assert(ok, 'menu value stopped the mod: ' .. tostring(why))
    return cfg, n
end

local schema = assert(darnmenu.schema(), 'schema does not parse')
local options, numbers, enums = {}, 0, 0
for _, section in ipairs(schema.sections) do
    for _, option in ipairs(section.options) do
        if option.path then options[option.path] = { option = option, section = section.title } end
    end
end

-- Every end of every number range, and every enum value, reaches the scheduler.
for path, entry in pairs(options) do
    local option = entry.option
    if option.kind == 'number' then
        numbers = numbers + 1
        assert(option.integer and option.min and option.max, path .. ' has no whole-number range')
        for _, value in ipairs({ option.min, option.max }) do
            local cfg, n = apply({ [path] = value })
            assert(#warnings == 0, path .. '=' .. value .. ' warned: ' .. tostring(warnings[1]))
            if path == 'max_pals_per_work_type' and value == 0 then
                -- The menu's 0 is config's "no limit", spelt nil.
                assert(cfg[path] == nil and n == 1, '0 did not become no limit')
            else
                assert(configuration.validate({ [path] = value }), path .. '=' .. value .. ' fails validate')
                assert(cfg[path] == value, path .. '=' .. value .. ' was not applied')
            end
        end
    elseif option.kind == 'enum' then
        for _, choice in ipairs(option.values) do
            enums = enums + 1
            local value = type(choice) == 'table' and choice.value or choice
            assert(configuration.validate({ [path] = value }), path .. '=' .. value .. ' fails validate')
            local cfg = apply({ [path] = value })
            assert(#warnings == 0 and cfg[path] == value, path .. '=' .. value .. ' was not applied')
        end
    end
end
assert(numbers == 3 and enums == 8, 'schema options went missing: ' .. numbers .. ' numbers, ' .. enums .. ' choices')
assert(options.interval_seconds.option.min == 5, 'Seconds between rechecks must start at 5')

-- The page's own defaults are valid on their own.
local defaults = {}
for key, value in pairs(schema.defaults) do
    if type(value) ~= 'table' then defaults[key] = value end
end
assert(configuration.validate(defaults), 'schema defaults fail validate')

-- A user file written by an older page (2) or by hand (7.5) still starts, with
-- the config.lua value and a warning naming the option.
for _, bad in ipairs({ 2, 7.5, 0, 301, 0 / 0, 1 / 0 }) do
    local cfg, n = apply({ interval_seconds = bad, dry_run = true })
    assert(cfg.interval_seconds == 10, 'bad interval ' .. tostring(bad) .. ' reached the config')
    assert(cfg.dry_run == true and n == 1, 'a bad value cost the good ones beside it')
    assert(#warnings == 1 and warnings[1]:find('"Seconds between rechecks"', 1, true)
        and warnings[1]:find('keeping 10', 1, true), 'no warning naming the option: ' .. tostring(warnings[1]))
end

-- Every other way a hand-edited file can be wrong is skipped the same way.
for _, case in ipairs({
    { min_suitability_rank = 9 }, { min_suitability_rank = 2.5 }, { max_pals_per_work_type = -1 },
    { max_pals_per_work_type = 21 }, { assignment_mode = 'bogus' }, { storage_scope = 'everywhere' },
    { log_level = 'loud' }, { enabled = 'yes' }, { interval_seconds = '10' },
}) do
    local key, value = next(case)
    local before = base()[key]
    local cfg, n = apply(case)
    assert(cfg[key] == before and n == 0, key .. '=' .. tostring(value) .. ' was applied')
    assert(#warnings == 1 and warnings[1]:find(tostring(value), 1, true), key .. ' did not warn')
end

-- No user file: nothing changes and nothing is said.
local untouched, none = apply(nil)
assert(none == 0 and #warnings == 0 and untouched.interval_seconds == 10)

-- The page uses the shared names (review H).
local function label(path) return options[path].option.label end
assert(label('interval_seconds') == 'Seconds between rechecks')
assert(label('run_on_world_load') == 'Recheck when a world loads')
assert(label('key_pass') == 'Recheck now')
assert(label('min_suitability_rank') == 'Lowest work level to dedicate')
assert(options.storage_scope.section == 'Production limits' and options.item_limits_on_rocks.section == 'Production limits')
-- Review round 2: Off does not free X jobs, and a limit is when Pals stop.
assert(options.enabled.option.help == 'Off gives back every job the mod switched off and stops steering. Jobs set to X stay off.')
assert(label('leave_unordered_pals_to_game') == 'Leave Pals with equal numbers to the game')
assert(options.key_panel.option.help:find('when Pals stop making an item', 1, true)
    and not options.key_panel.option.help:find('a base keeps', 1, true))
for path, entry in pairs(options) do
    assert(type(entry.option.help) == 'string' and entry.option.help ~= '', path .. ' has no help')
end
local function walk(value)
    if type(value) == 'string' then
        assert(not value:lower():find('ceiling', 1, true), 'page says ceiling: ' .. value)
    elseif type(value) == 'table' then
        for _, inner in pairs(value) do walk(inner) end
    end
end
walk(schema)

log.warn, log.say = original_warn, original_say
print('darnmenu ranges: ' .. numbers .. ' number options, ' .. enums .. ' choices, bad values skipped with a warning')
