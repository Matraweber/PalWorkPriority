-- Run the actual one-shot entrypoint with deterministic engine/readers and IO.
local runfile=TEST_ROOT..'/experiments/priority-roster-live/main.lua'
local original_dofile,original_open=dofile,io.open
local function fixture(mode)
    local f={queue={},lines={},marker='PWP_PRIORITY_ROSTER testnonce\n',reads=0,contexts=0}
    local function pair()
        f.contexts=f.contexts+1
        if mode=='not_ready' or mode=='direct_not_ready' and f.contexts>1 then return {} end
        return {status='context_agrees',agrees=true,directory='world',world='World',
            identity_loaded_status='read',identity_loaded_world=true,identity_selected_status='format_valid',
            identity_selected='world',identity_autosave_status='empty',
            world_address=(mode=='transition' or mode=='direct_transition') and f.contexts or 1,state_address=2,instance_address=3,manager_address=4}
    end
    for name,method in pairs({palapi='camp_pals',workdefs='value',log='say',trace='at',perf='new',frame_trace='new',store='durable_key',datafile='read',settings_gate='blocked'})do
        package.loaded[name]={[method]=assert(load('return function()end','@'..TEST_ROOT..'/experiments/priority-roster-live/'..name..'.lua'))()}
    end
    package.loaded.UEHelpers={GetEngine=function()return {}end,
        GetGameplayStatics=function()return {IsValid=function()return true end}end}
    _G.dofile=function(path)
        if path:match('/target.lua$')then return {route=mode and mode:match('^direct') and 'direct' or mode=='world' and 'world' or mode=='parameter' and 'parameter' or mode=='guild' and 'guild' or 'camp',storage='world',guild='guild',alias='alias',keys={'pal','missing'}}end
        if path:match('/settings_priority_live_reader.lua$')then return {new=function(o)
            assert(o.enabled and o.read_context and o.get_engine and o.authorize)
            return {owns_key=function(k,c)f.reads=f.reads+1;assert(c.stream=='priorities');return o.authorize() end,
                revoke=function()f.revoked=(f.revoked or 0)+1 end}
        end}end
        if path:match('/settings_priority_world_lookup.lua$')then return {read=function()error('not called by stub')end}end
        if path:match('/settings_priority_parameter_roster.lua$')then return {read=function(_,_,g,w,resolver)
            if mode=='world'then assert(type(resolver)=='function')end
            assert(g=='guild' and w.pal and w.missing)
            return {complete=true,reason='observed',records={{key='pal',group='guild',matches=true,address=10,world_resolved=mode=='world'}}}
        end}end
        if path:match('/settings_priority_guild_roster.lua$')then return {read=function(_,c)
            assert(c.guild=='guild' and c.legacy_guild=='alias');f.reads=f.reads+1
            return {complete=true,keys={'pal','missing','other'},count=3,array_address=9}
        end}end
        if path:match('/save_context_pair_probe.lua$')then return {read=pair}end
        if path:match('/save_local_authority.lua$')then return {read=function()
            return {authority_status='read',authority=true,guild_status='format_valid',guild=mode=='direct_foreign' and f.contexts>1 and 'foreign' or 'guild',legacy_guild='alias'}end}end
        if path:match('/settings_priority_roster.lua$')then return {read=function()
            f.reads=f.reads+1
            if mode=='throw' then error('native read unavailable')end
            return {complete=mode~='partial',camps={{key='camp',guild='alias',pals={
                {key='pal',capable={[1]=true,[2]=true}}}}},reason=mode=='unstable' and tostring(f.reads) or ''}
        end}end
        error('unexpected dependency '..path)
    end
    io.open=function(path,mode)
        if path:match('/run.txt$')then
            if mode=='r'then return {read=function()return f.marker end,close=function()return true end}end
            assert(mode=='w');return {write=function(_,s)f.marker=s;return true end,close=function()return true end}
        end
        assert(path:match('/roster.log$') and mode=='a')
        return {write=function(_,s)f.lines[#f.lines+1]=s;return true end,close=function()return true end}
    end
    _G.ExecuteInGameThreadWithDelay=function(ms,fn)assert(ms==30000 or ms==10000 or ms==2000);f.queue[#f.queue+1]=fn end
    original_dofile(runfile)
    function f:finish()
        local n=0
        while #self.queue>0 do n=n+1;assert(n<=121);table.remove(self.queue,1)()end
        return table.concat(self.lines)
    end
    return f
end
do
    local f=fixture();local text=f:finish()
    assert(f.reads==6 and text:find('done\tsamples=3',1,true)==nil) -- sorted output also carries activation=false
    assert(text:find('done\tactivation_allowed=false\tsamples=3',1,true))
    assert(text:find('matched=1',1,true) and text:find('unknown=1',1,true))
    assert(text:find('world_membership_proven=false',1,true))
    local n=#f.lines;original_dofile(runfile);assert(#f.lines==n and #f.queue==0) -- consumed marker
end
for _,mode in ipairs({'transition','throw','not_ready','direct_transition','direct_not_ready','direct_foreign'})do
    local f=fixture(mode);local s=f:finish()
    assert(s:find('\tfailed\t',1,true) and not s:find('\tdone\t',1,true))
    assert(not s:find('\tsample\t',1,true))
end
for _,mode in ipairs({'partial','unstable'})do
    local f=fixture(mode);local s=f:finish()
    assert(s:find(mode=='partial' and 'complete=false' or 'stable=false',1,true))
    assert(s:find('activation_allowed=false',1,true))
end
do
    local f=fixture('guild');local text=f:finish()
    assert(f.reads==6 and text:find('route=guild',1,true))
    assert(text:find('matched=2',1,true) and text:find('unknown=0',1,true))
    assert(text:find('world_membership_proven=false',1,true))
end
do
    local f=fixture('parameter');local text=f:finish()
    assert(f.reads==6 and text:find('route=parameter',1,true))
    assert(text:find('matched=1',1,true) and text:find('unknown=1',1,true))
    assert(text:find('\tparameter\t',1,true) and text:find('world_membership_proven=false',1,true))
end
do
    local f=fixture('world');local text=f:finish()
    assert(text:find('route=world',1,true) and text:find('world_resolved=true',1,true))
    assert(text:find('matched=1',1,true) and text:find('activation_allowed=false',1,true))
end
do
    local f=fixture('direct');local text=f:finish()
    assert(f.reads==12 and f.revoked==6 and text:find('route=direct',1,true))
    assert(text:find('matched=2',1,true) and text:find('unknown=0',1,true))
    assert(text:find('\townership\t',1,true) and text:find('world_membership_proven=false',1,true))
end
io.open,_G.dofile=original_open,original_dofile
print('priority roster entrypoint: consumed trigger, bounded retries/three samples, partial/unknown/transition refusal and read-only markers passed')
