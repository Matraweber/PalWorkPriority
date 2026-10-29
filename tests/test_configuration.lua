local fs=require('memory_fs')()
require('datafile').fs=fs
local config=require('configuration')
fs.files['scripts/config.lua']='return {work_priority={Mining=2},enabled=true}'
fs.files['root/priority.log']='old installation'
local cfg,err,fresh=config.load('root/','scripts/')
assert(cfg and cfg.work_priority.Mining==2 and not fresh,err)
assert(fs.files['root/config.migration.bak']==fs.files['scripts/config.lua'])
fs.files['scripts/config.lua']='return {work_priority={Mining=5}}'
cfg=config.load('root/','scripts/')
assert(cfg.work_priority.Mining==2,'reinstall replaced editable config')
fs.files['root/config.lua']='return this_is_invalid'
assert(config.load('root/','scripts/')==nil,'invalid config fell back silently')
fs.files['newScripts/config.lua']='return {enabled=true}'
cfg,err,fresh=config.load('new/','newScripts/')
assert(cfg and fresh,err)
for _, text in ipairs({
    'return {work_priority={Mining=1.5}}',
    'return {work_priority={Mining=0/0}}',
    'return {pal_overrides="broken"}',
    'return {work_caps={Mining={Stone=0}}}',
    'return {interval_seconds=1/0}',
    'return {max_pals_per_work_type=0/0}',
    'return {enabled="false"}',
    'return {counted_containers={"Chest",false}}',
}) do
    fs.files['root/config.lua']=text
    assert(config.load('root/','scripts/')==nil, 'invalid config was silently sanitized: '..text)
end
assert(config.validate({work_priority={Mining=false},max_pals_per_work_type=false}))

-- Upgrade reset notice (review H, 2026-10-28). The Workshop and Vortex loaders
-- delete what they installed, so an upgraded install arrives with only the
-- shipped default_config.lua; priorities.txt beside it says it is not new.
do
    local log = require('log')
    local warned = {}
    local original_warn = log.warn
    log.warn = function(message) warned[#warned + 1] = tostring(message) end
    local function fresh_module()
        package.loaded.configuration = nil
        return require('configuration')
    end
    local upgraded = fresh_module()
    assert(upgraded.upgrade_reset == false)
    fs.files['up/priorities.txt'] = 'PAL-A|1|X\n'
    fs.files['upScripts/default_config.lua'] = 'return {enabled=true}'
    local loaded, why, is_fresh = upgraded.load('up/', 'upScripts/')
    assert(loaded and is_fresh == false, why)
    assert(upgraded.upgrade_reset == true, 'removed config.lua went unnoticed')
    assert(#warned == 1 and warned[1]:find('Your earlier config.lua was not found', 1, true)
        and warned[1]:find('options page settings are kept', 1, true), 'no upgrade warning')
    -- The next launch reads the copy it made and says nothing more.
    assert(upgraded.load('up/', 'upScripts/') and #warned == 1)

    warned = {}
    local new = fresh_module()
    fs.files['newerScripts/default_config.lua'] = 'return {enabled=true}'
    loaded, why, is_fresh = new.load('newer/', 'newerScripts/')
    assert(loaded and is_fresh == true, why)
    assert(new.upgrade_reset == false and #warned == 0, 'a new install was told its config was removed')

    -- A manual install whose Scripts/config.lua survived is not a reset either.
    warned = {}
    local manual = fresh_module()
    fs.files['man/priorities.txt'] = 'PAL-A|1|X\n'
    fs.files['manScripts/config.lua'] = 'return {enabled=true}'
    assert(manual.load('man/', 'manScripts/'))
    assert(manual.upgrade_reset == false and #warned == 0, 'migrated Scripts/config.lua was called a reset')
    log.warn = original_warn
    package.loaded.configuration = config
end
