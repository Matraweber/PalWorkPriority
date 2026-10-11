local Probe=dofile(TEST_ROOT..'/experiments/save_identity_probe.lua')
local function object(t) t=t or {};t.IsValid=function() return true end;return t end
local id=string.rep('a',32)
local manager=object{AutoSaveWorldDefaultName=id,bIsLoadedWorldSaveData=true}
local instance=object{SaveGameManager=manager,SelectedWorldSaveDirectoryName=id:upper()}
local world=object{OwningGameInstance=instance,GetFullName=function() return 'World map' end}
local engine=object{GameViewport=object{World=world}}
local function check(expected)
    local out=Probe.read(engine)
    assert(out.state==expected,out.state)
    assert(out.verified==false and out.storage==nil and out.key==nil and out.ready==nil)
    for _,v in pairs(out) do assert(type(v)=='string' or type(v)=='boolean' or math.type(v)=='integer') end
    return out
end
assert(check('candidates_agree').loaded_world==true)
assert(check('candidates_agree').loaded_status=='read')
instance.SelectedWorldSaveDirectoryName={ToString=function() error('conversion failed') end}
assert(check('one_candidate').selected_status=='read_failed')
instance.SelectedWorldSaveDirectoryName=id
manager.AutoSaveWorldDefaultName=string.rep('b',32);check('candidates_conflict')
manager.bIsLoadedWorldSaveData=false
assert(check('candidates_conflict').loaded_world==false)
manager.AutoSaveWorldDefaultName=nil;check('one_candidate')
for _,bad in ipairs({'',string.rep('0',32),'../world',string.rep('x',32),string.rep('a',33)}) do
    instance.SelectedWorldSaveDirectoryName=bad
    check('no_candidate')
end
instance.SelectedWorldSaveDirectoryName=nil
setmetatable(instance,{__index=function() error('unreflected') end})
manager.bIsLoadedWorldSaveData=nil
setmetatable(manager,{__index=function() error('unavailable') end})
assert(check('no_candidate').loaded_world==nil)
assert(check('no_candidate').loaded_status=='read_failed')
instance.SaveGameManager=setmetatable({}, {__index=function() error('bad wrapper') end})
check('no_candidate')
world.OwningGameInstance=nil;check('unavailable')
engine.GameViewport=nil;check('unavailable')
assert(Probe.read(nil).verified==false)
-- A later call resolves the current world again, not the previous wrapper.
engine.GameViewport=object{World=object{GetFullName=function() return 'World next' end}}
assert(check('unavailable').world=='World next')
-- Live host -> Title -> remote-client pattern: the same game instance retains
-- its local selected ID. Stage labels are fixture context, not inferred roles.
-- Use a synthetic ID; the loaded flag is true only for the initial host stage.
do
    local retained_id=string.rep('3',32)
    local retained_manager=object{
        AutoSaveWorldDefaultName='',bIsLoadedWorldSaveData=true
    }
    local retained_instance=object{
        SelectedWorldSaveDirectoryName=retained_id,
        SaveGameManager=retained_manager
    }
    local viewport=object{}
    local retained_engine=object{GameViewport=viewport}
    local main_world='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
    local title_world='World /Game/Pal/Maps/Title/PL_Title.PL_Title'
    for _,stage in ipairs({
        {name='host',world=main_world,loaded=true},
        {name='Title',world=title_world,loaded=false},
        {name='client',world=main_world,loaded=false}
    }) do
        -- Replace only the world; preserve the game instance and its selected ID.
        viewport.World=object{
            OwningGameInstance=retained_instance,
            GetFullName=function() return stage.world end
        }
        retained_manager.bIsLoadedWorldSaveData=stage.loaded
        local out=Probe.read(retained_engine)
        assert(viewport.World.OwningGameInstance==retained_instance,stage.name)
        assert(out.world==stage.world and out.selected==retained_id,stage.name)
        assert(out.selected_status=='format_valid',stage.name)
        assert(out.loaded_status=='read' and out.loaded_world==stage.loaded,stage.name)
        assert(out.verified==false and out.ready==nil,stage.name)
        assert(out.storage==nil and out.key==nil,stage.name)
        assert(retained_instance.SelectedWorldSaveDirectoryName==retained_id,stage.name)
    end
end
print('save identity probe: bounded candidate reads, absent/false/throwing fields, no write authority')
do
    local function at(t,n) t=object(t);t.GetAddress=function() return n end;return t end
    local i=at({SelectedWorldSaveDirectoryName=id},21)
    local m=at({AutoSaveWorldDefaultName=id,bIsLoadedWorldSaveData=true,GetOuter=function() return i end},22)
    i.SaveGameManager=m
    local w=at({OwningGameInstance=i,GetFullName=function() return 'World identity' end},23)
    local v=object{World=w};local e=object{GameViewport=v}
    local out=Probe.read(e)
    assert(out.context_status=='context_agrees' and out.world_address==23 and out.instance_address==21 and out.manager_address==22)
    assert(out.verified==false and out.storage==nil)
    m.GetOuter=function() return at({},99) end
    out=Probe.read(e);assert(out.context_status=='owner_unestablished' and out.world_address==nil)
    m.GetOuter=function() v.World=at({OwningGameInstance=i},24);return i end
    out=Probe.read(e);assert(out.context_status=='context_changed' and out.instance_address==nil)
end
