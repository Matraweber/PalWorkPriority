-- Isolated Lua adapter for the fixed-root native whole-journal bridge.
-- No path argument, engine access, production wiring, migration or automatic retry.
-- The caller proves current local scope and supplies an already bound native ID.
-- schedule(worker) and resume(game_callback) MUST use the runtime's worker/game
-- routes. A failure after native admission retains ownership, even if not queued.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/save_native_backend.lua$'))
local Scope=dofile(root..'/save_scope.lua')
local M={}
local MAX_WIRE=600000
local HEX={}
for i=0,255 do HEX[string.char(i)]=string.format('%02x',i) end
local function integer(n) return math.type(n)=='integer' and n>0 and n<2147483647 end
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function number(s,zero)
    if type(s)~='string' or not s:match('^%d+$') then return end
    local n=math.tointeger(tonumber(s))
    if n and n>= (zero and 0 or 1) and n<=4294967295 and tostring(n)==s then return n end
end
function M.pack(fields)
    assert(plain(fields) and #fields<=16,'field list')
    for k in pairs(fields) do
        assert(math.type(k)=='integer' and k>=1 and k<=#fields,'dense field list')
    end
    local out,total={},0
    for _,value in ipairs(fields) do
        assert(type(value)=='string','wire string required')
        total=total+4+#value;assert(total<=MAX_WIRE,'wire capacity')
        out[#out+1]=string.pack('<I4',#value)..value
    end
    return table.concat(out)
end
function M.unpack(bytes,count)
    assert(type(bytes)=='string' and #bytes<=MAX_WIRE and math.type(count)=='integer'
        and count>=0 and count<=16,'wire shape')
    local out,at={},1
    for i=1,count do
        assert(at+3<=#bytes,'truncated field length')
        local n;n,at=string.unpack('<I4',bytes,at)
        assert(n<=#bytes-at+1,'truncated field')
        out[i]=bytes:sub(at,at+n-1);at=at+n
    end
    assert(at==#bytes+1,'trailing fields')
    return out
end
function M.call(native,command,handle,ticket,fields)
    local bytes=M.pack(fields)
    local hex=bytes:gsub('.',HEX)
    local r=table.pack(native(command,handle,ticket,hex,#hex))
    assert(r.n==6 and math.type(r[1])=='integer' and type(r[2])=='string'
        and #r[2]<=MAX_WIRE,'native reply shape')
    for i=3,6 do assert(math.type(r[i])=='integer','native metadata') end
    assert(r[3]>0 and r[4]>=0 and r[5]>=r[4] and r[6]>0,'native clock/thread')
    return r
end
local function copy(result)
    local out={}
    for k,v in pairs(result) do
        if k~='slots' then out[k]=v end
    end
    if result.slots then
        out.slots={}
        for i=1,2 do out.slots[i]={};for k,v in pairs(result.slots[i]) do out.slots[i][k]=v end end
    end
    return out
end
function M.new(options)
    assert(plain(options) and options.enabled==true,'development opt-in required')
    local native,schedule,resume=options.native,options.schedule,options.resume
    local handle,game=options.binding,options.game_thread
    local incarnation,epoch=options.incarnation,options.epoch
    local scope=Scope.new(options.storage,options.guild,options.stream).key
    local max=options.max_payload_bytes or 65536
    assert(type(native)=='function' and type(schedule)=='function' and type(resume)=='function'
        and integer(handle) and integer(game) and integer(epoch)
        and type(incarnation)=='string' and #incarnation>0 and #incarnation<=256
        and math.type(max)=='integer' and max>=65536 and max<=262144,'backend configuration')
    local flight,busy,last_ticket,last_consumed=nil,false,0,nil
    local function matches(identity,op)
        return plain(identity) and op and identity.scope==scope and identity.incarnation==incarnation
            and identity.epoch==epoch and identity.ticket==op.ticket and identity.kind==op.kind
            and identity.max_payload_bytes==max
    end
    local function control(command,ticket,fields)
        local r=M.call(native,command,handle,ticket,fields)
        assert(r[3]==game,'wrong control thread');return r
    end
    local function dispatch(request,kind)
        if flight or not plain(request) or not integer(request.ticket) or request.ticket<=last_ticket then return false end
        local op={ticket=request.ticket,kind=kind}
        if not matches(request,op) then return false end
        local fields={}
        if kind=='update' then
            if type(request.preimages)~='string' or #request.preimages==0 or #request.preimages>256
                or type(request.payload)~='string' or #request.payload>max
                or not integer(request.journal_generation) or not integer(request.covered_revision)
                or type(request.initialize)~='boolean' then return false end
            fields={request.preimages,request.payload,tostring(request.journal_generation),
                tostring(request.covered_revision),request.initialize and '1' or '0'}
        end
        flight,last_ticket=op,op.ticket
        local ok,r=pcall(control,kind=='recover' and 2 or 3,op.ticket,fields)
        if ok and r[1]==0 then flight=nil;return false end
        if not ok or r[1]~=1 or r[2]~='' then return nil end
        -- No wrappers or mutable request table reach the worker. It retains only
        -- this immutable ticket, binding ID and the original native function.
        local accepted,scheduled=pcall(schedule,function()
            local ran,reply=pcall(M.call,native,4,handle,op.ticket,{})
            pcall(resume,function()
                if flight~=op then return end
                op.worker_route_ok=ran and reply[1]==1 and reply[3]~=game
                -- Diagnostic only. Native retained mailbox decides completion;
                -- lost callback/return cannot cause another write or false ACK.
            end)
        end)
        if not accepted or scheduled==false then return nil end
        return true -- reservation already exists even on scheduler refusal
    end
    local function peek(identity)
        local op=flight
        if not matches(identity,op) then return end
        if op.result then return copy(op.result) end
        local reply=control(5,op.ticket,{})
        if reply[1]==2 and reply[2]=='' then return end
        assert(reply[1]==1,'peek failed')
        local f=M.unpack(reply[2],16)
        assert(f[1]==scope and f[2]==incarnation and number(f[3])==epoch,'native binding mismatch')
        assert(f[5]=='0' or f[5]=='1','certainty')
        local result={scope=scope,incarnation=incarnation,epoch=epoch,ticket=op.ticket,kind=op.kind,
            max_payload_bytes=max,terminal=true,certain=f[5]=='1',status=f[4],
            journal_generation=assert(number(f[6],true)),covered_revision=assert(number(f[7],true)),
            preimages=f[8],error=assert(number(f[9],true)),cleanup_error=assert(number(f[10],true))}
        assert(#result.preimages<=256,'preimage token')
        if op.kind=='recover' and result.status=='recovered' then
            result.slots={}
            for i=1,2 do
                local at=i==1 and 11 or 14
                local status=f[at]
                assert(status=='valid' or status=='missing' or status=='corrupt' or status=='unsupported'
                    or status=='foreign' or status=='unreadable','slot classification')
                local slot={status=status}
                if status=='valid' then
                    slot.scope=scope;slot.generation=assert(number(f[at+1]));slot.payload=f[at+2]
                    assert(#slot.payload<=max,'payload capacity')
                else assert(f[at+1]=='0' and f[at+2]=='','nonvalid record contents') end
                result.slots[i]=slot
            end
        else
            for i=11,16 do assert(f[i]=='','unexpected update slots') end
        end
        op.result=result;return copy(result)
    end
    local function consume(identity)
        local op=flight
        if matches(identity,last_consumed) then return true end
        if not matches(identity,op) or not op.result or op.result.certain~=true then return false end
        local r=control(6,op.ticket,{})
        if r[1]~=1 or r[2]~='' then return false end
        last_consumed=op;flight=nil;return true
    end
    local function guard(fn)
        return function(...)
            if busy then return nil end
            busy=true;local out=table.pack(pcall(fn,...));busy=false
            if not out[1] then error(out[2],0) end
            return table.unpack(out,2,out.n)
        end
    end
    return {contract='PWP-JOURNAL-DEV-1',max_payload_bytes=max,
        recover=guard(function(r)return dispatch(r,'recover')end),
        update=guard(function(r)return dispatch(r,'update')end),peek=guard(peek),consume=guard(consume)}
end
return M
