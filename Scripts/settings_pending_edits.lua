-- Pure, default-off server ledger; NO engine calls, callbacks, IO, ACKs or writes.
-- Integration contract (colon methods):
-- bind(peer) ONLY after a fresh authenticated handshake. peer={name,server,client,
-- guild=<proven canonical guild>,epoch}; all scalar strings except positive epoch.
-- Returns a never-reused binding integer. Explicitly invalidate the old binding
-- before replacing a name. Never use client-supplied guild as authentication.
-- reserve(binding,id,stream,exact_command,now) BEFORE mutation. Only status
-- 'reserved' permits calling the mutator ONCE; 'duplicate' never does. Preserve
-- the returned ticket across the synchronous call; no native component retained.
-- accepted(ticket,receipt,now) records false,'pending',receipt, NOT durability.
-- reject(ticket,now) only for definite rejection BEFORE acceptance; a throw/lost
-- result must instead call unknown(ticket,now). Neither cancels native work.
-- complete(ticket,proof,now) ONLY after an attachment-bound durability query AND
-- complete guarded snapshot send. proof includes the EXACT accepted receipt,
-- covered_revision, snapshot_revision. This module checks
-- matching/scalar bounds, not authenticity; it cannot establish durability or
-- attachment ownership. Completion freezes the network revision for ACK replay.
-- covered_revision is the writer revision, NOT a legacy/native journal generation.
-- Duplicate views contain copied receipt/publication metadata, never live tables.
-- expire(now) makes expired reserved/pending records 'unknown', never rejected;
-- late completion is refused. High-water IDs prevent replay after record eviction.
-- invalidate(binding) revokes reply eligibility and forgets that peer's records;
-- close() does so globally and permanently. Neither retires a writer.
-- Writer attachment integers are monotonic within one Lua VM, including module
-- reloads, through its scalar registry allocator. Reset/discard the ledger for a
-- new network/session/VM; these are not persistent or cross-VM identities. A new
-- ledger requires a fresh negotiated session; never reconnect old handles.
-- Caller supplies monotonic elapsed seconds; timeout starts at reservation and
-- duplicates/acceptance do not extend it. No wire changes or integration enabled.
-- Bounds: 128 peers, 128 active reservations globally, one per peer/stream,
-- 128 retained records per peer; oldest terminal records may be evicted.
local M={}
local MAX=2147483647
local function plain(t)return type(t)=='table' and getmetatable(t)==nil end
local function integer(n)return math.type(n)=='integer' and n>0 and n<=MAX end
local function text(s,n)return type(s)=='string' and #s>0 and #s<=n and not s:find('%c') end
local function guid(s)return text(s,32) and #s==32 and not s:find('[^0-9a-f]') and s~=string.rep('0',32)end
local function shape(t,keys)
    if not plain(t)then return false end
    for k in next,t do if not keys[k]then return false end end
    return true
end
local function copy(t)
    local r={};for k,v in pairs(t)do r[k]=type(v)=='table' and copy(v) or v end;return r
end
local peer_keys={name=true,server=true,client=true,guild=true,epoch=true}
local receipt_keys={scope=true,session=true,incarnation=true,epoch=true,revision=true,attachment=true}
local function receipt_ok(r,p,stream)
    if not shape(r,receipt_keys) or not text(r.session,256) or not text(r.incarnation,256)
        or not integer(r.epoch) or r.epoch~=p.identity.epoch or not integer(r.revision) or not integer(r.attachment)
        or not text(r.scope,128)then return false end
    local w,g,s=r.scope:match('^PWP%-SCOPE%-1:([0-9a-f]+):([0-9a-f]+):(%a+)$')
    return guid(w) and g==p.identity.guild and s==stream
end
function M.new(o)
    if not plain(o) or o.enabled~=true then return nil,'disabled' end
    local timeout=o.timeout
    if timeout==nil then timeout=8 end
    if type(timeout)~='number' or timeout~=timeout or timeout<=0 or timeout>8 then return nil,'invalid_timeout' end
    local peers,names,tickets={},{},{}
    local serial,binding_serial,total,peer_count,last,closed=0,0,0,0,0,false
    local api={}
    local function view(r,status)
        local v={status=status or r.state,state=r.state,ticket=r.ticket,id=r.id,
            stream=r.stream,command=r.command,binding=r.binding,deadline=r.deadline}
        if r.receipt then v.receipt=copy(r.receipt)end
        if r.publication then v.publication=copy(r.publication)end
        return v
    end
    local function terminal(r,state)
        if r.state=='reserved' or r.state=='pending' then
            total=total-1;peers[r.binding].active[r.stream]=nil;tickets[r.ticket]=nil
        end
        r.state=state
    end
    local function advance(now)
        if closed then return nil,'closed' end
        if type(now)~='number' or now~=now or now>1e12 or now<last then return nil,'invalid_clock' end
        last=now
        local expired={}
        for _,r in pairs(tickets)do
            if now>=r.deadline then terminal(r,'unknown');expired[#expired+1]=view(r)end
        end
        return expired
    end
    function api:bind(identity)
        if closed then return nil,'closed' end
        if not shape(identity,peer_keys) or not text(identity.name,256) or not text(identity.server,64)
            or not text(identity.client,64) or not guid(identity.guild) or not integer(identity.epoch)then return nil,'invalid_peer' end
        local old=names[identity.name]
        if old then
            for k in pairs(peer_keys)do if peers[old].identity[k]~=identity[k]then return nil,'replacement_requires_invalidation' end end
            return old
        end
        if peer_count>=128 or binding_serial>=MAX then return nil,'peer_capacity' end
        binding_serial=binding_serial+1;peer_count=peer_count+1
        peers[binding_serial]={identity=copy(identity),active={},records={},order={},high=0}
        names[identity.name]=binding_serial;return binding_serial
    end
    function api:reserve(binding,id,stream,command,now)
        local ok,why=advance(now);if not ok then return nil,why end
        local p=peers[binding]
        if not p then return nil,'stale_binding' end
        if not integer(id) or (stream~='limits' and stream~='priorities') or not text(command,768)then return nil,'invalid_request' end
        local r=p.records[id]
        if r then
            if r.command~=command or r.stream~=stream then return nil,'request_id_reused' end
            return view(r,'duplicate')
        end
        if id<=p.high then return nil,'stale_request' end
        -- Remember even capacity refusals: the same ID must not mutate later.
        p.high=id
        if total>=128 or p.active[stream] or serial>=MAX then return nil,'capacity' end
        if #p.order>=128 then
            for i,old in ipairs(p.order)do
                local candidate=p.records[old]
                if candidate.state~='reserved' and candidate.state~='pending' then
                    p.records[old]=nil;table.remove(p.order,i);break
                end
            end
        end
        serial=serial+1
        r={ticket=serial,binding=binding,id=id,stream=stream,command=command,state='reserved',deadline=now+timeout}
        p.records[id]=r;p.order[#p.order+1]=id;p.active[stream]=r;tickets[serial]=r;total=total+1
        return view(r)
    end
    function api:accepted(ticket,receipt,now)
        local ok,why=advance(now);if not ok then return nil,why end
        local r=tickets[ticket]
        if not r or r.state~='reserved' then return nil,'not_reserved' end
        if not receipt_ok(receipt,peers[r.binding],r.stream)then return nil,'invalid_receipt' end
        r.receipt=copy(receipt);r.state='pending';return view(r)
    end
    function api:reject(ticket,now)
        local ok,why=advance(now);if not ok then return nil,why end
        local r=tickets[ticket]
        if not r or r.state~='reserved' then return nil,'not_reserved' end
        terminal(r,'rejected');return view(r)
    end
    function api:unknown(ticket,now)
        local ok,why=advance(now);if not ok then return nil,why end
        local r=tickets[ticket];if not r then return nil,'not_pending' end
        terminal(r,'unknown');return view(r)
    end
    function api:complete(ticket,proof,now)
        local ok,why=advance(now);if not ok then return nil,why end
        local r=tickets[ticket]
        if not r or r.state~='pending' then return nil,'not_pending' end
        if not shape(proof,{receipt=true,covered_revision=true,snapshot_revision=true})
            or not receipt_ok(proof.receipt,peers[r.binding],r.stream)
            or not integer(proof.covered_revision) or proof.covered_revision<r.receipt.revision
            or not integer(proof.snapshot_revision)then return nil,'invalid_completion' end
        for k in pairs(receipt_keys)do if proof.receipt[k]~=r.receipt[k]then return nil,'receipt_mismatch' end end
        r.publication={covered_revision=proof.covered_revision,snapshot_revision=proof.snapshot_revision}
        terminal(r,'durable');return view(r)
    end
    function api:expire(now)return advance(now)end
    function api:invalidate(binding)
        local p=peers[binding];if not p then return false end
        for _,r in pairs(p.active)do terminal(r,'unknown')end
        names[p.identity.name]=nil;peers[binding]=nil;peer_count=peer_count-1;return true
    end
    function api:close()
        closed=true;peers,names,tickets={},{},{};total,peer_count=0,0
    end
    function api:status()return {closed=closed,pending=total,peers=peer_count}end
    return api
end
return M
