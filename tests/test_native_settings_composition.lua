-- Actual adapter -> journal queue -> Session -> settings codec/shared Barrier.
-- Only the fixed native ABI and worker/game scheduling are simulated. The disk
-- below is a native-boundary model, NOT evidence of SHA, filesystem or live IO.
local Backend=dofile(TEST_ROOT..'/experiments/save_native_backend.lua')
local Settings=dofile(TEST_ROOT..'/experiments/settings_session.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local Queue=dofile(TEST_ROOT..'/experiments/save_journal_queue.lua')
local Store,Caps=require('store'),require('caps')
local before={Store.data,Caps.data,Store.state,Caps.state}
local W,G=string.rep('a',32),string.rep('b',32)
local route={peer='peer-1',client='client-1'}
local function copy(t)
    if type(t)~='table' then return t end
    local r={};for k,v in pairs(t) do r[k]=copy(v) end;return r
end
-- Independent ABI field framing, rather than using the adapter to decode itself.
local function unpack_fields(hex,n)
    assert(type(hex)=='string' and #hex==n and n%2==0 and not hex:find('[^0-9a-f]'))
    local bytes=hex:gsub('..',function(s) return string.char(tonumber(s,16)) end)
    local fields,at={},1
    while at<=#bytes do
        assert(at+3<=#bytes)
        local size;size,at=string.unpack('<I4',bytes,at)
        assert(at+size-1<=#bytes)
        fields[#fields+1]=bytes:sub(at,at+size-1);at=at+size
    end
    return fields
end
local function pack_fields(fields)
    local out={};for _,s in ipairs(fields) do out[#out+1]=string.pack('<I4',#s)..s end
    return table.concat(out)
end
local function fixture(stream,seed)
    stream=stream or 'priorities'
    local f={thread=10,workers={},callbacks={},disk={},updates={},calls={},consumes=0,
        executions=0,publications=0,token='pair-0',lease={},authorized=true}
    f.scope=Scope.new(W,G,stream).key
    f.codec=Codec.new{storage=W,guild=G,stream=stream}
    function f.body(value)
        if stream=='limits' then return assert(Caps.serialize_snapshot({[G]={Mining={Stone=false,Ore=value}}})) end
        return assert(Store.serialize_snapshot({pal={[1]=false,[2]=value}},true))
    end
    function f.payload(value) return assert(f.codec.encode(f.body(value))) end
    if seed then f.disk[1]={generation=seed,payload=f.payload(1)} end
    local function active()
        if f.disk[1] and f.disk[2] then return f.disk[2].generation>f.disk[1].generation and 2 or 1 end
        return f.disk[1] and 1 or f.disk[2] and 2 or nil
    end
    function f.native(cmd,binding,ticket,hex,n)
        assert(binding==4,'only the pre-bound fixed-root capability is accepted')
        assert(f.thread==(cmd==4 and 11 or 10),'wrong native execution route')
        local fields=unpack_fields(hex,n)
        f.calls[#f.calls+1]={command=cmd,ticket=ticket}
        local status,data=1,''
        if cmd==2 or cmd==3 then
            assert(not f.pending and ticket>(f.high or 0),'owner already reserved or stale ticket')
            assert(#fields==(cmd==2 and 0 or 5),'no independent path/scope fields')
            local op={kind=cmd,ticket=ticket}
            if cmd==3 then
                local a=active();local generation=a and f.disk[a].generation or 0
                assert(fields[1]==f.token,'exact current preimage token')
                assert(tonumber(fields[3])==generation+1 and (fields[5]=='1')==(a==nil))
                assert(fields[5]=='0' or fields[5]=='1')
                op.payload,op.generation,op.covered=fields[2],tonumber(fields[3]),tonumber(fields[4])
                op.initialize=fields[5]=='1'
                assert(f.codec.supported(op.payload) and op.covered>0)
                f.updates[#f.updates+1]=copy(op)
            end
            f.high=ticket;f.pending=op
        elseif cmd==4 then
            local op=assert(f.pending);assert(op.ticket==ticket and not op.ran and #fields==0)
            op.ran=true;f.executions=f.executions+1
            local out={f.scope,'native-incarnation','7','','1','0','0',f.token,'0','0','','','','','',''}
            if op.kind==2 then
                out[4]='recovered'
                for i=1,2 do
                    local at=i==1 and 11 or 14;local record=f.disk[i]
                    out[at]=record and 'valid' or 'missing'
                    out[at+1]=record and tostring(record.generation) or '0'
                    out[at+2]=record and record.payload or ''
                end
            else
                local a=active();local target=a==1 and 2 or 1
                f.disk[target]={generation=op.generation,payload=op.payload}
                f.publications=f.publications+1
                f.token='pair-'..ticket
                out[4]=op.initialize and 'initialized' or 'updated'
                out[6],out[7],out[8]=tostring(op.generation),tostring(op.covered),f.token
                -- Simulate ambiguity AFTER bytes were published. The caller
                -- cannot ACK or retry merely because the disk model changed.
                if f.uncertain then out[4],out[5],out[9]='uncertain','0','5' end
            end
            f.terminal=pack_fields(out);f.certain=out[5]=='1'
        elseif cmd==5 then
            assert(f.pending and f.pending.ticket==ticket and #fields==0)
            status,data=f.terminal and 1 or 2,f.terminal or ''
        elseif cmd==6 then
            assert(f.pending and f.pending.ticket==ticket and f.terminal and #fields==0)
            assert(f.certain,'uncertain mailbox must never be consumed')
            if f.hold_consume then status=0
            else f.consumes=f.consumes+1;f.pending,f.terminal=nil,nil end
        else error('unexpected ABI command '..tostring(cmd)) end
        return status,data,f.thread,20,21,1000
    end
    f.backend=Backend.new{enabled=true,storage=W,guild=G,stream=stream,
        incarnation='native-incarnation',epoch=7,binding=4,game_thread=10,native=f.native,
        schedule=function(fn) assert(f.thread==10);f.workers[#f.workers+1]=fn;return true end,
        resume=function(fn)
            assert(f.thread==11)
            if not f.drop_callback then f.callbacks[#f.callbacks+1]=fn end
        end}
    f.context={scope=f.scope,session='lua-session',incarnation='native-incarnation',epoch=7,
        guild=G,stream=stream,camp='camp-A',authority=true}
    f.other=copy(f.context);f.other.camp='camp-B'
    f.session=Settings.new{enabled=true,storage=W,guild=G,stream=stream,
        session='lua-session',incarnation='native-incarnation',epoch=7,
        backend_kind='PWP-JOURNAL-DEV-1',backend=f.backend,lease=f.lease,clock=function() return 0 end,
        authorize=function(c)
            return f.authorized and c.scope==f.scope and c.epoch==7 and c.incarnation=='native-incarnation'
        end}
    function f.run_worker()
        local work=assert(table.remove(f.workers,1),'no worker queued')
        f.thread=11;local ok,err=pcall(work);f.thread=10;assert(ok,err)
        assert(f.terminal,'worker must leave a retained disk terminal')
    end
    function f.run_callbacks()
        while #f.callbacks>0 do table.remove(f.callbacks,1)() end
    end
    function f.poll() return f.session:poll(f.context) end
    function f.activate(expected_revision)
        local r=assert(f.session:take_recovered(f.context))
        assert(r.revision==expected_revision and r.scope==f.scope and r.session=='lua-session')
        assert(not f.session:take_recovered(f.context))
        assert(f.session:register_camp(f.context,true) and f.session:register_camp(f.other,true))
        return r
    end
    function f.edit(id,value,context)
        context=context or f.context
        local ticket=assert(f.session:stage(context,{request={peer=route.peer,client=route.client,
            id=id,command='edit-'..id}}))
        local receipt=assert(f.session:submit(context,ticket,f.body(value)))
        return ticket,receipt
    end
    return f
end

for _,stream in ipairs({'priorities','limits'}) do
    local f=fixture(stream);local s,c=f.session,f.context
    assert(s:open(c) and #f.workers==1)
    assert(not s:initialize(c,f.body(1)) and not s:take_recovered(c))
    assert(f.poll()=='recovering' and f.executions==0 and f.consumes==0)
    f.run_worker();f.run_callbacks()
    assert(not s:take_recovered(c),'callback alone does not activate recovered data')
    assert(f.poll()=='initialization_required' and f.consumes==1)
    assert(not s:ready(c) and not s:stage(c,{}) and #f.updates==0)
    local initial=assert(s:initialize(c,f.body(2)));assert(initial.revision==1)
    assert(f.publications==0 and f.poll()=='initializing' and not s:take_recovered(c))
    f.run_worker();f.run_callbacks();f.hold_consume=true
    assert(f.publications==1 and not s:take_recovered(c))
    f.poll();assert(not s:take_recovered(c) and not s:ready(c))
    f.hold_consume=false;assert(f.poll()=='recovered')
    local restored=f.activate(1)
    local encoded=stream=='priorities' and Store.serialize_snapshot(restored.settings.data,restored.settings.baseline)
        or Caps.serialize_snapshot(restored.settings.data)
    assert(encoded==f.body(2) and s:ready(c))
end

-- The full settings API requires durable initialization before edits. Recover a
-- generation-one record: logical edits 1/2/3 take TWO physical updates (2/3),
-- not three. Persisted generation cannot start at zero for a valid recovery.
for _,stream in ipairs({'priorities','limits'}) do
    local f=fixture(stream,1);local s,c=f.session,f.context
    assert(s:open(c));f.run_worker();assert(not s:take_recovered(c))
    assert(f.poll()=='recovered');f.activate(0)
    local t1,r1=f.edit(1,2);local t2,r2=f.edit(2,3,f.other);local t3,r3=f.edit(3,4)
    assert(r1.revision==1 and r2.revision==2 and r3.revision==3 and #f.updates==1)
    assert(f.updates[1].generation==2 and f.updates[1].covered==1)
    assert(not s:peek_ack(c,t1,route) and not s:ready(c))
    f.drop_callback=true;f.callbacks={};f.run_worker()
    assert(#f.callbacks==0 and f.pending and f.terminal and not s:peek_ack(c,t1,route))
    f.poll() -- retained native terminal survives the missing game callback
    assert(s:peek_ack(c,t1,route).revision==1 and not s:peek_ack(f.other,t2,route))
    assert(not s:ready(c) and #f.updates==2 and f.updates[2].generation==3 and f.updates[2].covered==3)
    assert(f.updates[2].payload==f.payload(4),'old completion must not clear newer edits')
    f.run_worker();f.poll()
    assert(s:ready(c) and s:ready(f.other) and s:peek_ack(c,t3,route).revision==3)
    assert(s:peek_ack(f.other,t2,route).durable_revision==3 and f.publications==2)
    assert(not s:peek_ack(c,t2,route) and s:consume_ack(c,t3,route))
end

-- Exact logical3/physical2 case at the real adapter/queue boundary: queue permits
-- coalescing during initialization; the higher-level settings gate intentionally
-- does not. This uses the same native ABI/scheduler model, no adapter stub.
do
    local f=fixture()
    local q=Queue.new{enabled=true,storage=W,guild=G,stream='priorities',
        incarnation='native-incarnation',epoch=7,backend=f.backend}
    assert(q:recover());f.run_worker();assert(q:poll()==false and q:can_initialize())
    assert(q:initialize(f.payload(1))==1 and q:submit(f.payload(2))==2 and q:submit(f.payload(3))==3)
    f.run_worker();local ok,payload=q:poll();assert(ok and payload==f.payload(1) and q.saved==1)
    assert(#f.updates==2 and f.updates[2].generation==2 and f.updates[2].covered==3)
    f.run_worker();q:poll();assert(q.saved==3 and q.journal_generation==2 and q:can_shutdown())
end

-- Revocation at each phase suppresses activation/ACKs but drains the original
-- native binding. A replacement context cannot consume the old mailbox.
for _,phase in ipairs({'recover','initialize','edit'}) do
    local f=fixture('priorities',phase~='initialize' and 1 or nil);local s,c=f.session,f.context
    assert(s:open(c))
    local ticket
    if phase~='recover' then
        f.run_worker();f.poll()
        if phase=='initialize' then assert(s:initialize(c,f.body(2)))
        else f.activate(0);ticket=f.edit(1,2) end
    end
    f.authorized=false
    f.poll();assert(not s:ready(c))
    f.run_worker()
    local replacement=copy(c);replacement.epoch=8
    local consumes=f.consumes
    assert(not s:poll(replacement) and f.consumes==consumes and f.pending)
    f.poll()
    assert(not f.pending and f.lease.holder==nil and not s:take_recovered(c))
    assert(not s:peek_ack(c,ticket or 1,route) and not s:stage(c,{}) and not s:ready(c))
end

-- Uncertain native publication may have changed disk, but can never acknowledge
-- or retry it; the retained mailbox keeps the owner and shared lease occupied.
for _,initializing in ipairs({false,true}) do
    local f=fixture('priorities',not initializing and 1 or nil);local s,c=f.session,f.context
    assert(s:open(c));f.run_worker();f.poll()
    local ticket
    if initializing then assert(s:initialize(c,f.body(2)))
    else f.activate(0);ticket=f.edit(1,2) end
    f.uncertain=true;f.run_worker();f.poll()
    local consumed,updates=f.consumes,#f.updates
    assert(s:status(c).state=='uncertain' and f.publications==1)
    for _=1,3 do assert(not s:retry(c));f.poll() end
    assert(f.consumes==consumed and #f.updates==updates and f.pending and f.terminal and f.lease.holder)
    assert(not s:ready(c) and not s:take_recovered(c) and not s:peek_ack(c,ticket or 1,route))
    assert(not s:close(c) and f.lease.holder and #f.workers==0)
end
assert(Store.data==before[1] and Caps.data==before[2] and Store.state==before[3] and Caps.state==before[4],
    'composition must not install production settings')
print('native settings composition: real adapter/codec/session/barrier, init, coalescing, lost callback, revocation and uncertainty passed')
