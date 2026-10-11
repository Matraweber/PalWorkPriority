local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local Transport=dofile(TEST_ROOT..'/experiments/save_transport.lua')
local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local Session=dofile(TEST_ROOT..'/experiments/save_session.lua')
local world=string.rep('1',32)
local guild=string.rep('a',32)
local function copy(t)
    if type(t)~='table' then return t end
    local r={};for k,v in pairs(t) do r[k]=copy(v) end;return r
end
local function same(a,b)
    for _,k in ipairs({'scope','incarnation','ticket','kind','slot'}) do
        if a[k]~=b[k] then return false end
    end
    return true
end
-- Reference backend contract only; these tests do NOT prove native ownership.
local function fixture()
    local f={disk={},calls={},consumes=0,clock=0}
    local backend={contract='PWP-SCOPED-DEV-1'}
    backend.dispatch=function(op)
        if f.op or f.reject then return false end
        f.op=copy(op);f.calls[#f.calls+1]=copy(op)
        if f.after_dispatch then f.after_dispatch(op) end
        if f.throw_start then error('already enqueued') end
        return true
    end
    backend.peek=function(id)
        if f.inject then return f.inject end
        if not f.op or not same(id,f.op) or not f.ready then return end
        local out=copy(f.op);out.terminal=true;out.success=not f.fail
        out.read=f.unreadable and {status='unreadable'} or f.disk[id.slot]
            and {status='ok',record=copy(f.disk[id.slot])} or {status='missing'}
        return out
    end
    backend.consume=function(id)
        f.consumes=f.consumes+1
        if f.on_consume then f.on_consume() end
        if f.acked and same(id,f.acked) then return true end
        if f.block_consume then return false end
        assert(f.op and f.ready and same(id,f.op),'consume wrong native operation')
        f.acked=copy(id)
        f.op,f.ready=nil,false
        if f.throw_after_consume then f.throw_after_consume=false;error('ack reply lost after release') end
        return true
    end
    f.backend=backend
    function f:queue(w,g,stream,incarnation)
        local adapter,key=Transport.new{enabled=true,storage=w or world,guild=g or guild,
            stream=stream or 'priorities',incarnation=incarnation or 'boot',backend=backend}
        return Queue.new(adapter,key,incarnation or 'boot'),adapter,key
    end
    function f:finish(q)
        assert(self.op)
        if self.op.kind=='write' and not self.fail then self.disk[self.op.slot]=copy(self.op.record) end
        self.ready=true
        return q:poll()
    end
    function f:recover(q)
        assert(q:recover());self:finish(q);local ok,payload=self:finish(q);assert(ok);return payload
    end
    return f
end

-- Exact encoding: worlds, guilds, streams and slots are all distinct, stable,
-- case-normalized, bounded and path safe. Unknown identities must stop writes.
do
    local names={}
    for _,w in ipairs({world,string.rep('2',32)}) do
        for _,g in ipairs({guild,string.rep('b',32)}) do
            for _,stream in ipairs({'priorities','limits'}) do
                local s=Scope.new(w,g,stream)
                assert(s.key==Scope.new(w:upper(),g:upper(),stream).key)
                for _,slot in ipairs({s.a,s.b}) do
                    assert(#slot<128 and slot:match('^[%w_]+$') and not names[slot])
                    assert(not slot:find('SaveScratch',1,true))
                    names[slot]=true
                end
            end
        end
    end
    for _,bad in ipairs({'',string.rep('0',32),'../world',string.rep('f',33),'map-name'}) do
        assert(not pcall(Scope.new,bad,guild,'priorities'))
        assert(not pcall(Scope.new,world,bad,'priorities'))
    end
    assert(not pcall(Scope.new,world,guild,'../limits'))
    assert(not pcall(Transport.new,{storage=world,guild=guild,stream='priorities'}))
    assert(not pcall(Transport.new,{enabled=true,storage=world,guild=guild,stream='priorities',incarnation='a',backend={}}))
end

-- Full queue recovery/write/readback with distinct guild/stream storage.
do
    local f=fixture();local q=f:queue();assert(f:recover(q)==nil)
    q:submit('Pal|1|X');f:finish(q);assert(q.saved==1)
    local other=f:queue(world,guild,'limits','two');assert(f:recover(other)==nil)
    other:submit('stone|100');f:finish(other)
    local guildq=f:queue(world,string.rep('b',32),'priorities','three')
    assert(f:recover(guildq)==nil);guildq:submit('other guild');f:finish(guildq)
    local restored=f:queue(world,guild,'priorities','four')
    assert(f:recover(restored)=='Pal|1|X')
    local limitq=f:queue(world,guild,'limits','five')
    assert(f:recover(limitq)=='stone|100')
end

-- Identity is checked before consuming. Wrong scope/incarnation/ticket/kind/slot
-- and nonterminal envelopes cannot unlock the actual operation.
do
    for _,field in ipairs({'scope','incarnation','ticket','kind','slot'}) do
        local f=fixture();local q=f:queue();assert(q:recover())
        f.inject=copy(f.op);f.inject.terminal=true;f.inject.success=true
        f.inject.read={status='missing'};f.inject[field]=field=='ticket' and 99 or 'wrong'
        q:poll();assert(f.consumes==0 and not q:can_shutdown())
        f.inject=nil;f:finish(q);assert(f:finish(q)==true)
    end
    local f=fixture();local q=f:queue();q:recover()
    f.inject=copy(f.op);f.inject.terminal=false;f.inject.success=true;f.inject.read={status='missing'}
    q:poll();assert(q.state=='uncertain' and f.consumes==0)
    f.inject=nil;f:finish(q);assert(f:finish(q)==true)
end

-- Null/unreadable load is not absence. A foreign slot blocks recovery even if
-- the other slot contains a valid prior generation of our own data.
do
    local f=fixture();local q=f:queue();f.unreadable=true;q:recover()
    assert(f:finish(q)==false and q.state=='error' and #f.calls==1)
    assert(not pcall(q.submit,q,'must not create fresh defaults'))
    f=fixture();q=f:queue();f:recover(q);q:submit('own A');f:finish(q)
    local s=Scope.new(world,guild,'priorities')
    f.disk[s.b]=copy(f.disk[s.a]);f.disk[s.b].session='foreign owner'
    local newer=f:queue(world,guild,'priorities','new')
    newer:recover();f:finish(newer)
    assert(f:finish(newer)==false and newer.state=='error')
    assert(not pcall(newer.submit,newer,'cannot overwrite foreign B'))
    assert(f.disk[s.b].session=='foreign owner')
end

-- Lost hook can be recovered through retained terminal state; failed consume
-- neither advances durability nor permits another dispatch. Retry only ACKs.
do
    local f=fixture();local q=f:queue();f:recover(q);q:submit('retained')
    f.block_consume=true;f:finish(q);assert(q.saved==0 and not q:can_shutdown())
    local calls=#f.calls;q:timeout();q:retry();assert(#f.calls==calls)
    local replacement=f:queue(world,guild,'limits','replacement')
    assert(replacement:recover()==false and f.op.kind=='write')
    f.block_consume=false;q:poll();assert(q.saved==1 and q:can_shutdown())
    assert(#f.calls==calls and f.consumes>=4)
end

-- Snapshot copies prevent backend mutation from changing the expected identity;
-- consume callbacks cannot recursively consume the same mailbox.
do
    local f=fixture();local q=f:queue();f:recover(q)
    f.after_dispatch=function(op) op.scope='mutated argument';op.record.payload='mutated payload' end
    q:submit('original')
    f.on_consume=function() q:poll() end
    f:finish(q);assert(q.saved==1)
    local s=Scope.new(world,guild,'priorities');assert(f.disk[s.a].payload=='original')
end

-- Lost acknowledgement response retries only the same acknowledgement. Even if
-- a new native operation is admitted in between, the old ACK cannot release it.
do
    local f=fixture();local q=f:queue();f:recover(q);q:submit('durable but reply lost')
    f.throw_after_consume=true;f:finish(q)
    assert(q.saved==0 and q.state=='uncertain' and f.op==nil)
    local newer=f:queue(world,guild,'limits','newer')
    assert(newer:recover());local pending=f.op
    q:poll();assert(q.saved==1 and f.op==pending)
    f:finish(newer);assert(f:finish(newer))
end

-- Bad adapter calls cannot choose paths, replay tickets or submit foreign data.
do
    local f=fixture();local _,adapter,key=f:queue()
    assert(not pcall(adapter.start_read,'../../settings',1) and #f.calls==0)
    local r={session='foreign',generation=1,payload='X',checksum='00000000'}
    assert(not pcall(adapter.start,r,'PWP_SaveScratch_v1_A',1) and #f.calls==0)
    r.session=key;r.payload=string.rep('X',65537)
    assert(not pcall(adapter.start,r,'PWP_SaveScratch_v1_A',1) and #f.calls==0)
    f.reject=true;assert(adapter.start_read('PWP_SaveScratch_v1_A',1)==false)
    assert(not pcall(adapter.start_read,'PWP_SaveScratch_v1_A',1))
end

-- Ambiguous dispatch preserves ownership; no retry before terminal evidence.
do
    local f=fixture();local q=f:queue();f:recover(q);f.throw_start=true
    q:submit('slow');assert(q.state=='uncertain')
    local calls=#f.calls;q:retry();assert(#f.calls==calls)
    f.throw_start=false;f:finish(q);assert(q.saved==1)
end

-- Session controller integration uses the same real queue and scoped transport.
do
    local f=fixture()
    local s=Scope.new(world,guild,'priorities')
    local c=Session.new{enabled=true,lease={},clock=function() return f.clock end,
        authorize=function() return true end,
        factory=function(owner,token)
            assert(owner==s.key)
            return f:queue(world,guild,'priorities',token)
        end}
    assert(c:open(s.key,'session-one'));f:finish(c);assert(f:finish(c).scope==s.key)
    local r1=c:submit('session-one','X');local r2=c:submit('session-one','X and 1')
    f:finish(c);assert(c:status(r1).state=='saved' and c:status(r2).state=='saving')
    c:close('session-one');f:finish(c);assert(c:status(r2).state=='stale')
    assert(c:open(s.key,'session-two'));f:finish(c)
    assert(f:finish(c).payload=='X and 1' and not c:take_committed('session-two'))
end
-- Inline completion can close/reopen a controller during dispatch. The old
-- caller must never receive an acceptance receipt labelled with the new owner.
do
    local f=fixture();local s=Scope.new(world,guild,'priorities')
    local c=Session.new{enabled=true,lease={},clock=function() return f.clock end,
        authorize=function() return true end,
        factory=function(owner,token)
            assert(owner==s.key);return f:queue(world,guild,'priorities',token)
        end}
    assert(c:open(s.key,'old'));f:finish(c);f:finish(c)
    f.after_dispatch=function(op)
        if op.kind~='write' then return end
        f.after_dispatch=nil
        f:finish(c)
        assert(c:close('old'))
        assert(c:open(s.key,'new'))
    end
    local receipt=c:submit('old','X')
    assert(receipt.session=='old' and receipt.scope==s.key and receipt.revision==1)
    assert(c:status(receipt).state=='stale' and c:status().state=='recovering')
    f:finish(c);assert(f:finish(c).session=='new')
    assert(c:status(receipt).state=='stale' and not c:take_committed('new'))
end
print('scoped transport: isolation, exact identities, retained completion and queue/session integration passed')
