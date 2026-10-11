-- Actual store/caps -> settings_writer -> settings_session -> journal queue /
-- codec / durability barrier. Only storage completion and legacy FS are fakes.
package.loaded.log={warn=function() end,error=function() end,say=function() end}
local file=require('datafile')
local Factory=dofile(TEST_ROOT..'/experiments/settings_session.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local W,G,H=string.rep('a',32),string.rep('b',32),string.rep('c',32)
local function copy(t)
    if type(t)~='table' then return t end
    local r={};for k,v in pairs(t) do r[k]=copy(v) end;return r
end
local function fixture(recovered_data)
    package.loaded.store=nil
    local m=require('store')
    local stream,guild='priorities',G
    local data={palA={[1]=1},palB={[1]=2}}
    local body=assert(m.serialize_snapshot(data,true))
    local recovered_body=assert(m.serialize_snapshot(recovered_data or {palA={[1]=4,[2]=false},palC={[3]=2}},true))
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
    f.options={enabled=true,session=s,context=c,recovery=recovery,
        owns_key=function(key,ctx)
            assert(ctx.guild==guild and ctx.epoch==7)
            if f.on_owned then f.on_owned(key,ctx) end
            return key=='palA' or key=='palB' or key=='palC'
        end}
    f.session,f.context,f.codec=s,c,codec
    f.options.authorize=function(ctx,alias)
        f.proofs=(f.proofs or 0)+1
        if f.on_proof then f.on_proof(ctx,alias) end
        return not f.caller_denied and ctx.guild==guild and alias==G
    end
    function f:activate() return m.activate_recovered(self.options) end
    function f:attach() return m.attach_persistence(self.options) end
    function f:edit(n,key) return m.apply_set(key or 'palA',1,n) end
    m.on_change=function() f.notices=f.notices+1;if f.on_notice then f.on_notice() end end
    f.io=#fs.operations
    return f
end

local Gate=require('settings_gate')
local function fresh(data) return fixture(data) end
local function unchanged(f,before)
    assert(f.m.serialize()==before and f.writes==0 and #f.fs.operations==f.io and f.notices==0)
end
-- Stale legacy replacement, recovered baseline/OFF, independent candidate,
-- asynchronous admission and deferred notification through the actual session.
do
    local f=fresh();local m=f.m;local before=m.serialize();local proofs={}
    f.on_owned=function(key,ctx) proofs[key]=(proofs[key] or 0)+1;ctx.guild='mutated' end
    assert(not f:attach());unchanged(f,before)
    assert(f:activate());assert(m.baseline and m.data.palA[1]==4 and m.data.palA[2]==false)
    assert(not m.data.palB and m.data.palC[3]==2 and m.persisted_revision==0)
    for _,key in ipairs({'palA','palB','palC'}) do assert(proofs[key]==2,key) end
    f.options.recovery.settings.data.palA[1]=5
    assert(m.data.palA[1]==4 and f.writes==0 and f.notices==0 and #f.fs.operations==f.io)
    local ok,why,receipt=f:edit(3);assert(not ok and why=='pending' and receipt.revision==1)
    assert(f.codec.decode(f.op.payload).baseline and f.codec.decode(f.op.payload).data.palA[2]==false)
    f:complete();local saved,scope=m.flush(nil,true,true)
    assert(saved and scope.key=='palA' and f.notices==0 and m.persisted_revision==1)
    assert(m.flush(nil,true) and f.notices==0 and #f.fs.operations==f.io)
end
-- Empty recovery can remove owned legacy rows; false baseline is preserved too.
for _,baseline in ipairs({true,false}) do
    local f=fresh({});f.options.recovery.settings.baseline=baseline
    assert(f:activate() and next(f.m.data)==nil and f.m.baseline==baseline)
end
-- Default-off does not fence legacy edits.
for _,enabled in ipairs({false,1,'true'}) do
    local f=fresh();f.options.enabled=enabled
    assert(not f:activate());assert(f:edit(3))
end
-- No syntactic identifier, roster subset, truthy response or lost callback
-- result substitutes for explicit proof of every key (including legacy-only B).
for _,key in ipairs({'palA','palB','palC'}) do
    for _,mode in ipairs({'false','nil','throw','truthy','last'}) do
        local f=fresh();local before=f.m.serialize();local counts={}
        f.options.owns_key=function(k)
            counts[k]=(counts[k] or 0)+1
            if k==key and (mode~='last' or counts[k]==2) then
                if mode=='throw' then error('lost proof') end
                if mode=='truthy' then return 1 end
                if mode=='nil' then return nil end
                return false
            end
            return true
        end
        assert(not f:activate(),key..mode);unchanged(f,before)
        assert(not f:edit(3) and not f.m.save() and not f.m.flush(nil,true))
        unchanged(f,before)
    end
end
-- Authority is distinct from membership, including loss inside the final
-- ownership callback. Context-only providers remain compatible with Startup.
for _,mode in ipairs({'missing','false','truthy','throw','last','ownership_loss'}) do
    local f=fresh();local before=f.m.serialize();local n=0
    f.options.authorize=function(c)
        n=n+1;assert(c.guild==G)
        if mode=='throw' then error('lost authority') end
        if mode=='truthy' then return 1 end
        if mode=='false' or mode=='last' and n>=3 then return false end
        return not f.caller_denied
    end
    if mode=='missing' then f.options.authorize=nil end
    local keys=0
    f.on_owned=function() keys=keys+1;if mode=='ownership_loss' and keys==6 then f.caller_denied=true end end
    assert(not f:activate());unchanged(f,before);assert(not f.m.save())
end
do
    local f=fresh();f.options.authorize=function(c)return c.guild==G end
    assert(f:activate())
end
-- A created writer survives failed final proof until original closure is
-- confirmed, and failure never installs the candidate or announces a save.
do
    local f=fresh();local before=f.m.serialize();local n,closes=0,0
    local close=f.session.close
    f.session.close=function(self,c) closes=closes+1;if closes==1 then return false end;return close(self,c) end
    f.options.authorize=function() n=n+1;return n<3 end
    assert(not f:activate() and closes==1);unchanged(f,before)
    assert(not f:activate() and closes==1)
    assert(f.m.finish_retirement(f.context) and closes==2)
    unchanged(f,before);assert(not f.m.save())
end
-- Typed envelope validation before callbacks; canonical rows are not coerced.
local bad={
    function(s) s.count=s.count+1 end,
    function(s) s.baseline=nil end,
    function(s) s.baseline='true' end,
    function(s) s.transient=1 end,
    function(s) s.data.palA[1]='4' end,
    function(s) s.data.palA[1]=4.0 end,
    function(s) s.data.palA[65]=1 end,
    function(s) s.data.slot1={[1]=1} end,
    function(s) s.data.empty={} end,
    function(s) setmetatable(s.data.palA,{}) end,
    function(s) setmetatable(s,{}) end,
    function(s) s.extra=true end,
}
for _,mutate in ipairs(bad) do
    local f=fresh();local before=f.m.serialize();mutate(f.options.recovery.settings)
    f.on_owned=function() error('must validate before proof') end
    assert(not f:activate());unchanged(f,before);assert(not f.m.save())
end
for _,mode in ipairs({'missing','client','undecided','dirty','authority','revision','proof'}) do
    local f=fresh()
    if mode=='missing' then f.fs.files.legacy=nil;f.m.load('legacy')
    elseif mode=='client' then f.m.set_role('client')
    elseif mode=='undecided' then f.m.set_role(nil)
    elseif mode=='dirty' then assert(f.m.apply_set('palA',1,3))
    elseif mode=='authority' then f.denied=true
    elseif mode=='revision' then f.options.recovery.revision=999
    else f.options.owns_key=nil end
    local before,state,revision=f.m.serialize(),f.m.state,f.m.persisted_revision
    f.io=#f.fs.operations
    assert(not f:activate());unchanged(f,before)
    assert(f.m.state==state and f.m.persisted_revision==revision and not f.m.save())
end
-- Reentrant public mutation/activation/retirement poisons the outer attempt.
local nested={
    function(f) return f:activate() end,
    function(f) return f:attach() end,
    function(f) return f:edit(2) end,
    function(f) return f.m.clear('palA',1) end,
    function(f) return f.m.apply_clear('palA',1) end,
    function(f) return f.m.capture_baseline('new',{[1]=true},{}) end,
    function(f) return f.m.save() end,
    function(f) return f.m.flush(nil,true) end,
    function(f) return f.m.poll_persistence() end,
    function(f) return f.m.load('other') end,
    function(f) return f.m.set_role('client') end,
    function(f) return f.m.detach_persistence() end,
    function(f) return f.m.retire_persistence(f.context) end,
    function(f) return f.m.finish_retirement(f.context) end,
}
for _,call in ipairs(nested) do
    for _,phase in ipairs({'first','session','last'}) do
        local f=fresh();local before=f.m.serialize();local n=0;local ran=false
        local function reenter() if not ran then ran=true;local result=call(f);assert(result==false or result==0) end end
        f.on_owned=function() n=n+1;if phase=='first' and n==1 or phase=='last' and n==4 then reenter() end end
        if phase=='session' then f.on_authorize=reenter end
        assert(not f:activate() and ran);unchanged(f,before);assert(not f.m.save())
    end
end
-- Caller tables and per-proof contexts are snapshots, never live identities.
for _,phase in ipairs({'first','session','last'}) do
    local f=fresh();local n=0;local mutated=false
    local function mutate()
        if mutated then return end;mutated=true
        f.options.context.guild=H;f.options.context.epoch=99
        f.options.recovery.revision=999;f.options.recovery.settings.data.palA[1]=5
        f.options.recovery.settings.baseline=false;f.options.owns_key=function()return false end
    end
    f.on_owned=function(_,ctx)
        n=n+1;assert(ctx.guild==G and ctx.epoch==7)
        if phase=='first' and n==1 or phase=='last' and n==4 then mutate() end
        ctx.guild=H
    end
    if phase=='session' then f.on_authorize=mutate end
    assert(f:activate() and mutated and f.m.data.palA[1]==4 and f.m.baseline and f.m.persisted_revision==0)
end
-- Recovery can run inside the shared coordinator fence; normal Store and Caps
-- calls remain fenced. The Store never acquires/releases somebody else's gate.
do
    local f=fresh();local token=assert(Gate.acquire());local before=f.m.serialize()
    assert(not f.m.save() and not f:edit(2));assert(f.m.load('other')==0)
    assert(not require('caps').save());unchanged(f,before)
    assert(f:activate() and Gate.held(token))
    assert(not f:edit(2) and not f.m.poll_persistence())
    assert(Gate.release(token));local ok,why=f:edit(2);assert(not ok and why=='pending')
end
-- Same-role refresh retains writer; session/role changes fence it.
do
    local f=fresh();assert(f:activate());f.m.set_role('authority')
    local ok,why=f:edit(2);assert(not ok and why=='pending')
    f.m.set_role('authority','next');assert(not f:edit(3) and not f.m.save())
end
-- Exact-owner retirement is a fence, not a drain. The journal fixture closes
-- after polling completion; native draining owners require a coordinator drain.
-- Only unchanged accepted bytes clear pending state, without notification.
do
    local f=fresh();local m=f.m;assert(f:activate());local _,why=f:edit(3);assert(why=='pending')
    local wrong=copy(f.context);wrong.epoch=8
    assert(not m.retire_persistence(wrong) and not m.finish_retirement(wrong))
    assert(m.retire_persistence(f.context) and not m.finish_retirement(f.context))
    assert(not m.save() and not f:edit(2) and m.state=='saving')
    f:complete();assert(m.finish_retirement(f.context))
    assert(m.state=='saved' and m.persisted_revision==1 and f.notices==0 and #f.fs.operations==f.io)
    assert(m.finish_retirement(f.context) and not m.save())
end
-- Changed bytes/role, an extra detach, or uncertain acceptance must not become
-- saved merely because closure was observed. Retirement emits no old ACK.
for _,mode in ipairs({'bytes','baseline','role','detach','uncertain'}) do
    local f=fresh();local m=f.m
    if mode=='uncertain' then
        local submit=f.session.submit
        f.session.submit=function(...) submit(...);error('lost receipt') end
    end
    assert(f:activate())
    f:edit(3);assert(m.state~='saved')
    assert(m.retire_persistence(f.context))
    if mode=='bytes' then m.data.palA[1]=2
    elseif mode=='baseline' then m.baseline=false
    elseif mode=='role' then m.set_role('client')
    elseif mode=='detach' then m.detach_persistence() end
    f:complete()
    m.finish_retirement(f.context)
    assert(m.state~='saved' and f.notices==0 and not m.save(),mode..':'..tostring(m.state)..':'..tostring(m.error))
end
print('store recovered: typed cutover, union ownership proofs, rollback, baseline, gate, reentry, async edits and retirement passed')
