-- Isolated adapter for the NEXT native bridge contract. V2/V3 are incompatible.
-- No actual Engine backend is implemented here. Backend calls run on the game
-- thread; they accept/return copied scalar tables, never retained UObjects.
-- dispatch(op): true accepted; false definitely not started; else uncertain.
-- peek(identity): nil pending, or a retained terminal envelope with full identity.
-- consume(identity): true only after matching terminal mailbox acknowledgement;
-- MUST be idempotent and must never acknowledge a different operation.
-- Native admission must enforce one owner across reloads, monotonic tickets and
-- a surviving world-lifetime fence. A Lua table or this version tag cannot prove
-- those guarantees. No production caller may use an unverified implementation.
local Scope=dofile((debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/save_transport.lua$'))..'/save_scope.lua')
local M={}
local A,B='PWP_SaveScratch_v1_A','PWP_SaveScratch_v1_B'
local function integer(n) return math.type(n)=='integer' and n>0 and n<2147483647 end
local function capacity(n)
    if n==nil then return 65536 end
    assert(math.type(n)=='integer' and n>=65536 and n<=262144,'unsupported payload capacity')
    return n
end
local function record(r,max_payload_bytes)
    if type(r)~='table' or type(r.session)~='string' or #r.session>256
        or not integer(r.generation) or type(r.payload)~='string' or #r.payload>max_payload_bytes
        or type(r.checksum)~='string' or #r.checksum~=8 or not r.checksum:match('^[0-9a-f]+$') then return end
    return {session=r.session,generation=r.generation,payload=r.payload,checksum=r.checksum}
end
local function identity(op)
    return {scope=op.scope,incarnation=op.incarnation,ticket=op.ticket,kind=op.kind,slot=op.slot,
        max_payload_bytes=op.max_payload_bytes}
end
local function same(a,b)
    return type(a)=='table' and a.scope==b.scope and a.incarnation==b.incarnation
        and a.ticket==b.ticket and a.kind==b.kind and a.slot==b.slot
        and (a.max_payload_bytes==b.max_payload_bytes
            or (a.max_payload_bytes==nil and b.max_payload_bytes==65536))
end
function M.new(options)
    assert(type(options)=='table' and options.enabled==true,'development opt-in required')
    local scope=Scope.new(options.storage,options.guild,options.stream)
    local incarnation=options.incarnation
    assert(type(incarnation)=='string' and #incarnation>0 and #incarnation<=256)
    local backend=options.backend
    assert(type(backend)=='table' and backend.contract=='PWP-SCOPED-DEV-1'
        and type(backend.dispatch)=='function' and type(backend.peek)=='function'
        and type(backend.consume)=='function','scoped native contract required; V3 is not compatible')
    -- An absent advertisement is the legacy 64 KiB contract, never an upgrade.
    -- Capture the exact agreement once; later table mutation cannot enlarge it.
    local max_payload_bytes=capacity(options.max_payload_bytes)
    assert(capacity(backend.max_payload_bytes)==max_payload_bytes,'backend payload capacity mismatch')
    local flight,last_ticket,polling=nil,0,false
    local adapter={max_payload_bytes=max_payload_bytes}
    local function start(kind,r,slot,ticket)
        assert(slot==A or slot==B,'unknown logical slot')
        assert(integer(ticket) and ticket>last_ticket,'operation ticket must increase')
        if flight then return false end
        local copied=r and record(r,max_payload_bytes)
        assert(kind~='write' or (copied and copied.session==scope.key),'foreign or invalid write record')
        local op={scope=scope.key,incarnation=incarnation,ticket=ticket,kind=kind,
            slot=slot==A and scope.a or scope.b,max_payload_bytes=max_payload_bytes}
        flight,last_ticket=op,ticket
        local request=identity(op);request.record=copied
        local ok,accepted=pcall(backend.dispatch,request)
        -- A synchronous completion may already have drained this exact op.
        if flight~=op then return ok and accepted or nil end
        if ok and accepted==false then flight=nil;return false end
        if ok and accepted==true then return true end
        return nil -- thrown dispatch may already own native IO
    end
    function adapter.start(r,s,t) return start('write',r,s,t) end
    function adapter.start_read(s,t) return start('read',nil,s,t) end
    local function poll(ticket)
        local op=flight
        if not op or ticket~=op.ticket then return end
        if not op.result then
            local result=backend.peek(identity(op))
            -- Capacity is part of the terminal identity. A mismatch cannot
            -- authorize consumption/release; keep ownership for a matching result.
            if result==nil or not same(result,op) then return end
            assert(result.terminal==true and type(result.success)=='boolean','nonterminal or ambiguous completion')
            local read=result.read
            assert(type(read)=='table','missing read classification')
            local status=read.status
            assert(status=='ok' or status=='missing' or status=='invalid' or status=='unreadable',
                'unknown read classification')
            local copied
            -- An oversized persisted record may be valid under a newer reader.
            -- Override even an erroneous invalid/missing label when data exists.
            if type(read.record)=='table' and type(read.record.payload)=='string'
                and #read.record.payload>max_payload_bytes then
                status='unreadable'
            end
            if status=='ok' then
                -- A foreign record is NOT corrupt data we may replace after
                -- finding a valid alternate slot. It stops the entire recovery.
                if type(read.record)~='table' or read.record.session~=scope.key then
                    status='unreadable'
                else
                    copied=record(read.record,max_payload_bytes)
                    if not copied then status='invalid' end
                end
            end
            op.result={ticket=ticket,success=result.success,read={status=status,record=copied}}
        end
        -- Hold local ownership until the backend releases its retained mailbox.
        -- A failed/throwing acknowledgement can be retried, never the actual IO.
        if backend.consume(identity(op))~=true then return end
        flight=nil
        return op.result
    end
    function adapter.poll(ticket)
        if polling then return end
        polling=true
        local ok,value=pcall(poll,ticket)
        polling=false
        if not ok then error(value,0) end
        return value
    end
    return adapter,scope.key
end
return M
