-- Persisted V6 records have no capacity field: current backend capability must
-- never turn an older reader's size limit into permission to replace newer data.
local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local Transport=dofile(TEST_ROOT..'/experiments/save_transport.lua')
local Read=dofile(TEST_ROOT..'/experiments/save_read.lua')
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local LOW,HIGH=65536,262144
local storage,guild=string.rep('1',32),string.rep('a',32)
local owner=Scope.new(storage,guild,'priorities').key
local function copy(r)
    if not r then return end
    return {session=r.session,generation=r.generation,payload=r.payload,checksum=r.checksum}
end
local function fixture(cap,mode,label,disk)
    local f={disk=disk or {},writes=0,consumes=0}
    local function slot(name) return assert(name:match('_([AB])$')) end
    local function dispatch(op)
        assert(not f.pending);f.pending=op
        if op.kind=='write' then
            f.writes=f.writes+1;f.disk[slot(op.slot)]=copy(op.record)
        end
        return true
    end
    local function read(op)
        local r=copy(f.disk[slot(op.slot)])
        if not r then return {status='missing'} end -- positive absence in fixture only
        if mode=='classifier' then
            return Read.from_native(owner,{schema='PWP-SCRATCH-1',fields_read=true,
                max_payload_bytes=cap,record=r},{max_payload_bytes=cap})
        end
        return {status=#r.payload>cap and label or 'ok',record=r}
    end
    if mode=='transport' then
        local b={contract='PWP-SCOPED-DEV-1',max_payload_bytes=cap,dispatch=dispatch}
        b.peek=function(id)
            local op=assert(f.pending);assert(id.ticket==op.ticket)
            return {scope=op.scope,incarnation=op.incarnation,ticket=op.ticket,kind=op.kind,
                slot=op.slot,max_payload_bytes=cap,terminal=true,success=true,read=read(op)}
        end
        b.consume=function(id)
            assert(f.pending.ticket==id.ticket);f.pending=nil;f.consumes=f.consumes+1;return true
        end
        f.adapter=Transport.new{enabled=true,storage=storage,guild=guild,stream='priorities',
            incarnation='boot',backend=b,max_payload_bytes=cap}
    else
        f.adapter={max_payload_bytes=cap,
            start=function(r,s,t) return dispatch{kind='write',record=r,slot=s,ticket=t} end,
            start_read=function(s,t) return dispatch{kind='read',slot=s,ticket=t} end,
            poll=function(t)
                local op=assert(f.pending);assert(op.ticket==t)
                f.pending=nil;return {ticket=t,success=true,read=read(op)}
            end}
    end
    f.queue=Queue.new(f.adapter,owner,'boot',{max_payload_bytes=cap})
    return f
end

-- Generate genuinely valid checksummed records with the real large queue.
local writer=fixture(HIGH,'raw','ok')
assert(writer.queue:recover());writer.queue:poll();assert(writer.queue:poll())
writer.queue:submit('older small |X|OFF');writer.queue:poll()
writer.queue:submit(string.rep('XOFF',HIGH//4));writer.queue:poll()
assert(writer.queue.saved==2 and writer.writes==2)
local small,large=copy(writer.disk.A),copy(writer.disk.B)
assert(small.generation==1 and large.generation==2 and #large.payload==HIGH)
assert(large.max_payload_bytes==nil,'capacity must not be persisted in this fixture')

local snapshot={schema='PWP-SCRATCH-1',fields_read=true,max_payload_bytes=LOW,record=large}
assert(Read.from_native(owner,snapshot).status=='unreadable')
-- Also refuse cap+1 even beyond the currently supported ceiling.
snapshot.record=copy(large);snapshot.record.payload=large.payload..'x';snapshot.max_payload_bytes=HIGH
assert(Read.from_native(owner,snapshot,{max_payload_bytes=HIGH}).status=='unreadable')

for _,reversed in ipairs({false,true}) do
    local disk={A=copy(reversed and large or small),B=copy(reversed and small or large)}
    -- Positive control: the larger reader recovers generation 2 byte-for-byte.
    local supported=fixture(HIGH,'raw','ok',disk)
    assert(supported.queue:recover());supported.queue:poll()
    local ok,payload=supported.queue:poll()
    assert(ok and payload==large.payload and supported.queue.saved==2 and supported.writes==0)
    for _,mode in ipairs({'classifier','transport','raw'}) do
        for _,label in ipairs({'ok','invalid','missing'}) do
            local f=fixture(LOW,mode,label,disk)
            assert(f.queue:recover())
            local result=f.queue:poll()
            if not reversed then assert(result==nil);result=f.queue:poll() end
            assert(result==false and f.queue.state=='error',mode..' allowed downgrade fallback')
            assert(f.queue.recovered_payload==nil and f.queue.saved==0)
            assert(not pcall(f.queue.submit,f.queue,'overwrite with older/default'))
            f.queue:retry();assert(f.writes==0 and not f.pending)
            assert(disk.A.payload==(reversed and large.payload or small.payload))
            assert(disk.B.payload==(reversed and small.payload or large.payload))
        end
    end
end

-- Verify the transport classification directly, without relying on queue checks.
for _,label in ipairs({'ok','invalid','missing'}) do
    local f=fixture(LOW,'transport',label,{A=copy(large)})
    assert(f.adapter.start_read('PWP_SaveScratch_v1_A',1))
    local terminal=assert(f.adapter.poll(1))
    assert(terminal.read.status=='unreadable' and terminal.read.record==nil)
    assert(f.consumes==1,'matching terminal identity may drain, but cannot authorize recovery')
end

-- Outbound cap+1 remains inadmissible; a failed read is never a write allowance.
local f=fixture(LOW,'raw','ok');assert(f.queue:recover());f.queue:poll();assert(f.queue:poll())
assert(not pcall(f.queue.submit,f.queue,string.rep('x',LOW+1)))
assert(f.writes==0 and f.queue.generation==0)
print('payload downgrade: valid newer 256KiB record blocks 64KiB fallback at classifier, transport and queue independently')
