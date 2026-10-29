-- net.notify_old_client: on the authority, an old-format client is told once
-- per client per session in the game's system chat, through component ->
-- transmitter (found by class walk) -> owning controller -> PlayerState.PlayerUId.
-- Clients never send it; failures are logged and never throw.
local said, warned, sent = {}, {}, {}
local authority = true
package.loaded.log = {
    say = function(m) said[#said + 1] = m end,
    warn = function(m) warned[#warned + 1] = m end,
    info = function() end, debug = function() end, error = function() end,
    count = function() return { ms = 0 } end,
}
local function obj(name, extra)
    local o = extra or {}
    o.GetFullName = function() return name end
    return o
end
local uid = { A = 11, B = 22, C = 33, D = 44 }
local controller = obj('BP_PalPlayerController_C /Game/x.ctrl', { PlayerState = obj('PS', { PlayerUId = uid }) })
local transmitter = obj('PalNetworkTransmitter /Game/x.tx1', { GetOwner = function() return controller end })
local outer_wrapper = obj('PalNetworkTransmitter /Game/x.tx1')
local comp = obj('PalNetworkBaseCampComponent /Game/x.tx1.BaseCamp', { GetOuter = function() return outer_wrapper end })
local world = obj('World /Game/x')
local util = obj('Default__PalUtility', { SendSystemToPlayerChat = function(_, w, text, uids)
    sent[#sent + 1] = { world = w, text = text, uids = uids }
end })
local transmitters_list = { transmitter }
FindAllOf = function(class)
    if class == 'PalNetworkTransmitter' then return transmitters_list end
    return {}
end
FindFirstOf = function(class) if class == 'World' then return world end end
package.loaded.palapi = {
    has_authority = function() return authority end,
    valid = function(o) return o ~= nil and o ~= false end,
    cdo = function(path) assert(path == '/Script/Pal.Default__PalUtility'); return util end,
}
package.loaded.net = nil
local net = require('net')

-- Told once, with the player's own uid and the notice text.
assert(net.notify_old_client(comp) == true, 'authority did not notify')
assert(#sent == 1 and sent[1].world == world and sent[1].text == net.OLD_CLIENT_NOTICE)
local u = sent[1].uids[1]
assert(u.A == 11 and u.B == 22 and u.C == 33 and u.D == 44, 'wrong player uid')
assert(net.OLD_CLIENT_NOTICE:find('update', 1, true))
assert(said[#said]:find('older Pal Work Priority', 1, true))

-- Not twice for the same client in one session.
assert(net.notify_old_client(comp) == false and #sent == 1, 'notified the same client twice')

-- A new session tells it again.
net.begin_session(2)
assert(net.notify_old_client(comp) == true and #sent == 2, 'new session did not notify')

-- A client never sends it.
net.begin_session(3)
authority = false
assert(net.notify_old_client(comp) == false and #sent == 2, 'a client sent the notice')
authority = true

-- An unresolvable sender: logged, no throw, no message, and not retried.
net.begin_session(4)
transmitters_list = {}
assert(net.notify_old_client(comp) == false and #sent == 2)
assert(warned[#warned]:find('could not tell an old client', 1, true), 'failure not logged')
transmitters_list = { transmitter }
assert(net.notify_old_client(comp) == false and #sent == 2, 'retried within the session')

-- 2026-10-29 round 2: a Hello with a higher schema is a newer client. It is
-- told the server is older and to ask the host, never to update itself.
net.begin_session(5)
local up_sent = {}
FName = function(text) return text end
comp.Notify_RequestClient_int32 = function(_, _, msg) up_sent[#up_sent + 1] = msg end
assert(net.receive_command(comp, 'PWP_Hello|' .. (net.SCHEMA + 1) .. '|' .. net.WORKS .. '|nonce1', 0) == false)
assert(#sent == 3 and sent[3].text == net.NEWER_CLIENT_NOTICE, 'newer client was told to update')
assert(sent[3].text:find('Ask the host to update the server.', 1, true)
    and not sent[3].text:find('Please update', 1, true))
assert(said[#said]:find('newer Pal Work Priority', 1, true))
assert(#net.NEWER_CLIENT_NOTICE <= #net.OLD_CLIENT_NOTICE + 16, 'notice grew past the old bound')
-- An older schema, and 0.4.1's bare Hello, still get the update advice.
net.begin_session(6)
assert(net.receive_command(comp, 'PWP_Hello|' .. (net.SCHEMA - 1) .. '|' .. net.WORKS .. '|nonce2', 0) == false)
assert(#sent == 4 and sent[4].text == net.OLD_CLIENT_NOTICE)
net.begin_session(7)
assert(net.receive_command(comp, 'PWP_Hello', 0) == false)
assert(#sent == 5 and sent[5].text == net.OLD_CLIENT_NOTICE)
-- Every reply is still the Incompatible line the client can read.
assert(#up_sent == 3)
for _, msg in ipairs(up_sent) do
    assert(msg == 'PWP_Incompatible|' .. net.SCHEMA .. '|' .. net.WORKS, msg)
end

print('old client notice checks passed')
