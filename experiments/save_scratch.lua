-- Isolated prototype: deliberately outside Scripts and never required by main.
-- Adapter owns Engine objects; this queue owns only copied strings/numbers.
-- start(record, slot, ticket) owns async save AND readback as one operation.
-- start_read(slot, ticket) owns one async recovery read. Both return true
-- accepted / false definitely not started; any other result is uncertain.
-- poll(ticket) -> nil pending / {ticket, success=boolean, read={status=...}}.
-- Read statuses: 'ok' with record, 'missing', 'invalid', or 'unreadable'.
-- For recovery, success=false may accompany positively identified missing or
-- invalid data. It never turns an ambiguous failure into proof of absence.
-- Completion means ALL IO stopped. No synchronous read method is called.
-- recover() starts A and returns true/false/nil for accepted/rejected/uncertain.
-- poll() advances recovery to B, then returns true,payload (nil if empty),
-- false on failure, or nil while pending. recovered_payload exposes the result.
-- Engine LoadGameFromSlot returning nil does NOT establish a missing slot.
-- All adapter methods MUST run on the game thread. No Lua worker callbacks.
local M = {}
local A, B = 'PWP_SaveScratch_v1_A', 'PWP_SaveScratch_v1_B'
local function capacity(n)
    if n==nil then return 65536 end
    assert(math.type(n)=='integer' and n>=65536 and n<=262144,'unsupported payload capacity')
    return n
end
local function checksum(session, generation, payload)
    local text = string.format('PWP-SCRATCH-1:%d:%s:%d:%s', #session, session, generation, payload)
    local h = 2166136261
    for i = 1, #text do h = ((h ~ text:byte(i)) * 16777619) & 0xffffffff end
    return string.format('%08x', h)
end
local function valid(r, session, max_payload_bytes)
    return type(r) == 'table' and r.session == session and type(r.payload) == 'string'
        and #r.payload <= max_payload_bytes and math.type(r.generation) == 'integer'
        and r.generation > 0 and r.generation < 2147483647
        and r.checksum == checksum(session, r.generation, r.payload)
end
function M.new(adapter, scope, session, options)
    assert(options==nil or type(options)=='table')
    local max_payload_bytes=capacity(options and options.max_payload_bytes)
    -- Required by a future settings integration; absent only for raw-byte
    -- diagnostics. Policy must be pure/nonreentrant, return literal true and
    -- validate supported settings semantics, not merely an integrity checksum.
    local validate_payload=options and options.validate_payload
    assert(validate_payload==nil or type(validate_payload)=='function','invalid payload validator')
    local function supported(payload)
        if not validate_payload then return true end
        local ok,answer=pcall(validate_payload,payload)
        return ok and answer==true
    end
    assert(type(adapter)=='table' and capacity(adapter.max_payload_bytes)==max_payload_bytes,
        'adapter payload capacity mismatch')
    assert(type(scope) == 'string' and #scope > 0 and #scope <= 256)
    session = session or 'initial'
    assert(type(session) == 'string' and #session > 0 and #session <= 256)
    local q = {session = session, generation = 0, saved = 0, ticket = 0, state = 'unrecovered',
        max_payload_bytes=max_payload_bytes}
    local flight, latest, last_slot, recovered, recovery
    local function copy(r)
        return {session=r.session, generation=r.generation, payload=r.payload, checksum=r.checksum}
    end
    local function launch(kind, slot, record)
        assert(not flight, 'overlapping scratch operation')
        q.ticket = q.ticket + 1
        local op = {kind=kind, record=record, slot=slot, ticket=q.ticket, session=q.session}
        flight = op
        local ok, accepted
        if kind == 'read' then ok, accepted = pcall(adapter.start_read, slot, op.ticket)
        else ok, accepted = pcall(adapter.start, copy(record), slot, op.ticket) end
        if flight ~= op then return end
        if ok and accepted == false then
            flight, recovery = nil, nil; q.state = 'error'; return false
        end
        -- A thrown/ambiguous start may already have enqueued IO. Keep the lock;
        -- only matching completion can release it. Never retry on a timeout.
        if ok and accepted == true then
            q.state = kind == 'read' and 'recovering' or 'saving'; return true
        end
        q.state = 'uncertain'; return nil
    end
    local function issue()
        if flight or not latest then return end
        return launch('write', last_slot == A and B or A, latest)
    end
    function q:recover()
        assert(not flight and not latest, 'recovery requires an idle queue')
        recovered = false
        self.recovered_payload = nil
        recovery = {missing=0}
        return launch('read', A)
    end
    function q:submit(payload)
        assert(recovered, 'successful scratch recovery required before writing')
        assert(type(payload) == 'string' and #payload <= max_payload_bytes)
        assert(supported(payload),'unsupported settings snapshot')
        assert(self.generation < 2147483646, 'scratch generation exhausted')
        self.generation = self.generation + 1
        local assigned = self.generation
        -- Persist stable owner/scope, never an incarnation token. The field is
        -- named session only to match the prototype asset's existing schema.
        latest = {session=scope, generation=self.generation, payload=payload,
            checksum=checksum(scope, self.generation, payload)}
        issue(); return assigned
    end
    function q:poll()
        if not flight then return end
        local op = flight
        local ok, result = pcall(adapter.poll, op.ticket)
        if flight ~= op then return end
        if not ok then self.state = 'uncertain'; return end
        if result == nil then return end
        if type(result) ~= 'table' then self.state = 'uncertain'; return end
        if result.ticket ~= op.ticket then return end
        if type(result.success) ~= 'boolean' then self.state = 'uncertain'; return end
        local done, read = op, result.read
        flight = nil
        if done.session ~= self.session then
            recovery, recovered = nil, false
            self.state = 'error'; return false
        end
        if done.kind == 'read' then
            local batch = recovery
            local status = type(read) == 'table' and read.status
            local observed = type(read)=='table' and read.record
            local observed_valid = valid(observed, scope, max_payload_bytes)
            -- Independently refuse unsupported persisted sizes, even if an
            -- adapter labels them invalid/missing. Never fall back and overwrite.
            if type(observed)=='table' and type(observed.payload)=='string'
                and #observed.payload>max_payload_bytes then
                recovery, recovered = nil, false
                self.state = 'error'; return false
            end
            -- Do not trust a lower-layer label over conflicting copied bytes.
            -- Foreign data is not replaceable corruption. A valid record cannot
            -- be missing/invalid, nor can any returned record prove absence.
            if (type(observed)=='table' and type(observed.session)=='string' and observed.session~=scope)
                or (observed_valid and status~='ok') or (status=='missing' and observed~=nil) then
                recovery, recovered = nil, false
                self.state = 'error'; return false
            end
            if not batch or (status ~= 'ok' and status ~= 'missing' and status ~= 'invalid')
                or (status == 'ok' and not result.success) then
                recovery = nil; self.state = 'error'; return false
            end
            if status == 'missing' then batch.missing = batch.missing + 1 end
            local r = status == 'ok' and read.record or nil
            if status == 'ok' and observed_valid then
                -- A checksum-valid record may belong to a newer settings
                -- schema. Do not select the older slot and overwrite it.
                if not supported(r.payload) then
                    recovery, recovered = nil, false
                    self.state = 'error'; return false
                end
                if batch.best and r.generation == batch.best.generation and r.payload ~= batch.best.payload then
                    recovery = nil; self.state = 'error'; return false
                end
                if not batch.best or r.generation > batch.best.generation then
                    batch.best, batch.slot = copy(r), done.slot
                end
            end
            if done.slot == A then
                if launch('read', B) == false then return false end
                return
            end
            recovery = nil
            if not batch.best and batch.missing ~= 2 then self.state = 'error'; return false end
            recovered = true
            local best = batch.best
            self.generation, self.saved = best and best.generation or 0, best and best.generation or 0
            last_slot = batch.slot
            self.recovered_payload = best and best.payload or nil
            self.state = best and 'saved' or 'idle'
            return true, self.recovered_payload
        end
        local record = type(read) == 'table' and read.status == 'ok' and read.record
        local good = result.success and valid(record, done.record.session, max_payload_bytes)
            and record.generation == done.record.generation and record.payload == done.record.payload
        if not good then self.state = 'error'; return false end
        last_slot, self.saved = done.slot, done.record.generation
        if latest and latest.generation == self.saved then latest = nil end
        self.state = latest and 'dirty' or 'saved'; issue()
    end
    function q:retry() if not flight and latest then issue() end end
    -- A deadline stops us claiming progress; it does not cancel native IO.
    -- Keep flight/latest locked until the adapter supplies a terminal result.
    function q:timeout()
        if flight then self.state = 'uncertain'; return true end
        return false
    end
    function q:reset(session_key)
        assert(type(session_key) == 'string' and #session_key > 0 and #session_key <= 256)
        -- An incarnation token, not a reusable map name, is required.
        assert(session_key ~= self.session, 'reset needs a new session token')
        if flight or latest then return false, 'save must drain before reset' end
        self.session, self.generation, self.saved = session_key, 0, 0
        latest, last_slot, recovered, recovery = nil, nil, false, nil
        self.recovered_payload = nil
        self.state = 'unrecovered'; return true
    end
    function q:can_shutdown() return not flight and not latest end
    return q
end
return M
