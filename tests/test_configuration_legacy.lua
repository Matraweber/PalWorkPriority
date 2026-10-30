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
    -- Review round 3: leniency is per value. An edit to another key keeps
    -- 0.4.1's rules for the untouched lines (interval still 5, Lumbering
    -- still dropped beside a changed entry), while a value typed under 0.5
    -- is checked strictly.
    warned={}
    fs.files['old/config.lua']=legacy:gsub('Deforest=2','Deforest=3'):gsub('}$',',dry_run=true}')
    local edited,edited_why=config.load('old/','oldScripts/')
    assert(edited,'an edit elsewhere stopped the mod: '..tostring(edited_why))
    assert(edited.interval_seconds==5 and edited.max_pals_per_work_type==false and edited.dry_run==true)
    assert(edited.work_priority.Deforest==3 and edited.work_priority.Lumbering==nil
        and edited.work_priority.Mining==nil,'untouched entries lost their leniency')
    assert(edited.work_caps.Mining.Wood==300 and edited.pal_overrides.Diggy.Cool==1)
    assert(said('interval_seconds'),'the clamp was not said')
    assert(config.refused==false)
    -- Review round 4 (Gap 2): per value inside a Pal's overrides and a work's
    -- limits too. One changed value left its 0.4.1 siblings strict.
    fs.files['old/config.lua']=legacy:gsub('Cool=1','Cool=2')
    local pal,pal_why=config.load('old/','oldScripts/')
    assert(pal,'one edit inside a Pal stopped the mod: '..tostring(pal_why))
    assert(pal.pal_overrides.Diggy.Cool==2 and pal.pal_overrides.Diggy.Mining==nil
        and pal.pal_overrides.Broken==nil,'the edit was lost or the bad sibling kept')
    fs.files['old/config.lua']=legacy:gsub('Wood=300','Wood=400')
    local caps,caps_why=config.load('old/','oldScripts/')
    assert(caps,'one edit inside a limit stopped the mod: '..tostring(caps_why))
    assert(caps.work_caps.Mining.Wood==400 and caps.work_caps.Mining.Stone==nil
        and caps.work_caps.Mining.Ore==nil and caps.work_caps.Lumbering==nil,'the edit was lost or a bad sibling kept')
    -- A value typed under 0.5 inside the same entry is still strict, and so
    -- is a new item under a work type 0.4.1's rules drop.
    fs.files['old/config.lua']=legacy:gsub('Cool=1','Cool=1,EmitFlame=7')
    assert(config.load('old/','oldScripts/')==nil,'a new bad value inside an old entry was sanitized')
    fs.files['old/config.lua']=legacy:gsub('Wood=5','Wood=5,Stone=9')
    assert(config.load('old/','oldScripts/')==nil,'a new item under an unknown work type was sanitized')
    -- The refused file's limits are held for caps (Engine P3-2).
    assert(config.held_caps and config.held_caps.Lumbering and config.held_caps.Lumbering.Stone==9)
    fs.files['old/config.lua']='return {work_caps='
    assert(config.load('old/','oldScripts/')==nil and config.held_caps==true,'an unparsable file held no limits')
    assert(config.load('old/','oldScripts/')==nil)
    fs.files['old/config.lua']=legacy
    assert(config.load('old/','oldScripts/') and config.held_caps==nil,'a good file still held limits')
    fs.files['old/config.lua']=legacy:gsub('interval_seconds=2','interval_seconds=3')
    local typed,typed_why=config.load('old/','oldScripts/')
    assert(typed==nil and typed_why=='invalid interval_seconds','a newly typed 3 was accepted: '..tostring(typed_why))
    assert(config.refused==true,'a refused value was not marked')
    fs.files['old/config.lua']=legacy:gsub('Deforest=2','Deforest=2,Cool=9')
    assert(config.load('old/','oldScripts/')==nil,'a new bad entry beside old ones was sanitized')
    -- A torn backup: nothing is lenient any more, and the whole file is strict.
    fs.files['old/config.lua']=legacy..' '
    fs.files['old/config.migration.bak']=legacy:sub(1,40)
    assert(config.load('old/','oldScripts/')==nil,'a torn backup still allowed leniency')
    fs.files['old/config.migration.bak']=legacy
end

-- P3 (round 3): 0.4.1 read the switches by truthiness, so 1 or "true" meant on.
do
    warned={}
    local config=fresh_module()
    fs.files['truthyScripts/config.lua']='return {dry_run=1,enabled="yes",run_on_world_load=0}'
    local cfg,why=config.load('truthy/','truthyScripts/')
    assert(cfg,'truthy switches stopped the mod: '..tostring(why))
    assert(cfg.dry_run==true and cfg.enabled==true and cfg.run_on_world_load==true,'a truthy switch turned off')
    assert(said('config.dry_run should be true or false. Using true for 1, as 0.4.1 did.'))
    -- Typed under 0.5, the same value is refused.
    fs.files['truthy/config.lua']='return {dry_run=2}'
    assert(config.load('truthy/','truthyScripts/')==nil)
end

-- P3 (round 3): the backup goes through a temporary file. A failed rename
-- leaves no torn config.migration.bak, and the next launch tries again.
-- Review round 4 (P3-3): the settings were read fine, so a failed write no
-- longer stops the mod; it starts on them and warns.
do
    local config=fresh_module()
    warned={}
    fs.files['bakScripts/config.lua']='return {interval_seconds=20}'
    fs.fault=function(op,path) return op=='rename' and path=='bak/config.migration.bak.tmp>bak/config.migration.bak' end
    local cfg,why=config.load('bak/','bakScripts/')
    fs.fault=nil
    assert(cfg and cfg.interval_seconds==20,'a failed backup write stopped the mod: '..tostring(why))
    assert(said('config backup replacement failed') and said('the next launch tries again'),'nothing was said')
    assert(fs.files['bak/config.migration.bak']==nil and fs.files['bak/config.lua']==nil)
    fs.fault=function(op,path) return op=='write' and path=='bak/config.migration.bak.tmp' end
    cfg,why=config.load('bak/','bakScripts/')
    fs.fault=nil
    assert(cfg and said('config backup failed') and fs.files['bak/config.migration.bak']==nil)
    -- The backup is written but the editable copy is not.
    fs.fault=function(op,path) return op=='rename' and path=='bak/config.lua.tmp>bak/config.lua' end
    cfg,why=config.load('bak/','bakScripts/')
    fs.fault=nil
    assert(cfg and cfg.interval_seconds==20 and said('config migration replacement failed'),tostring(why))
    assert(fs.files['bak/config.lua']==nil)
    cfg,why=config.load('bak/','bakScripts/')
    assert(fs.files['bak/config.lua']=='return {interval_seconds=20}' and fs.files['bak/config.lua.tmp']==nil)
    assert(cfg and cfg.interval_seconds==20,tostring(why))
    assert(fs.files['bak/config.migration.bak']=='return {interval_seconds=20}'
        and fs.files['bak/config.migration.bak.tmp']==nil)
end

-- P3 (round 3): the user-facing work_caps errors no longer say "legacy".
do
    local config=fresh_module()
    local _,why=config.validate({work_caps={Mining={Stone=0}}})
    assert(why=='invalid work_caps entry: Mining/Stone',tostring(why))
    _,why=config.validate({work_caps={Nope={}}})
    assert(why=='invalid work_caps entry: Nope',tostring(why))
end

-- Review round 3: a refused config.lua is shown in Production Limits through
-- the reset notice slot; a reset notice still waiting keeps its marker.
do
    local config=fresh_module()
    fs.files['rej/'..config.MARKER]=config.UPGRADE_MESSAGE..'\n'
    fs.files['rej/config.lua']='return {interval_seconds=1}'
    assert(config.load('rej/','rejScripts/')==nil and config.refused==true)
    config.show_rejection('config.lua rejected: invalid interval_seconds.')
    assert(config.upgrade_reset==true and config.upgrade_message=='config.lua rejected: invalid interval_seconds.')
    -- Review round 4: shown is not acknowledged while the mod stays paused.
    assert(config.ack_upgrade_reset()==false and config.upgrade_reset==true
        and config.upgrade_message=='config.lua rejected: invalid interval_seconds.',
        'the rejection went after the first look')
    assert(config.ack_upgrade_reset()==false and config.upgrade_reset==true,'a second opening lost the rejection')
    assert(fs.files['rej/'..config.MARKER],'showing the rejection removed the waiting reset marker')
    config.show_rejection('again')
    assert(config.upgrade_message=='again')
    -- Fixed: the reset notice that was waiting comes back, and only that one
    -- is acknowledged.
    config.clear_rejection()
    assert(config.rejection==nil and config.upgrade_reset==true and config.upgrade_message==config.UPGRADE_MESSAGE)
    assert(config.ack_upgrade_reset()==true and config.upgrade_reset==false and fs.files['rej/'..config.MARKER]==nil)
    fs.files['rejScripts/default_config.lua']='return {interval_seconds=15}'
    assert(config.defaults('rejScripts/').interval_seconds==15)
    fs.files['devScripts/config.lua']='return {interval_seconds=25}'
    assert(config.defaults('devScripts/').interval_seconds==25,'a source checkout has no defaults')
    assert(config.defaults('noneScripts/')==nil)
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
    assert(config.upgrade_message:find('Options page settings are kept',1,true))
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

-- Review round 4 (P3-2): after a manual 0.4.1 upgrade the old
-- Scripts/config.lua stays beside the shipped defaults. Edits to it did
-- nothing without a word.
do
    local infos={}
    local original_info=log.info
    log.info=function(message) infos[#infos+1]=tostring(message) end
    local config=fresh_module()
    fs.files['left/config.lua']='return {interval_seconds=20}'
    fs.files['leftScripts/config.lua']='return {interval_seconds=60}'
    fs.files['leftScripts/default_config.lua']='return {}'
    local cfg=config.load('left/','leftScripts/')
    log.info=original_info
    assert(cfg and cfg.interval_seconds==20)
    assert(infos[1] and infos[1]:find('leftScripts/config.lua is not read; the settings are in left/config.lua',1,true),
        tostring(infos[1]))
end

log.warn=original_warn
package.loaded.configuration=nil
print('configuration legacy: 0.4.1 leniency, BOM, persistent reset notice')
