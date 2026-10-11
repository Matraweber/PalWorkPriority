-- Pure end-to-end pipeline: real serializers, no native calls or filesystem IO.
local Session=dofile(TEST_ROOT..'/experiments/save_session.lua')
local Transport=dofile(TEST_ROOT..'/experiments/save_transport.lua')
local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local Read=dofile(TEST_ROOT..'/experiments/save_read.lua')
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local DEFAULT,MAX=65536,262144
local storage,guild=string.rep('1',32),string.rep('a',32)
local function copy(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t) do out[k]=copy(v) end;return out
end
local function backend(cap)
    return {contract='PWP-SCOPED-DEV-1',max_payload_bytes=cap,
        dispatch=function() error('unexpected IO') end,
        peek=function() error('unexpected IO') end,consume=function() error('unexpected IO') end}
end
local function opts(b,cap)
    return {enabled=true,storage=storage,guild=guild,stream='priorities',incarnation='boot',
        backend=b,max_payload_bytes=cap}
end
local function session_options(factory,cap)
    return {enabled=true,lease={},clock=function() return 0 end,authorize=function() return true end,
        factory=factory,max_payload_bytes=cap}
end

-- No coerced, nonfinite, out-of-bounds, or otherwise unsupported capacities.
for _,bad in ipairs({false,true,'262144',0,-1,65535,262145,65536.5,math.huge,0/0,{}}) do
    assert(not pcall(Session.new,session_options(function() end,bad)))
    assert(not pcall(Transport.new,opts(backend(MAX),bad)))
    assert(not pcall(Transport.new,opts(backend(bad),MAX)))
    assert(not pcall(Queue.new,{max_payload_bytes=MAX},'scope','boot',{max_payload_bytes=bad}))
    assert(not pcall(Read.from_native,'scope',{}, {max_payload_bytes=bad}))
end
-- Exact negotiation: do not silently adopt a larger peer's advertised limit.
for _,pair in ipairs({{DEFAULT,MAX},{MAX,DEFAULT},{MAX,131072}}) do
    local requested,advertised=table.unpack(pair)
    assert(not pcall(Transport.new,opts(backend(advertised),requested)))
    assert(not pcall(Queue.new,{max_payload_bytes=advertised},'scope','boot',
        {max_payload_bytes=requested}))
    local recoveries=0
    local options=session_options(function(_,_,cap)
        assert(cap==requested)
        return {max_payload_bytes=advertised,recover=function() recoveries=recoveries+1 end}
    end,requested)
    local c=Session.new(options)
    assert(c:open('scope','boot')==false and recoveries==0 and options.lease.holder==nil)
end
assert(not pcall(Transport.new,opts(backend(),MAX)))
assert(not pcall(Transport.new,opts(backend(MAX))))
assert(not pcall(Queue.new,{},'scope','boot',{max_payload_bytes=MAX}))
assert(not pcall(Queue.new,{max_payload_bytes=MAX},'scope'))
local calls=0
local c=Session.new(session_options(function()
    return {recover=function() calls=calls+1 end}
end,MAX))
assert(c:open('scope','boot')==false and calls==0)

-- Supported capacity is a captured agreement, not mutable options/defaults.
local b=backend(DEFAULT);local options=opts(b)
local adapter,key=Transport.new(options)
options.max_payload_bytes=MAX;b.max_payload_bytes=MAX
assert(adapter.max_payload_bytes==DEFAULT)
assert(not pcall(adapter.start,{session=key,generation=1,payload=string.rep('x',DEFAULT+1),
    checksum='00000000'},'PWP_SaveScratch_v1_A',1))

local function fixture(cap,stream,disk)
    local f={disk=disk or {},calls={},writes=0,consumes=0}
    f.cap=cap or DEFAULT
    f.owner=Scope.new(storage,guild,stream or 'priorities').key
    f.backend=backend(cap)
    f.backend.dispatch=function(op)
        assert(not f.op and op.max_payload_bytes==f.cap)
        f.op=copy(op);f.calls[#f.calls+1]=copy(op)
        if op.kind=='write' then f.writes=f.writes+1 end
        return true
    end
    f.backend.peek=function(id)
        assert(f.op and id.ticket==f.op.ticket)
        if not f.ready then return end
        local result=copy(f.op);result.terminal=true;result.success=true
        if f.omit_envelope_cap then result.max_payload_bytes=nil end
        if f.envelope_cap~=nil then result.max_payload_bytes=f.envelope_cap end
        local r=f.disk[id.slot]
        if r then
            result.read=Read.from_native(f.owner,{schema='PWP-SCRATCH-1',fields_read=true,
                max_payload_bytes=f.snapshot_cap or cap,record=copy(r)}, {max_payload_bytes=cap})
        elseif f.ambiguous_absence then
            result.read=Read.from_native(f.owner,{exists=false},{max_payload_bytes=cap})
        else
            -- Positive absence is a property of this in-memory fixture ONLY.
            -- The real native nil/false classifier never supplies 'missing'.
            result.read={status='missing'}
        end
        return result
    end
    f.backend.consume=function(id)
        assert(f.ready and id.ticket==f.op.ticket)
        f.consumes=f.consumes+1
        f.op=nil;f.ready=false;return true
    end
    f.options=session_options(function(owner,token,limit)
        assert(owner==f.owner and limit==f.cap)
        local a,k=Transport.new{enabled=true,storage=storage,guild=guild,stream=stream or 'priorities',
            incarnation=token,backend=f.backend,max_payload_bytes=cap}
        f.adapter=a
        f.queue=Queue.new(a,k,token,{max_payload_bytes=cap})
        return f.queue
    end,cap)
    f.controller=Session.new(f.options)
    function f:finish()
        assert(self.op)
        if self.op.kind=='write' then self.disk[self.op.slot]=copy(self.op.record) end
        self.ready=true
        return self.controller:poll()
    end
    function f:open(token)
        self.token=token
        assert(self.controller:open(self.owner,token))
        assert(self:finish()==nil)
        local recovered=self:finish();assert(recovered and recovered.session==token)
        return recovered
    end
    return f
end

-- Boundary sizes through session -> queue -> transport -> classifier -> queue.
for _,cap in ipairs({DEFAULT,131072,MAX}) do
    -- Exercise omitted options/advertisement at the legacy capacity.
    local negotiated
    if cap~=DEFAULT then negotiated=cap end
    local f=fixture(negotiated);f:open('boot')
    local payload=string.rep('x',cap)
    local receipt=assert(f.controller:submit('boot',payload))
    local generation,writes=f.queue.generation,f.writes
    assert(f.controller:submit('boot',payload..'x')==nil)
    assert(not pcall(f.queue.submit,f.queue,payload..'x'))
    assert(f.queue.generation==generation and f.writes==writes)
    f:finish();assert(f.controller:status(receipt).state=='saved')
    assert(not pcall(f.adapter.start,{session=f.owner,generation=2,payload=payload..'x',
        checksum='00000000'},'PWP_SaveScratch_v1_A',f.queue.ticket+1))
    assert(Read.from_native(f.owner,{schema='PWP-SCRATCH-1',fields_read=true,max_payload_bytes=cap,
        record={session=f.owner,generation=1,payload=payload..'x',checksum='00000000'}},
        {max_payload_bytes=cap}).status=='unreadable')
    assert(f.controller:close('boot'))
    local fresh=fixture(negotiated,nil,f.disk)
    local recovered=fresh:open('fresh');assert(recovered.payload==payload and recovered.revision==1)
    assert(fresh.writes==0 and fresh.controller:take_committed('fresh')==nil)
end

-- Large capability does not bypass independent development/authorization gates.
do
    local made=0
    local options=session_options(function() made=made+1 end,MAX)
    options.enabled=false
    assert(Session.new(options):open('scope','boot')==false and made==0)
    options.enabled=true;options.authorize=function() return false end
    assert(Session.new(options):open('scope','boot')==false and made==0)
    local f=fixture(MAX);f:open('boot')
    local receipt=assert(f.controller:submit('boot',string.rep('x',MAX)))
    local consumes=f.consumes
    f.envelope_cap=DEFAULT;f:finish()
    assert(f.controller:status(receipt).state=='saving' and f.queue.saved==0)
    assert(f.consumes==consumes and not f.queue:can_shutdown())
    assert(f.controller:take_committed('boot')==nil)
    f.envelope_cap=nil;f.controller:poll()
    assert(f.controller:status(receipt).state=='saved' and f.consumes==consumes+1)
end

-- Capability disagreement/missing advertisement cannot authorize empty recovery.
for _,fault in ipairs({'omit_envelope_cap','envelope_cap','ambiguous_absence'}) do
    local f=fixture(MAX)
    f[fault]=fault=='envelope_cap' and DEFAULT or true
    assert(f.controller:open(f.owner,'boot'));f:finish()
    if fault=='ambiguous_absence' then
        assert(f.controller:status().state=='error')
    else
        assert(f.controller:status().state=='recovering' and f.consumes==0)
        assert(not f.queue:can_shutdown())
        f.queue:timeout();assert(f.controller:status().state=='uncertain')
        assert(not f.controller:close('boot'))
        assert(not f.controller:open(f.owner,'replacement'))
    end
    assert(f.writes==0)
    assert(f.controller:submit('boot','defaults')==nil)
end
local sample={schema='PWP-SCRATCH-1',fields_read=true,record={session='scope',generation=1,
    payload='x',checksum='00000000'}}
assert(Read.from_native('scope',sample,{max_payload_bytes=MAX}).status=='unreadable')
sample.max_payload_bytes=MAX
assert(Read.from_native('scope',sample).status=='unreadable')
for _,bad in ipairs({false,'262144',0,MAX+1}) do
    sample.max_payload_bytes=bad
    assert(Read.from_native('scope',sample,{max_payload_bytes=MAX}).status=='unreadable')
end

-- Real production serialization, with every persistence entry point trapped.
local io_calls,notices=0,0
package.loaded.log={warn=function() end,error=function() end}
package.loaded.datafile={read=function() io_calls=io_calls+1;error('unexpected IO') end,
    write=function() io_calls=io_calls+1;error('unexpected IO') end}
local Store=require('store')
local Caps=require('caps')
Store.data={};Store.baseline=true;Store.state='saving';Store.generation=9
Store.on_change=function() notices=notices+1 end
local firstkey
for pal=1,300 do
    local k=string.format('%08d-1234567890-1234567890-1234567890',pal)
    firstkey=firstkey or k;Store.data[k]={}
    for work=1,14 do
        if work%6==0 then Store.data[k][work]=false else Store.data[k][work]=work%5+1 end
    end
end
local priorities=assert(Store.serialize())
assert(#priorities==194799,'real 300-Pal snapshot size changed: '..#priorities)
local _,disabled=priorities:gsub('|X\n','');assert(disabled==600)
local capguild=string.rep('g',160)
Caps.data={[capguild]={Mining={}}};Caps.state='saving';Caps.generation=7
Caps.on_change=Store.on_change
Caps.remote={remoteOnly={Mining={DoNotPersist=999}}}
local firstitem
for i=1,500 do
    local item=string.format('%04d',i)..string.rep('i',60)
    firstitem=firstitem or item
    Caps.data[capguild].Mining[item]=i%2==0 and 250 or false
end
local limits=assert(Caps.serialize())
assert(#limits>DEFAULT and #limits<MAX and not limits:find('DoNotPersist',1,true))
local _,off=limits:gsub('|OFF\n','');assert(off==250)

local function pipeline(stream,initial,edit)
    local legacy=fixture(nil,stream);legacy:open('legacy')
    assert(legacy.controller:submit('legacy',initial)==nil and legacy.writes==0)
    local f=fixture(MAX,stream);f:open('boot')
    local r1=assert(f.controller:submit('boot',initial))
    local middle=edit(2);local r2=assert(f.controller:submit('boot',middle))
    local latest=edit(3);local r3=assert(f.controller:submit('boot',latest))
    assert(#middle>DEFAULT and #latest>DEFAULT and f.writes==1)
    assert(f.op.record.payload==initial and f.controller:take_committed('boot')==nil)
    f:finish()
    assert(f.controller:status(r1).state=='saved' and f.controller:status(r2).state=='saving')
    local event=f.controller:take_committed('boot');assert(event.first==1 and event.last==1)
    assert(f.writes==2 and f.op.record.payload==latest and f.op.record.generation==3)
    f:finish();event=f.controller:take_committed('boot')
    assert(event.first==2 and event.last==3 and f.controller:status(r3).state=='saved')
    assert(f.controller:close('boot'))
    -- Entirely new controller/queue/transport, retained scalar records only.
    local restored=fixture(MAX,stream,f.disk)
    local recovered=restored:open('fresh')
    assert(recovered.payload==latest and recovered.revision==3 and restored.writes==0)
    assert(restored.controller:take_committed('fresh')==nil)
    -- A mismatched copied-read capacity aborts, even with older valid data.
    local incompatible=fixture(MAX,stream,f.disk);incompatible.snapshot_cap=DEFAULT
    assert(incompatible.controller:open(incompatible.owner,'incompatible'));incompatible:finish()
    assert(incompatible.controller:status().state=='error' and incompatible.writes==0)
    return recovered.payload
end
local restored_priorities=pipeline('priorities',priorities,function(n)
    Store.data[firstkey][1]=n;return assert(Store.serialize())
end)
assert(restored_priorities:find(firstkey..'|6|X\n',1,true))
local restored_limits=pipeline('limits',limits,function(n)
    Caps.data[capguild].Mining[firstitem]=n*100;return assert(Caps.serialize())
end)
assert(restored_limits:find('|OFF\n',1,true))
assert(Store.state=='saving' and Store.generation==9 and Caps.state=='saving' and Caps.generation==7)
assert(io_calls==0 and notices==0)
print('payload capacity: legacy defaults, exact bounded negotiation, cap+1, recovery, real 300-Pal X/OFF coalescing passed')
