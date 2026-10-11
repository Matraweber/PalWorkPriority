-- Actual wire/typed codec; modeled frozen native protocol. No DLL/IO/activation.
package.loaded.log={warn=function() end,error=function() end}
package.loaded.datafile={read=function() error('unexpected IO') end,write=function() error('unexpected IO') end}
local Adapter=dofile(TEST_ROOT..'/experiments/save_draining_backend.lua')
local Wire=dofile(TEST_ROOT..'/experiments/save_native_backend.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local W,G=string.rep('1',32),string.rep('2',32)
local function copy(t)
    if type(t)~='table' then return t end
    local r={};for k,v in pairs(t) do r[k]=copy(v) end;return r
end
local function fixture(stream,missing)
    stream=stream or 'priorities'
    local codec=Codec.new{storage=W,guild=G,stream=stream}
    local function body(n)
        if stream=='limits' then return require('caps').serialize_snapshot({[G]={Mining={Stone=n}}}) end
        return require('store').serialize_snapshot({pal={[1]=n}},true)
    end
    local c={scope='PWP-SCOPE-1:'..W..':'..G..':'..stream,guild=G,stream=stream,session='session',
        incarnation='boot',epoch=7,authority=true,camp='campA'}
    local f={calls={},phase='dormant',accepted=0,committed=0,generation=0,error='none',cleanup=0,
        lt=0,lc=0,lr=0,outcome='none',terminal='',certain='',terr='',thread=10,body=body,codec=codec,
        slots=missing and {{'missing','0',''},{'missing','0',''}} or
            {{'valid','6',assert(codec.encode(body(1)))},{'valid','7',assert(codec.encode(body(2)))}}}
    function f:fields()
        local r={c.scope,c.incarnation,tostring(c.epoch),tostring(self.accepted),tostring(self.committed),self.phase,
            self.error,tostring(self.generation),tostring(self.cleanup),self.terminal,self.certain,self.terr,
            tostring(self.lt),tostring(self.lc),tostring(self.lr),self.outcome}
        if self.status_fields then self.status_fields(r) end
        return r
    end
    function f:recovery_fields()
        local a,b=self.slots[1],self.slots[2]
        local r={c.scope,c.incarnation,'7','recovered','1',tostring(self.generation),'0','pair-1','0','0',
            a[1],a[2],a[3],b[1],b[2],b[3]}
        if self.recovery_fields_hook then self.recovery_fields_hook(r) end
        return r
    end
    function f:finish_recovery()
        self.phase='awaiting_validation';self.terminal='recovered';self.certain='1';self.terr='0'
        self.generation=math.max(tonumber(self.slots[1][2]),tonumber(self.slots[2][2]))
    end
    function f:commit(revision)
        local target=revision or self.accepted
        -- Real native initialization cannot coalesce away revision1.
        if self.initial and target>1 then self:commit(1) end
        self.committed=target;self.generation=self.generation+1
        self.terminal=self.initial and 'initialized' or 'updated';self.initial=false;self.certain='1';self.terr='0'
    end
    function f.native(cmd,handle,ticket,hex,length)
        assert(handle==4 and #hex==length and not hex:find('[^0-9a-f]'))
        local raw=hex:gsub('..',function(s) return string.char(tonumber(s,16)) end)
        local fields=Wire.unpack(raw,(cmd==4 or cmd==5) and 1 or 0)
        f.calls[#f.calls+1]={command=cmd,ticket=ticket,fields=copy(fields)}
        if f.before then f.before(cmd) end
        if f.throw_before==cmd then error('before call') end
        local status,data=1,''
        if cmd==6 then data=Wire.pack(f:fields())
        elseif cmd==3 then
            if f.phase=='recovering' then status=2 else data=Wire.pack(f:recovery_fields()) end
        elseif cmd==9 then assert(f.phase=='closed');f.cleaned=true
        else
            assert(ticket>f.lt and ticket<2147483647,'ticket replay')
            f.lt,f.lc,f.lr,f.outcome=ticket,cmd,0,'accepted'
            if f.refuse==cmd then status=0;f.outcome='refused'
            elseif cmd==2 then assert(f.phase=='dormant');f.phase='recovering'
            elseif cmd==4 then assert(f.phase=='awaiting_validation');f.phase='ready';f.initial=fields[1]=='initialize_missing'
            elseif cmd==5 then
                assert(f.phase=='ready' and codec.decode(fields[1]),'only valid copied typed payloads')
                f.accepted=f.accepted+1;f.lr=f.accepted;f.latest=fields[1]
                data=Wire.pack({tostring(f.accepted)})
            elseif cmd==7 then f.closed_admission=true;if f.phase~='blocked' then f.phase='closing' end
            elseif cmd==8 then
                if f.phase~='blocked' then
                    if f.accepted>f.committed then f:commit() end;f.phase='closed'
                end
                data=Wire.pack(f:fields());f.drains=(f.drains or 0)+1
            else error('unexpected configure/bind/worker call') end
        end
        if f.after then f.after(cmd) end
        if f.throw_after==cmd then error('lost native return') end
        if f.no_results==cmd then return end
        if f.malformed==cmd then data=Wire.pack({'bad'}) end
        if f.trailing==cmd then data=data..Wire.pack({'extra'}) end
        return status,data,f.thread,20,21,1000
    end
    f.options={enabled=true,native=f.native,binding=4,game_thread=10,storage=W,guild=G,stream=stream,
        session='session',incarnation='boot',epoch=7,authorize=function(proof)
            assert(proof.scope==c.scope and proof.guild==G and proof.epoch==7 and proof.camp==c.camp)
            if f.on_authorize then f.on_authorize(proof) end
            proof.guild='mutated copy'
            return not f.denied
        end}
    f.api=Adapter.new(f.options);f.context=copy(c)
    function f:open()
        assert(self.api:start(self.context));assert(self.api:poll(self.context).state=='recovering')
        self:finish_recovery();assert(self.api:poll(self.context).state=='awaiting_validation')
    end
    function f:ready()
        self:open();assert(self.api:approve(self.context,missing and 'initialize_missing' or 'existing'))
        return self.api:poll(self.context)
    end
    return f
end

-- Inert construction/default off, immutable options, all original-context fences.
do
    local f=fixture();assert(#f.calls==0)
    f.options.enabled=false;assert(not pcall(Adapter.new,f.options))
    f.options.enabled=true;f.options.authorize=nil;assert(not pcall(Adapter.new,f.options))
    f.options.native=function() error('mutable options used') end
    f.options.guild='bad';f.options.epoch=9
    assert(f:ready().state=='saved')
    for _,k in ipairs({'scope','guild','stream','session','incarnation','epoch','authority'}) do
        local c=copy(f.context);c[k]=false;local n=#f.calls
        assert(f.api:submit(c,f.body(3))==false and #f.calls==n,k)
    end
end
for _,stream in ipairs({'priorities','limits'}) do
    local f=fixture(stream);f:open()
    local r=f.api:recovery(f.context);assert(r.kind=='existing' and r.revision==0 and r.generation==7)
    r.slots[2].payload='changed';r.settings.data={};assert(f.api:recovery(f.context).slots[2].payload~='changed')
    assert(not f.api:approve(f.context,'initialize_missing'))
    assert(f.api:approve(f.context,'existing'));assert(not f.api:approve(f.context,'existing'))
    local receipt,why=f.api:submit(f.context,f.body(3));assert(receipt.revision==1 and why=='pending')
    assert(receipt.scope==f.context.scope and receipt.session=='session' and receipt.epoch==7)
    assert(f.api:submit(f.context,f.body(4)).revision==2)
    assert(f.api:submit(f.context,f.body(5)).revision==3)
    assert(f.accepted==3 and f.api:poll(f.context).state=='saving' and not f.api:take_committed(f.context))
    f:commit(1);assert(f.api:poll(f.context).state=='saving')
    assert(f.api:take_committed(f.context).revision==1 and not f.api:take_committed(f.context))
    f:commit(3);assert(f.api:poll(f.context).state=='saved')
    assert(f.api:take_committed(f.context).revision==3)
    assert(not f.api:cleanup(f.context))
    assert(f.api:close(f.context) and not f.api:submit(f.context,f.body(1)))
    assert(f.api:drain(f.context).state=='closed' and f.api:cleanup(f.context))
    local n=#f.calls;assert(f.api:cleanup(f.context) and #f.calls==n)
    assert(f.drains==1 and f.cleaned)
end
do
    local f=fixture(nil,true);f:open();assert(f.api:recovery(f.context).kind=='missing')
    local n=#f.calls;assert(not f.api:submit(f.context,f.body(1)) and #f.calls==n)
    assert(not f.api:approve(f.context,'existing'))
    assert(f.api:approve(f.context,'initialize_missing'))
    assert(f.api:poll(f.context).state=='initialization_required')
    assert(f.api:submit(f.context,f.body(1)).revision==1)
    assert(f.api:submit(f.context,f.body(2)).revision==2)
    assert(f.api:poll(f.context).state=='saving')
    local r=f.api:drain(f.context);assert(r.committed==2 and r.generation==2 and r.state=='closed')
    assert(not f.api:take_committed(f.context) and f.api:cleanup(f.context))
end
-- Both typed slots, exact packets and candidate selection fail closed.
for _,mode in ipairs({'old_schema','new_schema','equal_conflict','foreign','corrupt_pair','missing_bytes','generation','extra'}) do
    local f=fixture()
    if mode=='old_schema' then f.slots[1][3]='unsupported'
    elseif mode=='new_schema' then f.slots[2][3]='unsupported'
    elseif mode=='equal_conflict' then f.slots[1][2]='7'
    elseif mode=='foreign' then f.slots[1]={'foreign','0',''}
    elseif mode=='corrupt_pair' then f.slots={{'corrupt','0',''},{'corrupt','0',''}}
    elseif mode=='missing_bytes' then f.slots[1]={'missing','0','unexpected'}
    elseif mode=='generation' then f.recovery_fields_hook=function(r) r[6]='8' end
    elseif mode=='extra' then f.trailing=3 end
    assert(f.api:start(f.context));f:finish_recovery()
    assert(f.api:poll(f.context)==nil and f.api:inspect().state=='uncertain',mode)
    local n=#f.calls;assert(not f.api:approve(f.context,'existing') and #f.calls==n)
    assert(not f.api:recovery(f.context))
end
do
    local f=fixture();f.slots[1]={'corrupt','0',''};assert(f:ready().state=='saved')
end
-- Lost mutation result is sticky, tickets never replay, native can still drain.
for _,command in ipairs({2,4,5,7,8}) do
    for _,loss in ipairs({'throw_after','no_results','malformed'}) do
        local f=fixture()
        if command~=2 then f:open() end
        if command>=5 then assert(f.api:approve(f.context,'existing')) end
        f[loss]=command
        local r
        if command==2 then r=f.api:start(f.context)
        elseif command==4 then r=f.api:approve(f.context,'existing')
        elseif command==5 then r=f.api:submit(f.context,f.body(3))
        elseif command==7 then r=f.api:close(f.context)
        else r=f.api:drain(f.context) end
        assert(r==nil and f.api:inspect().state=='uncertain',command..loss)
        if command==5 then assert(f.api:inspect().candidate_retained and f.accepted==1) end
        local lost_ticket=f.api:inspect().ticket;f[loss]=nil
        assert(f.api:poll(f.context).state=='uncertain')
        assert(not f.api:submit(f.context,f.body(4)) and not f.api:take_committed(f.context))
        local drained=f.api:drain(f.context)
        assert(drained.state=='uncertain' and drained.phase=='closed' and drained.ticket>lost_ticket)
        assert(not f.api:cleanup(f.context),'unknown remains retained')
    end
end
do
    local f=fixture();f:ready();f.refuse=5
    assert(f.api:submit(f.context,f.body(3))==false and f.accepted==0)
    assert(f.api:inspect().state=='error' and not f.api:inspect().candidate_retained)
    assert(not f.api:take_committed(f.context))
end
-- Fresh authority failure suppresses activation/ACK even after actual acceptance.
do
    local f=fixture();f.denied=true;assert(not f.api:start(f.context) and #f.calls==0)
    f=fixture();f:ready();f.after=function(cmd) if cmd==5 then f.denied=true end end
    assert(f.api:submit(f.context,f.body(3))==nil and f.accepted==1)
    f:commit();assert(f.api:poll(f.context).state=='revoked' and not f.api:take_committed(f.context))
    assert(f.api:drain(f.context).state=='revoked') -- drains original owner, no activation
end
-- Reentry cannot admit another snapshot or leak a successful outer receipt.
for _,where in ipairs({'authorize','native'}) do
    local f=fixture();f:ready()
    local nested=function() assert(f.api:submit(f.context,f.body(4))==nil) end
    if where=='authorize' then f.on_authorize=nested else f.after=function(cmd) if cmd==5 then nested() end end end
    assert(f.api:submit(f.context,f.body(3))==nil)
    assert(f.api:inspect().state=='uncertain' and f.accepted==(where=='native' and 1 or 0))
end
do
    local f=fixture();f:ready();f.after=function(cmd) if cmd==5 then assert(f.api:close(f.context)==nil) end end
    assert(f.api:submit(f.context,f.body(3))==nil and f.api:inspect().candidate_retained)
end
do
    local f=fixture();f:ready();f.throw_before=5
    assert(f.api:submit(f.context,f.body(3))==nil and f.accepted==0 and f.api:inspect().candidate_retained)
    local count=#f.calls;assert(not f.api:submit(f.context,f.body(4)) and #f.calls==count)
    -- An exception cannot tell us whether native consumed the ticket. Never
    -- interpret the older last-ticket status as permission to repeat it.
    f.throw_before=nil;assert(f.api:poll(f.context)==nil)
    assert(f.api:drain(f.context).state=='uncertain' and not f.api:cleanup(f.context))
    f=fixture();f.api:drain(f.context);f.throw_after=9
    assert(f.api:cleanup(f.context)==nil and f.cleaned)
    f.throw_after=nil;count=#f.calls
    assert(not f.api:cleanup(f.context) and #f.calls==count,'lost cleanup is not auto retried')
end
for _,change in ipairs({{binding=0},{binding=129},{epoch=0},{epoch=2147483647},
    {game_thread=0},{max_payload_bytes=65535},{max_payload_bytes=262145},{incarnation='bad space'}}) do
    local f=fixture();for k,v in pairs(change) do f.options[k]=v end
    assert(not pcall(Adapter.new,f.options) and #f.calls==0,'bounded inert construction')
end
-- Runtime status errors must never become false saved/committed notifications.
for _,mode in ipairs({'wrong_owner','wrong_epoch','counter_regression','excess_accept','bad_ticket','bad_enum','extra','wrong_thread','uncertain','error'}) do
    local f=fixture();f:ready();f.api:submit(f.context,f.body(3));f:commit();assert(f.api:poll(f.context).state=='saved')
    if mode=='wrong_owner' then f.status_fields=function(r) r[1]='foreign' end
    elseif mode=='wrong_epoch' then f.status_fields=function(r) r[3]='8' end
    elseif mode=='counter_regression' then f.status_fields=function(r) r[5]='0' end
    elseif mode=='excess_accept' then f.status_fields=function(r) r[4]='2' end
    elseif mode=='bad_ticket' then f.status_fields=function(r) r[13]='99' end
    elseif mode=='bad_enum' then f.status_fields=function(r) r[6]='almost_saved' end
    elseif mode=='extra' then f.trailing=6
    elseif mode=='wrong_thread' then f.thread=11
    elseif mode=='uncertain' then f.phase='blocked';f.error='uncertain';f.terminal='uncertain';f.certain='0'
    else f.phase='blocked';f.error='publication';f.terminal='io_error';f.terr='29' end
    local r=f.api:poll(f.context);assert(not r or r.state~='saved',mode)
    assert(not f.api:take_committed(f.context),mode)
    if mode=='wrong_owner' or mode=='wrong_epoch' or mode=='wrong_thread' then
        local n=#f.calls;assert(not f.api:drain(f.context) and #f.calls==n,'no control after identity/route mismatch')
    end
end
do
    local f=fixture();f:ready();local n=#f.calls
    assert(f.api:submit(f.context,'bad\0body')==false)
    assert(f.api:submit(f.context,string.rep('x',262145))==false and #f.calls==n)
    f=fixture();assert(f.api:drain(f.context).phase=='closed' and f.api:cleanup(f.context))
    assert(f.calls[1].command==6 and f.calls[2].command==8,'dormant owner close without recovery')
end
-- Plausible owner/counters alone are not proof of publication. Keep the legal
-- terminal-before-counter window (worker hasn't consumed/committed yet).
for _,bad in ipairs({'recovered','empty','zero_generation','same_generation','error_in_ready'}) do
    local f=fixture();f:ready();f.api:submit(f.context,f.body(3));f:commit()
    if bad=='recovered' then f.terminal='recovered'
    elseif bad=='empty' then f.terminal,f.certain,f.terr='','',''
    elseif bad=='zero_generation' then f.generation=0
    elseif bad=='same_generation' then f.generation=7
    else f.error='publication' end
    local r=f.api:poll(f.context);assert(not r or r.state~='saved',bad)
    assert(not f.api:take_committed(f.context),bad)
end
do
    local f=fixture();f:ready();f.api:submit(f.context,f.body(3))
    f.terminal='updated' -- real worker has a terminal but has not consumed yet
    assert(f.api:poll(f.context).state=='saving' and not f.api:take_committed(f.context))
    f:commit();assert(f.api:poll(f.context).state=='saved' and f.api:take_committed(f.context).revision==1)
end

-- FULL composition: settings_writer -> actual settings_session / save_session /
-- draining_queue / this adapter / protected wire. Only native completion is
-- modeled. Neither these modules nor the test activate production settings.
local Settings=dofile(TEST_ROOT..'/experiments/settings_session.lua')
local Writer=require('settings_writer')
local function composed(stream,missing)
    local f=fixture(stream,missing);local c=f.context
    f.lease={}
    f.settings=Settings.new{enabled=true,storage=W,guild=G,stream=c.stream,session=c.session,
        incarnation=c.incarnation,epoch=c.epoch,backend_kind='PWP-DRAINING-DEV-1',backend=f.api,
        max_payload_bytes=65536,lease=f.lease,clock=function()return 0 end,
        authorize=function(proof)return not f.denied and proof.scope==c.scope and proof.epoch==7 end}
    assert(f.settings:open(c));f:finish_recovery()
    local event=f.settings:poll(c)
    if not missing then assert(event=='recovered') end
    function f:attach_writer(expected)
        local restored=assert(self.settings:take_recovered(c))
        assert(self.settings:register_camp(c,true) and self.settings:ready(c))
        local actual=c.stream=='limits' and require('caps').serialize_snapshot(restored.settings.data)
            or require('store').serialize_snapshot(restored.settings.data,restored.settings.baseline)
        assert(actual==expected,'exact original recovery body')
        self.writer=assert(Writer.new{enabled=true,session=self.settings,context=c,recovery=restored,
            body=actual,recovery_body=actual})
        return restored
    end
    return f
end
for _,stream in ipairs({'priorities','limits'}) do
    local f=composed(stream);local c=f.context;local restored=f:attach_writer(f.body(2))
    assert(restored.revision==0 and f.generation==7)
    assert(f.writer:submit(f.body(3)).state=='pending')
    assert(f.writer:submit(f.body(4)).state=='pending' and f.accepted==2)
    local n=#f.calls;f:commit(1)
    assert(#f.calls==n,'native completes without ANY Lua callback or poll')
    assert(f.writer:poll().state=='saving' and not f.settings:ready(c))
    f:commit(2);local saved=f.writer:poll()
    assert(saved.state=='saved' and saved.body==f.body(4) and saved.revision==2)
    assert(f.settings:ready(c) and f.settings:status(c).barrier.durable==2)
    assert(f.writer:submit(f.body(5)).state=='pending' and f.accepted==3)
    assert(f.latest==f.codec.encode(f.body(5)),'tail already copied into native ownership')
    assert(f.writer:close()==false and f.closed_admission and not f.drains)
    assert(f.lease.holder and not f.cleaned and not f.writer:drain(),
        'ordinary writer drain/poll cannot join or release native owner')
    assert(f.settings:drain(c) and f.drains==1 and f.cleaned and f.lease.holder==nil)
    assert(f.committed==3 and f.writer:drain() and f.writer:poll().state=='stale')
    assert(not f.settings:ready(c) and not f.settings:take_recovered(c))
end
for _,stream in ipairs({'priorities','limits'}) do
    local f=composed(stream,true);local c=f.context
    assert(not f.settings:take_recovered(c) and not f.settings:ready(c))
    local init=assert(f.settings:initialize(c,f.body(1)))
    assert(init.revision==1 and f.accepted==1 and f.committed==0)
    assert(not f.settings:take_recovered(c),'initial admission cannot activate recovery')
    local n=#f.calls;f:commit(1);assert(#f.calls==n)
    assert(f.settings:poll(c)=='recovered')
    assert(f:attach_writer(f.body(1)).revision==1,'initial payload activates only once durable')
    local r=f.writer:submit(f.body(2));assert(r.state=='pending' and r.receipt.revision==2)
    f:commit(2);assert(f.writer:poll().state=='saved' and f.generation==2)
    assert(f.settings:drain(c) and f.cleaned)
end
-- Native acceptance survives a lost return across every layer, with no saved,
-- ACK, activation or unsafe cleanup even after native independently completes.
do
    local f=composed();local c=f.context;f:attach_writer(f.body(2))
    f.throw_after=5
    assert(f.writer:submit(f.body(3)).state=='uncertain' and f.accepted==1)
    assert(f.writer:status().candidate_retained and f.api:inspect().candidate_retained)
    f.throw_after=nil;local n=#f.calls;f:commit(1);assert(#f.calls==n)
    assert(f.writer:poll().state~='saved' and not f.settings:ready(c))
    assert(f.settings:drain(c)==false and f.drains==1 and not f.cleaned and f.lease.holder)
    assert(f.api:inspect().phase=='closed' and f.api:inspect().state=='uncertain')
    n=#f.calls;assert(f.settings:drain(c)==false and #f.calls==n,'no duplicate native drain after uncertain handoff')
end
do
    local f=composed(nil,true);local c=f.context;f.throw_after=5
    assert(not f.settings:initialize(c,f.body(1)) and f.accepted==1)
    f.throw_after=nil;f:commit(1);f.settings:poll(c)
    assert(not f.settings:take_recovered(c) and not f.settings:ready(c))
    assert(not f.settings:drain(c) and not f.cleaned and f.lease.holder)
end
for _,failure in ipairs({'revoked','publication'}) do
    local f=composed();local c=f.context;f:attach_writer(f.body(2))
    assert(f.writer:submit(f.body(3)).state=='pending')
    if failure=='revoked' then f.denied=true
    else f.phase='blocked';f.error='publication';f.terminal='io_error';f.certain='1';f.terr='29' end
    assert(f.writer:poll().state~='saved' and not f.settings:ready(c))
    if failure=='revoked' then
        assert(f.settings:drain(c) and f.committed==1 and f.cleaned)
    else assert(not f.settings:drain(c) and not f.cleaned) end
end
for _,lost in ipairs({false,true}) do
    local f=composed();local c=f.context;f:attach_writer(f.body(2))
    local route={peer='peer',client='connection'}
    local stage=assert(f.settings:stage(c,{request={peer=route.peer,client=route.client,id=1,command='edit-1'}}))
    if lost then f.no_results=5 end
    local r=f.settings:submit(c,stage,f.body(3))
    assert(not f.settings:peek_ack(c,stage,route))
    if lost then assert(not r) else assert(r.revision==1) end
    f.no_results=nil;f:commit(1);f.settings:poll(c)
    local ack=f.settings:peek_ack(c,stage,route)
    if lost then assert(not ack and not f.settings:ready(c))
    else assert(ack.revision==1 and f.settings:consume_ack(c,stage,route)) end
end
print('draining backend: frozen wire, real typed codec, native revisions, explicit close/drain, uncertain tickets and context fences passed')
print('draining composition: actual writer/session/queue/adapter, durable init, native-only progress, lost returns and explicit owner cleanup passed')
