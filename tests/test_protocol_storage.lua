-- Pure wire fixtures: no engine, filesystem, transport, deploy or game actions.
local p = require("protocol")
assert(p.SCHEMA == 4)

local function view(overrides)
    local v = {scope="camp", camp="camp-A", choices={"camp-B", "camp-A"},
        verified=true, totals={Ore=12, Wood=0, ["Mod.Item"]=7}, age_ms=2000, remaining_ms=58000}
    for k, value in pairs(overrides or {}) do v[k] = value end
    return v
end
local function receiver(request, scope, camp, now)
    local s = p.receiver("server", "client", "guild")
    assert(p.expect_storage(s, request or "req-1", scope or "camp", camp or "camp-A", now or 0))
    return s
end
local function encode(v, revision, request)
    return assert(p.storage_snapshot("server", "client", "guild", revision or 1, request or "req-1", v or view()))
end
local function deliver(s, batch, now)
    local event
    for i, wire in ipairs(batch) do
        assert(#wire <= p.MAX_PACKET)
        local got, err = p.receive(s, wire, now or 0)
        assert(not err, tostring(err))
        if i < #batch then assert(not got, "partial state escaped") else event = got end
    end
    return assert(event)
end
local function raw(rows, revision)
    local out = {"PWP_V2|B|server|client|guild|S|" .. (revision or 1) .. "|F|" .. #rows}
    for i, row in ipairs(rows) do
        out[#out+1] = "PWP_V2|D|server|client|guild|S|" .. (revision or 1) .. "|" .. i .. "|" .. row
    end
    out[#out+1] = "PWP_V2|E|server|client|guild|S|" .. (revision or 1) .. "|" .. #rows .. "|" .. p.checksum(rows)
    return out
end
local function refused(batch, wanted)
    local s, last = receiver(), nil
    for _, packet in ipairs(batch) do
        local event, err = p.receive(s, packet, 0)
        assert(not event)
        if err then last = err; break end
    end
    assert(last and (not wanted or wanted == last), tostring(last) .. " ~= " .. tostring(wanted))
    assert(s.revisions.S == 0 and not s.pending.S)
end
local meta = "C:camp-A|M:req-1:2000:58000:1:1:1|-"
local camps = "C:camp-A|C:2|camp-A=1"

-- Full selected-scope totals, not the subset of item IDs present in rules.
local s = receiver()
local batch = encode()
assert(#batch == 5, "metadata + camp chunk + item chunk + B/E")
local event = deliver(s, batch, 1)
assert(event.stream == "S" and event.mode == "F" and event.request == "req-1")
assert(event.session == "server" and event.client_session == "client" and event.guild == "guild")
assert(event.storage.scope == "camp" and event.storage.camp == "camp-A")
assert(event.storage.choices[1] == "camp-A" and event.storage.choices[2] == "camp-B")
assert(event.storage.totals.Wood == 0 and event.storage.totals.Ore == 12 and event.storage.totals["Mod.Item"] == 7)
assert(event.storage.totals.Missing == nil, "wire decoder invented zero")
assert(event.storage.age_ms == 3000 and event.storage.remaining_ms == 57000)
assert(event.received_at == 1 and event.expires_at == 58)
assert(s.revisions.S == 0 and not s.full.S)
assert(not p.commit(s, event), "S commit requires current local time")
assert(p.commit(s, event, 1) and s.revisions.S == 1)
assert(not p.commit(s, event, 1), "candidate committed twice")
assert(select(2, p.receive(s, batch[1], 2)) == "storage_unrequested")
assert(not p.expire(s, 57.999))
assert(p.expire(s, 58) and s.resync.S and not s.storage_request)
assert(deliver(receiver(),encode(view({age_ms=2000.0,remaining_ms=58000.0}))))

-- Empty verified stock is distinct from explicit unknown, including choices.
local empty = deliver(receiver(), encode(view({totals={}})))
assert(empty.storage.verified and next(empty.storage.totals) == nil)
local unavailable = view({verified=false, totals={}, age_ms=0, remaining_ms=0})
local unknown_state = receiver()
local unknown = deliver(unknown_state, encode(unavailable))
assert(not unknown.storage.verified and next(unknown.storage.totals) == nil)
assert(#unknown.storage.choices == 2 and p.commit(unknown_state, unknown, 0))
local guild = {scope="guild", choices={}, verified=true, totals={}, age_ms=0, remaining_ms=5000}
local guild_state = p.receiver("server", "client", "guild")
assert(p.expect_storage(guild_state, "req-1", "guild", nil, 0))
local ge = deliver(guild_state, encode(guild))
assert(ge.storage.scope == "guild" and ge.storage.camp == nil)

-- The initial request need not know the server's configured scope/default camp.
local auto = p.receiver("server", "client", "guild")
assert(p.expect_storage(auto, "req-1", nil, nil, 0))
assert(deliver(auto, batch).storage.camp == "camp-A")
local selected_auto = p.receiver("server", "client", "guild")
assert(p.expect_storage(selected_auto, "req-1", nil, "camp-A", 0))
assert(deliver(selected_auto, encode(guild)).storage.scope == "guild")
local wrong_auto = p.receiver("server", "client", "guild")
assert(p.expect_storage(wrong_auto, "req-1", nil, "camp-B", 0))
p.receive(wrong_auto, batch[1], 0)
assert(select(2,p.receive(wrong_auto,batch[2],0)) == "wrong_storage_request")
local no_camp = {scope="camp", choices={}, verified=false, totals={}, age_ms=0, remaining_ms=0}
local unresolved = p.receiver("server", "client", "guild")
assert(p.expect_storage(unresolved,"req-1",nil,"camp-A",0))
local ue = deliver(unresolved, encode(no_camp))
assert(ue.storage.scope == "camp" and ue.storage.camp == nil and not ue.storage.verified)
no_camp.verified, no_camp.remaining_ms = true, 1000
assert(not p.storage_snapshot("server","client","guild",1,"req-1",no_camp))

-- Invalid domain input never silently truncates, defaults to zero or refreshes.
for _, overrides in ipairs({
    {scope="global"}, {camp="bad|camp"}, {verified="true"},
    {totals={Ore=-1}}, {totals={Ore=1.25}}, {totals={Ore=math.huge}}, {totals={Ore=0/0}},
    {totals={Ore=p.MAX_STORAGE_AMOUNT+1}}, {totals={["bad,item"]=1}}, {totals={Ore="1"}},
    {age_ms=-1}, {age_ms=60001}, {age_ms=0/0}, {remaining_ms=0}, {remaining_ms=60000},
    {verified=false}, {choices={"camp-A", "camp-A"}}, {choices={"other-camp"}},
    {choices={[2]="camp-A"}}, {choices={extra="camp-A"}},
}) do assert(not p.storage_snapshot("server", "client", "guild", 1, "req-1", view(overrides))) end
assert(not p.storage_snapshot("server", "client", "guild", 1, "bad:request", view()))
assert(not p.storage_snapshot("server", "client", "guild", 1, "req-1", nil))
assert(not p.snapshot("server", "client", "guild", "S", 1, "D", {}))
assert(not p.snapshot("server", "client", "guild", "S", 1, "F", {}))

-- Chunking scales with bytes, not item count; budgets cover complete packets.
local many = {}
for i=1, 200 do many["Item" .. i] = i end
local packed = encode(view({totals=many}))
assert(#packed < 12 and #packed <= p.MAX_STORAGE_CHUNKS+2)
local pe = deliver(receiver(), packed)
assert(pe.storage.totals.Item200 == 200)
local largest = {}
for i=1, p.MAX_STORAGE_ITEMS do largest["I" .. i] = 0 end
assert(deliver(receiver(), encode(view({totals=largest}))).storage.totals.I512 == 0)
largest.Extra = 1
assert(not p.storage_snapshot("server", "client", "guild", 1, "req-1", view({totals=largest})))
local too_many_camps = {}
for i=1, p.MAX_STORAGE_CAMPS+1 do too_many_camps[i] = "camp" .. i end
assert(not p.storage_snapshot("server", "client", "guild", 1, "req-1", view({choices=too_many_camps})))
local long_items = {}
for i=1, 512 do long_items[string.rep("x", 60) .. string.format("%04d", i)] = 2147483647 end
assert(not p.storage_snapshot("server", "client", "guild", 1, "req-1", view({totals=long_items})))
local long_server, long_client, long_guild, long_camp = string.rep("s",64), string.rep("c",64), string.rep("g",128), string.rep("b",128)
local long_state = p.receiver(long_server, long_client, long_guild)
assert(p.expect_storage(long_state, string.rep("r",64), "camp", long_camp, 0))
local long_batch = assert(p.storage_snapshot(long_server, long_client, long_guild, 2147483647,
    string.rep("r",64), view({camp=long_camp, choices={long_camp}, totals=many})))
assert(deliver(long_state, long_batch).storage.totals.Item1 == 1)

-- Byte/chunk budgets are enforced independently of item count, on both sides.
local old_bytes = p.MAX_STORAGE_BYTES
p.MAX_STORAGE_BYTES = 64
assert(not p.storage_snapshot("server","client","guild",1,"req-1",view()))
refused(batch, "snapshot_too_large")
p.MAX_STORAGE_BYTES = old_bytes
local old_chunks = p.MAX_STORAGE_CHUNKS
p.MAX_STORAGE_CHUNKS = 2
assert(not p.storage_snapshot("server","client","guild",1,"req-1",view()))
refused(batch, "invalid_begin")
p.MAX_STORAGE_CHUNKS = old_chunks

-- Reordered delivery and identical retries are valid; duplicates aren't totals.
local reordered = receiver()
p.receive(reordered, batch[1], 0)
for i=#batch-1,2,-1 do
    assert(not p.receive(reordered, batch[i], 0))
    assert(not p.receive(reordered, batch[i], 0))
end
assert(p.receive(reordered, batch[#batch], 0).storage.totals.Ore == 12)
refused(raw({meta, camps, "C:camp-A|I:3|Ore=1,Ore=2"}), "invalid_row")
refused(raw({meta:gsub(":1:1|", ":2:1|"), camps, "C:camp-A|I:3|Ore=1", "C:camp-A|I:4|Ore=2"}), "invalid_storage")
refused(raw({meta, camps, "C:camp-A|C:3|camp-A=1", "C:camp-A|I:4|Ore=1"}), "invalid_storage")
refused(raw({meta, camps}), "invalid_storage")
refused(raw({meta, "C:camp-A|C:2|camp-B=1", "C:camp-A|I:3|Ore=1"}), "invalid_storage")
for _, value in ipairs({"Ore=-1", "Ore=1.5", "Ore=1e3", "Ore=nan", "Ore=inf", "Ore=2147483648",
    "Ore=1,", ",Ore=1", "Ore=1,,Wood=2", "Ore=", "bad=id=1", "Ore= 1", "Ore=+1"}) do
    refused(raw({meta, camps, "C:camp-A|I:3|" .. value}), "invalid_row")
end
refused(raw({meta, camps, "C:camp-A|I:4|Ore=1"}), "invalid_row")
refused(raw({meta, "C:camp-A|C:2|camp-A=0", "C:camp-A|I:3|Ore=1"}), "invalid_row")
refused(raw({meta:gsub("2000:58000", "3000:58000"), camps, "C:camp-A|I:3|Ore=1"}), "invalid_row")
refused(raw({meta:gsub("2000:58000:1", "0:0:0"), camps, "C:camp-A|I:3|Ore=1"}), "invalid_row")

-- Checksums cover metadata too, and lost packets never yield partial shelves.
local altered = encode()
altered[2] = altered[2]:gsub("2000:58000", "3000:57000")
refused(altered, "incomplete_snapshot")
local lost = encode()
table.remove(lost, 4)
refused(lost, "incomplete_snapshot")
refused({"PWP_V2|B|server|client|guild|S|1|F|33"}, "invalid_begin")
refused({"PWP_V2|B|server|client|guild|S|1|F|0"}, "invalid_begin")
refused({"PWP_V2|U|server|client|guild|S|1|camp-A|Ore|1|0"}, "invalid_delta")

-- Session, guild, selection and outstanding request are independent fences.
local fenced = receiver()
for _, field in ipairs({"server", "client", "guild"}) do
    assert(select(2, p.receive(fenced, batch[1]:gsub(field, "foreign", 1), 0)) == "wrong_session")
end
assert(not fenced.buffers.S)
assert(select(2, p.receive(p.receiver("server", "client", "guild"), batch[1], 0)) == "storage_unrequested")
assert(p.expect_storage(fenced, "req-2", "camp", "camp-B", 0))
p.receive(fenced, batch[1], 0)
assert(select(2, p.receive(fenced, batch[2], 0)) == "wrong_storage_request")
for i=3,#batch do assert(select(2,p.receive(fenced,batch[i],0)) == "wrong_storage_request") end
assert(fenced.storage_request.id == "req-2" and not fenced.pending.S)
assert(deliver(fenced, encode(view({camp="camp-B"}), 2, "req-2")))
local same_scope = receiver("req-2")
p.receive(same_scope, batch[1], 0)
assert(select(2, p.receive(same_scope, batch[2], 0)) == "wrong_storage_request")
assert(deliver(same_scope, encode(view(), 2, "req-2")))
local selected = receiver()
local old_event = deliver(selected, batch)
assert(p.expect_storage(selected, "req-2", "camp", "camp-B", 0))
assert(not p.commit(selected, old_event, 0))
assert(not p.expect_storage(selected, "req-2", "camp", "camp-B", 0))
assert(not p.expect_storage(selected, "req-3", "global", nil, 0))

-- A newer full batch supersedes an uncommitted candidate, never vice versa.
local newer = receiver()
local old = deliver(newer, batch)
p.receive(newer, encode(view(), 2)[1], 0)
assert(not p.commit(newer, old, 0))
assert(select(2, p.receive(newer, batch[1], 0)) == "stale_revision")
local pending = receiver()
local pending_event = deliver(pending, encode(view(), 2))
assert(select(2, p.receive(pending, batch[1], 0)) == "stale_revision")
assert(p.commit(pending, pending_event, 0))

-- Time translation uses actual age plus conservative request RTT, not a pass.
local drip = receiver(nil,nil,nil,100)
local drip_batch = encode(view({age_ms=55000,remaining_ms=5000}))
p.receive(drip, drip_batch[1], 101)
for i=2,#drip_batch-1 do p.receive(drip, drip_batch[i], 102) end
local de = assert(p.receive(drip, drip_batch[#drip_batch], 103))
assert(de.storage.age_ms == 58000 and de.storage.remaining_ms == 2000 and de.expires_at == 105)
assert(not p.commit(drip, de, 105), "expired data committed")
local pending_expired, pending_streams = p.expire(drip,105)
assert(pending_expired and pending_streams.S and not drip.pending.S)
local timed = receiver()
for i=1,#drip_batch-1 do p.receive(timed, drip_batch[i], 0) end
assert(select(2,p.receive(timed,drip_batch[#drip_batch],5)) == "storage_expired")
local stalled = receiver()
p.receive(stalled,batch[1],0)
local expired, streams = p.expire(stalled,p.TIMEOUT)
assert(expired and streams.S and not streams.P and not streams.R)
assert(not stalled.buffers.S and not stalled.storage_request)
local too_late = receiver()
assert(select(2,p.receive(too_late,batch[1],60)) == "storage_expired")
local backwards = receiver(nil,nil,nil,100)
assert(select(2,p.receive(backwards,batch[1],99)) == "storage_expired")

-- Storage cannot gate settings readiness, even on errors or invalidation.
local independent = receiver()
independent.full.P, independent.full.R = true, true
independent.resync.P, independent.resync.R = false, false
assert(p.ready(independent))
p.receive(independent, "PWP_V2|B|server|client|guild|S|1|F|999", 0)
assert(p.ready(independent) and independent.resync.S)
assert(p.expect_storage(independent,"again","camp","camp-A",0))
local unavailable_event = deliver(independent, encode(unavailable, 2, "again"))
assert(p.commit(independent,unavailable_event,0) and p.ready(independent))
p.invalidate(independent,"S")
assert(p.ready(independent))
p.invalidate(independent)
assert(not p.ready(independent) and not independent.storage_request)
