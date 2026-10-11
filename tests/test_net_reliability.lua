local time, role, up, down = 0, false, {}, {}
os.clock = function() return time end
FName = function(s) return s end
local server_comp = { guild = "guild-A" }
function server_comp:GetFullName() return "component-A" end
function server_comp:Notify_RequestClient_int32(_, name) down[#down + 1] = name end
local client_comp = {}
function client_comp:Request_Server_int32(_, name, value) up[#up + 1] = {name, value} end
package.loaded.log = { warn = function() end, say = function() end, debug = function() end,
    count = function() return {ms = 0} end }
local function instance(authority)
    package.loaded.palapi = { valid = function(o) return type(o) == "table" end,
        has_authority = function() return authority end,
        owned_network_component = function() return client_comp end }
    package.loaded.net = nil
    local n = require("net")
    n.guild_of_sender = function(c) return c.guild end
    return n
end
local server, client = instance(true), instance(false)
server.begin_session(41); client.begin_session(77)
local priorities, edits, accept = {[1] = 1, [2] = false}, 0, true
local function rows_for(guild)
    assert(guild == "guild-A", "roster called for forged guild")
    return {{key = "PAL-A", ranks = {[1] = 3}, prios = priorities}}
end
local caps = { all = function(_, guild)
    assert(guild == "guild-A")
    return { Mining = {Stone = 100} }
end }
local snapshots = 0
client.on_snapshot = function(rows, meta)
    assert(meta.session == 77 and meta.server_session == server.local_nonce)
    assert(meta.guild == "guild-A" and rows[1].amount == 100)
    snapshots = snapshots + 1
    return true
end
server.on_command = function(command, _, comp)
    local p = server.split(command)
    if p[1] == "PWP_Hello" then
        assert(server.push_rules(caps, {}, comp))
        assert(server.push_pals(rows_for, comp))
        return true
    end
    edits = edits + 1
    if not accept then return accept end
    assert(p[1] == "PWP_Prio")
    priorities[tonumber(p[3])] = require("protocol").decode_priority(p[4])
    assert(server.push_pals(rows_for, comp, p[2]))
    return true
end
local function send_to_server()
    local q = up; up = {}
    for _, m in ipairs(q) do server.receive_command(server_comp, m[1], m[2]) end
    return q
end
local function send_to_client()
    local q = down; down = {}
    for _, m in ipairs(q) do client.receive_state(m) end
    return q
end
assert(not client.request_prio("PAL-A", 1, 2))
assert(client.hello()); send_to_server()
assert(client.status == "connecting" and next(client.pals) == nil)
send_to_client()
assert(next(server.clients) == nil, "Hello alone installed an unconfirmed peer")
send_to_server(); send_to_client()
assert(client.status == "ready" and client.server_guild == "guild-A" and snapshots == 1)
assert(client.pals["PAL-A"].prios[2] == false, "X lost on wire")

-- Three fast edits produce one request, then a queued click while it is in flight.
assert(client.request_prio("PAL-A", 1, 2))
assert(client.request_prio("PAL-A", 1, 3))
assert(client.request_prio("PAL-A", 1, 4))
assert(client.pending_priority("PAL-A", 1) == 4 and #up == 0)
time = 0.2; client.poll(); assert(#up == 1)
local old_request = up[1][1]
assert(client.request_prio("PAL-A", 1, 5))
send_to_server(); assert(edits == 1 and priorities[1] == 4)
local original_ack=down[#down]
assert(original_ack:match("^PWP_V2|A|"))
send_to_client()
assert(client.pending_priority("PAL-A", 1) == 5, "in-flight acknowledgement lost newer click")
time = 0.4; client.poll(); assert(#up == 1)
send_to_server(); send_to_client()
assert(client.pals["PAL-A"].prios[1] == 5)
assert(select(2, client.pending_priority("PAL-A", 1)) == false)

-- Duplicate requests acknowledge again without calling main twice.
server.receive_command(server_comp, old_request, 0)
assert(edits == 2)
assert(down[#down]==original_ack, "duplicate ACK borrowed a newer snapshot revision")
send_to_client()
server.receive_command(server_comp, old_request:gsub("|Prio|PAL%-A|1|4", "|Prio|PAL-A|1|X"), 0)
assert(edits == 2); send_to_client()

accept = false
client.request_prio("PAL-A", 1, false)
assert(client.pending_priority("PAL-A", 1) == false)
time = 0.6; client.poll(); send_to_server(); send_to_client()
assert(client.status == "ready" and client.status_reason == "rejected" and client.pals["PAL-A"].prios[1] == 5)
assert(select(2, client.pending_priority("PAL-A", 1)) == false)
-- A nil return from a non-throwing main handler is also a rejection.
accept = nil
client.request_prio("PAL-A", 1, 1)
time = 0.8; client.poll(); send_to_server(); send_to_client()
assert(client.status == "ready" and client.status_reason == "rejected")

-- Missing acknowledgement never commits optimistic state as confirmed.
accept = true
client.request_prio("PAL-A", 1, 2)
time = 1; client.poll()
time = 10; client.poll()
assert(client.status_reason == "ack_timeout")
assert(client.pals["PAL-A"].prios[1] == 5)
assert(select(2, client.pending_priority("PAL-A", 1)) == false)
up = {}

-- A timeout reconnects for confirmed state; it does not assume the write failed.
time = 12.1; assert(client.hello())
send_to_server(); send_to_client(); send_to_server(); send_to_client()
assert(client.status == "ready")
client.request_prio("PAL-A", 1, false)
time = 12.3; client.poll(); send_to_server()
local delayed = down; down = {}
local last = delayed[#delayed]
assert(last:match("^PWP_V2|A|"))
assert(#delayed == 2 and delayed[1]:match("^PWP_V2|U|"), "single edit grew to multiple row RPCs")
local generation = client.pals_gen
client.receive_state(last)
assert(select(2, client.pending_priority("PAL-A", 1)), "ack alone cleared pending state")
assert(client.pals_gen == generation, "ack without snapshot became visible")
client.receive_state(delayed[#delayed - 1])
assert(client.pals["PAL-A"].prios[1] == false)
assert(not select(2, client.pending_priority("PAL-A", 1)))

-- Old Hello cannot evict a confirmed current peer without its fresh challenge.
local active = server.clients["component-A"]
server.receive_command(server_comp, "PWP_Hello|2|14|old-session", 0)
assert(server.clients["component-A"] == active)
server.receive_command(server_comp, "PWP_V2|C|" .. server.local_nonce .. "|old-session|guild-A|1", 0)
assert(server.clients["component-A"] == active)
down = {}

-- Incomplete rule batches do not invoke the durable-data integration callback.
local peer = server.clients["component-A"]
local malformed = assert(require("protocol").snapshot(server.local_nonce, client.local_nonce,
    "guild-A", "R", peer.revisions.R + 1, "F", {"Mining|Stone|100", "Mining|Ore|200"}))
local snapshot_count = snapshots
client.receive_state(malformed[1]); client.receive_state(malformed[2])
client.receive_state(malformed[#malformed])
assert(snapshots == snapshot_count and #client.rules == 1)
assert(client.status_reason == "incomplete_snapshot")

-- Even a successful edit ack cannot settle against the PRE-edit snapshot.
time = 18.3; client.poll()
send_to_server(); send_to_client(); send_to_server(); send_to_client()
assert(client.status == "ready")
local normal_handler = server.on_command
server.on_command = function(command, value, comp)
    if command == "PWP_Hello" then return normal_handler(command, value, comp) end
    edits = edits + 1
    return true -- persistence succeeded but the state's push could not complete
end
client.request_prio("PAL-A", 1, 3)
time = 18.5; client.poll(); send_to_server(); send_to_client()
assert(select(2, client.pending_priority("PAL-A", 1)))
assert(client.pals["PAL-A"].prios[1] == false)
time = 27; client.poll()
assert(client.status_reason == "snapshot_timeout")
assert(not select(2, client.pending_priority("PAL-A", 1)))
server.on_command = normal_handler
up = {}

-- Wrong session, forged guild and unnegotiated legacy commands never reach main.
local before = edits
server.receive_command(server_comp, old_request:gsub("guild%-A", "guild-B"), 0)
server.receive_command(server_comp, "PWP_Prio|PAL-A|1|X", 0)
assert(edits == before)
down = {}
local previous = client.local_nonce
client.begin_session(78)
client.reset()
assert(client.epoch == 78 and client.local_nonce ~= previous)
assert(next(client.pals) == nil and not client.server_guild)
assert(not client.receive_state("PWP_Welcome|2|14|" .. previous .. "|" .. server.local_nonce .. "|guild-A|1"))
assert(client.status == "connecting")
client.receive_state("PWP_PalReset")
assert(client.status == "incompatible" and not client.hello())
client.begin_session(79)
client.receive_state("PWP_Welcome|2|13|" .. client.local_nonce .. "|server|guild|1")
assert(client.status == "incompatible", "column mismatch accepted")

-- Undecided role never sends a hello or consumes even a valid welcome.
local undecided = instance(nil)
assert(not undecided.hello())
assert(not undecided.receive_state("PWP_Welcome|2|14|" .. undecided.local_nonce .. "|server|guild|1"))
