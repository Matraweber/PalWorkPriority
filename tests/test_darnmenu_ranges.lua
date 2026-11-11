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
    elseif option.kind == 'enum' and path:find('^new_pal_priority_') then
        -- A job's default: written into work_priority, "X" as false, on or off.
        local job = path:sub(#'new_pal_priority_' + 1)
        assert(option.dependsOn == nil, path .. ' is greyed out while the setting is off, but X applies then too')
        for _, value in ipairs(option.values) do
            enums = enums + 1
            local want = tonumber(value)
            if value == 'X' then want = false end
            local cfg = apply({ [path] = value })
            assert(#warnings == 0 and cfg.work_priority[job] == want, path .. '=' .. value .. ' was not applied')
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
assert(numbers == 3 and enums == 8 + 13 * 6, 'schema options went missing: ' .. numbers .. ' numbers, ' .. enums .. ' choices')
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

-- The jobs' defaults (0.5.1): every job but the inert Anyone, the shipped
-- numbers as the page's own defaults, "X" or a typed number accepted, bad
-- values skipped with a warning, config.lua's table never changed in place.
do
    local shipped = base().work_priority
    local listed = 0
    for job, prio in pairs(shipped) do
        if job ~= 'Anyone' then
            listed = listed + 1
            assert(schema.defaults['new_pal_priority_' .. job] == tostring(prio), job .. ' page default differs from config.lua')
            assert(options['new_pal_priority_' .. job], job .. ' is not on the page')
        end
    end
    assert(listed == #darnmenu.NEW_PAL_JOBS and listed == 13)
    -- Setting off: the value still replaces config.lua's (X must work then).
    local cfg, n = apply({ new_pal_priority_Transport = '5' })
    assert(cfg.work_priority.Transport == 5 and n == 1 and #warnings == 0, 'not applied with the setting off')
    local cx = apply({ new_pal_priority_Watering = 'X' })
    assert(cx.work_priority.Watering == false, 'X did not reach work_priority')
    local typed = apply({ new_pal_priority_Mining = 2 })
    assert(typed.work_priority.Mining == 2 and #warnings == 0, 'a number typed into the file was refused')
    local loaded = base()
    darnmenu.user_settings = function() return { new_pal_priority_Mining = '2' } end
    local same = loaded.work_priority
    darnmenu.apply(loaded)
    assert(loaded.work_priority.Mining == 2 and same.Mining == 4, "config.lua's table was changed in place")
    for _, bad in ipairs({ '6', '0', 'x', 7, '2.5', true }) do
        local c, m = apply({ new_pal_priority_Transport = bad })
        assert(c.work_priority.Transport == 1 and m == 0, 'bad job value ' .. tostring(bad) .. ' applied')
        assert(#warnings == 1 and warnings[1]:find('"Transporting"', 1, true), 'bad job value did not warn')
    end
    -- A number on the page lifts an X from config.lua, like any saved value.
    local xcfg = base()
    xcfg.work_priority.Watering = false
    darnmenu.user_settings = function() return { new_pal_priority_Watering = '2' } end
    darnmenu.apply(xcfg)
    assert(xcfg.work_priority.Watering == 2, 'a saved page value lost to config.lua')
end

-- The page shows config.lua (review 2026-11-10): its defaults come from the
-- file as loaded; a value the checks refuse keeps the shipped default.
do
    local function page(base_cfg)
        local chunk = assert(load(darnmenu.schema_text(base_cfg), '=page', 't', {}))
        return chunk().defaults
    end
    assert(darnmenu.schema_text(nil) == darnmenu.schema_text(nil) and page(nil).new_pal_priority_Transport == '1')
    local own = base()
    own.work_priority.Transport, own.work_priority.Watering = 5, false
    own.interval_seconds, own.use_work_priority_for_new_pals, own.chat_prefix = 30, true, '!w'
    own.max_pals_per_work_type, own.storage_scope = nil, 'global'
    local d = page(own)
    assert(d.new_pal_priority_Transport == '5' and d.new_pal_priority_Watering == 'X', 'job defaults not from config.lua')
    assert(d.interval_seconds == 30 and d.use_work_priority_for_new_pals == true and d.chat_prefix == '!w')
    assert(d.max_pals_per_work_type == 0 and d.storage_scope == 'global', 'no limit or scope not shown')
    assert(d.key_panel and d.key_panel.key == 'F1', 'a hotkey default was lost')
    own.interval_seconds, own.log_level = 2, 'loud'
    d = page(own)
    assert(d.interval_seconds == 10 and d.log_level == 'info', 'a refused value reached the page')
    -- Values validate takes but the page cannot offer keep the shipped default;
    -- config.lua's false for no limit shows as 0 (re-review P3-1, P3-2).
    own.interval_seconds, own.min_suitability_rank, own.max_pals_per_work_type = 600, 6, false
    d = page(own)
    assert(d.interval_seconds == 10 and d.min_suitability_rank == 1, 'an out-of-range value reached the page')
    assert(d.max_pals_per_work_type == 0, 'false for no limit did not show as 0')
    local shipped = page(base())
    for k, v in pairs(schema.defaults) do
        if type(v) ~= 'table' then assert(shipped[k] == v, k .. ': the shipped config.lua does not give the shipped page') end
    end
end

-- The chat prefix is on the page and checked like config.lua's.
do
    assert(options.chat_prefix and options.chat_prefix.option.kind == 'text')
    local c = apply({ chat_prefix = '!w' })
    assert(c.chat_prefix == '!w' and #warnings == 0)
    c = apply({ chat_prefix = '' })
    assert(c.chat_prefix == '!pwp' and #warnings == 1, 'an empty prefix was applied')
end

-- 0.5.2 (Nexus suggestion, 2026-11-11): the controls line under the stand
-- can be switched off on the page, and config.lua's value is the default.
do
    assert(options.show_stand_legend and options.show_stand_legend.option.kind == 'bool')
    assert(schema.defaults.show_stand_legend == true)
    local c = apply({ show_stand_legend = false })
    assert(c.show_stand_legend == false and #warnings == 0, 'the switch was not applied')
    c = apply({ show_stand_legend = 'no' })
    assert(c.show_stand_legend == true and #warnings == 1, 'a non-boolean switch was applied')
    local own = base(); own.show_stand_legend = false
    local d = assert(load(darnmenu.schema_text(own), '=page', 't', {}))().defaults
    assert(d.show_stand_legend == false, 'config.lua false not shown on the page')
    assert(require('configuration').validate({ show_stand_legend = 1 }) == nil, 'validate took a number')
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
-- Review round 4, scheduler P2-1: the old help said a Pal below the level
-- "may still do it", which is false for an edited Pal (the job is switched
-- off) and says nothing about Pals with equal numbers (left to the game).
assert(options.min_suitability_rank.option.help == "The Pal's work level for that job (the small number on the job icon), not the 1-5 priority. Ranked Pals only: a job below this level is switched off for them. Pals with equal numbers are left to the game.",
    'min_suitability_rank help: ' .. tostring(options.min_suitability_rank.option.help))
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
