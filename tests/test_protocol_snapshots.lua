local p = require("protocol")
local ranks, prios = string.rep("1", p.WORKS), string.rep("2", p.WORKS)
local function payload(key, priority) return key .. "|" .. ranks .. "|" .. (priority or prios) end
local function state() return p.receiver("server", "client", "guild") end
local function batch(rev, rows, mode)
    return assert(p.snapshot("server", "client", "guild", "P", rev, mode or "F", rows))
end
local s = state()
local b = batch(1, {payload("PAL-A"), payload("PAL-B")})
for i = 1, #b - 1 do assert(p.receive(s, b[i], 0) == nil); assert(s.revisions.P == 0) end
local event = assert(p.receive(s, b[#b], 0))
assert(event.revision == 1 and #event.rows == 2 and event.guild == "guild")
assert(s.revisions.P == 0 and not s.full.P, "validation committed before application")
assert(p.commit(s, event))
assert(s.revisions.P == 1 and s.full.P)
assert(select(2, p.receive(s, b[1], 1)) == "stale_revision")

-- Lost rows, wrong counts and altered data cannot commit a partial table.
local lost = batch(2, {payload("PAL-A"), payload("PAL-B")})
p.receive(s, lost[1], 0); p.receive(s, lost[2], 0)
assert(select(2, p.receive(s, lost[#lost], 0)) == "incomplete_snapshot")
assert(s.revisions.P == 1)
local corrupt = batch(3, {payload("PAL-A")})
p.receive(s, corrupt[1], 0)
p.receive(s, corrupt[2]:gsub("PAL%-A", "PAL-C"), 0)
assert(select(2, p.receive(s, corrupt[3], 0)) == "incomplete_snapshot")
assert(s.revisions.P == 1)

-- Indexing supports delivery order changes, but never duplicate keys.
local ordered = batch(4, {payload("PAL-A"), payload("PAL-B")})
p.receive(s, ordered[1], 0); p.receive(s, ordered[3], 0); p.receive(s, ordered[2], 0)
local ordered_event = assert(p.receive(s, ordered[4], 0))
assert(ordered_event.rows[1].key == "PAL-A" and p.commit(s, ordered_event))
local duplicate = batch(5, {payload("PAL-A"), payload("PAL-B")})
p.receive(s, duplicate[1], 0); p.receive(s, duplicate[2], 0)
assert(select(2, p.receive(s, duplicate[3]:gsub("PAL%-B", "PAL-A"), 0)) == "duplicate_row")
assert(s.revisions.P == 4)
assert(not p.snapshot("server", "client", "guild", "P", 8, "F", {payload("PAL-A"), payload("PAL-A")}))

-- Widths and bounded counts are a protocol contract, not truncation hints.
assert(not p.row("P", "PAL-A|1|1"))
assert(not p.row("P", payload("slot12")))
assert(not p.row("P", payload("PAL-A", string.rep("6", p.WORKS))))
assert(not p.row("R", "Mining|Ore|1.5"))
assert(not p.row("R", "Mining|Ore|0"))
assert(not p.row("R", "Mining|Ore|10000000"))
assert(not p.parts(string.rep("a", p.MAX_PACKET + 1)))
local oversized = "PWP_V2|B|server|client|guild|P|8|F|513"
assert(select(2, p.receive(s, oversized, 0)) == "invalid_begin")
assert(not s.buffers.P)

-- A delta without a completed initial snapshot cannot masquerade as a roster.
-- Errors require a FULL repair of the affected stream before further deltas.
local repair = batch(5, {payload("PAL-A")})
p.receive(s, repair[1], 0); p.receive(s, repair[2], 0)
assert(p.commit(s, assert(p.receive(s, repair[3], 0))))
local delta = batch(6, {payload("PAL-A", "X" .. prios:sub(2))}, "D")
assert(#delta == 1)
assert(select(2, p.receive(state(), delta[1], 0)) == "invalid_delta")
local delta_event = assert(p.receive(s, delta[1], 0))
assert(delta_event.rows[1].prios[1] == false and p.commit(s, delta_event))
assert(select(2, p.receive(s, batch(8, {payload("PAL-A")}, "D")[1], 0)) == "delta_revision_gap")

local stale = batch(10, {payload("PAL-A")})
assert(select(2, p.receive(s, stale[1]:gsub("client", "previous"), 0)) == "wrong_session")
assert(select(2, p.receive(s, stale[1]:gsub("guild", "other"), 0)) == "wrong_session")
p.receive(s, stale[1], 0)
assert(p.expire(s, p.TIMEOUT + 1) and not s.buffers.P)
assert(select(2, p.receive(s, stale[3], 20)) == "missing_begin")

-- Empty FULL is valid and deliberately distinct from missing or truncated.
local empty = batch(11, {})
p.receive(s, empty[1], 0)
local empty_event = assert(p.receive(s, empty[2], 0))
assert(#empty_event.rows == 0 and p.commit(s, empty_event))
assert(not p.edit({"Prio", "PAL-A", "1.5", "2"}))
assert(not p.edit({"Prio", "PAL-A", "1", "0"}))
assert(not p.edit({"Clear", "Mining", "Ore", "extra"}))
assert(p.edit({"Prio", "PAL-A", "1", "X"}) == "PWP_Prio|PAL-A|1|X")
assert(p.row("R", "Mining|Mod.Ore|10"))
assert(p.edit({"Set","Mining","Mod.Ore","10"}))
assert(p.edit({"Clear","Mining","Mod.Ore"}))
assert(not p.item("Ore|injection") and not p.item("Ore\n"))
