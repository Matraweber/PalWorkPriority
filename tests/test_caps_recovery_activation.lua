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
local function fixture(name,new_pal,runtime,recovered_data)
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
    local recovered_body=assert(m.serialize_snapshot(recovered_data or {[guild]={Mining={Stone=42000},Deforest={Wood=false}}}))
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
    f.options.authorize=function(ctx,alias)
        f.proofs=(f.proofs or 0)+1
        if f.on_proof then f.on_proof(ctx,alias) end
        return not f.caller_denied and ctx.guild==guild and alias==runtime_key
    end
    function f:activate() return m.activate_recovered(self.options) end
    function f:attach() return m.attach_persistence(self.options) end
    function f:edit(n,key)
        if name=='store' then return m.apply_set(key or 'palA',1,n) end
        return m.apply_set('Mining','Stone',n,runtime_key)
    end
    m.on_change=function() f.notices=f.notices+1;if f.on_notice then f.on_notice() end end
    f.io=#fs.operations
    return f
end


local function fresh() return fixture('caps',nil,LIVE_ALIAS) end
local function unchanged(f,before)
    assert(f.m.serialize()==before and f.writes==0 and #f.fs.operations==f.io and f.notices==0)
end
-- Stale legacy must not prevent explicit recovered activation; attachment still
-- requires equality. Activation itself does not submit or announce a new save.
do
    local f=fresh();local m=f.m;local before=m.serialize()
    assert(not f:attach());unchanged(f,before)
    assert(f:activate() and f.proofs==2)
    assert(m.data[LIVE_ALIAS].Mining.Stone==42000 and m.data[LIVE_ALIAS].Deforest.Wood==false)
    assert(not m.data[LIVE_GUILD] and m.state=='saved' and m.persisted_revision==0)
    assert(f.writes==0 and #f.fs.operations==f.io and f.notices==0)
    f.options.recovery.settings.data[LIVE_GUILD].Mining.Stone=1
    assert(m.data[LIVE_ALIAS].Mining.Stone==42000)
    local ok,why=f:edit(45000);assert(not ok and why=='pending')
    assert(f.codec.decode(f.op.payload).data[LIVE_GUILD].Mining.Stone==45000)
    f:complete();assert(m.flush(100,true) and f.notices==1 and #f.fs.operations==f.io)
    m.detach_persistence();assert(not m.save() and not f:edit(46000))
end
-- An empty typed journal is authoritative too: stale legacy rows disappear.
do
    local f=fixture('caps',nil,LIVE_ALIAS,{})
    assert(f:activate() and next(f.m.data)==nil and f.writes==0 and #f.fs.operations==f.io)
end
-- Default OFF does not disrupt legacy behavior.
for _,enabled in ipairs({false,'true',1}) do
    local f=fresh();f.options.enabled=enabled;local before=f.m.serialize()
    assert(not f:activate());unchanged(f,before);assert(f:edit(32000))
end
do
    local f=fresh();f.options.enabled=nil;assert(not f:activate());assert(f:edit(32000))
end
local cases={
    function(f) f.options.runtime_guild=nil end,
    function(f) f.options.runtime_guild='*' end,
    function(f) f.options.runtime_guild=H end,
    function(f) f.options.runtime_guild=LIVE_GUILD end,
    function(f) f.options.runtime_guild='-0758686034-1314655308-1294252187-537966059' end,
    function(f) f.options.authorize=nil end,
    function(f) f.caller_denied=true end,
    function(f) f.denied=true end,
    function(f) f.options.context.epoch=8 end,
    function(f) f.options.context.incarnation='old' end,
    function(f) f.options.context.stream='priorities' end,
    function(f) f.options.recovery.session='old' end,
    function(f) f.options.recovery.revision=1 end,
    function(f) f.options.recovery.settings.baseline=true end,
    function(f) f.options.recovery.settings.count=99 end,
    function(f) f.options.recovery.settings.data[LIVE_GUILD].Mining={} end,
    function(f) f.options.recovery.settings.data[LIVE_GUILD]={};f.options.recovery.settings.count=0 end,
    function(f) setmetatable(f.options.recovery.settings.data,{}) end,
    function(f) f.options.recovery.settings.data[LIVE_GUILD].Mining.Stone='42000' end,
    function(f) f.options.recovery.settings.data[H]={} end,
    function(f) f.options.recovery.settings.data['*']={} end,
    function(f) f.options.recovery.settings.data[LIVE_ALIAS]={} end,
    function(f) f.session.ready=function() return false end end,
    function(f) f.session.ready=function() error('lost') end end,
    function(f) f.m.data['*']={} end,
    function(f) f.m.data[H]={} end,
    function(f) f.m.data[LIVE_GUILD]={} end,
}
for i,change in ipairs(cases) do
    local f=fresh();change(f);local before=f.m.serialize()
    assert(not f:activate(),i);unchanged(f,before)
    assert(not f.m.save() and not f:edit(32000) and not f.m.flush(100,true),i)
    unchanged(f,before)
end
-- Both caller proof crossings are required, and exceptions fail closed.
for _,phase in ipairs({1,2}) do
    for _,throws in ipairs({false,true}) do
        local f=fresh();local before=f.m.serialize()
        f.on_proof=function()
            if f.proofs==phase then
                if throws then error('proof lost') end
                f.caller_denied=true
            end
        end
        assert(not f:activate());unchanged(f,before)
        assert(not f.m.save());unchanged(f,before)
    end
end
-- Callback authority loss after session validation must be noticed by the
-- second caller proof, even if a callback returned an earlier ready result.
do
    local f=fresh();local before=f.m.serialize();local ready=f.session.ready
    f.session.ready=function(self,c)
        local yes=ready(self,c);f.caller_denied=true;return yes
    end
    assert(not f:activate());unchanged(f,before)
end
for _,action in ipairs({'activate','attach','save','set','clear','apply','flush','load','detach','role'}) do
    for _,phase in ipairs({'proof','session','final'}) do
        local f=fresh();local before=f.m.serialize();local ran=false
        local function crossing()
            if ran then return end;ran=true
            if action=='activate' then assert(not f:activate())
            elseif action=='attach' then assert(not f:attach())
            elseif action=='save' then assert(not f.m.save())
            elseif action=='set' then assert(not f.m.set('Mining','Stone',50000,LIVE_ALIAS))
            elseif action=='clear' then assert(not f.m.clear('Mining','Stone',LIVE_ALIAS))
            elseif action=='apply' then assert(not f:edit(50000))
            elseif action=='flush' then assert(not f.m.flush(100,true))
            elseif action=='load' then f.m.load('legacy')
            elseif action=='detach' then f.m.detach_persistence()
            else f.m.set_role('client') end
        end
        if phase=='session' then f.on_authorize=crossing
        else f.on_proof=function() if f.proofs==(phase=='proof' and 1 or 2) then crossing() end end end
        assert(not f:activate(),action..phase);assert(ran);unchanged(f,before)
        assert(not f.m.save());unchanged(f,before)
    end
end
-- Refusal must retain an already accepted writer, including in-flight work.
do
    local f=fresh();assert(f:activate());assert(not f:edit(44000));local writes=f.writes
    assert(not f:activate());assert(f.writes==writes and f.m.data[LIVE_ALIAS].Mining.Stone==44000)
    f:complete();assert(f.m.flush(100,true) and f.notices==1)
end
-- Final-proof failure retains the closed writer until the original owner drains.
do
    local f=fresh();local before=f.m.serialize();local close=f.session.close;local closes=0
    f.session.close=function(self,c) closes=closes+1;if closes==1 then return false end;return close(self,c) end
    f.on_proof=function() if f.proofs==2 then f.caller_denied=true end end
    assert(not f:activate() and closes==1);unchanged(f,before)
    assert(not f:activate() and closes==1)
    f.m.poll_persistence();assert(closes>=2);assert(not f.m.save());unchanged(f,before)
end
-- A ready journal does not prove the provenance of missing/corrupt legacy
-- input. Keep the startup gate explicit: no activation, mutation or fallback.
for _,legacy in ipairs({'missing','corrupt','backup'}) do
    local f=fresh()
    if legacy=='missing' then f.fs.files.legacy=nil
    elseif legacy=='corrupt' then f.fs.files.legacy='not a valid limits row\n'
    else f.fs.files['legacy.bak']=f.fs.files.legacy;f.fs.files.legacy=nil end
    f.m.load('legacy')
    local expected=legacy=='missing' and 'missing' or legacy=='corrupt' and 'error' or 'saving'
    assert(f.m.state==expected)
    assert(f.session:ready(f.context)) -- valid journal alone is insufficient
    f.io=#f.fs.operations
    local before,state,err,generation=f.m.serialize(),f.m.state,f.m.error,f.m.generation
    local ok,why=f:activate();assert(not ok and why=='unavailable' and not f.proofs)
    unchanged(f,before)
    assert(not f.m.save() and not f.m.flush(100,true))
    unchanged(f,before)
    assert(f.m.state==state and f.m.error==err and f.m.generation==generation)
end
-- Caller-owned containers are not reread after a crossing. In particular the
-- shallow recovery-envelope copy protects revision, while the deep candidate
-- and immutable body protect nested settings. Each proof gets a fresh context.
for _,phase in ipairs({'first','session','last'}) do
    local f=fresh();local calls,mutated=0,false
    local original_context=copy(f.context)
    local function mutate()
        if mutated then return end;mutated=true
        f.options.context.guild=H;f.options.context.epoch=99
        f.options.context.scope='wrong';f.options.context.session='wrong'
        f.options.recovery.scope='wrong';f.options.recovery.session='wrong'
        f.options.recovery.revision=123
        f.options.recovery.settings.data[LIVE_GUILD].Mining.Stone=1
        f.options.recovery.settings.data[H]={Mining={Stone=2}}
        f.options.recovery.settings.count=999
        f.options.context={};f.options.recovery={}
        f.options.runtime_guild=H;f.options.session={}
        f.options.authorize=function() error('replacement must not be called') end
    end
    f.options.authorize=function(c,alias)
        calls=calls+1
        for k,v in pairs(original_context) do assert(c[k]==v,k) end
        assert(alias==LIVE_ALIAS)
        if phase=='first' and calls==1 or phase=='last' and calls==2 then mutate() end
        c.guild=H;c.epoch=99;c.scope='wrong';c.session='wrong'
        return true
    end
    if phase=='session' then f.on_authorize=mutate end
    assert(f:activate() and mutated and calls==2)
    assert(f.m.persisted_revision==0 and f.m.data[LIVE_ALIAS].Mining.Stone==42000)
    assert(f.m.data[LIVE_ALIAS].Deforest.Wood==false and not f.m.data[H])
    assert(f.writes==0 and #f.fs.operations==f.io)
    local ok,why,receipt=f:edit(47000)
    assert(not ok and why=='pending' and receipt.revision==1)
    assert(receipt.scope==original_context.scope and receipt.session==original_context.session)
    assert(receipt.epoch==original_context.epoch and receipt.incarnation==original_context.incarnation)
    local decoded=assert(f.codec.decode(f.op.payload))
    assert(decoded.data[LIVE_GUILD].Mining.Stone==47000 and not decoded.data[H])
    f:complete();assert(f.m.flush(100,true) and f.m.persisted_revision==1)
    assert(#f.fs.operations==f.io)
end
print('caps recovery activation: guarded cutover, typed alias mapping, authority, reentry, owner retention and async edits passed')
