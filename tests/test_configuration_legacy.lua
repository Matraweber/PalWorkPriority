-- Review round 2 (2026-10-29): a 0.4.1 config.lua that 0.4.1 accepted must
-- still load, a byte order mark must not stop the mod, and the reset notice
-- must survive until the panel has shown it.
local fs=require('memory_fs')()
require('datafile').fs=fs
local log=require('log')
local warned={}
local original_warn=log.warn
log.warn=function(message) warned[#warned+1]=tostring(message) end
local function fresh_module()
    package.loaded.configuration=nil
    return require('configuration')
end
local function said(text)
    for _,line in ipairs(warned) do if line:find(text,1,true) then return true end end
    return false
end

-- P1: values 0.4.1 warned about and clamped or dropped.
do
    local config=fresh_module()
    local legacy='return {interval_seconds=2,max_pals_per_work_type=0,'
        ..'work_priority={Lumbering=1,Mining=2.5,Deforest=2},'
        ..'pal_overrides={Diggy={Mining=1.5,Cool=1},Broken="x"},'
        ..'work_caps={Mining={Stone=0,Ore=2.5,Wood=300},Lumbering={Wood=5}},min_suitability_rank=0}'
    fs.files['old/priorities.txt']='PAL-A|1|X\n'
    fs.files['oldScripts/config.lua']=legacy
    local cfg,why=config.load('old/','oldScripts/')
    assert(cfg,'0.4.1 config stopped the mod: '..tostring(why))
    assert(cfg.interval_seconds==5,'interval not clamped to 5')
    assert(cfg.max_pals_per_work_type==false,'0 did not mean no limit')
    assert(cfg.work_priority.Lumbering==nil and cfg.work_priority.Mining==nil
        and cfg.work_priority.Deforest==2,'bad work priorities kept or good one lost')
    assert(cfg.pal_overrides.Diggy.Mining==nil and cfg.pal_overrides.Diggy.Cool==1
        and cfg.pal_overrides.Broken==nil,'bad Pal overrides kept')
    assert(cfg.work_caps.Mining.Stone==nil and cfg.work_caps.Mining.Ore==nil
        and cfg.work_caps.Mining.Wood==300 and cfg.work_caps.Lumbering==nil,'bad limits kept')
    assert(cfg.min_suitability_rank==1)
    assert(said("unknown work type 'Lumbering'") and said('interval_seconds'),'nothing was said')
    -- The editable copy keeps the user's exact bytes, so the next launch reads
    -- the same file under the same rules.
    assert(fs.files['old/config.lua']==legacy,'root copy was rewritten')
    assert(fs.files['old/config.migration.bak']==legacy)
    fs.files['oldScripts/config.lua']=nil -- a Workshop update removed it
    local again,again_why=config.load('old/','oldScripts/')
    assert(again and again.interval_seconds==5 and again.max_pals_per_work_type==false,
        'second launch stopped: '..tostring(again_why))
    assert(config.upgrade_reset==false,'the migrated copy was called a reset')
    -- Once the user edits the copy, 0.5's own check applies.
    fs.files['old/config.lua']=legacy..' '
    assert(config.load('old/','oldScripts/')==nil,'an edited copy was sanitized')
end

-- P2: a UTF-8 byte order mark, root and legacy.
do
    local config=fresh_module()
    local bom='\239\187\191'
    fs.files['bom/config.lua']=bom..'return {interval_seconds=20}'
    local cfg,why=config.load('bom/','bomScripts/')
    assert(cfg and cfg.interval_seconds==20,'BOM in root config.lua: '..tostring(why))
    fs.files['bom2Scripts/config.lua']=bom..'return {interval_seconds=30}'
    cfg,why=config.load('bom2/','bom2Scripts/')
    assert(cfg and cfg.interval_seconds==30,'BOM in legacy config.lua: '..tostring(why))
    assert(fs.files['bom2/config.lua']==bom..'return {interval_seconds=30}','legacy bytes changed')
    assert(config.load('bom2/','bom2Scripts/'),'second launch with BOM stopped')
end

-- P2: the reset notice survives restarts until the panel acknowledges it.
do
    warned={}
    local config=fresh_module()
    fs.files['ws/priorities.txt']='PAL-A|1|X\n'
    fs.files['wsScripts/default_config.lua']='return {enabled=true}'
    assert(config.load('ws/','wsScripts/'))
    assert(config.upgrade_reset==true and config.upgrade_message==config.UPGRADE_MESSAGE)
    assert(config.upgrade_message:find('options page settings are kept',1,true))
    assert(fs.files['ws/'..config.MARKER],'no marker written')
    -- Next launch, before the panel was ever opened.
    local later=fresh_module()
    assert(later.upgrade_reset==false)
    assert(later.load('ws/','wsScripts/'))
    assert(later.upgrade_reset==true and later.upgrade_message==later.UPGRADE_MESSAGE,
        'the notice was lost on restart')
    assert(later.ack_upgrade_reset()==true)
    assert(later.upgrade_reset==false and fs.files['ws/'..later.MARKER]==nil,'ack left the marker')
    local after=fresh_module()
    assert(after.load('ws/','wsScripts/') and after.upgrade_reset==false,'acknowledged notice came back')

    -- Marker write fails: still said this session, with a warning.
    warned={}
    local failing=fresh_module()
    fs.files['wf/priorities.txt']='PAL-A|1|X\n'
    fs.files['wfScripts/default_config.lua']='return {enabled=true}'
    fs.fault=function(op,path) return op=='open' and path=='wf/'..failing.MARKER end
    assert(failing.load('wf/','wfScripts/'))
    fs.fault=nil
    assert(failing.upgrade_reset==true and said('shown this session only'))
end

-- P3: config.lua deleted by hand while config.migration.bak holds the user's
-- bytes. No loader touched it, so no loader is blamed.
do
    warned={}
    local config=fresh_module()
    fs.files['hand/config.migration.bak']='return {interval_seconds=40}'
    fs.files['hand/priorities.txt']='PAL-A|1|X\n'
    fs.files['handScripts/default_config.lua']='return {enabled=true}'
    assert(config.load('hand/','handScripts/'))
    assert(config.upgrade_reset==true and config.upgrade_message==config.MISSING_MESSAGE)
    assert(config.MISSING_MESSAGE:find('config.lua was missing, defaults are in use',1,true))
    assert(not said('Workshop') and said('config.lua was missing'),'a hand deletion blamed the update')
    assert(fs.files['hand/config.migration.bak']=='return {interval_seconds=40}','user bytes overwritten')
    local later=fresh_module()
    assert(later.load('hand/','handScripts/') and later.upgrade_message==later.MISSING_MESSAGE)
end

log.warn=original_warn
package.loaded.configuration=nil
print('configuration legacy: 0.4.1 leniency, BOM, persistent reset notice')
