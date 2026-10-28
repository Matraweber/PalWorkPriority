-- Schema 5 limit state on the storage stream. Pure wire fixtures: no engine,
-- filesystem, transport, deploy or game actions.
local p = require("protocol")
assert(p.SCHEMA == 5)

local function view(overrides)
    local v = {scope="camp", camp="camp-A", choices={"camp-A", "camp-B"}, verified=true,
        totals={Stone=900, Ore=12}, age_ms=1000, remaining_ms=29000,
        limits={per_item=true, verdicts={Mining={capped=1, camps=1, unknown=0},
            Deforest={capped=0, camps=1, unknown=0}}, stopped={Stone=true}}}
    for k, value in pairs(overrides or {}) do v[k] = value end
    -- pairs never carries a nil override: guild scope drops the camp, false the limits.
    if v.scope == "guild" then v.camp = nil end
    if v.limits == false then v.limits = nil end
    return v
end
local function limits(overrides)
    local l = {per_item=true, verdicts={Mining={capped=1, camps=1, unknown=0}}, stopped={Stone=true}}
    for k, value in pairs(overrides or {}) do l[k] = value end
    return l
end
local function receiver(scope, camp)
    local s = p.receiver("server", "client", "guild")
    assert(p.expect_storage(s, "req-1", scope, camp, 0))
    return s
end
local function deliver(s, batch)
    local event
    for i, wire in ipairs(batch) do
        assert(#wire <= p.MAX_PACKET)
        local got, err = p.receive(s, wire, 0)
        assert(not err, tostring(err))
        if i == #batch then event = got else assert(not got, "partial state escaped") end
    end
    return assert(event)
end
local function encode(v)
    return p.storage_snapshot("server", "client", "guild", 1, "req-1", v)
end
local function raw(rows)
    local out = {"PWP_V2|B|server|client|guild|S|1|F|" .. #rows}
    for i, row in ipairs(rows) do out[#out+1] = "PWP_V2|D|server|client|guild|S|1|" .. i .. "|" .. row end
    out[#out+1] = "PWP_V2|E|server|client|guild|S|1|" .. #rows .. "|" .. p.checksum(rows)
    return out
end
local function refused(batch, wanted, scope, camp)
    local s, last = receiver(scope or "camp", camp or "camp-A"), nil
    for _, packet in ipairs(batch) do
        local event, err = p.receive(s, packet, 0)
        assert(not event, "invalid limit state accepted")
        if err then last = err; break end
    end
    assert(last and (not wanted or wanted == last), tostring(last) .. " ~= " .. tostring(wanted))
end

-- Round trip: flag, verdicts for exactly this camp, items with rocks held.
local event = deliver(receiver("camp", "camp-A"), assert(encode(view())))
local got = event.storage.limits
assert(got.per_item == true and got.stopped.Stone == true and got.stopped.Ore == nil)
assert(got.verdicts.Mining.capped == 1 and got.verdicts.Mining.camps == 1 and got.verdicts.Mining.unknown == 0)
assert(got.verdicts.Deforest.capped == 0 and event.storage.totals.Stone == 900)
-- Off and unsaid are different answers.
assert(deliver(receiver("camp", "camp-A"), assert(encode(view({limits=limits({per_item=false})})))).storage.limits.per_item == false)
local unsaid = deliver(receiver("camp", "camp-A"), assert(encode(view({limits=false})))).storage.limits
assert(unsaid.per_item == nil and next(unsaid.verdicts) == nil and next(unsaid.stopped) == nil)
-- The flag also rides on a reply without a count, but verdicts never do.
local blind = view({verified=false, totals={}, age_ms=0, remaining_ms=0, limits={per_item=false}})
local be = deliver(receiver("camp", "camp-A"), assert(encode(blind)))
assert(not be.storage.verified and be.storage.limits.per_item == false)
-- Guild scope: one verdict over all the guild's counted camps.
local guild = view({scope="guild", camp=nil, limits=limits({verdicts={Mining={capped=2, camps=3, unknown=0},
    Deforest={capped=0, camps=3, unknown=1}}})})
local ge = deliver(receiver("guild", nil), assert(encode(guild)))
assert(ge.storage.limits.verdicts.Mining.capped == 2 and ge.storage.limits.verdicts.Mining.camps == 3)
assert(ge.storage.limits.verdicts.Deforest.unknown == 1)

-- Encoding refuses any limit state it cannot vouch for.
for _, bad in ipairs({
    {verified=false, totals={}, age_ms=0, remaining_ms=0},                      -- verdict without a count
    {verified=false, totals={}, age_ms=0, remaining_ms=0, limits={stopped={Stone=true}}},
    {limits=limits({verdicts={Mining={capped=2, camps=1, unknown=0}}})},       -- capped > camps
    {limits=limits({verdicts={Mining={capped=1, camps=1, unknown=1}}})},       -- capped + unknown > camps
    {limits=limits({verdicts={Mining={capped=0, camps=0, unknown=0}}})},       -- no camp
    {limits=limits({verdicts={Mining={capped=0.5, camps=1, unknown=0}}})},
    {limits=limits({verdicts={Mining={capped=0/0, camps=1, unknown=0}}})},
    {limits=limits({verdicts={Mining={capped="1", camps=1, unknown=0}}})},
    {limits=limits({verdicts={Mining={capped=0, camps=33, unknown=0}}})},
    {limits=limits({verdicts={Mining={capped=0, camps=1}}})},
    {limits=limits({verdicts={["Min|ing"]={capped=0, camps=1, unknown=0}}})},
    {limits=limits({verdicts={["bad,work"]={capped=0, camps=1, unknown=0}}})},
    {limits=limits({verdicts={Mining=true}})},
    {limits=limits({verdicts={Mining={capped=1, camps=2, unknown=0}}})},       -- camp scope counts one camp
    {limits=limits({stopped={["bad,item"]=true}})},
    {limits=limits({stopped={Stone=1}})},
    {limits=limits({stopped={"Stone"}})},
    {limits=limits({per_item="yes"})},
    {limits=limits({verdicts="Mining"})},
    {limits=true},
}) do
    assert(not encode(view(bad)), "invalid limit state encoded")
end
local works = {}
for i = 1, p.WORKS + 1 do works["Work" .. i] = {capped=0, camps=3, unknown=0} end
local _, why = encode(view({scope="guild", camp=nil, limits=limits({verdicts=works})}))
assert(why == "storage_too_large")
works["Work" .. (p.WORKS + 1)] = nil
local wide = deliver(receiver("guild", nil), assert(encode(view({scope="guild", camp=nil, limits=limits({verdicts=works})}))))
assert(wide.storage.limits.verdicts["Work" .. p.WORKS].camps == 3)
local held = {}
for i = 1, p.MAX_STORAGE_ITEMS + 1 do held["Item" .. i] = true end
assert(select(2, encode(view({limits=limits({stopped=held})}))) == "storage_too_large")
held["Item" .. (p.MAX_STORAGE_ITEMS + 1)] = nil
local full = deliver(receiver("camp", "camp-A"), assert(encode(view({limits=limits({stopped=held})}))))
local n = 0
for _ in pairs(full.storage.limits.stopped) do n = n + 1 end
assert(n == p.MAX_STORAGE_ITEMS and full.storage.totals.Stone == 900)

-- Decoding is strict: counts, value grammar, scope and the old schema row.
local meta = "C:camp-A|M:req-1:1000:29000:1:0:1:1:1|1"
local camps = "C:camp-A|C:2|camp-A=1"
local verdict = "C:camp-A|V:3|Mining=1/1/0"
local stopped = "C:camp-A|X:4|Stone=1"
local ok = deliver(receiver("camp", "camp-A"), raw({meta, camps, verdict, stopped}))
assert(ok.storage.limits.verdicts.Mining.capped == 1 and ok.storage.limits.stopped.Stone)
refused(raw({"C:camp-A|M:req-1:1000:29000:1:0:1|-", camps}), "invalid_row")  -- schema 4 row
refused(raw({meta:gsub(":1:1|1$", ":2:1|1"), camps, verdict, stopped}), "invalid_storage")
refused(raw({meta:gsub(":1:1|1$", ":1:2|1"), camps, verdict, stopped}), "invalid_storage")
refused(raw({meta, camps, verdict}), "invalid_storage")
refused(raw({meta:gsub("|1$", "|2"), camps, verdict, stopped}), "invalid_row")
refused(raw({meta:gsub("|1$", "|"), camps, verdict, stopped}), "invalid_row")
refused(raw({meta:gsub(":1:1|1$", ":15:1|1"), camps, verdict, stopped}), "invalid_row")
refused(raw({"C:camp-A|M:req-1:0:0:0:0:1:1:0|-", camps, verdict}), "invalid_row")
refused(raw({"C:camp-A|M:req-1:0:0:0:0:1:0:1|-", camps, (stopped:gsub("X:4", "X:3"))}), "invalid_row")
for _, value in ipairs({"Mining=1/1", "Mining=2/1/0", "Mining=0/0/0", "Mining=1/1/1", "Mining=-1/1/0",
    "Mining=1.0/1/0", "Mining=a/1/0", "Mining=1/1/0/0", "Mining=1/33/0", "Mining= 1/1/0",
    "Mining=1/1/0,Mining=0/1/0", "Min ing=1/1/0", "Mining=1/1/0,", "=1/1/0"}) do
    refused(raw({meta, camps, "C:camp-A|V:3|" .. value, stopped}), "invalid_row")
end
for _, value in ipairs({"Stone=2", "Stone=0", "bad,id=1", "Stone=1/1/0", "Stone"}) do
    refused(raw({meta, camps, verdict, "C:camp-A|X:4|" .. value}), "invalid_row")
end
refused(raw({meta, camps, "C:camp-A|V:3|Mining=1/2/0", stopped}), "invalid_storage")
refused(raw({meta, camps, verdict, "C:camp-A|X:4|Stone=1", "C:camp-A|X:5|Stone=1"}), "invalid_storage")
print("protocol schema 5: limit state round trip, strict bounds on both sides, schema 4 rows refused")
