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
