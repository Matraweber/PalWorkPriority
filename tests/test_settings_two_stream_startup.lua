-- Two real startup coordinators and stores; only native IO/engine proof is fake.
package.loaded.log={warn=function()end,error=function()end,say=function()end}
local W,G=string.rep('3',32),string.rep('4',32)
local K=string.rep('0',32)..string.rep('A',32)
local function fixture(fail)
    for _,n in ipairs({'settings_gate','store','caps'})do package.loaded[n]=nil end
    local Gate=require('settings_gate')
    local Store,Caps=require('store'),require('caps')
    local File=require('datafile');local fs=require('memory_fs')();File.fs=fs
    local bodies={priorities=assert(Store.serialize_snapshot({[K]={[1]=1,[2]=false}},false)),
        limits=assert(Caps.serialize_snapshot({[G]={Mining={Stone=200}}}))}
    assert(File.write('priorities',bodies.priorities,0));Store.load('priorities');Store.set_role('authority')
    assert(File.write('limits',bodies.limits,0));Caps.load('limits');Caps.set_role('authority')
    local Startup=dofile(TEST_ROOT..'/experiments/settings_startup.lua')
    local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
    local Group=dofile(TEST_ROOT..'/experiments/settings_startup_gate_group.lua')
    local group=assert(Group.new{enabled=true});local children={}
    for _,stream in ipairs({'limits','priorities'})do
        local scope='PWP-SCOPE-1:'..W..':'..G..':'..stream
        local codec=Codec.new{storage=W,guild=G,stream=stream}
        local f={accepted=0,committed=0,phase='dormant',drains=0,cleanups=0}
        local function view()return {scope=scope,session='boot',ticket=f.accepted,generation=9,
            committed=f.committed,state=f.phase=='awaiting_validation' and f.phase or 'saving',phase=f.phase}end
        local b={contract='PWP-DRAINING-DEV-1',max_payload_bytes=65536}
        function b:start()f.phase='awaiting_validation';return true end
        function b:inspect()return view()end
        function b:poll()return view()end
        function b:recovery()return {scope=scope,session='boot',kind='existing',payload=assert(codec.encode(bodies[stream]))}end
        function b:approve()f.phase='ready';return true end
        function b:submit()f.accepted=f.accepted+1;return {scope=scope,session='boot',revision=f.accepted}end
        function b:close()f.phase='closing';return true end
        function b:drain()f.drains=f.drains+1;f.committed=f.accepted;f.phase='closed';return view()end
        function b:cleanup()f.cleanups=f.cleanups+1;return true end
        local module=stream=='limits' and Caps or Store
        f.startup=assert(Startup.new{enabled=true,storage=W,guild=G,stream=stream,session='boot',incarnation='inc',
            epoch=1,camp='camp',runtime_guild=G,backend=b,lease={},clock=function()return 0 end,
            gate=assert(group:child(stream)),authorize=function()return true end,owns_key=function(k)return k==K end,
            verify_coverage=function()return fail~='coverage' end,
            activate=function(o)if fail=='activation' and stream=='priorities'then return false end;return module.activate_recovered(o)end,
            detach=module.retire_persistence,finalize=module.finish_retirement})
        children[stream]=f
    end
    local Combined=dofile(TEST_ROOT..'/experiments/settings_combined_owner.lua')
    local combined=assert(Combined.new{enabled=true,fence=function()return group:fence()end})
    for _,stream in ipairs({'limits','priorities'})do
        local revoked=false
        local proof={revoke=function()revoked=true;return false end,status=function()return {state=revoked and 'revoked' or 'active'}end}
        assert(combined:register(stream,children[stream].startup,{proof}))
    end
    return Gate,group,children,Store,Caps,fs,combined
end
for _,failure in ipairs({'none','coverage','activation'})do
    local Gate,group,children,Store,Caps,fs,combined=fixture(failure)
    local io=#fs.operations
    for _,s in ipairs({'limits','priorities'})do assert(children[s].startup:start())end
    assert(children.limits.startup:poll() and children.limits.startup:status().state=='active')
    assert(Gate.blocked())
    assert(not Caps.apply_set('Mining','Stone',300,G) and children.limits.accepted==0)
    assert(not Store.apply_set(K,1,5) and children.priorities.accepted==0)
    local yes=children.priorities.startup:poll()
    if failure=='none'then
        assert(yes and Gate.blocked())
        assert(group:commit(function(s)return children[s].startup:status().state=='active' end))
        assert(not Gate.blocked())
        local a,why=Store.apply_set(K,1,5);assert(not a and why=='pending' and children.priorities.accepted==1)
        a,why=Caps.apply_set('Mining','Stone',300,G);assert(not a and why=='pending' and children.limits.accepted==1)
    else
        assert(not yes and Gate.blocked())
        assert(not group:commit(function(s)return children[s].startup:status().state=='active' end))
        assert(children.limits.accepted==0 and children.priorities.accepted==0)
    end
    local closed=combined:drain()
    assert(closed==(failure=='none'))
    assert(combined:drain()==closed)
    assert(combined:status().cleanup_verified==closed)
    for _,s in ipairs({'limits','priorities'})do assert(children[s].drains==1 and children[s].cleanups==1)end
    assert(Gate.blocked() and #fs.operations==io)
end
print('two-stream startup: partial activation never admits edits; both ready required; failures stay fenced through independent drains')
