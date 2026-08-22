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

-- Who has sent us something, so we know who to push to.
--
-- Names, never components. Storing the component wrapper and calling it back
-- two minutes later is the use-after-free this codebase is built to avoid -
-- demand.lua carries a long comment about why it stopped keeping work
-- objects, and a network component on a busy server churns exactly the same
-- way. The name is a string, which is safe to keep forever, and the component
-- is looked up again inside the call that uses it.
--
-- name -> { at = os.clock() }
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

-- The live component with this full name, or nil.
--
-- Resolved inside the frame it is used, which is the only age at which an
-- engine object is safe to touch. FindAllOf is not free, but it runs once per
-- message to one client rather than once per frame, and the alternative is a
-- stored wrapper - which is not a cheaper option, it is a crash.
local function live_client(name)
    local all = FindAllOf("PalNetworkBaseCampComponent")
    if not all then return nil end
    for _, comp in ipairs(all) do
        if full_name(comp) == name then return comp end
    end
    return nil
end

-- Server to one client, through that client's own component.
--
-- Takes either a name (the stored case, re-resolved here) or a component the
-- caller obtained in this same call, which is what the hook handlers pass.
function M.to_client(comp, message)
    if type(comp) == "string" then comp = live_client(comp) end
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
        -- TTL only. The IsValid that used to sit here asked a component
        -- wrapper stored on an earlier frame whether it was still alive,
        -- which is the same stored-wrapper dereference that demand.lua was
        -- purged of; on a busy server clients churn exactly like work
        -- objects. A dead component makes the send fail, and a failed send
        -- drops the entry, which is the same outcome without the dangerous
        -- question.
        if (now - entry.at) > CLIENT_TTL then
            M.clients[name] = nil
        elseif M.to_client(name, message) then
            sent = sent + 1
        else
            M.clients[name] = nil
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
        M.clients[name] = { at = os.clock() }
    end
    -- Returned for the caller to use NOW, inside this hook callback. It is
    -- deliberately not what gets stored.
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
-- The rule protocol
-- ---------------------------------------------------------------------------
--
-- Everything rides in the FName, pipe separated, because that is the only
-- payload channel these two RPCs have.
--
--   up    PWP_Hello                          announce, ask for everything
--         PWP_Set|<work>|<item>|<amount>     set a rule
--         PWP_Clear|<work>|<item>            remove one
--
--   down  PWP_Reset                          forget everything, a batch follows
--         PWP_Rule|<work>|<item>|<amount>    one rule
--         PWP_Done                           end of batch
--
-- The batch is bracketed rather than counted. A count would have to be right,
-- and a client that missed one message would wait for a total that never
-- arrives; brackets just mean the list ends when it ends.

local function split(text)
    local out = {}
    for part in tostring(text):gmatch("([^|]+)") do out[#out + 1] = part end
    return out
end

-- Called on the authority to push every rule to one client, or to all of
-- them when comp is nil.
function M.push_rules(caps, cfg, comp)
    local all = caps.all(cfg)

    local send = function(msg)
        if comp then return M.to_client(comp, msg) end
        return M.broadcast(msg) > 0
    end

    send(PREFIX .. "Reset")
    for work, items in pairs(all) do
        for item, amount in pairs(items) do
            send(string.format("%sRule|%s|%s|%d", PREFIX, work, item, amount))
        end
    end
    send(PREFIX .. "Done")
end

-- Called on a client to ask the server for a rule change. Returns false when
-- there is nothing to send through, which is normal before a world settles.
function M.request(kind, work, item, amount)
    if kind == "clear" then
        return M.to_server(string.format("%sClear|%s|%s", PREFIX, work, item), 0)
    end
    return M.to_server(
        string.format("%sSet|%s|%s|%d", PREFIX, work, item, amount or 0), 0)
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

M.PREFIX = PREFIX
M.split = split

return M
