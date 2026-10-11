-- Real Caps -> writer -> SettingsSession -> draining queue. Only native storage
-- and proof providers are simulated; no installed player files are read/written.
package.loaded.log={warn=function()end,error=function()end,say=function()end}
local Startup=dofile(TEST_ROOT..'/experiments/settings_startup.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local File=require('datafile')
local W,G=string.rep('3',32),string.rep('4',32)
local scope='PWP-SCOPE-1:'..W..':'..G..':limits'
local function fixture(existing)
    -- Each fault fixture models a separate process; uncertain owners deliberately
    -- keep the shared fence. Never reset it inside a production session.
    package.loaded.settings_gate=nil
    package.loaded.store=nil
    package.loaded.caps=nil
    Startup=dofile(TEST_ROOT..'/experiments/settings_startup.lua')
    local caps=require('caps')
    local fs=require('memory_fs')();File.fs=fs
    local old=assert(caps.serialize_snapshot({[G]={Mining={Stone=100,Ore=false}}}))
    local newer=assert(caps.serialize_snapshot({[G]={Mining={Stone=200,Ore=false}}}))
    assert(File.write('legacy',old,0));caps.load('legacy');caps.set_role('authority')
    local codec=Codec.new{storage=W,guild=G,stream='limits'}
    local f={boot='boot',a=0,c=0,g=existing and 9 or 0,ticket=0,phase='dormant',lease={},
        verifies=0,activates=0,detaches=0,drains=0,cleanups=0,old=old,caps=caps,fs=fs}
    local function view()return {scope=scope,session=f.boot,ticket=f.ticket,generation=f.g,
        committed=f.c,state=f.phase=='awaiting_validation' and f.phase or 'saving',phase=f.phase}end
    local b={contract='PWP-DRAINING-DEV-1',max_payload_bytes=65536}
    function b:start()f.phase='awaiting_validation';return true end
    function b:inspect()return view()end
    function b:poll()return view()end
    function b:recovery()
        if f.bad_recovery then return nil end
        return {scope=scope,session=f.boot,kind=existing and 'existing' or 'missing',
            payload=existing and assert(codec.encode(newer))}
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
        runtime_guild=G,backend=b,lease=f.lease,clock=function()return 0 end,migration_body=old,
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
        activate=function(options)
            f.activates=f.activates+1
            local yes=caps.activate_recovered(options)
            if f.on_activate then f.on_activate()end
            return yes
        end,
        finalize=function(c)return caps.finish_retirement(c)end,
        detach=function(c)
            assert(c.session==f.boot);f.detaches=f.detaches+1
            if f.detach_lost then return false end
            return caps.retire_persistence(c) -- fenced, not drained
        end}
    f.o=o;f.s=assert(Startup.new(o));f.io=#fs.operations
    function f:complete()self.c=self.a;self.g=math.max(self.g,self.a)end
    return f
end
do
    assert(not Startup.new{} and not Startup.new{enabled='true'})
    local f=fixture(true);assert(f.s:start());assert(f.s:poll())
    assert(f.s:status().state=='active' and f.verifies==0 and f.a==0)
    assert(f.caps.data[G].Mining.Stone==200 and f.caps.data[G].Mining.Ore==false)
    local yes,why=f.caps.apply_set('Mining','Stone',300,G);assert(not yes and why=='pending')
    assert(f.caps.state~='saved' and f.a==1)
    f:complete();assert(f.caps.poll_persistence())
    f.denied=true;f.s:poll();assert(f.s:status().owner_retained and not f.caps.apply_set('Mining','Stone',400,G))
    assert(f.s:drain() and f.cleanups==1 and not f.lease.holder)
    assert(f.s:drain() and f.drains==1 and #f.fs.operations==f.io)
end
do
    local f=fixture(false);assert(f.s:start());assert(f.s:poll())
    assert(f.s:fenced() and require('settings_gate').blocked())
    local ok,why=f.caps.apply_set('Mining','Stone',999,G);assert(not ok and why=='settings_recovering')
    ok,why=require('store').save();assert(not ok and why=='settings_recovering')
    assert(f.s:status().state=='initializing' and f.a==1 and f.verifies==1 and f.activates==0)
    assert(f.s:poll() and f.a==1 and f.activates==0)
    f:complete();assert(f.s:poll() and f.activates==1 and f.caps.data[G].Mining.Stone==100)
    assert(not f.s:fenced() and not require('settings_gate').blocked())
    assert(f.s:drain() and f.cleanups==1 and #f.fs.operations==f.io)
end
for _,failure in ipairs({'reject_backup','bad_recovery','submit_lost'})do
    local f=fixture(false);f[failure]=true;assert(f.s:start());assert(not f.s:poll())
    assert(f.activates==0 and f.caps.data[G].Mining.Stone==100 and #f.fs.operations==f.io)
    local n=f.a;f.s:poll();assert(f.a==n and f.verifies<=1)
    local drained=f.s:drain()
    assert(require('settings_gate').blocked()==(drained~=true))
end
do
    local f=fixture(false)
    f.on_verify=function(c)c.session='changed';f.denied=true end
    assert(f.s:start());assert(not f.s:poll() and f.a==0)
    assert(f.s:drain()) -- original identity survives callback mutation/lost authority
end
-- No backup/import work for existing journals, including when import inputs
-- are absent. Options mutation after construction cannot change the binding.
do
    local f=fixture(true)
    f.o.migration_body=nil;f.o.verify_migration=nil
    f.s=assert(Startup.new(f.o));f.o.session='replacement';f.o.guild=string.rep('5',32)
    assert(f.s:start() and f.s:poll() and f.verifies==0 and f.a==0)
    assert(f.s:drain())
end
for _,missing in ipairs({'migration_body','verify_migration'})do
    local f=fixture(false);f.o[missing]=nil;f.s=assert(Startup.new(f.o))
    assert(f.s:start());assert(not f.s:poll() and f.a==0 and f.activates==0)
    assert(f.s:drain())
end
-- Lost verifier/activation replies never trigger a second import or activation.
do
    local f=fixture(false);f.on_verify=function()error('backup proof lost')end
    assert(f.s:start());assert(not f.s:poll() and f.a==0)
    assert(not f.s:poll() and f.verifies==1 and f.s:status().initialization_attempted)
    assert(f.s:drain())
end
-- Transition during pending initialization drains the original accepted bytes,
-- but cannot activate their old-world settings into the next session.
do
    local f=fixture(false);assert(f.s:start() and f.s:poll() and f.a==1)
    f.denied=true;assert(not f.s:poll() and f.activates==0)
    assert(not f.s:drain() and f.c==1 and f.cleanups==1 and f.latest==f.old)
    assert(f.s:status().state=='recovery_required' and not f.s:status().owner_retained)
    local io=#f.fs.operations
    assert(not f.caps.apply_set('Mining','Stone',400,G) and not f.caps.save() and #f.fs.operations==io)
    assert(require('settings_gate').blocked())
end
for _,callback in ipairs({'on_verify','on_activate','on_auth'})do
    local f=fixture(callback~='on_verify')
    assert(f.s:start())
    f[callback]=function()f.s:poll()end
    assert(not f.s:poll() and f.s:status().state=='retiring')
    f[callback]=nil
    local drained=f.s:drain();assert(f.cleanups==1)
    assert((drained==true)==(callback=='on_verify'))
end
do
    local f=fixture(true);assert(f.s:start());assert(f.s:poll())
    for _,key in ipairs({'scope','session','incarnation','guild','stream','camp','epoch','authority'})do
        local c={scope=scope,session='boot',incarnation='inc',guild=G,stream='limits',camp='camp',epoch=1,authority=true}
        c[key]='wrong';assert(not f.caps.retire_persistence(c),'wrong owner '..key)
    end
    assert(f.s:poll() and f.s:status().state=='active')
    f.drain_lost=true;assert(not f.s:drain());assert(not f.s:drain())
    assert(f.drains==1 and f.cleanups==0 and f.s:status().owner_retained and f.lease.holder)
end
do
    local f=fixture(true);assert(f.s:start());assert(f.s:poll())
    f.detach_lost=true;assert(not f.s:drain() and f.drains==0)
    f.detach_lost=false;assert(f.s:drain() and f.drains==1)
end
do
    local f=fixture(true);assert(f.s:start())
    f.on_activate=function()error('lost activation return')end
    assert(not f.s:poll() and f.detaches>0)
    assert(not f.caps.apply_set('Mining','Stone',400,G))
    assert(not f.s:drain() and f.cleanups==1 and require('settings_gate').blocked())
end
-- Refused startup never owns native IO and must not drain the competing owner.
do
    local f=fixture(true);assert(f.s:start())
    f.s:retire() -- cancel before observing existing journal recovery
    assert(not f.s:drain() and f.cleanups==1 and f.s:status().state=='recovery_required')
    local io=#f.fs.operations
    assert(not f.caps.apply_set('Mining','Stone',400,G) and #f.fs.operations==io)
    assert(require('settings_gate').blocked())
end
for _,role in ipairs({'client','authority'})do
    local f=fixture(true);assert(f.s:start() and f.s:poll())
    local yes,why=f.caps.apply_set('Mining','Stone',300,G);assert(not yes and why=='pending')
    -- Transition itself detaches; cleanup must compare pre-transition role/session.
    f.caps.set_role(role,'replacement')
    assert(f.s:drain() and f.caps.state~='saved' and f.cleanups==1)
end
for _,change in ipairs({'memory','role'})do
    local f=fixture(true);assert(f.s:start() and f.s:poll())
    local yes,why=f.caps.apply_set('Mining','Stone',300,G);assert(not yes and why=='pending')
    f.s:retire()
    if change=='memory' then f.caps.data[G].Mining.Stone=999
    else f.caps.set_role(nil,'next') end
    assert(f.s:drain() and f.caps.state~='saved','stale cleanup cannot declare current data saved')
end
do
    local f=fixture(true);local other={};f.lease.holder=other
    assert(not f.s:start());assert(f.s:drain())
    assert(f.lease.holder==other and f.drains==0 and f.cleanups==0 and not f.s:status().owner_retained)
end
-- No incidental Caps poll/flush between retiring and attaching a replacement.
do
    local f=fixture(true);assert(f.s:start() and f.s:poll())
    local notices=0;f.caps.on_change=function()notices=notices+1 end
    local yes,why=f.caps.apply_set('Mining','Stone',300,G)
    assert(not yes and why=='pending' and f.caps.state=='saving')
    assert(f.s:drain() and f.caps.state=='saved' and notices==0 and f.c==1)
    local original=f.s
    f.boot='replacement';f.o.session=f.boot;f.phase='dormant';f.a,f.c=0,0
    f.s=assert(Startup.new(f.o));assert(f.s:start() and f.s:poll())
    assert(f.s:status().state=='active' and f.activates==2)
    local old={scope=scope,session='boot',incarnation='inc',guild=G,stream='limits',camp='camp',epoch=1,authority=true}
    assert(not f.caps.retire_persistence(old) and not f.caps.finish_retirement(old))
    assert(original:drain() and f.s:poll())
    assert(f.s:drain() and f.cleanups==2)
end
print('startup: journal-first recovery, verified initialization, durable activation, original-owner drain and failure fencing passed')
-- Repeated role discovery must not detach a healthy writer. A true transition
-- still retires it, preventing an old session from receiving another edit.
do
    local f=fixture(true)
    f.caps.set_role('authority',1)
    assert(f.s:start() and f.s:poll())
    f.caps.set_role('authority',1)
    local yes,why=f.caps.apply_set('Mining','Stone',301,G)
    assert(not yes and why=='pending' and f.a==1)
    f:complete();assert(f.caps.poll_persistence())
    f.caps.set_role('authority',2)
    local count=f.a
    assert(not f.caps.apply_set('Mining','Stone',302,G) and f.a==count)
    assert(f.s:drain())
end
-- Real migration guard -> startup -> Caps/writer/session/queue composition.
do
    local Migration=dofile(TEST_ROOT..'/experiments/settings_migration_guard.lua')
    local f=fixture(false);local files={}
    for _,base in ipairs({'priorities.txt','caps.txt'})do
        for _,suffix in ipairs({'','.tmp','.pending','.bak'})do files[base..suffix]=false end
    end
    files['caps.txt']=f.old
    files['priorities.txt']=assert(require('store').serialize_snapshot({pal={[1]=false}},true))
    local function reader(name)
        if files[name]==false then return nil,'missing',2 end
        return files[name]
    end
    local guard=assert(Migration.new{enabled=true,files=files,storage=W,guild=G,runtime_guild=G,
        read_source=reader,read_backup=reader,verify_receipt=function()return true end,
        fenced=function()return f.s:fenced() and not f.denied end})
    f.o.migration_body=guard:body()
    f.o.verify_migration=function(c,b)return guard:verify(c,b)end
    f.s=assert(Startup.new(f.o));assert(f.s:start() and f.s:poll() and f.a==1 and f.activates==0)
    f:complete();assert(f.s:poll() and f.activates==1);assert(f.s:drain())
end
