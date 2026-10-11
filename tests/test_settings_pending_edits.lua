local Ledger=dofile(TEST_ROOT..'/experiments/settings_pending_edits.lua')
local W,G=string.rep('a',32),string.rep('b',32)
local function peer(n)return {name='peer'..(n or 1),server='server',client='client',guild=G,epoch=1}end
local function receipt(stream,n)return {scope='PWP-SCOPE-1:'..W..':'..G..':'..(stream or 'limits'),
    session='session',incarnation='incarnation',epoch=1,revision=n or 1,attachment=1}end
local function proof(r)return {receipt=r,covered_revision=r.revision,snapshot_revision=7}end
local function copy(t)local r={};for k,v in pairs(t)do r[k]=type(v)=='table' and copy(v) or v end;return r end
local function fixture()local l=assert(Ledger.new{enabled=true});return l,assert(l:bind(peer()))end
assert(not Ledger.new() and not Ledger.new{} and not Ledger.new{enabled='true'})
for _,t in ipairs({false,0,-1,9,math.huge,0/0,'8'})do assert(not Ledger.new{enabled=true,timeout=t})end

-- Only reserved may enter the mutator. Duplicate callbacks while the mutator is
-- in flight cannot invoke it again, even before an acceptance receipt exists.
do
    local l,b=fixture();local writes=0
    local function dispatch(id,command)
        local v=l:reserve(b,id,'limits',command,0)
        if v and v.status=='reserved' then
            writes=writes+1
            local nested=l:reserve(b,id,'limits',command,0)
            assert(nested.status=='duplicate' and nested.state=='reserved')
        end
        return v
    end
    local v=dispatch(1,'set|Stone|35001');dispatch(1,'set|Stone|35001')
    assert(writes==1 and l:status().pending==1)
    assert(not l:reserve(b,1,'limits','set|Stone|35002',0))
    assert(not l:reserve(b,1,'priorities','set|Stone|35001',0))
    local r=receipt();assert(l:accepted(v.ticket,r,1).state=='pending')
    r.revision=999;v.command='changed'
    local d=l:reserve(b,1,'limits','set|Stone|35001',2)
    assert(d.receipt.revision==1 and d.deadline==8);d.receipt.revision=666
    assert(not l:reject(v.ticket,2),'accepted mutation cannot be relabeled rejected')
    local p=proof(receipt());p.covered_revision=3 -- later durable revision covers it
    assert(l:complete(v.ticket,p,3).state=='durable')
    p.snapshot_revision=100
    d=l:reserve(b,1,'limits','set|Stone|35001',4)
    assert(d.status=='duplicate' and d.state=='durable' and d.publication.snapshot_revision==7)
    d.publication.snapshot_revision=200
    assert(l:reserve(b,1,'limits','set|Stone|35001',5).publication.snapshot_revision==7)
    assert(not l:complete(v.ticket,proof(receipt()),5) and writes==1)
end

-- One active request per peer/stream; global cap checked before any mutation.
do
    local l,b=fixture();assert(l:reserve(b,1,'limits','a',0))
    assert(not l:reserve(b,2,'limits','b',0))
    assert(select(2,l:reserve(b,2,'limits','b',0))=='stale_request')
    assert(l:reserve(b,3,'priorities','c',0));assert(l:status().pending==2)
    for i=2,127 do local binding=assert(l:bind(peer(i)));assert(l:reserve(binding,1,'limits','a',0))end
    local extra=assert(l:bind(peer(128)))
    assert(not l:reserve(extra,1,'limits','a',0));assert(not l:bind(peer(129)))
    assert(l:status().pending==128 and l:status().peers==128)
    assert(#l:expire(8)==128 and l:status().pending==0)
    assert(l:reserve(extra,2,'limits','b',8))
end

-- Timeout means unknown for both reserved and accepted. No renewal/replay, and
-- completion on the deadline cannot turn unknown into durable.
for _,accepted in ipairs({false,true})do
    local l,b=fixture();local v=l:reserve(b,1,'limits','a',0)
    if accepted then assert(l:accepted(v.ticket,receipt(),7))end
    assert(l:reserve(b,1,'limits','a',7.9).deadline==8)
    assert(not l:complete(v.ticket,proof(receipt()),8))
    assert(l:reserve(b,1,'limits','a',8).state=='unknown')
    assert(not l:accepted(v.ticket,receipt(),8) and not l:reject(v.ticket,8))
    assert(l:status().pending==0)
end
do
    local l,b=fixture();local v=l:reserve(b,1,'limits','a',0)
    assert(l:unknown(v.ticket,0).state=='unknown')
    assert(l:reserve(b,1,'limits','a',0).state=='unknown')
    v=l:reserve(b,2,'limits','b',0);assert(l:reject(v.ticket,0).state=='rejected')
    assert(l:reserve(b,2,'limits','b',0).state=='rejected')
end

-- Explicit lifecycle invalidation, new nonce/epoch/guild binding; stale handles
-- cannot complete or reserve even after the same peer name reconnects.
for _,field in ipairs({'server','client','guild','epoch'})do
    local l,b=fixture();local identity=peer();local v=l:reserve(b,1,'limits','a',0)
    assert(l:accepted(v.ticket,receipt(),0))
    identity[field]=field=='epoch' and 2 or field=='guild' and string.rep('c',32) or 'new'
    assert(not l:bind(identity))
    assert(l:invalidate(b));local fresh=assert(l:bind(identity));assert(fresh~=b)
    assert(not l:complete(v.ticket,proof(receipt()),0) and not l:reserve(b,2,'limits','b',0))
    assert(l:reserve(fresh,1,'limits','a',0).status=='reserved')
end
do
    local l,b=fixture();local identity=peer();assert(l:bind(identity)==b)
    identity.guild=string.rep('c',32);assert(l:bind(peer())==b)
    l:reserve(b,1,'limits','a',0);l:close();l:close()
    assert(l:status().closed and l:status().pending==0 and not l:bind(peer()))
    assert(not l:reserve(b,2,'limits','b',1))
end

-- Eviction is bounded, but high water prevents a previously terminal mutation
-- being submitted a second time once its duplicate record has been discarded.
do
    local l,b=fixture()
    for id=1,300 do local v=assert(l:reserve(b,id,'limits','a',0));assert(l:reject(v.ticket,0))end
    assert(select(2,l:reserve(b,1,'limits','a',0))=='stale_request')
    assert(l:reserve(b,300,'limits','a',0).state=='rejected')
end

-- No foreign receipt, undercovered generation, arbitrary userdata/function or
-- metatable is retained. All fields are allowlisted, all returned tables copied.
for _,field in ipairs({'scope','session','incarnation','epoch','revision','attachment'})do
    local l,b=fixture();local v=l:reserve(b,1,'limits','a',0);local r=receipt();r[field]=nil
    assert(not l:accepted(v.ticket,r,0));assert(l:accepted(v.ticket,receipt(),0))
    local p=proof(receipt());p.receipt[field]=(field=='epoch' or field=='revision' or field=='attachment') and 2 or 'foreign'
    assert(not l:complete(v.ticket,p,0));assert(l:status().pending==1)
end
do
    local l,b=fixture();local v=l:reserve(b,1,'limits','a',0)
    local native=assert(io.tmpfile());local r=receipt();r.native=native
    assert(not l:accepted(v.ticket,r,0));r.native=function()error('must never call')end
    assert(not l:accepted(v.ticket,r,0));r.native=nil;setmetatable(r,{})
    assert(not l:accepted(v.ticket,r,0));native:close()
    assert(l:accepted(v.ticket,receipt(),0))
    for _,field in ipairs({'covered_revision','snapshot_revision'})do
        for _,bad in ipairs({0,-1,1.5,math.huge,0/0,{},function()end})do
            local p=proof(receipt());p[field]=bad;assert(not l:complete(v.ticket,p,0))
        end
    end
    local p=proof(receipt());p.extra={};assert(not l:complete(v.ticket,p,0))
    assert(l:complete(v.ticket,proof(receipt()),0))
end
for _,bad in ipairs({-1,math.huge,0/0,1e30,'1'})do
    local l,b=fixture();assert(not l:reserve(b,1,'limits','a',bad));assert(l:status().pending==0)
end
do
    local l,b=fixture();local v=l:reserve(b,1,'limits','a',2)
    assert(not l:accepted(v.ticket,receipt(),1));assert(l:accepted(v.ticket,receipt(),2))
    assert(l:expire(10)[1].state=='unknown')
end
print('pending edits: bounded reservations, duplicate/reentry suppression, copied receipts, lifecycle and unknown timeouts')
