-- Real Store -> writer -> SettingsSession -> draining queue. Only native storage
-- and proof providers are simulated; no installed player files are read/written.
package.loaded.log={warn=function()end,error=function()end,say=function()end}
local Startup=dofile(TEST_ROOT..'/experiments/settings_startup.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local File=require('datafile')
local Coverage=dofile(TEST_ROOT..'/experiments/settings_priority_coverage.lua')
local W,G=string.rep('3',32),string.rep('4',32)
local scope='PWP-SCOPE-1:'..W..':'..G..':priorities'
local function fixture(existing,palkey)
    palkey=palkey or 'pal'
    -- Each fault fixture models a separate process; uncertain owners deliberately
    -- keep the shared fence. Never reset it inside a production session.
    package.loaded.settings_gate=nil
    package.loaded.store=nil
    package.loaded.caps=nil
    Startup=dofile(TEST_ROOT..'/experiments/settings_startup.lua')
    local store=require('store')
    local fs=require('memory_fs')();File.fs=fs
    local old=assert(store.serialize_snapshot({[palkey]={[1]=5,[2]=false}},true))
    local newer=assert(store.serialize_snapshot({[palkey]={[1]=1,[2]=2,[3]=3,[4]=4,[5]=5,[6]=false}},true))
    assert(File.write('legacy',old,0));store.load('legacy');store.set_role('authority')
    local codec=Codec.new{storage=W,guild=G,stream='priorities'}
    local f={boot='boot',a=0,c=0,g=existing and 9 or 0,ticket=0,phase='dormant',lease={},
        verifies=0,activates=0,detaches=0,drains=0,cleanups=0,old=old,store=store,newer=newer,coverages=0,ownerships=0,fs=fs}
    local function view()return {scope=scope,session=f.boot,ticket=f.ticket,generation=f.g,
        committed=f.c,state=f.phase=='awaiting_validation' and f.phase or 'saving',phase=f.phase}end
    local b={contract='PWP-DRAINING-DEV-1',max_payload_bytes=65536}
    function b:start()f.phase='awaiting_validation';return true end
    function b:inspect()return view()end
    function b:poll()return view()end
    function b:recovery()
        if f.bad_recovery then return nil end
        return {scope=scope,session=f.boot,kind=f.kind or (existing and 'existing' or 'missing'),
            payload=existing and (f.payload or assert(codec.encode(newer)))}
    end
    function b:approve(_,mode)
        assert(mode==(existing and 'existing' or 'initialize_missing'));f.phase='ready';return true
    end
    function b:submit(c,body)
        assert(c.session==f.boot and c.epoch==1 and c.guild==G)
        f.a=f.a+1;f.ticket=f.ticket+1;f.latest=body
        if f.submit_lost then error('lost submit')end
        return {scope=scope,session=f.boot,revision=f.a}
    end
    function b:close(c)assert(c.session==f.boot);f.phase='closing';return true end
    function b:drain(c)
        assert(c.session==f.boot and c.epoch==1);f.drains=f.drains+1
        if f.drain_lost then error('lost drain')end
        f.c=f.a;f.g=math.max(f.g,f.a);f.phase='closed';return view()
    end
    function b:cleanup()f.cleanups=f.cleanups+1;return true end
    local o={enabled=true,storage=W,guild=G,session='boot',incarnation='inc',epoch=1,camp='camp',
        stream='priorities',runtime_guild=G,backend=b,lease=f.lease,clock=function()return 0 end,migration_body=old,
        authorize=function(c)
            assert(c.session==f.boot and c.epoch==1)
            if f.on_auth then f.on_auth(c)end
            return not f.denied
        end,
        verify_migration=function(c,body)
            f.verifies=f.verifies+1;assert(body==old and c.guild==G)
            if f.on_verify then f.on_verify(c)end
            return not f.reject_backup
        end,
        owns_key=function(key,c)
            f.ownerships=f.ownerships+1
            assert(c.scope==scope and c.storage==W and c.guild==G and c.stream=='priorities'
                and c.session==f.boot and c.incarnation=='inc' and c.epoch==1 and c.camp=='camp' and c.authority==true)
            if f.on_owns then return f.on_owns(key,c) end
            return key==palkey
        end,
        verify_coverage=function(c,recovered)
            f.coverages=f.coverages+1
            assert(c.scope==scope and c.session==f.boot and c.camp=='camp')
            assert(recovered.scope==scope and recovered.session==f.boot)
            assert(f.s:fenced() and f.activates==0)
            if f.on_coverage then return f.on_coverage(c,recovered) end
            return Coverage.check(recovered.settings,f.roster)
        end,
        activate=function(options)
            f.activates=f.activates+1;f.activation=options
            local yes=store.activate_recovered(options)
            if f.on_activate then f.on_activate()end
            return yes
        end,
        finalize=function(c)return store.finish_retirement(c)end,
        detach=function(c)
            assert(c.session==f.boot);f.detaches=f.detaches+1
            if f.detach_lost then return false end
            return store.retire_persistence(c) -- fenced, not drained
        end}
    -- Explicit simulated census, never engine evidence or inferred from rows.
    f.roster={complete=true,pals={{key=palkey,capable={[1]=true,[2]=true}}}}
    f.o=o;f.s=assert(Startup.new(o));f.io=#fs.operations
    function f:complete()self.c=self.a;self.g=math.max(self.g,self.a)end
    return f
end
-- Opt-in only, stream allowlist, and mandatory key ownership provider.
do
    assert(not Startup.new{} and not Startup.new{enabled='true'})
    for _,stream in ipairs({'unknown','',false,1}) do
        local f=fixture(true);f.o.stream=stream;assert(not pcall(Startup.new,f.o))
    end
    local f=fixture(true);f.o.owns_key=nil;assert(not pcall(Startup.new,f.o))
end
-- Existing recovery never invokes migration; preserve all priority values, X,
-- baseline metadata and durable revision through the real Store/session/queue.
do
    local f=fixture(true);f.o.migration_body=nil;f.o.verify_migration=nil
    f.s=assert(Startup.new(f.o));assert(f.s:start() and f.s:poll())
    assert(f.s:status().state=='active' and f.verifies==0 and f.coverages==1 and f.a==0)
    assert(f.store.serialize()==f.newer and f.store.baseline==true)
    for i=1,5 do assert(f.store.data.pal[i]==i) end
    assert(f.store.data.pal[6]==false and f.ownerships>0)
    assert(f.activation.owns_key~=f.o.owns_key)
    local yes,why=f.store.apply_set('pal',1,4);assert(not yes and why=='pending' and f.a==1)
    assert(f.store.state~='saved');f:complete();assert(f.store.poll_persistence())
    assert(f.s:drain() and f.drains==1 and f.cleanups==1 and not f.lease.holder)
    assert(#f.fs.operations==f.io)
end
-- A true return cannot certify modified context, identity, metadata or rows.
for _,mutation in ipairs({
    function(c)c.session='replacement' end,
    function(c)c.camp='replacement' end,
    function(c)c.extra=true end,
    function(c)c.authority=nil end,
    function(c)setmetatable(c,{}) end,
    function(_,r)r.scope='replacement' end,
    function(_,r)r.session='replacement' end,
    function(_,r)r.revision=r.revision+1 end,
    function(_,r)r.extra=true end,
    function(_,r)r.settings.data.pal[1]=5 end,
    function(_,r)r.settings.data.pal[6]=1 end,
    function(_,r)r.settings.baseline=false end,
    function(_,r)r.settings.count=0 end,
    function(_,r)r.settings.transient=1 end,
    function(_,r)r.settings.data.foreign={[1]=2} end,
    function(_,r)r.settings.data.pal[1]=nil end,
    function(_,r)r.settings.data.pal[1]=1.0 end,
    function(_,r)setmetatable(r.settings.data.pal,{}) end,
    function(_,r)r.settings.data=r end,
}) do
    local f=fixture(true)
    f.on_coverage=function(c,r)mutation(c,r);return true end
    assert(f.s:start() and not f.s:poll())
    assert(f.activates==0 and f.store.serialize()==f.old and f.s:status().owner_retained)
    assert(f.s:status().reason=='coverage proof rejected' and require('settings_gate').blocked())
    assert(not f.store.apply_set('pal',1,1) and not f.s:poll() and f.coverages==1)
    assert(not f.s:drain() and f.drains==1 and f.cleanups==1)
    assert(f.s:status().state=='recovery_required' and require('settings_gate').blocked())
    assert(#f.fs.operations==f.io)
end
-- A buggy provider fills a missing baseline before using the real pure checker.
-- Its result is true for the altered copy, but cannot certify the original.
for _,existing in ipairs({true,false}) do
    local f=fixture(existing);f.roster.pals[1].capable[7]=true
    f.on_coverage=function(_,r)
        assert(not Coverage.check(r.settings,f.roster))
        r.settings.data.pal[7]=false;r.settings.count=r.settings.count+1
        assert(Coverage.check(r.settings,f.roster))
        return true
    end
    assert(f.s:start())
    if not existing then assert(f.s:poll());f:complete() end
    assert(not f.s:poll() and f.activates==0 and f.store.serialize()==f.old)
    assert(f.s:status().reason=='coverage proof rejected' and f.s:status().owner_retained)
    assert(not f.s:drain() and f.cleanups==1 and require('settings_gate').blocked())
    assert(#f.fs.operations==f.io)
end
-- A header and even a nonempty full row set cannot substitute for proof.
for _,mode in ipairs({'missing','false','nil','truthy','throw','reentrant','revoke'}) do
    local f=fixture(true)
    if mode=='missing' then f.o.verify_coverage=nil;f.s=assert(Startup.new(f.o))
    else f.on_coverage=function()
        if mode=='throw' then error('coverage lost') end
        if mode=='reentrant' then f.s:poll();return true end
        if mode=='revoke' then f.denied=true;return true end
        if mode=='truthy' then return 1 end
        if mode=='false' then return false end
    end end
    assert(f.s:start());assert(not f.s:poll(),mode)
    assert(f.activates==0 and f.store.serialize()==f.old and f.s:status().owner_retained)
    assert(require('settings_gate').blocked() and not f.store.save())
    assert(not f.s:poll() and f.coverages<=1)
    assert(not f.s:drain() and f.drains==1 and f.cleanups==1)
    assert(f.s:status().state=='recovery_required' and require('settings_gate').blocked())
    assert(#f.fs.operations==f.io)
end
-- No baseline marker/empty data also needs external coverage; metadata survives.
for _,baseline in ipairs({false,true}) do
    local f=fixture(true)
    local body=assert(f.store.serialize_snapshot({},baseline))
    f.payload=assert(Codec.new{storage=W,guild=G,stream='priorities'}.encode(body))
    f.on_coverage=function(_,r)assert(r.settings.baseline==baseline and r.settings.count==0);return true end
    assert(f.s:start() and f.s:poll() and f.store.serialize()==body and f.coverages==1)
    assert(f.s:drain())
end
-- Missing-journal import is one verified attempt; coverage follows durability.
do
    local f=fixture(false);assert(f.s:start() and f.s:poll())
    assert(f.a==1 and f.verifies==1 and f.coverages==0 and f.activates==0)
    assert(f.s:fenced() and not f.store.apply_set('pal',1,1))
    assert(f.s:poll() and f.a==1 and f.coverages==0)
    f:complete();assert(f.s:poll() and f.coverages==1 and f.activates==1)
    assert(f.store.serialize()==f.old and f.s:drain() and #f.fs.operations==f.io)
end
for _,mode in ipairs({'unknown','corrupt','missing_body','missing_verifier','rejected','lost'}) do
    local f=fixture(false)
    if mode=='unknown' then f.kind='unknown'
    elseif mode=='corrupt' then f.bad_recovery=true
    elseif mode=='missing_body' then f.o.migration_body=nil
    elseif mode=='missing_verifier' then f.o.verify_migration=nil
    elseif mode=='rejected' then f.reject_backup=true
    else f.on_verify=function()error('lost proof')end end
    f.s=assert(Startup.new(f.o));assert(f.s:start());assert(not f.s:poll())
    assert(f.a==0 and f.activates==0 and f.coverages==0 and f.store.serialize()==f.old)
    f.s:drain();assert(f.drains==1 and #f.fs.operations==f.io)
end
-- Coverage can fail after an accepted migration: keep the journal fenced.
do
    local f=fixture(false);f.on_coverage=function()return false end
    assert(f.s:start() and f.s:poll());f:complete();assert(not f.s:poll())
    assert(f.activates==0 and not f.s:drain() and f.c==1 and f.cleanups==1)
    assert(require('settings_gate').blocked())
end
-- Store activation calls the bound ownership proof, with authority checked
-- again after every callback. Failures cannot install a usable writer.
for _,mode in ipairs({'false','throw','reentrant','revoke','truthy'}) do
    local f=fixture(true)
    f.on_owns=function()
        if mode=='throw' then error('ownership lost') end
        if mode=='reentrant' then f.s:poll();return true end
        if mode=='revoke' then f.denied=true;return true end
        if mode=='truthy' then return 'true' end
        return false
    end
    assert(f.s:start());assert(not f.s:poll(),mode)
    assert(f.activates==1 and f.store.serialize()==f.old and f.s:status().owner_retained)
    assert(not f.store.apply_set('pal',1,1) and not f.s:drain() and f.cleanups==1)
    assert(require('settings_gate').blocked() and #f.fs.operations==f.io)
end
-- Store's final proof occurs after writer construction. Failure must retain
-- that writer for original-session drain without installing recovered settings.
do
    local f=fixture(true)
    f.on_owns=function()return f.ownerships<2 end
    assert(f.s:start() and not f.s:poll())
    assert(f.ownerships==2 and f.activates==1 and f.store.serialize()==f.old)
    assert(f.s:status().owner_retained and not f.s:drain())
    assert(f.drains==1 and f.cleanups==1 and require('settings_gate').blocked())
end
-- Lost activation return may already have installed a writer: retire and drain
-- it, retaining the shared fence because startup never confirmed cutover.
do
    local f=fixture(true);f.on_activate=function()error('lost activation return')end
    assert(f.s:start() and not f.s:poll())
    assert(f.detaches>0 and not f.store.apply_set('pal',1,4))
    assert(not f.s:drain() and f.cleanups==1 and require('settings_gate').blocked())
end
-- Copies, immutable construction inputs, and exact context matching.
do
    local f=fixture(true)
    f.on_owns=function(key,c)c.session='mutated';return key=='pal' end
    assert(f.s:start() and f.s:poll())
    f.o.owns_key=function()error('replacement callback must not run')end
    f.o.session='replacement';f.o.stream='limits';f.o.authorize=function()return false end
    local yes,why=f.store.apply_set('pal',1,4);assert(not yes and why=='pending')
    assert(f.s:drain())
end
for _,field in ipairs({'scope','storage','guild','stream','session','incarnation','epoch','camp','authority'}) do
    local f=fixture(true);assert(f.s:start() and f.s:poll())
    local c={};for k,v in pairs(f.activation.context)do c[k]=v end;c[field]='wrong'
    local n=f.ownerships
    assert(not f.activation.owns_key('pal',c) and f.ownerships==n)
    assert(not f.s:poll() and f.s:drain())
end
-- Original-owner drain retains uncertain native state and never retries it.
do
    local f=fixture(true);assert(f.s:start() and f.s:poll())
    f.store.apply_set('pal',1,4);f.denied=true;assert(not f.s:poll())
    f.drain_lost=true;assert(not f.s:drain() and not f.s:drain())
    assert(f.drains==1 and f.cleanups==0 and f.lease.holder and f.s:status().owner_retained)
end
do
    local f=fixture(true);assert(f.s:start() and f.s:poll())
    f.detach_lost=true;assert(not f.s:drain() and f.drains==0)
    f.detach_lost=false;assert(f.s:drain() and f.drains==1)
end
-- Actual pure checker + explicit fake current-camp census integration.
for _,mode in ipairs({'partial','missing_work','missing_pal','X'}) do
    local f=fixture(true)
    if mode=='partial' then f.roster.complete=false
    elseif mode=='missing_work' then f.roster.pals[1].capable[7]=true
    elseif mode=='missing_pal' then f.roster.pals[2]={key='other',capable={[1]=true}}
    else f.roster.pals[1].capable[6]=true end
    assert(f.s:start())
    if mode=='X' then assert(f.s:poll() and f.s:drain())
    else
        assert(not f.s:poll() and f.activates==0 and not f.s:drain())
        assert(f.cleanups==1 and require('settings_gate').blocked())
    end
end
-- Bound proof remains fresh after activation, including reentry from an edit.
for _,mode in ipairs({'false','throw','reentrant','revoke','before'}) do
    local f=fixture(true);assert(f.s:start() and f.s:poll())
    local n=f.a
    if mode=='before' then f.denied=true
    else f.on_owns=function()
        if mode=='throw' then error('lost ownership') end
        if mode=='reentrant' then f.s:poll();return true end
        if mode=='revoke' then f.denied=true;return true end
        return false
    end end
    assert(not f.store.apply_set('pal',1,4) and f.a==n)
    assert(f.store.serialize()==f.newer and not f.s:poll())
    assert(f.s:drain() and f.cleanups==1 and #f.fs.operations==f.io)
end
print('priority startup: explicit coverage, fresh bound ownership, isolated recovery, migration and original-owner drain passed')

-- Real startup/Store composition with the default-off fresh membership adapter.
-- Engine evidence is explicitly simulated; this is not transition live proof.
for _,failure in ipairs({'membership','authority','world','epoch','provider_epoch','removed','reentry','mutation'})do
    local Membership=dofile(TEST_ROOT..'/experiments/settings_priority_membership.lua')
    local key=string.rep('0',32)..string.rep('A',32)
    local f=fixture(true,key)
    local c={scope=scope,storage=W,guild=G,stream='priorities',session='boot',incarnation='inc',epoch=1,camp='camp',authority=true}
    local current,world,reads=true,true,0
    local epoch,token,mode=1,function()end,nil
    local RealAuthority=dofile(TEST_ROOT..'/experiments/settings_startup_authority.lua')
    local authority=assert(RealAuthority.new{enabled=true,context=c,runtime_guild=G,
        get_epoch=function()return {available=true,supported=true,epoch=epoch,token=token}end,
        read_evidence=function()return {status='context_agrees',agrees=true,world='World test',directory=W,role=3,dedicated=false,
            world_address=1,state_address=2,instance_address=3,manager_address=4,
            identity_loaded_status='read',identity_loaded_world=true,identity_selected_status='format_valid',
            identity_selected=W,identity_autosave_status='empty'}end,
        read_authority=function()return {authority_status='read',authority=not f.denied,guild_status='format_valid',guild=G,
            legacy_guild='1145324612-1145324612-1145324612-1145324612',world_address=1,state_address=2,instance_address=3}end})
    f.o.authorize=authority.authorize
    local member
    member=assert(Membership.new{enabled=true,context=c,runtime_guild=G,authorize=authority.authorize,
        read_member=function(k,ctx)
            reads=reads+1;assert(k==key and ctx.scope==scope)
            if mode=='reentry'then member.owns_key(k,ctx)end
            if mode=='mutation'then ctx.session='changed'end
            return {complete=true,key=k,group=current and G or W,world_resolved=world,in_guild=mode~='removed'}
        end})
    f.o.owns_key=member.owns_key;f.s=assert(Startup.new(f.o))
    assert(f.s:start() and f.s:poll() and reads>0)
    local before=reads;local yes,why=f.store.apply_set(key,1,4)
    assert(not yes and why=='pending' and f.a==1 and reads>before)
    f:complete();assert(f.store.poll_persistence())
    local saved=f.store.serialize();local submissions=f.a
    if failure=='membership'then current=false
    elseif failure=='world'then world=false
    elseif failure=='authority'then f.denied=true
    elseif failure=='provider_epoch'then epoch=2
    elseif failure=='removed' or failure=='reentry' or failure=='mutation'then mode=failure
    else
        local wrong={};for k,v in pairs(c)do wrong[k]=v end;wrong.epoch=2
        assert(not member.owns_key(key,wrong))
    end
    assert(not f.store.apply_set(key,2,4) and f.a==submissions)
    assert(f.store.serialize()==saved and not f.s:poll())
    assert(f.s:drain() and f.cleanups==1 and #f.fs.operations==f.io)
end
print('priority membership startup integration: fresh positive edit, membership/world/authority/epoch rejection before submit, unchanged data and original-owner drain')
