-- Actual store/caps -> settings_writer -> settings_session -> journal queue /
-- codec / durability barrier. Only storage completion and legacy FS are fakes.
package.loaded.log={warn=function() end,error=function() end,say=function() end}
local file=require('datafile')
local Factory=dofile(TEST_ROOT..'/experiments/settings_session.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local W,G,H=string.rep('a',32),string.rep('b',32),string.rep('c',32)
local LIVE_ALIAS='-758686034-1314655308-1294252187-537966059'
local LIVE_GUILD='d2c75eae4e5c0c4c4d24b89b2010b5eb'
local function copy(t)
    if type(t)~='table' then return t end
    local r={};for k,v in pairs(t) do r[k]=copy(v) end;return r
end
local function fixture(name,new_pal,runtime)
    package.loaded[name]=nil
    local m=require(name)
    local stream=name=='store' and 'priorities' or 'limits'
    local guild=runtime and LIVE_GUILD or G
    local runtime_key=runtime or guild
    local data=name=='store' and {palA={[1]=1},palB={[1]=2}} or {[guild]={Mining={Stone=100}}}
    -- Fixed read-only observation of the actual legacy caps.txt rows. Tests never
    -- access the installed file, infer membership, or change runtime guild keys.
    if runtime then data={[runtime]={Deforest={Wood=30000},Mining={Stone=35000}}} end
    if new_pal then data.palB=nil end
    local body=assert(m.serialize_snapshot(data,true))
    local recovered_body=runtime and assert(m.serialize_snapshot({[guild]=data[runtime]})) or body
    local fs=require('memory_fs')();file.fs=fs
    assert(file.write('legacy',body,0));m.load('legacy');m.set_role('authority')
    local codec=Codec.new{storage=W,guild=guild,stream=stream,max_payload_bytes=65536}
    local scope='PWP-SCOPE-1:'..W..':'..guild..':'..stream
    local c={scope=scope,session='boot',incarnation='inc',guild=guild,camp='A',stream=stream,epoch=7,authority=true}
    local f={m=m,fs=fs,writes=0,notices=0,token='pair-0',history={},
        slots={{status='valid',scope=scope,generation=7,payload=assert(codec.encode(recovered_body))},{status='missing'}}}
    local function admit(op)
        assert(not f.op);f.op=copy(op);f.history[#f.history+1]=copy(op)
        if op.kind=='update' then f.writes=f.writes+1 end
        if f.on_admit then f.on_admit() end
        return true
    end
    local backend={contract='PWP-JOURNAL-DEV-1',max_payload_bytes=65536,
        recover=admit,update=admit,
        peek=function() return f.result end,
        consume=function() assert(f.result and f.result.certain);f.op,f.result=nil,nil;return true end}
    local s=Factory.new{enabled=true,storage=W,guild=guild,stream=stream,session='boot',incarnation='inc',epoch=7,
        backend_kind='PWP-JOURNAL-DEV-1',backend=backend,lease={},clock=function() return 0 end,
        max_payload_bytes=65536,authorize=function(ctx)
            if f.on_authorize then f.on_authorize(ctx) end
            return not f.denied and ctx.scope==scope and ctx.epoch==7 and ctx.guild==guild
        end}
    function f:complete(state)
        local op=assert(self.op);local r=copy(op);r.terminal=true;r.certain=state~='uncertain'
        if state then r.status=state
        elseif op.kind=='recover' then r.status='recovered';r.slots=copy(self.slots);r.preimages=self.token
        else
            r.status='updated';self.token='pair-'..op.ticket;r.preimages=self.token
            self.slots[2]={status='valid',scope=scope,generation=op.journal_generation,payload=op.payload}
        end
        self.result=r
    end
    assert(s:open(c));f:complete();assert(s:poll(c)=='recovered')
    local recovery=assert(s:take_recovered(c));assert(s:register_camp(c,true));assert(s:ready(c))
    f.options={enabled=true,session=s,context=c,recovery=recovery,runtime_guild=runtime,
        owns_key=function(key,ctx)
            assert(ctx.guild==guild and ctx.epoch==7)
            if f.on_owned then f.on_owned(key,ctx) end
            return key=='palA' or key=='palB'
        end}
    f.session,f.context,f.codec=s,c,codec
    function f:attach() return m.attach_persistence(self.options) end
    function f:edit(n,key)
        if name=='store' then return m.apply_set(key or 'palA',1,n) end
        return m.apply_set('Mining','Stone',n,runtime_key)
    end
    m.on_change=function() f.notices=f.notices+1;if f.on_notice then f.on_notice() end end
    f.io=#fs.operations
    return f
end

for _,name in ipairs({'store','caps'}) do
    -- Two accepted snapshots: first completion must not announce the newer one.
    local f=fixture(name);assert(f:attach());local before=f.m.serialize()
    local ok,why,r=f:edit(3);assert(ok==false and why=='pending' and r.revision==1)
    assert(f.m.serialize()~=before and f.m.state=='saving' and f.notices==0)
    ok,why,r=f:edit(4,name=='store' and 'palB' or nil);assert(not ok and why=='pending' and r.revision==2)
    assert(not f.m.flush(100,true))
    f:complete();assert(not f.m.flush(100,true) and f.notices==0 and f.m.state=='saving')
    f:complete();assert(f.m.flush(100,true) and f.notices==1 and f.m.state=='saved')
    assert(f.m.persisted_revision==2 and f.m.generation==1 and #f.fs.operations==f.io)

    -- Same bytes still create a new revision: no true until that revision commits.
    f=fixture(name);assert(f:attach());f:edit(3)
    f.on_notice=function() f.on_notice=nil;assert(not f:edit(3)) end
    f:complete();assert(not f.m.flush(100,true) and f.m.state=='saving')
    f:complete();assert(f.m.flush(100,true) and f.m.persisted_revision==2)

    -- Reentrant notification admits a new edit, so current snapshot is NOT saved.
    f=fixture(name);assert(f:attach());f:edit(3)
    f.on_notice=function() f.on_notice=nil;assert(not f:edit(4)) end
    f:complete();assert(not f.m.flush(100,true) and f.m.state=='saving' and f.notices==1)
    f:complete();assert(f.m.flush(100,true) and f.notices==2)

    for _,status in ipairs({'io_error','uncertain'}) do
        f=fixture(name);assert(f:attach());f:edit(3);f:complete(status)
        assert(not f.m.flush(100,true) and f.m.state=='error' and f.notices==0,status)
    end

    -- Definite stage refusal and ambiguous post-admission lost return.
    f=fixture(name);f.session.stage=function() return nil,'refused' end
    assert(f:attach());before=f.m.serialize();assert(not f:edit(3))
    assert(f.m.serialize()==before and f.writes==0 and f.m.state=='saved')
    f=fixture(name);f.session.submit=function() return false end
    assert(f:attach());before=f.m.serialize();assert(not f:edit(3))
    assert(f.m.serialize()==before and f.writes==0 and not f.m.flush(100,true))
    f=fixture(name);local submit=f.session.submit
    f.session.submit=function(self,ctx,ticket,body) submit(self,ctx,ticket,body);return nil end
    assert(f:attach());before=f.m.serialize();assert(not f:edit(3))
    assert(f.writes==1 and f.m.serialize()==before and f.m.state=='error')
    f:complete();assert(not f.m.flush(100,true) and f.notices==0)

    -- Detach within dispatch cannot install a candidate in another role/load.
    for _,transition in ipairs({'role','load'}) do
        f=fixture(name);assert(f:attach());before=f.m.serialize()
        f.on_admit=function()
            if transition=='role' then f.m.set_role('client') else f.m.load('legacy') end
        end
        assert(not f:edit(3));assert(f.m.serialize()==before and f.notices==0)
        f:complete();assert(not f.m.poll_persistence() and f.notices==0)
        assert(f.m.serialize()==before)
    end

    -- Attachment validation cannot recursively replace an attachment.
    f=fixture(name);local status=f.session.status;local nested
    f.session.status=function(self,ctx)
        if not nested then nested={f:attach()} end
        return status(self,ctx)
    end
    assert(f:attach());assert(nested[1]==false and nested[2]=='attachment_busy')
    f:edit(3);assert(f.writes==1)

    f=fixture(name);f.options.enabled=false;assert(not f:attach() and f.writes==0)
    f=fixture(name);f.m.set_role('client');assert(not f:attach() and f.writes==0)
    f=fixture(name);f.options.recovery.settings.data={};assert(not f:attach() and f.writes==0)
    f=fixture(name);f.session.ready=function() return false end;assert(not f:attach() and f.writes==0)

    -- Close without a new load must never silently fall back to legacy writes.
    f=fixture(name);assert(f:attach());f.m.detach_persistence()
    assert(not f:edit(3) and not f.m.flush(100,true) and #f.fs.operations==f.io)

    f=fixture(name);assert(f:attach())
    local cleared=name=='store' and {f.m.apply_clear('palA',1)} or {f.m.apply_clear('Mining','Stone',G)}
    assert(cleared[1]==false and cleared[2]=='pending' and f.notices==0)
    f:complete();assert(f.m.flush(100,true) and f.notices==1)
end

-- Ownership proof reentry must stop the outer candidate BEFORE any staging.
do
    local f=fixture('store');assert(f:attach())
    f.on_owned=function()
        f.on_owned=nil;local ok,why=f:edit(5,'palB');assert(not ok and why=='pending')
    end
    local ok,why=f:edit(3);assert(not ok and why=='snapshot_changed')
    assert(f.writes==1 and f.m.get('palB',1)==5 and f.m.get('palA',1)==1)
    f:complete();assert(f.m.flush(100,true))
    f=fixture('store');assert(f:attach());assert(not f:edit(3,'foreign') and f.writes==0)
    -- Mutating the caller's context in an ownership callback cannot redirect it.
    f=fixture('store');f.on_owned=function() f.options.context.guild=H end
    assert(f:attach());assert(not f:edit(3) and f.writes==1)
end
do
    local f=fixture('store',true);assert(f:attach())
    local ok,why=f.m.capture_baseline('palB',{[1]=true,[2]=true},{[2]=true})
    assert(not ok and why=='pending' and f.m.state=='saving' and f.notices==0)
    assert(f.m.get('palB',2)==false and not f.m.flush(100,true))
    f:complete();assert(f.m.flush(100,true) and f.notices==1)
end
do
    local f=fixture('caps');assert(f:attach())
    assert(not f.m.apply_set('Mining','Stone',200,H) and f.writes==0)
    assert(f.m.adopt_wildcard(G)==0)
    f=fixture('caps');f.m.data['*']={Mining={Stone=100}};assert(not f:attach())
end
-- Explicit live signed alias: preserve runtime API/key semantics while ONLY the
-- immutable persistence body is canonical. Recovery still comes from the real
-- typed session; matching GUID bits alone never supplies fresh authorization.
do
    local f=fixture('caps',nil,LIVE_ALIAS);local m=f.m
    assert(f:attach() and m.data[LIVE_ALIAS].Mining.Stone==35000 and not m.data[LIVE_GUILD])
    assert(m.for_work({},'Deforest',LIVE_ALIAS).Wood==30000)
    assert(m.all({},LIVE_ALIAS).Mining.Stone==35000 and next(m.all({},LIVE_GUILD))==nil)
    local ok,why,r=f:edit(36000)
    assert(not ok and why=='pending' and r.scope==f.context.scope and r.revision==1)
    local decoded=assert(f.codec.decode(f.op.payload))
    assert(decoded.data[LIVE_GUILD].Mining.Stone==36000 and not decoded.data[LIVE_ALIAS])
    assert(m.data[LIVE_ALIAS].Mining.Stone==36000 and not m.data[LIVE_GUILD])
    assert(m.serialize():find(LIVE_ALIAS,1,true) and not m.serialize():find(LIVE_GUILD,1,true))
    f:complete();assert(m.flush(100,true) and f.notices==1)

    ok,why=m.clear('Deforest','Wood',LIVE_ALIAS)
    assert(not ok and why=='pending' and not m.data[LIVE_ALIAS].Deforest)
    assert(not f.codec.decode(f.op.payload).data[LIVE_GUILD].Deforest)
    f:complete();assert(m.flush(100,true) and f.notices==2)
    -- Clearing the last explicit rule must serialize an empty canonical snapshot.
    ok,why=m.clear('Mining','Stone',LIVE_ALIAS)
    assert(not ok and why=='pending' and next(m.data)==nil)
    assert(next(f.codec.decode(f.op.payload).data)==nil)
    f:complete();assert(m.flush(100,true))

    -- Inherited config remains runtime-only; clearing writes an OFF mask, not a
    -- flattened config or deletion that would expose inherited limits again.
    local cfg={work_caps={Mining={Stone=900,Ore=123}}};m.configure(cfg)
    ok,why=m.clear('Mining','Stone',LIVE_ALIAS)
    assert(not ok and why=='pending' and m.data[LIVE_ALIAS].Mining.Stone==false)
    decoded=f.codec.decode(f.op.payload)
    assert(decoded.data[LIVE_GUILD].Mining.Stone==false and decoded.data[LIVE_GUILD].Mining.Ore==nil)
    assert(m.all(cfg,LIVE_ALIAS).Mining.Stone==nil and m.all(cfg,LIVE_ALIAS).Mining.Ore==123)
    f:complete();assert(m.flush(100,true) and #f.fs.operations==f.io)
end

-- No guessed mapping, case folding, wildcard adoption, or merging equivalent
-- aliases. Even an empty colliding group is rejected, not silently normalized.
for _,bad in ipairs({false,'*',H,LIVE_GUILD,LIVE_GUILD:upper(),
    '-0758686034-1314655308-1294252187-537966059',
    '-758686034-1314655308-1294252187-537966060',
    '-5053653330-1314655308-1294252187-537966059',
    '4294967296-1314655308-1294252187-537966059'}) do
    local f=fixture('caps',nil,LIVE_ALIAS);f.options.runtime_guild=bad
    assert(not f:attach() and f.writes==0)
end
do
    local f=fixture('caps',nil,LIVE_ALIAS);f.options.runtime_guild=nil
    assert(not f:attach() and f.writes==0)
end
for _,other in ipairs({'*',H,LIVE_GUILD,'3536281262-1314655308-1294252187-537966059'}) do
    local f=fixture('caps',nil,LIVE_ALIAS);f.m.data[other]={}
    assert(not f:attach() and f.writes==0)
end
do
    local f=fixture('caps',nil,LIVE_ALIAS);f.m.data[LIVE_ALIAS].Mining.Stone=35001
    assert(not f:attach() and f.writes==0) -- exact mapped body, not just alias identity
    f=fixture('caps',nil,LIVE_ALIAS);f.denied=true
    assert(not f:attach() and f.writes==0) -- mathematical equality is not authority
    f=fixture('caps',nil,LIVE_ALIAS);assert(f:attach());f.denied=true
    assert(not f:edit(40000) and f.m.data[LIVE_ALIAS].Mining.Stone==35000 and f.writes==0)
end
do
    local f=fixture('caps',nil,LIVE_ALIAS);assert(f:attach())
    -- Caller mutation after attachment cannot redirect its private mapping.
    f.options.runtime_guild=H;f.options.context.guild=H
    assert(not f:edit(40000) and f.writes==1)
    assert(f.codec.decode(f.op.payload).data[LIVE_GUILD].Mining.Stone==40000)
    f:complete();assert(f.m.flush(100,true))
    assert(not f.m.apply_clear('Mining','Stone',LIVE_GUILD) and f.writes==1)
    assert(not f.m.apply_set('Mining','Stone',10,H) and f.writes==1)
end

for _,transition in ipairs({'role','load'}) do
    local f=fixture('caps',nil,LIVE_ALIAS);assert(f:attach());local before=f.m.serialize()
    f.on_admit=function()
        if transition=='role' then f.m.set_role('client') else f.m.load('legacy') end
    end
    assert(not f:edit(40000) and f.m.serialize()==before and f.notices==0)
    f:complete();assert(not f.m.poll_persistence() and f.m.serialize()==before and f.notices==0)
    assert(not f.m.data[LIVE_GUILD])
end
do
    local f=fixture('caps',nil,LIVE_ALIAS);assert(f:attach());f:edit(40000)
    f.on_notice=function() f.on_notice=nil;assert(not f:edit(45000)) end
    f:complete();assert(not f.m.flush(100,true) and f.m.state=='saving')
    assert(f.m.data[LIVE_ALIAS].Mining.Stone==45000 and not f.m.data[LIVE_GUILD])
    f:complete();assert(f.m.flush(100,true) and f.notices==2)
end
do
    local f=fixture('caps',nil,LIVE_ALIAS);local nested
    f.on_authorize=function()
        if not nested then nested={f:attach()} end
    end
    assert(f:attach() and nested[1]==false and nested[2]=='attachment_busy')
    f.on_authorize=nil
    f.on_admit=function() assert(not f:edit(45000)) end
    assert(not f:edit(40000) and f.m.state=='error')
    assert(f.m.data[LIVE_ALIAS].Mining.Stone==35000 and f.writes==1)
    f:complete();assert(not f.m.flush(100,true) and f.notices==0)
end
-- Removal of mapping on detach/load: legacy sync serialization still writes the
-- original signed key; a subsequent canonical attachment on the SAME module
-- uses only its newly supplied context, with no stale alias left behind.
do
    local f=fixture('caps',nil,LIVE_ALIAS);assert(f:attach());f.m.detach_persistence()
    assert(not f:edit(40000) and #f.fs.operations==f.io)
    assert(not f.m.poll_persistence()) -- drain closed writer before reattachment
    f.m.load('legacy');assert(f:edit(40000))
    assert(f.m.data[LIVE_ALIAS].Mining.Stone==40000 and not f.m.data[LIVE_GUILD])
    local nextf=fixture('caps',nil,LIVE_ALIAS)
    local canonical=nextf.m.serialize_snapshot(nextf.options.recovery.settings.data)
    assert(file.write('canonical',canonical,0));f.m.load('canonical')
    nextf.options.runtime_guild=nil
    assert(f.m.attach_persistence(nextf.options))
    local ok,why=f.m.apply_set('Mining','Stone',41000,LIVE_GUILD)
    assert(not ok and why=='pending' and f.m.data[LIVE_GUILD].Mining.Stone==41000 and not f.m.data[LIVE_ALIAS])
    nextf:complete();assert(f.m.flush(100,true))
end
print('persistence attachment: actual session, proven signed runtime alias, canonical-only snapshots, reentry and stale guards passed')
