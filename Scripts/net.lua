-- Transport between a client and whichever machine has authority.
--
-- There is no custom networking here. Two vanilla RPCs on
-- PalNetworkBaseCampComponent carry everything, with the command packed into
-- an FName and a small number in the int32:
--
--   Request_Server_int32        client -> server
--   Notify_RequestClient_int32  server -> one client, Client and Reliable
--
-- Each side receives by hooking the call it does not make. The approach comes
-- from PalPriority, which ships on it, and three of its constraints are worth
-- taking on trust rather than rediscovering:
--
--   Never the Multicast variants. An unmodded client must receive nothing.
--
--   A hook fires on the machine that MAKES the call, not only the one that
--   receives it, so a client hooking Request_Server_int32 sees its own
--   outgoing messages. Every handler checks its role before acting or a
--   client cheerfully answers its own requests.
--
--   Any custom message proves the component it arrived on belongs to a real
--   modded player, which is the only reliable way to find one worth pushing
--   state back to. A component found by FindFirstOf at boot may be a dud
--   whose writes silently go nowhere.

local log = require("log")
local api = require("palapi")

local M = {}

local PREFIX = "PWP_"
local CLIENT_TTL = 120          -- seconds before an unheard-from client is dropped

M.installed = false

-- Components that have sent us something, so we know who to push to.
-- name -> { comp = component, at = os.clock() }
M.clients = {}

-- Set by main.lua. Called on the authority with (command, value, component).
M.on_command = nil
-- Set by main.lua. Called on a client with (message).
M.on_state = nil

-- Phase 0 diagnostics. Every number here is reported by "!pwp net".
M.stats = {
    sent_up = 0, sent_down = 0,
    got_up = 0, got_down = 0,
    echo_sent = 0, echo_returned = 0,
    last_error = nil,
}

-- ---------------------------------------------------------------------------
-- Reading a hook's arguments
-- ---------------------------------------------------------------------------

-- The FName argument, whichever position it turns up in.
--
-- Request_Server_int32 is (BaseCampId, FunctionName, Value) and the notify
-- side is assumed to match, but assuming is what this file exists to avoid,
-- so both candidates are tried and whichever yields a string wins.
local function read_name(a, b)
    for _, param in ipairs({ a, b }) do
        local text
        pcall(function()
            local v = param:get()
            if v then text = v:ToString() end
        end)
        if type(text) == "string" and text ~= "" and text ~= "None" then
            return text
        end
    end
    return nil
end

local function read_int(param)
    local n
    pcall(function() n = param:get() end)
    if type(n) == "number" then return math.floor(n) end
    return 0
end

local function full_name(o)
    local n
    pcall(function() n = o:GetFullName() end)
    if type(n) == "string" then return n end
    return nil
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

local ZERO_GUID = { A = 0, B = 0, C = 0, D = 0 }

-- Client to server. Returns false when there is no component to send through,
-- which happens before the world has settled and is not an error.
function M.to_server(command, value)
    local comp = api.network_component()
    if not api.valid(comp) then return false end

    local ok, err = pcall(function()
        comp:Request_Server_int32(ZERO_GUID, FName(command), value or 0)
    end)

    if not ok then
        M.stats.last_error = tostring(err)
        return false
    end

    M.stats.sent_up = M.stats.sent_up + 1
    return true
end

-- Server to one client, through that client's own component.
function M.to_client(comp, message)
    if not api.valid(comp) then return false end

    local ok, err = pcall(function()
        comp:Notify_RequestClient_int32(ZERO_GUID, FName(message), 1)
    end)

    if not ok then
        M.stats.last_error = tostring(err)
        return false
    end

    M.stats.sent_down = M.stats.sent_down + 1
    return true
end

-- Every modded client we have heard from, dropping the stale as we go.
function M.broadcast(message)
    local now = os.clock()
    local sent = 0

    for name, entry in pairs(M.clients) do
        if (now - entry.at) > CLIENT_TTL or not api.valid(entry.comp) then
            M.clients[name] = nil
        elseif M.to_client(entry.comp, message) then
            sent = sent + 1
        end
    end
    return sent
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

local function remember(context)
    local comp
    pcall(function() comp = context:get() end)
    if not api.valid(comp) then return nil end

    local name = full_name(comp)
    if name then
        M.clients[name] = { comp = comp, at = os.clock() }
    end
    return comp
end

function M.install()
    if M.installed then return true end

    local ok_up = pcall(function()
        RegisterHook("/Script/Pal.PalNetworkBaseCampComponent:Request_Server_int32",
            function(Context, A, B, C)
                pcall(function()
                    local command = read_name(B, A)
                    if type(command) ~= "string" then return end
                    if command:sub(1, #PREFIX) ~= PREFIX then return end

                    -- Our own outgoing call, seen on the way out. Only the
                    -- authority answers.
                    if not api.has_authority() then return end

                    M.stats.got_up = M.stats.got_up + 1
                    local comp = remember(Context)
                    local value = read_int(C)

                    -- Phase 0. Answered before anything else and regardless of
                    -- role wiring, so the round trip can be proved on its own.
                    if command == PREFIX .. "Echo" then
                        M.to_client(comp, PREFIX .. "EchoBack|" .. value)
                        return
                    end

                    if M.on_command then M.on_command(command, value, comp) end
                end)
            end)
    end)

    local ok_down = pcall(function()
        RegisterHook("/Script/Pal.PalNetworkBaseCampComponent:Notify_RequestClient_int32",
            function(Context, A, B, C)
                pcall(function()
                    local message = read_name(B, A)
                    if type(message) ~= "string" then return end
                    if message:sub(1, #PREFIX) ~= PREFIX then return end

                    M.stats.got_down = M.stats.got_down + 1

                    if message:sub(1, #PREFIX + 8) == PREFIX .. "EchoBack" then
                        M.stats.echo_returned = M.stats.echo_returned + 1
                        log.say("transport: echo came back, the round trip works")
                        return
                    end

                    if M.on_state then M.on_state(message) end
                end)
            end)
    end)

    M.installed = ok_up and ok_down
    if not M.installed then
        log.warn("transport hooks failed to register, up=" .. tostring(ok_up) ..
            " down=" .. tostring(ok_down))
    end
    return M.installed
end

function M.reset()
    M.clients = {}
end

-- ---------------------------------------------------------------------------
-- Phase 0 self test
-- ---------------------------------------------------------------------------

-- Sends one echo and leaves the answer to arrive on its own.
--
-- On single player and a listen server host this proves the pair of calls
-- work at all, because Notify_RequestClient_int32 executes locally there. On
-- a client it proves the messages actually cross the wire, which is the only
-- question that decides whether any of this is possible.
function M.selftest()
    if not M.installed then
        log.say("transport: hooks are not installed, nothing to test")
        return false
    end

    local where = api.has_authority() and "authority" or "client"
    M.stats.echo_sent = M.stats.echo_sent + 1

    if not M.to_server(PREFIX .. "Echo", M.stats.echo_sent) then
        log.say("transport: no base camp network component yet. " ..
            "Stand in your base and try again")
        return false
    end

    log.say("transport: echo " .. M.stats.echo_sent .. " sent as " .. where ..
        ", waiting for it to come back")
    return true
end

function M.report()
    log.say("transport:")
    log.say("  hooks installed: " .. tostring(M.installed))
    log.say("  role: " .. (api.has_authority() and "authority" or "client"))
    log.say(string.format("  sent up %d, received up %d",
        M.stats.sent_up, M.stats.got_up))
    log.say(string.format("  sent down %d, received down %d",
        M.stats.sent_down, M.stats.got_down))
    log.say(string.format("  echo sent %d, returned %d",
        M.stats.echo_sent, M.stats.echo_returned))

    local known = 0
    for _ in pairs(M.clients) do known = known + 1 end
    log.say("  modded clients heard from: " .. known)

    if M.stats.last_error then
        log.say("  last error: " .. M.stats.last_error)
    end

    if M.stats.echo_sent > 0 and M.stats.echo_returned == 0 then
        log.say("  the echo has not come back. Either the RPC does not reach " ..
            "the server, or the reply does not reach here.")
    end
end

return M
