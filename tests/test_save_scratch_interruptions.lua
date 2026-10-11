local M = dofile(TEST_ROOT .. '/experiments/save_scratch.lua')
local A, B = 'PWP_SaveScratch_v1_A', 'PWP_SaveScratch_v1_B'
local cases = 0
local function check(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ': ' .. tostring(err))
    cases = cases + 1
end
local function copy(record)
    if not record then return nil end
    local result = {}
    for k, v in pairs(record) do result[k] = v end
    return result
end

-- Disk outlives each simulated process. Persisting a write, completing IO,
-- and delivering its acknowledgement are deliberately separate events.
local function boot(disk, incarnation)
    local f = {disk=disk, calls={}, responses={}, dead=false}
    local function start(kind, record, slot, ticket)
        assert(not f.dead and not f.pending, 'overlapping or dead-process IO')
        assert(slot == A or slot == B)
        local op = {kind=kind, record=copy(record), slot=slot, ticket=ticket}
        f.calls[#f.calls+1] = op
        if f.start_mode == 'reject' then return false end
        f.pending = op
        if f.start_mode == 'throw' then error('IO accepted before adapter threw') end
        if f.start_mode == 'unknown' then return nil end
        return true
    end
    f.q = M.new({
        read=function() error('synchronous IO forbidden') end,
        start=function(r,s,t) return start('write',r,s,t) end,
        start_read=function(s,t) return start('read',nil,s,t) end,
        poll=function(ticket)
            assert(not f.dead and f.pending and f.pending.ticket == ticket)
            if f.poll_mode == 'throw' then error('completion unavailable') end
            if f.poll_mode == 'malformed' then return false end
            if #f.responses > 0 then return table.remove(f.responses,1) end
            local op = f.pending
            if not op.done then return nil end
            f.pending = nil
            return op.done
        end,
    }, 'interruption-owner', incarnation)
    function f:persist(kind)
        local op = assert(self.pending)
        assert(op.kind == 'write')
        if kind == 'partial' then
            self.disk[op.slot] = {session=op.record.session, generation=op.record.generation}
        else
            self.disk[op.slot] = copy(op.record)
            if kind == 'corrupt' then self.disk[op.slot].payload = 'torn payload' end
        end
    end
    function f:complete(success, read)
        local op = assert(self.pending)
        if not read then
            local record = self.disk[op.slot]
            read = record and {status='ok',record=copy(record)} or {status='missing'}
        end
        op.done = {ticket=op.ticket, success=success ~= false, read=read}
        return op.done
    end
    function f:finish(success, read)
        self:complete(success, read)
        return self.q:poll()
    end
    function f:recover()
        assert(self.q:recover() == true and self.pending.slot == A)
        assert(self:finish() == nil and self.pending.slot == B)
        return self:finish()
    end
    function f:save(payload)
        self.q:submit(payload); self:persist(); self:finish()
        assert(self.q:can_shutdown())
    end
    function f:crash()
        -- Process death ends this adapter's IO; only disk survives. No old
        -- queue or callback is reused by a fresh process.
        self.dead, self.pending, self.responses = true, nil, {}
    end
    return f
end
local function seeded()
    local disk = {}
    local f = boot(disk, 'first-process')
    assert(f:recover())
    f:save('previous valid')
    assert(f.q.saved == 1 and disk[A].payload == 'previous valid')
    return disk, f
end

for _, damage in ipairs({'untouched','partial','corrupt'}) do
    check('interrupted target ' .. damage .. ' preserves previous valid slot', function()
        local disk, f = seeded()
        local backup = copy(disk[A])
        f.q:submit('interrupted replacement')
        assert(f.pending.slot == B)
        if damage ~= 'untouched' then f:persist(damage) end
        assert(f.q.saved == 1 and not f.q:can_shutdown())
        f:crash()
        local restart = boot(disk, 'restart')
        local ok, payload = restart:recover()
        assert(ok and payload == 'previous valid' and restart.q.saved == 1)
        assert(disk[A].checksum == backup.checksum and disk[A].payload == backup.payload)
        restart.q:submit('replacement after recovery')
        assert(restart.pending.slot == B, 'must replace damaged target, not valid backup')
        restart:persist(); restart:finish()
        assert(restart.q.saved == 2 and restart.q:can_shutdown())
    end)
end

for _, completed in ipairs({false,true}) do
    check('crash after persistence before ACK, completion queued=' .. tostring(completed), function()
        local disk, f = seeded()
        f.q:submit('newest persisted')
        f:persist()
        if completed then f:complete() end
        assert(f.q.saved == 1 and not f.q:can_shutdown())
        f:crash()
        local restart = boot(disk, 'restart')
        local ok, payload = restart:recover()
        assert(ok and payload == 'newest persisted' and restart.q.saved == 2)
        restart.q:submit('third generation')
        assert(restart.pending.slot == A and restart.pending.record.generation == 3)
        restart:persist(); restart:finish()
        assert(restart.q.saved == 3)
    end)
end

check('definite storage failure remains dirty and explicit retry preserves backup', function()
    local disk, f = seeded()
    f.q:submit('retry me'); f:persist('partial')
    assert(f:finish(false,{status='invalid'}) == false)
    assert(f.q.saved == 1 and f.q.state == 'error' and not f.q:can_shutdown())
    assert(not f.q:reset('premature-reset'))
    local calls = #f.calls
    for _=1,10 do f.q:poll() end
    assert(#f.calls == calls and disk[A].payload == 'previous valid')
    f.q:retry()
    assert(#f.calls == calls+1 and f.pending.slot == B)
    assert(f.pending.record.generation == 2 and f.pending.record.payload == 'retry me')
    f:persist(); f:finish(); f:crash()
    local restart = boot(disk, 'restart')
    local ok, payload = restart:recover()
    assert(ok and payload == 'retry me' and restart.q.saved == 2)
end)

check('stale completion cannot acknowledge or unlock a newer flight', function()
    local _, f = seeded()
    f.q:submit('second'); f:persist()
    local old = f:complete()
    f.q:submit('third queued')
    f.q:poll() -- second acknowledged; third starts automatically
    assert(f.q.saved == 2 and f.pending.record.generation == 3)
    local calls, ticket = #f.calls, f.pending.ticket
    for _=1,3 do
        f.responses[#f.responses+1] = old
        f.q:poll(); f.q:retry()
        assert(f.q.saved == 2 and #f.calls == calls and f.pending.ticket == ticket)
        assert(not f.q:can_shutdown() and not f.q:reset('blocked-reset'))
    end
    f:persist(); f:finish()
    assert(f.q.saved == 3 and f.q:can_shutdown())
end)

for _, kind in ipairs({'read','write'}) do
    for _, start_mode in ipairs({'unknown','throw'}) do
        check(kind .. ' uncertain IO stays locked: ' .. start_mode, function()
            local disk, seeded_process = seeded()
            local f = seeded_process
            if kind == 'read' then f:crash(); f = boot(disk,'reader') end
            f.start_mode = start_mode
            if kind == 'read' then f.q:recover() else f.q:submit('in flight'); f:persist() end
            local calls, ticket, saved = #f.calls, f.pending.ticket, f.q.saved
            for _, poll_mode in ipairs({'pending','throw','malformed','ambiguous'}) do
                f.poll_mode = poll_mode
                for _=1,5 do
                    if poll_mode == 'ambiguous' then
                        f.responses[#f.responses+1] = {ticket=ticket,success='unknown'}
                    end
                    f.q:poll(); f.q:retry()
                    assert(#f.calls == calls and f.pending.ticket == ticket and f.q.saved == saved)
                    assert(not f.q:can_shutdown() and not f.q:reset('unsafe-reset'))
                    assert(not pcall(f.q.recover,f.q))
                end
            end
            f.start_mode, f.poll_mode = nil, nil
            f:finish()
            if kind == 'read' then assert(f.pending.slot == B); assert(f:finish()) end
            assert(f.q:can_shutdown() and f.q.saved == (kind == 'read' and 1 or 2))
        end)
    end
end

check('unreadable recovery target does not silently fall back to older backup', function()
    local disk, f = seeded()
    f.q:submit('possibly newest'); f:persist(); f:crash()
    local restart = boot(disk,'restart')
    restart.q:recover(); restart:finish()
    assert(restart:finish(false,{status='unreadable'}) == false)
    assert(restart.q.state == 'error' and not pcall(restart.q.submit,restart.q,'overwrite'))
    local calls = #restart.calls
    restart.q:retry(); assert(#restart.calls == calls)
    local ok, payload = restart:recover() -- explicit read recovery when storage is readable
    assert(ok and payload == 'possibly newest' and restart.q.saved == 2)
end)

print('scratch interruptions: ' .. cases .. ' persisted-storage cases passed')
