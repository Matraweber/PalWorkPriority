local M = dofile(TEST_ROOT .. '/experiments/save_scratch.lua')
local A, B = 'PWP_SaveScratch_v1_A', 'PWP_SaveScratch_v1_B'
local cases = 0
local function check(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ': ' .. tostring(err)); cases = cases + 1
end
local function fixture(files)
    local f = {files=files or {}, calls={}, pending=nil}
    local function begin(kind, record, slot, ticket)
        assert(not f.pending, 'overlapping operation')
        assert(slot == A or slot == B)
        f.calls[#f.calls+1] = {kind=kind, record=record, slot=slot, ticket=ticket}
        if f.start_mode == 'reject' then return false end
        f.pending = f.calls[#f.calls]
        if f.start_mode == 'throw' then error('accepted then threw') end
        if f.start_mode == 'nil' then return nil end
        return true
    end
    f.adapter = {
        read=function() error('synchronous read forbidden') end,
        start=function(r,s,t) return begin('write',r,s,t) end,
        start_read=function(s,t) return begin('read',nil,s,t) end,
        poll=function(ticket)
            assert(f.pending and ticket == f.pending.ticket)
            if f.poll_mode == 'throw' then error('poll unavailable') end
            if f.poll_mode == 'malformed' then return 7 end
            if f.poll_mode == 'false' then return false end
            if f.poll_mode == 'wrong_ticket' then return {ticket=ticket-1,success=true} end
            if f.poll_mode == 'ambiguous' then return {ticket=ticket,success='yes'} end
            if not f.pending.done then return nil end
            local p = f.pending; f.pending = nil
            if p.kind == 'write' and not p.fail then f.files[p.slot] = p.record end
            if p.override then return p.result end
            local read = f.files[p.slot] and {status='ok',record=f.files[p.slot]} or {status='missing'}
            return {ticket=p.ticket, success=not p.fail, read=read}
        end,
    }
    function f:queue(session) return M.new(self.adapter,'owner',session or 'session-a') end
    function f:finish(q, result)
        assert(self.pending)
        if result then
            result.ticket = self.pending.ticket
            self.pending.override, self.pending.result = true, result
        end
        self.pending.done = true
        return q:poll()
    end
    function f:recover(q)
        local n = #self.calls
        assert(q:recover() == true and #self.calls == n+1 and self.pending.slot == A)
        assert(not pcall(q.submit,q,'too early') and not q:can_shutdown())
        q:poll(); assert(#self.calls == n+1)
        assert(self:finish(q) == nil and #self.calls == n+2 and self.pending.slot == B)
        assert(not pcall(q.submit,q,'still too early'))
        local ok, payload = self:finish(q)
        assert(ok and #self.calls == n+2 and q:can_shutdown())
        return payload
    end
    return f
end

check('delayed recovery, coalescing and delayed save/readback', function()
    local f=fixture(); local q=f:queue()
    assert(not pcall(q.submit,q,'before recovery'))
    assert(f:recover(q)==nil and q.saved==0)
    q:submit('1|X'); q:submit('2|X'); q:submit('3|X')
    local n=#f.calls; assert(n==3 and f.pending.record.payload=='1|X')
    -- Platform write finished, but async readback has not completed.
    f.files[f.pending.slot]=f.pending.record
    q:poll(); assert(q.saved==0 and #f.calls==n and not q:can_shutdown())
    f:finish(q); assert(q.saved==1 and #f.calls==n+1 and f.pending.record.payload=='3|X')
    assert(f.calls[n].slot~=f.pending.slot)
    f:finish(q); assert(q.saved==3 and q.state=='saved' and q:can_shutdown())
    local reload=f:queue('new-incarnation')
    assert(f:recover(reload)=='3|X' and reload.saved==3)
    assert(not pcall(q.submit,q,string.rep('x',65537)))
end)

check('failed saves and corrupt readback retain dirty data and backup', function()
    local f=fixture();local q=f:queue();f:recover(q)
    q:submit('old');f:finish(q)
    q:submit('new');f.pending.fail=true;f:finish(q)
    assert(q.saved==1 and q.state=='error' and not q:can_shutdown())
    assert(not q:reset('b'))
    assert(f:recover(f:queue('restart'))=='old')
    q:retry();f:finish(q,{success=true,read={status='ok',record={}}})
    assert(q.saved==1 and q.state=='error')
    q:retry();f:finish(q);assert(q.saved==2 and q.state=='saved')
    q:submit('inflight');assert(not q:reset('b'));f:finish(q)
    assert(q:reset('b') and not pcall(q.submit,q,'before reload'))
    assert(f:recover(q)=='inflight' and q.saved==3)
end)

for _, kind in ipairs({'read','write'}) do
    for _, mode in ipairs({'nil','throw'}) do
        check(kind .. ' uncertain start ' .. mode, function()
            local f=fixture();local q=f:queue()
            if kind=='write' then f:recover(q) end
            f.start_mode=mode
            if kind=='read' then q:recover() else q:submit('payload') end
            local n=#f.calls
            assert(q.state=='uncertain' and not q:can_shutdown() and not q:reset('b'))
            q:retry();q:poll();assert(#f.calls==n)
            assert(not pcall(q.recover,q))
            f.start_mode=nil;f:finish(q)
            if kind=='read' then assert(#f.calls==n+1);f:finish(q) end
            assert(q:can_shutdown())
        end)
    end
    for _, mode in ipairs({'throw','malformed','false','wrong_ticket','ambiguous'}) do
        check(kind .. ' uncertain poll ' .. mode, function()
            local f=fixture();local q=f:queue()
            if kind=='write' then f:recover(q);q:submit('payload') else q:recover() end
            local n=#f.calls;f.poll_mode=mode;q:poll();q:retry()
            assert(#f.calls==n and not q:can_shutdown() and not q:reset('b'))
            f.poll_mode=nil;f:finish(q)
            if kind=='read' then f:finish(q) end
            assert(q:can_shutdown())
        end)
    end
end

check('definite rejection and failed B start do not authorize writes', function()
    local f=fixture();local q=f:queue();f.start_mode='reject'
    assert(q:recover()==false and q.state=='error' and q:can_shutdown())
    assert(not pcall(q.submit,q,'blocked'))
    f.start_mode=nil;q:recover();f.start_mode='reject'
    assert(f:finish(q)==false and q.state=='error' and not pcall(q.submit,q,'blocked'))
    f.start_mode=nil;f:recover(q)
    f.start_mode='reject';q:submit('dirty')
    assert(q.state=='error' and not q:can_shutdown() and not q:reset('b'))
    f.start_mode=nil;q:retry();f:finish(q);assert(q.saved==1)
end)

local bad_reads={
    {success=false}, {success=true}, {success=true,read=false},
    {success=true,read={}}, {success=false,read={status='unreadable'}},
    {success=true,read={status='unknown'}}, {success=false,read={status='ok',record={}}},
}
for i, response in ipairs(bad_reads) do
    check('failed/ambiguous recovery read ' .. i, function()
        local f=fixture();local q=f:queue();f:recover(q)
        q:recover();local n=#f.calls
        assert(f:finish(q,response)==false and #f.calls==n)
        assert(q.state=='error' and not pcall(q.submit,q,'blocked after rerecovery'))
    end)
    check('failed/ambiguous save readback ' .. i, function()
        local f=fixture();local q=f:queue();f:recover(q);q:submit('payload')
        f:finish(q,response)
        assert(q.state=='error' and q.saved==0 and not q:can_shutdown())
        q:retry();f:finish(q);assert(q.saved==1)
    end)
end

check('both invalid and invalid/missing refuse initialization', function()
    for _, second in ipairs({'invalid','missing'}) do
        local f=fixture();local q=f:queue();q:recover()
        f:finish(q,{success=false,read={status='invalid'}})
        assert(f:finish(q,{success=false,read={status=second}})==false)
        assert(not pcall(q.submit,q,'blocked'))
    end
end)

check('valid backup plus invalid newer, copied recovery records', function()
    local f=fixture();local q=f:queue();f:recover(q);q:submit('backup');f:finish(q)
    q:submit('newer');f:finish(q);f.files[B]={payload='corrupt'}
    local r=f:queue('restart');r:recover();f:finish(r)
    f.files[A].payload='mutated after completion'
    local ok,payload=f:finish(r,{success=false,read={status='invalid'}})
    assert(ok and payload=='backup' and r.saved==1)
    r:submit('replacement');assert(f.pending.slot==B);f:finish(r)
end)

check('same-generation conflicting valid records fail closed', function()
    local function record(payload)
        local f=fixture();local q=f:queue();f:recover(q);q:submit(payload);f:finish(q)
        return f.files[A]
    end
    local f=fixture({[A]=record('one'),[B]=record('two')});local q=f:queue();q:recover();f:finish(q)
    assert(f:finish(q)==false and not pcall(q.submit,q,'blocked'))
end)

check('B failure cannot accept valid A; scope/checksum validation', function()
    local f=fixture();local q=f:queue();f:recover(q);q:submit('old');f:finish(q)
    q:recover();f:finish(q)
    assert(f:finish(q,{success=false,read={status='unreadable'}})==false)
    assert(not pcall(q.submit,q,'blocked'))
    local foreign=M.new(f.adapter,'foreign-owner','new');local prior=#f.calls
    foreign:recover()
    assert(f:finish(foreign)==false and not pcall(foreign.submit,foreign,'blocked'))
    assert(#f.calls==prior+1 and f.pending==nil,'foreign record must stop before reading another slot')
    f.files[A].checksum='wrong'
    local r=f:queue();r:recover();f:finish(r);assert(f:finish(r)==false)
end)

for _, mode in ipairs({'nil','throw'}) do
    check('uncertain B start remains locked ' .. mode, function()
        local f=fixture();local q=f:queue();q:recover();f.start_mode=mode;f:finish(q)
        local n=#f.calls;assert(n==2 and q.state=='uncertain')
        q:poll();q:retry();assert(#f.calls==n and not q:can_shutdown())
        assert(not pcall(q.submit,q,'blocked') and not q:reset('b'))
        f.start_mode=nil;assert(f:finish(q)==true and #f.calls==n)
    end)
end

check('positive missing statuses may accompany unsuccessful engine loads', function()
    local f=fixture();local q=f:queue();q:recover()
    f:finish(q,{success=false,read={status='missing'}})
    local ok,payload=f:finish(q,{success=false,read={status='missing'}})
    assert(ok and payload==nil and q.state=='idle' and q.saved==0)
    q:submit('permitted');f:finish(q);assert(q.saved==1)
end)

check('adapter mutation and valid but wrong readback cannot acknowledge', function()
    local f=fixture();local q=f:queue();f:recover(q)
    q:submit('original');f.pending.record.payload='adapter changed the copy';f:finish(q)
    assert(q.saved==0 and q.state=='error')
    q:retry();assert(f.pending.record.payload=='original');f:finish(q)
    local old=f.files[A]
    q:submit('new');f:finish(q,{success=true,read={status='ok',record=old}})
    assert(q.saved==1 and q.state=='error' and not q:can_shutdown())
end)

print('scratch async queue: ' .. cases .. ' cases passed; no synchronous reads')
