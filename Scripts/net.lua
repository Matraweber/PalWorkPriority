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
--   Measured on 23 August, this last one did not hold: a client that had
--   just sent two messages reported saw_up 0, counted above the role gate,
--   so its own outgoing calls never reached its own hook. The role checks
--   stay - they cost nothing and the claim may hold on other builds or for
--   the down call - but nothing should be inferred from a client's own
--   up-hook firing, because here it does not.
--
--   Any custom message proves the component it arrived on belongs to a real
--   modded player, which is the only reliable way to find one worth pushing
--   state back to. A component found by FindFirstOf at boot may be a dud
--   whose writes silently go nowhere.

local log = require("log")
local api = require("palapi")
local wire = require("protocol")
local settings_gate = require('settings_gate')

local M = {}

-- Fixed, opt-in phase labels; no native wrappers or timing state survive the
-- synchronous call. Inclusive child measurements must not be added to parents.
local function push_phase(label, fn, ...)
    if log.perf then return log.around(label, fn, ...) end
    return fn(...)
end

-- How many work types the wire format carries.
--
-- It was the literal 14, written twice, against #workdefs.ORDER - which is 14
-- today. Adding a work type would have silently truncated the new column in
-- one direction only, with nothing anywhere to notice. net.lua deliberately
-- requires only log and palapi, so this is named here and CHECKED against
-- workdefs once at load in main.lua, where that module is already in scope.
M.WORKS = 14

local PREFIX = "PWP_"

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
-- Main supplies state-bound durability and deferred completion adapters.
M.publication_guard = nil
M.pending_owner = nil
M.pending_status = nil
M.publish_pending = nil
-- Main supplies authenticated interest and a plain-data snapshot builder.
M.on_storage_interest = nil
M.on_storage_request = nil
-- Main supplies (guild, view) -> the server's plain limit state for exactly
-- that storage view (panel_status.server_limits). Unset, a schema 5 reply
-- carries no verdicts and "-" for the flag, and clients keep their own cfg.
M.on_limit_state = nil
-- Client: the server's item_limits_on_rocks once a storage reply said it.
M.server_item_limits = nil
-- Set by main.lua. Called on a client with (message).
M.on_state = nil

-- Phase 0 diagnostics. Every number here is reported by "!pwp net".
M.stats = {
    sent_up = 0, sent_down = 0,
    got_up = 0, got_down = 0,
    echo_sent = 0, echo_returned = 0,
    last_error = nil,

    -- Counted before the role gate below, and separate from got_up for a
    -- reason. A hook fires on the machine that MAKES the call, so a client
    -- sees its own outgoing message - but got_up sits under the authority
    -- check, so a client reports zero whether the call was made or not.
    -- That left "the RPC was never issued" and "the RPC was issued and
    -- vanished" looking identical from the client, and they want opposite
    -- fixes: the first is a bad component, the second is ownership.
    saw_up = 0,

    -- Which resolution produced the component the last send went through,
    -- so a working round trip says what fixed it rather than just working.
    owner_route = nil,
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

-- The component a client is allowed to send a server RPC through.
--
-- Measured on 23 August rather than guessed, because the first guess was
-- wrong. There are always exactly two PalNetworkBaseCampComponents on a
-- client, and each is the BaseCamp component of a PalNetworkTransmitter:
--
--   PalNetworkTransmitter_A  owner: BP_PalPlayerController_C   <- this player
--   PalNetworkTransmitter_B  owner: BP_PalGameStateInGame_C    <- the world
--
-- Only the first can carry a client to server RPC. A client does not own the
-- game state, so Unreal drops anything sent through the second before it
-- reaches the wire, and drops it silently: the call returns, the pcall
-- succeeds, and sent_up counts a message that never left.
--
-- api.network_component answers with FindFirstOf, which returns whichever of
-- the two the engine lists first. That ordering is not stable across a
-- reconnect. Leaving to the menu and rejoining happened to leave the player's
-- transmitter first and everything worked; rejoining after the SERVER
-- restarted left the game state's first and every send vanished. Same two
-- objects, different order - which is why this looked like a client going
-- stale over hours when it was really a coin flip resolved at reconnect.
--
-- So the owner is checked instead of trusting the order. Resolved per call
-- and never stored; this runs on a rule change, not in the pass.
local function owned_component()
    -- palapi's resolver, which carries the name memo: after the first full
    -- resolution a send costs two StaticFindObjects and a re-proof instead
    -- of two full array walks (74-90ms on a grown session, per CLICK on a
    -- client). This function used to be a verbatim un-memoed copy of that
    -- walk; the copy is gone and the memo counters now cover the send path
    -- too. The re-proof inside palapi is the same owner check the copy did.
    local comp = api.owned_network_component()
    if comp ~= nil then return comp, "owner" end
    return nil, nil
end

-- Client to server. Returns false when there is no component to send through,
-- which happens before the world has settled and is not an error.
function M.to_server(command, value, current)
    if current and not current() then return false end
    -- The owned one when this is a client, because an unowned component is
    -- not a slower path here, it is a silent no-op. The old answer stays as
    -- the fallback so the authority - where ownership is not a question -
    -- behaves exactly as before.
    local comp, route = owned_component()
    if current and not current() then return false end

    -- No fallback on a client.
    --
    -- api.network_component() is FindFirstOf, which returns whichever of the
    -- two components the engine lists first - and that order FLIPS after a
    -- server restart. Sending through the unowned one is dropped by Unreal
    -- before the wire while sent_up still counts it, which is the transport
    -- bug this codebase spent a day on. scheduler.run_pass and
    -- scheduler.restore both deleted this same fallback for that reason.
    --
    -- to_server kept it, and it is the one send site whose result is reported
    -- to the PLAYER as success: store.submit and caps.submit only say "could
    -- not reach the server" when this returns false. So the fallback turned a
    -- refusal the player could see into a click that was accepted on screen
    -- and never happened.
    --
    -- Kept under authority, where ownership genuinely is not in question.
    if not api.valid(comp) and api.has_authority() then
        if current and not current() then return false end
        comp, route = api.network_component(), "findfirst"
    end
    if current and not current() then return false end
    if not api.valid(comp) then return false end
    if current and not current() then return false end
    M.stats.owner_route = route

    local ok, err = pcall(function()
        local name = FName(command)
        if current and not current() then return false end
        comp:Request_Server_int32(ZERO_GUID, name, value or 0)
        return true
    end)

    if not ok then
        M.stats.last_error = tostring(err)
        return false
    end

    if err == false or (current and not current()) then return false end
    M.stats.sent_up = M.stats.sent_up + 1
    return true
end

-- The live component with this full name, or nil.
--
-- Resolved inside the frame it is used, which is the only age at which an
-- engine object is safe to touch. FindAllOf is not free, but it runs once per
-- message to one client rather than once per frame, and the alternative is a
-- stored wrapper - which is not a cheaper option, it is a crash.
local function live_client(name, current)
    if current and not current() then return nil end
    local all = FindAllOf("PalNetworkBaseCampComponent")
    if current and not current() then return nil end
    if not all then return nil end
    for _, comp in ipairs(all) do
        -- Validated before it is asked its name. FindAllOf hands back
        -- everything it finds including objects on their way out, and
        -- GetFullName on one of those is a member call on freed memory - the
        -- pcall inside full_name cannot catch that, it never could. Every
        -- other FindAllOf loop in this codebase checks first.
        local valid = api.valid(comp)
        if current and not current() then return nil end
        if valid then
            local found = full_name(comp)
            if current and not current() then return nil end
            if found == name then return comp end
        end
    end
    return nil
end

-- Server to one client, through that client's own component.
--
-- Takes either a name (the stored case, re-resolved here) or a component the
-- caller obtained in this same call, which is what the hook handlers pass.
function M.to_client(comp, message, current, authorize)
    if current and not current() then return false end
    if type(comp) == "string" then comp = live_client(comp, current) end
    if current and not current() then return false end
    if not api.valid(comp) then return false end
    if current and not current() then return false end

    local ok, err = pcall(function()
        local name = FName(message)
        if current and not current() then return false end
        -- Conversion can dispatch native callbacks. Prove storage ownership
        -- after it, immediately before sending, using this callback's census.
        if authorize and not authorize() then return false end
        if current and not current() then return false end
        comp:Notify_RequestClient_int32(ZERO_GUID, name, 1)
        return true
    end)

    if not ok then
        M.stats.last_error = tostring(err)
        return false
    end
    if err == false then return false end
    if current and not current() then return false end

    M.stats.sent_down = M.stats.sent_down + 1
    return true
end



-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

-- Which client a message arrived on, as a string.
--
-- Exposed so the command handler can rate-limit per sender instead of
-- globally: one client hammering the channel should not stop everybody
-- else's edits from landing.
-- The guild a message belongs to, resolved from the object it arrived on.
--
-- Never from what the client says. A client that could name its own guild
-- could name one it is not in, and a ceiling filed under that guild would
-- suspend work at bases it has no business touching - griefing that looks
-- exactly like the mod misbehaving. So the sender is traced back through the
-- component the RPC actually came in on: component -> its transmitter ->
-- that transmitter's owning controller -> that player's guild.
--
-- Transmitters are read from FindAllOf and matched by name rather than
-- reached through the component's outer, because GetOuter hands back a
-- wrapper without the actor function table and GetOwner on it silently fails.
-- That cost an afternoon once already.
-- Every transmitter in memory, by name, from one walk.
--
-- Built by the caller and passed down, because who needs it decides how often
-- the walk happens: once for a single inbound message, once for a whole push
-- to every client. It used to be walked inside the per-client answer, which is
-- the shape this split exists to break.
local function transmitters(current)
    local out = {}
    local found = FindAllOf("PalNetworkTransmitter") or {}
    if current and not current() then return out end
    for _, t in ipairs(found) do
        local valid = api.valid(t)
        if current and not current() then return out end
        if valid then
            local n = full_name(t)
            if current and not current() then return out end
            if n then out[n] = t end
        end
    end
    return out
end

-- The guild behind a base camp component, against a prebuilt lookup.
--
-- The lookup is a membership test as much as a shortcut: the component's outer
-- is only accepted as a transmitter because a class-filtered walk found it
-- under that name, rather than because GetOuter said so.
local function guild_via(comp, tx_by_name, current)
    local outer
    pcall(function() outer = comp:GetOuter() end)
    if current and not current() then return nil end
    if not api.valid(outer) then return nil end
    if current and not current() then return nil end

    local want = full_name(outer)
    if current and not current() then return nil end
    if not want then return nil end

    local t = tx_by_name[want]
    if not api.valid(t) then return nil end
    if current and not current() then return nil end

    local owner
    pcall(function() owner = t:GetOwner() end)
    if current and not current() then return nil end
    if not api.valid(owner) then return nil end
    if current and not current() then return nil end
    return api.guild_of(owner)
end

-- One message, one sender: the walk is worth it here and happens once.
function M.guild_of_sender(comp, current)
    if not api.valid(comp) then return nil end
    if current and not current() then return nil end
    local tx = transmitters(current)
    if current and not current() then return nil end
    return guild_via(comp, tx, current)
end

function M.who(comp, current)
    if not api.valid(comp) then return nil end
    if current and not current() then return nil end
    return full_name(comp)
end

-- Tell a player with an older copy of the mod why nothing they change sticks.
--
-- On 2026-10-19 a 0.4.1 client on the rc1 server got PWP_Incompatible, which
-- it cannot read: it showed an empty limit list and answered a refused change
-- with "limit set ... your rules are sent to it". The game's own system chat
-- needs no mod on the receiving side, so the server says it there, once per
-- client per session: UPalUtility::SendSystemToPlayerChat(world, text, {uid}),
-- the player reached through the same component -> transmitter -> owner chain
-- as guild_via. Only names are kept between calls. Any failure is silent apart
-- from the log and never blocks the Incompatible reply itself.
-- The version comes from main.lua's VERSION through set_version, so it cannot
-- go stale in the next release (round 3: it was a hardcoded "(0.5.0)").
local function old_client_notice(version)
    return "Pal Work Priority: this server runs a newer version of the mod"
        .. (version and (" (" .. version .. ")") or "") .. ". " ..
        "Your copy is older, so your priority and limit changes are not applied here. " ..
        "Please update Pal Work Priority."
end
M.OLD_CLIENT_NOTICE = old_client_notice(nil)
function M.set_version(version)
    M.MOD_VERSION = version
    M.OLD_CLIENT_NOTICE = old_client_notice(version)
end
-- A client whose Hello names a higher schema is the newer one (round 2,
-- 2026-10-29): telling it to update was wrong advice.
M.NEWER_CLIENT_NOTICE = "Pal Work Priority: this server runs an older Pal Work Priority. " ..
    "Your copy is newer, so your priority and limit changes are not applied here. " ..
    "Ask the host to update the server."
local told_old, told_count = {}, 0

-- newer: the client's Hello named a higher schema than this server's.
function M.notify_old_client(comp, newer)
    if api.has_authority() ~= true or not api.valid(comp) then return false end
    local name = full_name(comp)
    if not name or told_old[name] then return false end
    -- Bounded (round 3). An old client never confirms, so there is no peer
    -- to notice it leave; forget them all once the list is long. At worst a
    -- player who is still on an old copy is told a second time.
    if told_count >= 64 then told_old, told_count = {}, 0 end
    told_old[name], told_count = true, told_count + 1
    local ok, why = pcall(function()
        local outer = comp:GetOuter()
        if not api.valid(outer) then error("no transmitter") end
        local t = transmitters()[full_name(outer)]
        if not api.valid(t) then error("transmitter not found") end
        local owner = t:GetOwner()
        if not api.valid(owner) then error("no owning controller") end
        local ps = owner.PlayerState
        if not api.valid(ps) then error("no player state") end
        local uid = ps.PlayerUId
        local util = api.cdo("/Script/Pal.Default__PalUtility")
        local world = FindFirstOf("World")
        if not (api.valid(util) and api.valid(world)) then error("utility or world missing") end
        util:SendSystemToPlayerChat(world, newer and M.NEWER_CLIENT_NOTICE or M.OLD_CLIENT_NOTICE,
            { { A = uid.A, B = uid.B, C = uid.C, D = uid.D } })
    end)
    if ok and newer then
        log.say("told a client with a newer Pal Work Priority that this server is older (system chat)")
    elseif ok then
        log.say("told a client with an older Pal Work Priority to update (system chat)")
    else
        log.warn("could not tell an old client to update: " .. tostring(why))
    end
    return ok
end

-- Resolve without recording.
--
-- Echo needs a component to answer on and must NOT put it on the push list:
-- the up hook fires for the machine's own outgoing calls, so on a host
-- '!pwp net' filed the HOST's own component as a connected client. Nothing
-- evicts it - it always resolves - so from then on the session believed a
-- client was present. That made chat_is_trusted false, refusing every
-- changing command from chat for the rest of the session, and made every
-- edit pay a full base walk pushing to a client that is the machine itself.
local function resolve(context)
    local comp
    pcall(function() comp = context:get() end)
    if not api.valid(comp) then return nil end
    return comp
end

function M.install()
    if M.installed then return true end

    -- Only the halves that have not already landed.
    local ok_up, ok_down = M.up_hooked, M.down_hooked

    if not ok_up then ok_up = pcall(function()
        RegisterHook("/Script/Pal.PalNetworkBaseCampComponent:Request_Server_int32",
            function(Context, A, B, C)
                -- Counted above the prefix test on purpose.
                --
                -- This hook is on PalNetworkBaseCampComponent, not on
                -- anything of ours, so it fires for every base camp RPC the
                -- game makes. How many of those are not ours is the whole
                -- unknown: the mod's own traffic is already counted below by
                -- saw_up and got_down, and neither says what the hook costs
                -- to sit there.
                local _b = log.count("hook: net up")
                local _t0 = log.perf and os.clock() or nil

                local hook_ok, hook_error = pcall(function()
                    local command = read_name(B, A)
                    if type(command) ~= "string" then return end
                    if command:sub(1, #PREFIX) ~= PREFIX then return end

                    M.stats.saw_up = M.stats.saw_up + 1

                    -- Our own outgoing call, seen on the way out. Only the
                    -- authority answers.
                    if not api.has_authority() then return end

                    M.stats.got_up = M.stats.got_up + 1
                    local value = read_int(C)

                    -- Phase 0. Answered before anything else and regardless of
                    -- role wiring, so the round trip can be proved on its own.
                    --
                    -- Resolved rather than remembered: see resolve() above.
                    -- An echo proves the pipe, it does not announce a player.
                    if command == PREFIX .. "Echo" then
                        M.to_client(resolve(Context),
                            PREFIX .. "EchoBack|" .. value)
                        return
                    end

                    M.receive_command(resolve(Context), command, value)
                end)
                if not hook_ok then log.warn("network up hook failed: " .. tostring(hook_error)) end

                if _t0 then _b.ms = _b.ms + (os.clock() - _t0) * 1000 end
            end)
    end) end

    if not ok_down then ok_down = pcall(function()
        RegisterHook("/Script/Pal.PalNetworkBaseCampComponent:Notify_RequestClient_int32",
            function(Context, A, B, C)
                local _b = log.count("hook: net down")
                local _t0 = log.perf and os.clock() or nil

                local hook_ok, hook_error = pcall(function()
                    local message = read_name(B, A)
                    if type(message) ~= "string" then return end
                    if message:sub(1, #PREFIX) ~= PREFIX then return end

                    M.stats.got_down = M.stats.got_down + 1

                    if message:sub(1, #PREFIX + 8) == PREFIX .. "EchoBack" then
                        M.stats.echo_returned = M.stats.echo_returned + 1
                        log.say("transport: echo came back, the round trip works")
                        return
                    end

                    -- The authority does not apply its own push.
                    --
                    -- Below the echo branch on purpose. The self test relies
                    -- on Notify_RequestClient_int32 running locally on a host
                    -- - that is how it proves the pair of calls work in single
                    -- player at all - so gating the whole handler would break
                    -- the one thing it exists to prove. Only the rule
                    -- application is refused.
                    --
                    -- The up hook has refused its own outgoing calls since it
                    -- was written and this one never did. Measured on 23
                    -- August the gap does not currently fire: a day of pushes
                    -- with the server at debug produced zero "rules updated
                    -- from the server" lines there and fourteen on the client.
                    -- If a build ever did deliver them, push_rules sends ONE
                    -- guild's batch, replace_all would swallow it whole, and
                    -- since a pushed row carries no guild every rule on the
                    -- machine would collapse into the wildcard and every other
                    -- guild's would be dropped - then saved over caps.txt by
                    -- the next set. One line, for something that expensive.
                    if api.has_authority() then return end

                    M.receive_state(message)
                end)
                if not hook_ok then log.warn("network down hook failed: " .. tostring(hook_error)) end

                if _t0 then _b.ms = _b.ms + (os.clock() - _t0) * 1000 end
            end)
    end) end

    -- Tracked separately, and never re-registered.
    --
    -- A UE4SS hook cannot be unregistered, so a retry after a half success
    -- would double-register the half that already landed and every message
    -- would be handled twice. This used to keep one flag: if one side
    -- registered and the other did not, M.installed stayed false, selftest
    -- refused to run and status reported NOT HOOKED - while one hook was
    -- genuinely live and firing.
    M.up_hooked = M.up_hooked or ok_up
    M.down_hooked = M.down_hooked or ok_down
    M.installed = M.up_hooked and M.down_hooked

    if not M.installed then
        log.warn("transport hooks: up=" .. tostring(M.up_hooked) ..
            " down=" .. tostring(M.down_hooked) ..
            ". A hook cannot be unregistered, so the half that landed stays " ..
            "and will not be registered again.")
    end
    return M.installed
end

-- Only a negotiated peer may reach main's existing authorized command handler.
-- Nonces isolate sessions; they are not a substitute for RPC ownership checks.
local send_up = M.to_server
local receiver, sequence, nonce_serial = nil, 0, 0
local requests, cells, offers = {}, {}, {}
-- Storage has its own receiver, uncertainty, request IDs and paced queue.
-- No native wrappers survive a request callback or transport beat.
-- Bounds: at most four S packets per 100ms callback (or one lock packet),
-- one fresh recipient/census shared only within that callback; eight queued peers, twelve
-- seconds to start, <9 seconds to finish a started batch, twenty-second client
-- request deadline. Unchanged selections refresh >=10 seconds after completion;
-- selection changes and server admission are limited to one request per second.
-- The wire currently permits 32 data chunks + B/E (34 packets). These are
-- traffic bounds, not a claim about native callback cost or frame-time safety.
local stock = {}
M.storage_stats = {requests=0, builds=0, packets=0, transmitter_walks=0,
    component_fallbacks=0, queue_peak=0}
local challenge_serial = 0
-- One synchronous handler's authenticated plain data; never engine wrappers.
local command_context = nil
local deferred, deferred_jobs, deferred_order, deferred_busy=nil,{},{},false
local deferred_bindings={}
function M.enable_deferred(enabled)
    if enabled~=true and enabled~=false then return false end
    if enabled and (next(M.clients or {})~=nil or deferred_busy or api.has_authority()~=true) then return false end
    if deferred then deferred:close() end
    deferred,deferred_jobs,deferred_order,deferred_bindings=nil,{},{},{}
    if enabled then deferred=require('settings_pending_edits').new{enabled=true} end
    return true
end
local hello_at, hello_tries = nil, 0
local hello_failures = 0 -- sends that failed this session; see hello()
local ACK_TIMEOUT, COALESCE = 8, 0.10
local durable_ack = { P = 0, R = 0 }
M.SCHEMA = wire.SCHEMA
M.pals, M.pals_gen, M.pending_gen = {}, 0, 0
-- At most one request watermark for each persistence file, never per snapshot.
M.save_failures = {}
M.status, M.status_reason = "connecting", "awaiting_session"
M.on_snapshot, M.on_status, M.on_edit, M.on_session = nil, nil, nil, nil

local function now() return os.clock() end

local unavailable_reason
local recovery_retry_at,recovery_retries=nil,0
-- Schema 3 already has a reason field. Only known codes may cross the wire;
-- handler errors and old peers' unknown reasons collapse to generic rejection.
local rejection_reasons={unsupported_limit=true,no_active_legacy_rule=true,too_many_limits=true,
    rejected=true,handler_error=true,invalid_edit=true,request_id_reused=true,stale_request=true,
    rate_limited=true}
local function rejection_reason(reason)
    return type(reason)=='string' and rejection_reasons[reason] and reason or 'rejected'
end
local function set_status(status, reason, force)
    if unavailable_reason then status,reason='unavailable',unavailable_reason end
    if status == "ready" and (M.save_failures.P or M.save_failures.R) then
        status, reason = "applied_unsaved", "save_failed"
    end
    local changed = M.status ~= status or M.status_reason ~= reason
    M.status, M.status_reason = status, reason
    if status=='ready' then recovery_retry_at,recovery_retries=nil,0 end
    if (changed or force) and M.on_status then
        local ok, err = pcall(M.on_status, status, reason)
        if not ok then log.warn("network status callback failed: " .. tostring(err)) end
    end
end

local function can_edit()
    return not unavailable_reason and receiver and wire.ready(receiver)
        and (M.status == "ready" or M.status == "rejected" or M.status == "applied_unsaved")
end

local function notify_edit(entry, status, reason)
    entry.status = status
    M.pending_gen = M.pending_gen + 1
    if M.on_edit then
        local ok, err = pcall(M.on_edit, entry.key, entry.work, status, reason, entry.id)
        if not ok then log.warn("network edit callback failed: " .. tostring(err)) end
    end
    -- Main also uses on_edit for the limits status. Pending retries, acks
    -- awaiting snapshots and older accepted edits prove no durable recovery.
    -- Reassert the connection/file status after every edit callback while a
    -- save error remains; settle clears it only after a later durable commit.
    if M.save_failures.P or M.save_failures.R then
        set_status(M.status, M.status_reason, true)
    end
end

function M.begin_session(epoch)
    -- Enablement belongs to this explicitly reviewed session, never a reconnect
    -- into another local world/role. Late replies lose their original ledger.
    if deferred then deferred:close() end
    deferred,deferred_jobs,deferred_order,deferred_bindings=nil,{},{},{}
    unavailable_reason=nil
    recovery_retry_at,recovery_retries=nil,0
    command_context = nil
    told_old, told_count = {}, 0
    stock = { open=false, serial=0, jobs={}, order={}, later={} }
    nonce_serial = nonce_serial + 1
    M.epoch = epoch
    M.local_nonce = string.format("%x-%x-%x", os.time(), math.floor(now() * 1000000), nonce_serial)
    M.server_nonce, M.guild, M.server_guild = nil, nil, nil
    M.server_item_limits = nil
    M.clients, M.pals, M.rules = {}, {}, {}
    M.pals_gen, M.pending_gen = M.pals_gen + 1, M.pending_gen + 1
    receiver, requests, cells, offers, sequence = nil, {}, {}, {}, 0
    hello_at, hello_tries, hello_failures = nil, 0, 0
    M.revisions = { P = 0, R = 0 }
    M.save_failures, durable_ack = {}, { P = 0, R = 0 }
    set_status("connecting", "awaiting_handshake")
    -- Also fires when a Welcome reveals a restarted server without a local
    -- ClientRestart. Main can immediately clear its separate remote caps view.
    if M.on_session then
        local ok, err = pcall(M.on_session, epoch)
        if not ok then log.warn("network session callback failed: " .. tostring(err)) end
    end
    return M.local_nonce
end

-- main owns the epoch and may call reset after begin_session in its reset list.
function M.reset() return M.begin_session(M.epoch) end

-- Main sets this to "the role is decided and this is a client". A Hello sent
-- before that was answered with an R snapshot that on_snapshot had to refuse,
-- which threw the stream away and spent one of the server's announcements
-- (round 3). Standalone transport fixtures leave it nil.
M.may_hello = nil

function M.hello()
    if api.has_authority() ~= false or M.status == "incompatible" then return false end
    if M.may_hello and M.may_hello() ~= true then return false end
    local t = now()
    if hello_at and t - hello_at < 2 then return false end
    local tries = hello_tries
    hello_at, hello_tries = t, math.min(6, hello_tries + 1)
    -- 0.4.1 recognizes Hello and replies in its old format. Seeing that reply
    -- explicitly reports incompatibility; it never enters our snapshot parser.
    local sent = send_up(table.concat({ PREFIX .. "Hello", M.SCHEMA, M.WORKS,
        M.local_nonce }, "|"), 0)
    if not sent then
        -- Nothing left this machine, so the server has not been asked yet.
        -- Keep the 5 s retry instead of backing off towards "no mod on this
        -- server" while the network component is still resolving (up to
        -- about 18 s into a join). Six of those, then the usual backoff.
        hello_failures = hello_failures + 1
        if hello_failures <= 6 then hello_tries = tries end
        set_status("connecting", "transport_unavailable")
    end
    return sent
end

-- The stand grid asking again for the full pal table: a pal caught after the
-- join, or a guild whose camps had not streamed in yet.
--
-- The handshake is not the grid's business. It asked from the first second
-- of a join, before the role was decided, and the 18 s announce asked again,
-- so an ordinary join spent the server's announcement budget and was told
-- off for it (round 3, "too many at once" in the 2026-10-29 retest). poll
-- owns the handshake now; this only asks a client that is already connected,
-- and an answer that is already on its way counts as asked.
-- true: a Hello went up. "pending": one went up in the last ASK_RECENT
-- seconds and its answer is a full table, so count the ask as made.
-- false: nothing sent; try again later.
local ASK_RECENT = 10
function M.ask_pals()
    if not can_edit() then return false end
    if hello_at and now() - hello_at < ASK_RECENT then return "pending" end
    return M.hello()
end

function M.to_server(command, value)
    if command == PREFIX .. "Hello" then return M.hello() end
    if command == PREFIX .. "Echo" then return send_up(command, value) end
    return false -- edits must carry request IDs and negotiated session fields
end

local function peer_for(comp, guild)
    local name = M.who(comp)
    local peer = name and M.clients[name]
    if not peer or peer.server ~= M.local_nonce or peer.guild ~= guild then return nil end
    return peer
end

-- Schema 3 lock control message. Only confirmed peers receive it; it grants
-- nothing. A client latches it until begin_session creates a fresh nonce.
local function peer_current(peer)
        local epoch,server,client,guild=M.epoch,M.local_nonce,peer.client,peer.guild
        local name
        for k,p in pairs(M.clients)do if rawequal(p,peer)then name=k;break end end
        return function()
            return api.has_authority()==true and M.epoch==epoch and M.local_nonce==server
                and name~=nil and rawequal(M.clients[name],peer) and peer.server==server
                and peer.client==client and peer.guild==guild
        end
end
local function unavailable(comp,peer,current)
    current=current or peer_current(peer)
    if not current() then return true end -- invalidated: stop this operation
    if not settings_gate.blocked() then return false end
    local reason=settings_gate.status()=='restart_required'
        and 'settings_restart_required' or 'settings_recovering'
    M.to_client(comp,wire.envelope('L',peer.server,peer.client,peer.guild)..'|'..reason,current)
    if not current() then return true end
    return true
end
local function snapshot_guard(comp,peer,current)
    return function()
        if not current() then return false end
        return not unavailable(comp,peer,current) and current()
    end
end

local function clear_stock_view(keep_metadata)
    stock.view, stock.pending = nil, nil
    if not keep_metadata then stock.metadata = nil end
    if stock.receiver then wire.invalidate(stock.receiver, 'S') end
end

-- When the next storage request may go. The server refuses a request that
-- ARRIVES under 1 s after the previous one (receive_stock) and says nothing,
-- so the client then waits out the 20 s pending timeout plus a 10 s poll.
-- Spacing sends by exactly 1 s lost that race to ordinary link jitter
-- (live 2026-10-29: no count for 45 s after a limit edit); keep a margin.
local STOCK_SPACING = 1.5
local function stock_soon()
    return math.max(now() + COALESCE, (stock.last_sent or -STOCK_SPACING) + STOCK_SPACING)
end

-- The guild's limits changed (an R snapshot with other rows committed or a
-- Set/Clear was acknowledged). The server's verdict in the cached count
-- described the old limits: drop it, keep the totals, and ask for a fresh
-- count soon (round 2, 2026-10-29: the panel showed a stale "Limit reached"
-- for up to ten seconds after an edit). A count already in flight keeps its
-- totals, and its verdict for REFRESH_VERDICT seconds only: it may have been
-- built before the edit (round 3), and the count that follows it soon
-- replaces it. Dropping that verdict at once left the panel at "No count
-- yet" for a whole extra round (live 2026-10-29).
local REFRESH_VERDICT = 2
local function limits_changed()
    if stock.view and stock.view.storage then stock.view.storage.limits = nil end
    if stock.pending then stock.pending.refresh = true end
    if stock.open then stock.due = stock_soon() end
end

function M.set_storage_open(open)
    open = open == true
    if stock.open == open then return end
    stock.open, stock.interest, stock.due = open, nil, nil
    clear_stock_view()
end

function M.request_stock(guild, selected)
    if not stock.open or not wire.token(guild) or (selected ~= nil and not wire.token(selected))
        or guild ~= M.guild or unavailable_reason then return false end
    local old = stock.interest
    if old and old.guild == guild and old.selected == selected then return true end
    -- No base asked for (a chat or console read such as `pwp limit`) is
    -- answered by whatever base is already chosen. Treating it as a new
    -- selection threw away the panel's count and request mid-flight.
    if old and old.guild == guild and selected == nil then return true end
    -- The UI adopts a server-selected default after the first complete reply.
    -- That is not a new selection and must not discard its just-received data.
    local view = stock.view or stock.metadata
    if old and old.guild == guild and view and
        (view.storage.scope == 'guild' or (old.selected == nil and view.storage.camp == selected)) then
        old.selected = selected
        return true
    end
    stock.interest = {guild=guild, selected=selected}
    clear_stock_view()
    stock.due = stock_soon()
    return true
end

function M.storage_view(guild, selected)
    local out = {verified=false, guild=guild, epoch=M.epoch, choices={},
        label='Storage unavailable', totals={}}
    local event, interest = stock.view or stock.metadata, stock.interest
    if not stock.open or unavailable_reason or not event or not interest or guild ~= M.guild
        or guild ~= interest.guild or event.guild ~= guild or event.epoch ~= M.epoch
        or event.session ~= M.server_nonce or event.client_session ~= M.local_nonce then return out end
    local view = event.storage
    if view.scope == 'camp' and view.camp ~= nil and selected ~= nil and view.camp ~= selected then return out end
    out.scope, out.camp, out.expires_at = view.scope, view.camp, event.expires_at
    for i, camp in ipairs(view.choices) do
        out.choices[i] = camp
        if camp == view.camp then out.index = i end
    end
    out.label = view.scope == 'guild' and 'All loaded bases in your guild'
        -- No camp id: "(a1b2c3d4)" meant nothing to a player (review P2-9).
        or (out.index and ('Base '..out.index..' of '..#out.choices)
            or 'Storage unavailable')
    -- Count freshness does not revoke confirmed selector metadata. Otherwise
    -- every TTL gap removes the header action needed to choose another camp.
    out.verified = view.verified == true and now() < event.expires_at
    if out.verified then
        -- Published totals are immutable by contract. The picker keys its
        -- sorted/search cache by this identity, so never copy on a UI read.
        out.totals = view.totals
        -- The server's verdicts describe this count and expire with it.
        if not event.limits_until or now() < event.limits_until then out.limits = view.limits end
    end
    return out
end

-- The server's limit state for the current, still fresh count, or nil.
function M.limit_state()
    local event = stock.view
    if not event or not stock.open or unavailable_reason or event.epoch ~= M.epoch
        or event.guild ~= M.guild or event.session ~= M.server_nonce
        or event.client_session ~= M.local_nonce or event.storage.verified ~= true
        or now() >= event.expires_at then return nil end
    if event.limits_until and now() >= event.limits_until then return nil end
    return event.storage.limits
end

-- Whether the server holds rocks of this item off in the counted scope; nil
-- while no fresh schema 5 count says.
function M.item_stopped(item)
    local limits = M.limit_state()
    if type(limits) ~= 'table' or type(limits.stopped) ~= 'table' then return nil end
    return limits.stopped[item] == true
end

local admit_stock
local function receive_stock(comp, p)
    if #p ~= 7 or not wire.token(p[6], 10) or not p[6]:match('^[1-9]%d*$')
        or not wire.integer(p[6], 1, 2147483647)
        or (p[7] ~= '-' and not wire.token(p[7])) then return false end
    local state, epoch, server = stock, M.epoch, M.local_nonce
    local function active() return stock == state and M.epoch == epoch and M.local_nonce == server
        and api.has_authority() == true end
    if not active() then return false end
    local name = M.who(comp, active)
    if not active() then return false end
    local peer = name and M.clients[name]
    if not peer then return false end
    local current_peer = peer_current(peer)
    local attempt
    local function current()
        return active() and current_peer() and (not attempt or peer.stock_attempt==attempt)
    end
    if not current() or p[3] ~= peer.server or p[4] ~= peer.client or p[5] ~= peer.guild then return false end
    local id, t = tonumber(p[6]), now()
    if id <= (peer.stock_high or 0) then return false end
    if peer.stock_at and t-peer.stock_at < 1 then
        -- Under 1 s after the last one: keep the newest and serve it once the
        -- second has passed (storage_tick), instead of dropping it unanswered.
        -- A save or pass on this thread delays handling a request, not its
        -- arrival, so a client spacing by its own send times could not avoid
        -- this; it then waited the 20 s timeout plus a 10 s poll (round 3).
        -- Plain values only. The guild is proven again when it is served.
        peer.stock_next = {request=p[6], selected=p[7], id=id, at=t}
        state.later[name] = peer
        return true
    end
    return admit_stock(name, peer, p[6], p[7], t, comp)
end

-- Queue one storage request. comp is the component it arrived on, or nil for a
-- request kept by receive_stock: that one was matched to this peer by name and
-- nonce, and stock_recipient proves the guild again before anything is sent.
admit_stock = function(name, peer, request, selected, t, comp)
    local state, epoch, server = stock, M.epoch, M.local_nonce
    local function active() return stock == state and M.epoch == epoch and M.local_nonce == server
        and api.has_authority() == true end
    local id = tonumber(request)
    local current_peer = peer_current(peer)
    local attempt
    local function current()
        return active() and current_peer() and (not attempt or peer.stock_attempt==attempt)
    end
    if not current() then return false end
    local count = 0
    for _ in pairs(state.jobs) do count = count + 1 end
    if not state.jobs[name] and count >= 8 then return false end
    -- Debit before the transmitter census, including failed ownership probes.
    -- A nested request supersedes this invocation even before a job exists.
    attempt = {}
    peer.stock_attempt, peer.stock_at, peer.stock_next = attempt, t, nil
    local guild = peer.guild
    if comp then
        guild = push_phase('network storage: request guild',M.guild_of_sender,comp,current)
        if not current() or guild ~= peer.guild then return false end
    end
    -- Native ownership resolution may have admitted other peers reentrantly.
    -- Recount immediately before insertion, with no native/callback boundary.
    count = 0
    for _ in pairs(state.jobs) do count = count + 1 end
    local added = state.jobs[name] == nil
    if added and count >= 8 then return false end
    peer.stock_high = id
    local job = {name=name, peer=peer, request=request, selected=selected ~= '-' and selected or nil,
        queued=t, epoch=epoch, server=server, client=peer.client, guild=guild}
    if not state.jobs[name] or state.active == state.jobs[name] then state.order[#state.order+1] = name end
    state.jobs[name] = job
    M.storage_stats.requests = M.storage_stats.requests + 1
    M.storage_stats.queue_peak = math.max(M.storage_stats.queue_peak, count + (added and 1 or 0))
    -- Publish the job before the callback so nested requests supersede it.
    if not settings_gate.blocked() then
        local ok, accepted = pcall(function()
            return M.on_storage_interest and M.on_storage_interest(guild)
        end)
        if not current() or state.jobs[name] ~= job then return false end
        if not ok or accepted ~= true then
            state.jobs[name] = nil
            for i=#state.order,1,-1 do
                if state.order[i]==name then table.remove(state.order,i) end
            end
            return false
        end
    end
    return true
end

-- Requests kept by receive_stock, served once their peer's second has passed.
-- Plain Lua over the few peers that have one; no engine call until admitted.
local function serve_later()
    local state, t, names = stock, now(), {}
    -- Listed first: admitting can reenter receive_stock, which adds to later.
    for name in pairs(state.later) do names[#names+1] = name end
    for _, name in ipairs(names) do
        local peer = state.later[name]
        local wanted = peer and peer.stock_next
        if not wanted or M.clients[name] ~= peer or peer.server ~= M.local_nonce
            or wanted.id <= (peer.stock_high or 0) or t - wanted.at >= wire.TIMEOUT then
            state.later[name] = nil
            if peer then peer.stock_next = nil end
        elseif not peer.stock_at or t - peer.stock_at >= 1 then
            state.later[name] = nil
            admit_stock(name, peer, wanted.request, wanted.selected, t, nil)
            if stock ~= state then return end
        end
    end
end

local function stock_recipient(job, current)
    -- Reuse a single synchronous transmitter census for component resolution
    -- AND ownership proof. No wrappers or lookup table escape this callback.
    M.storage_stats.transmitter_walks = M.storage_stats.transmitter_walks + 1
    local tx = push_phase('network storage: transmitters', transmitters, current)
    if not current() then return nil end
    local cls, comp
    pcall(function() cls=api.cdo('/Script/Pal.PalNetworkBaseCampComponent') end)
    if not current() then return nil end
    if cls then
        for _, transmitter in pairs(tx) do
            if not current() then return nil end
            local candidate
            pcall(function() candidate=transmitter:GetComponentByClass(cls) end)
            if not current() then return nil end
            local valid=api.valid(candidate)
            if not current() then return nil end
            if valid and M.who(candidate,current)==job.name then comp=candidate; break end
            if not current() then return nil end
        end
    end
    if not current() then return nil end
    if not comp then
        M.storage_stats.component_fallbacks = M.storage_stats.component_fallbacks + 1
        comp=push_phase('network storage: component fallback',live_client,job.name,current)
    end
    if not current() or not comp then return nil end
    local guild=push_phase('network storage: sender guild',guild_via,comp,tx,current)
    if not current() or guild~=job.guild then return nil end
    return comp, tx
end

local function pump_stock()
    local state, t = stock, now()
    -- One global active response avoids interleaving many ten-second batches.
    if not state.active then
        while #state.order > 0 do
            local name = table.remove(state.order, 1)
            local job = state.jobs[name]
            if job and t-job.queued < 12 then state.active = job; break end
            state.jobs[name] = nil
        end
    end
    local job = state.active
    if not job then return end
    local peer = job.peer
    local current_peer = peer_current(peer)
    local function current()
        return stock == state and state.active == job and state.jobs[job.name] == job
            and M.epoch == job.epoch and M.local_nonce == job.server
            and peer.client == job.client and peer.guild == job.guild and current_peer()
    end
    local function discard()
        if state.active == job then state.active = nil end
        if state.jobs[job.name] == job then state.jobs[job.name] = nil end
    end
    if not current() or (job.started and t-job.started >= wire.TIMEOUT-1) then discard(); return end
    local comp, tx = stock_recipient(job, current)
    if not current() or not comp then discard(); return end
    -- This guard may send one lock packet. Never send S in that same beat.
    local guarded = snapshot_guard(comp, peer, current)
    if not guarded() then discard(); return end
    if not job.batch then
        M.storage_stats.builds = M.storage_stats.builds + 1
        local ok, view = pcall(function()
            return M.on_storage_request and push_phase('network storage: build',
                M.on_storage_request,job.guild,job.selected,t)
        end)
        if not current() then discard(); return end
        -- Schema 5: the server's own verdicts for exactly this view. Plain
        -- data from the last pass; a failure only leaves the reply without.
        if ok and type(view) == 'table' and M.on_limit_state then
            local got, limits = pcall(M.on_limit_state, job.guild, view)
            if not current() then discard(); return end
            if got and type(limits) == 'table' then
                local copy = {}
                for k, v in pairs(view) do copy[k] = v end
                copy.limits, view = limits, copy
            end
        end
        peer.stock_revision = (peer.stock_revision or 0) + 1
        local batch = ok and view and push_phase('network storage: encode',wire.storage_snapshot,job.server,job.client,job.guild,
            peer.stock_revision,job.request,view)
        if not batch and ok and type(view) == 'table' and view.limits ~= nil then
            -- An oversized or invalid limit state must not cost the count.
            view.limits = nil
            batch = wire.storage_snapshot(job.server,job.client,job.guild,peer.stock_revision,job.request,view)
        end
        if not batch then
            -- Preserve bounded selector metadata if possible, never partial totals.
            local unavailable_view = {scope=type(view)=='table' and view.scope or 'camp',
                camp=type(view)=='table' and view.camp or job.selected,
                choices=type(view)=='table' and view.choices or {}, verified=false,
                totals={},age_ms=0,remaining_ms=0}
            batch = wire.storage_snapshot(job.server,job.client,job.guild,
                peer.stock_revision,job.request,unavailable_view)
            if not batch then
                unavailable_view.choices = {}
                batch = wire.storage_snapshot(job.server,job.client,job.guild,
                    peer.stock_revision,job.request,unavailable_view)
            end
        end
        if not current() or not batch then discard(); return end
        job.batch, job.cursor, job.started = batch, 1, t
    end
    if not guarded() then discard(); return end
    -- No guard passed to to_client may itself send a packet during this send.
    local function send_current()
        return current() and not settings_gate.blocked() and now()-job.started < wire.TIMEOUT-1
    end
    local function authorize()
        local guild = push_phase('network storage: sender guild',guild_via,comp,tx,send_current)
        return send_current() and guild == job.guild
    end
    for packet = 1, 4 do
        if not send_current() or now()-job.started >= wire.TIMEOUT-1 then discard(); return end
        if not push_phase('network storage: send',M.to_client,comp,job.batch[job.cursor],send_current,authorize)
            or not send_current() then discard(); return end
        M.storage_stats.packets = M.storage_stats.packets + 1
        job.cursor = job.cursor + 1
        if job.cursor > #job.batch then discard(); return end
    end
end

function M.storage_tick()
    if api.has_authority() == true then
        local state = stock
        if state.pumping then return end
        state.pumping = true
        local ok, err = pcall(function()
            if next(state.later) ~= nil then serve_later() end
            pump_stock()
        end)
        state.pumping = false
        if not ok then error(err) end
        return
    end
    if api.has_authority() ~= false or not stock.open or unavailable_reason then return end
    local t, interest = now(), stock.interest
    if stock.receiver then
        local aged = stock.view and stock.view.storage.verified and t >= stock.view.expires_at
        if wire.expire(stock.receiver,t) then
            clear_stock_view(true)
            -- A count that only aged out keeps the poll already due for it.
            -- It can expire just before that poll, and putting the poll off
            -- by another 10 s left the panel with no count for that long
            -- (round 3). No extra request: it is the same poll. A broken or
            -- timed out transfer still backs off 10 s.
            stock.due = aged and math.min(stock.due or t+10, t+10) or t+10
        end
    end
    if stock.pending then
        if t-stock.pending.started < 20 then return end
        clear_stock_view(true); stock.due=t+10
    end
    if not interest or not receiver or interest.guild ~= receiver.guild
        or (stock.due and t < stock.due) then return end
    stock.serial = stock.serial + 1
    if stock.serial > 2147483647 then return end
    local id = tostring(stock.serial)
    stock.receiver = stock.receiver or wire.receiver(receiver.server,receiver.client,receiver.guild)
    if not wire.expect_storage(stock.receiver,id,nil,interest.selected,t) then return end
    stock.pending = {id=id,started=t,interest=interest}
    stock.due, stock.last_sent = t+10, t
    local state, pending, target = stock, stock.pending, receiver
    local function current()
        return stock==state and stock.open and stock.pending==pending and stock.interest==interest
            and receiver==target and not unavailable_reason and api.has_authority()==false
    end
    local sent = send_up(wire.envelope('T',receiver.server,receiver.client,receiver.guild)
        ..'|'..id..'|'..(interest.selected or '-'),0,current)
    if stock ~= state or stock.pending ~= pending then return end
    if not sent then clear_stock_view(true); stock.due=t+10 end
end

local function receive_stock_state(message)
    local state, pending = stock, stock.pending
    if not state.open or not pending or not state.receiver then return false end
    local event, err = wire.receive(state.receiver,message,now())
    if err then return false end -- S uncertainty never changes P/R readiness.
    if not event then return true end
    if stock ~= state or state.pending ~= pending or state.interest ~= pending.interest
        or event.stream ~= 'S' or event.request ~= pending.id then return false end
    local view = event.storage
    if not view or (view.verified and view.scope=='camp' and pending.interest.selected ~= nil
        and view.camp ~= pending.interest.selected) then return false end
    if not wire.commit(state.receiver,event,now()) then return false end
    local totals = {}
    for item, amount in pairs(view.totals) do totals[item] = amount end
    view.totals = totals -- one owned publication per atomic commit
    -- The flag is server configuration, not part of the count: it stays
    -- known for this session after the count expires.
    if view.limits and view.limits.per_item ~= nil then M.server_item_limits = view.limits.per_item end
    event.epoch = M.epoch
    -- Retain only plain selector metadata across count expiry/timeouts, never
    -- a reference to the expired totals. Lifecycle/selection clears both.
    state.metadata = {epoch=event.epoch, guild=event.guild, session=event.session,
        client_session=event.client_session, storage={scope=view.scope,camp=view.camp,choices=view.choices}}
    state.view, state.pending, state.due = event, nil, now()+10
    if pending.refresh then
        state.due = stock_soon()
        -- Possibly built before the edit: its verdict lives only until the
        -- count that follows it is due back.
        if view.limits ~= nil then event.limits_until = now() + REFRESH_VERDICT end
    end
    return true
end

local function send_ack(comp, peer, id, accepted, reason, revisions, extra)
    -- Freeze before any authority/settings/native guard can reenter. A retry
    -- must replay the original publication boundary, not borrow later state.
    revisions = revisions or peer.revisions
    local priority_revision, rules_revision = revisions.P, revisions.R
    local current=snapshot_guard(comp,peer,peer_current(peer))
    if extra then
        local base=current
        current=function()return base() and extra()end
    end
    if not current() then return false end
    local outcome = accepted == "applied_unsaved" and "2" or (accepted and "1" or "0")
    return M.to_client(comp, wire.envelope("A", peer.server, peer.client, peer.guild)
        .. "|" .. id .. "|" .. outcome .. "|" .. reason
        .. "|" .. priority_revision .. "|" .. rules_revision,current)
end

-- The token is internal to receive_command, not supplied by the wire. Invalid
-- tokens abstain rather than doing a fresh lookup for a superseded request.
function M.command_guild(token, comp, epoch)
    local c = command_context
    if not c or not rawequal(c.token, token) then return nil end
    local name = M.who(comp)
    -- The native name read may itself dispatch a nested callback.
    if command_context ~= c or c.epoch ~= epoch or M.epoch ~= c.epoch
        or M.local_nonce ~= c.server or not rawequal(M.clients[c.name], c.peer)
        or c.peer.guild ~= c.guild or c.peer.client ~= c.client
        or c.peer.server ~= c.server or name ~= c.name then return nil end
    return c.guild
end

function M.receive_command(comp, command, value)
    -- A reentrant invocation invalidates the outer lookup, even if rejected.
    command_context = nil
    if not api.has_authority() or not api.valid(comp) then return false end
    local p = wire.parts(command)
    if not p then return false end
    local name = M.who(comp)
    if not name then return false end
    if p[1] == PREFIX .. "Hello" then
        if #p ~= 4 or tonumber(p[2]) ~= M.SCHEMA or tonumber(p[3]) ~= M.WORKS
            or not wire.token(p[4], 64) then
            M.to_client(comp, PREFIX .. "Incompatible|" .. M.SCHEMA .. "|" .. M.WORKS)
            local schema = wire.integer(p[2], 1, 2147483647)
            M.notify_old_client(comp, schema ~= nil and schema > M.SCHEMA)
            return false
        end
        local guild = M.guild_of_sender(comp)
        if not wire.token(guild) then return false end -- unresolved is not empty
        local offer_count = 0
        for who, offer in pairs(offers) do
            if now() - offer.at >= wire.TIMEOUT then offers[who] = nil
            else offer_count = offer_count + 1 end
        end
        if offers[name] and now() - offers[name].at < 1 then return false end
        if not offers[name] and offer_count >= 128 then return false end
        local peer = M.clients[name]
        if not peer or peer.client ~= p[4] or peer.guild ~= guild then
            local count = 0
            for _ in pairs(M.clients) do count = count + 1 end
            if not peer and count >= 128 then return false end
            peer = { server = M.local_nonce, client = p[4], guild = guild,
                at = now(), acks = {}, order = {}, high = 0, revisions = { P = 0, R = 0 },
                next_revision = { P = 0, R = 0 } }
        end
        challenge_serial = challenge_serial + 1
        local challenge = tostring(challenge_serial)
        offers[name] = { peer = peer, challenge = challenge, at = now() }
        -- Do not replace a live peer on Hello alone: an old queued Hello can
        -- still arrive after reconnect. Only the matching fresh challenge can
        -- confirm this offer; its recipient must still have that client nonce.
        if not M.to_client(comp, table.concat({ PREFIX .. "Welcome", M.SCHEMA,
            M.WORKS, peer.client, peer.server, peer.guild, challenge }, "|")) then return false end
        return true
    end
    if p[1] == "PWP_V2" and p[2] == "C" then
        local offer = offers[name]
        if #p ~= 6 or not offer or now() - offer.at >= wire.TIMEOUT then return false end
        local peer = offer.peer
        if p[3] ~= peer.server or p[4] ~= peer.client or p[5] ~= peer.guild
            or p[6] ~= offer.challenge or M.guild_of_sender(comp) ~= peer.guild then return false end
        offers[name], M.clients[name] = nil, peer
        if unavailable(comp,peer) then return false end
        if M.on_command then
            local ok, err = pcall(M.on_command, PREFIX .. "Hello", value, comp)
            if not ok then log.warn("network hello handler failed: " .. tostring(err)) end
        end
        return true
    end
    if p[1] == 'PWP_V2' and p[2] == 'T' then return receive_stock(comp,p) end
    if p[1] ~= "PWP_V2" or p[2] ~= "Q" then
        -- Old mutations never reach main, even if the component once negotiated.
        if command:sub(1, #PREFIX) == PREFIX then
            M.to_client(comp, PREFIX .. "Incompatible|" .. M.SCHEMA .. "|" .. M.WORKS)
            M.notify_old_client(comp)
        end
        return false
    end
    local guild = M.guild_of_sender(comp)
    local peer = peer_for(comp, guild)
    if not peer or p[3] ~= peer.server or p[4] ~= peer.client or p[5] ~= peer.guild then return false end
    if unavailable(comp,peer) then return false end
    local id = wire.integer(p[6], 1, 2147483647)
    if not id then return false end
    -- Reserve through result publication, including error logging/authority
    -- checks that may reenter. Unknown in-flight IDs have no result to reply.
    -- Completed cached IDs can still replay their original result.
    if peer.inflight and not peer.acks[id] then return false end
    local edit = {}
    for i = 7, #p do edit[#edit + 1] = p[i] end
    local legacy = wire.edit(edit)
    if not legacy then send_ack(comp, peer, id, false, "invalid_edit"); return false end
    local old = peer.acks[id]
    if old then
        if old.command ~= legacy then send_ack(comp, peer, id, false, "request_id_reused"); return false end
        if old.unknown then return false end
        send_ack(comp, peer, id, old.accepted, old.reason, old.revisions)
        return old.accepted
    end
    -- A native callback can synchronously deliver another request while main
    -- is applying this peer's edit. Reserve before mutation; do not reject the
    -- still-running ID as stale or admit an overlapping mutation. No result is
    -- known yet. Cached completed results above remain replayable.
    if peer.inflight then return false end
    if id <= peer.high then send_ack(comp, peer, id, false, "stale_request"); return false end
    peer.high = id
    local context = { token = {}, epoch = M.epoch, server = M.local_nonce,
        client = peer.client, guild = guild, name = name, peer = peer }
    peer.inflight = context
    command_context = context
    -- Main retains sender/guild/rate/capability validation. Only explicit true
    -- acknowledges acceptance; a sent RPC or a non-throwing nil never does.
    local reservation,ledger,stream=nil,deferred,edit[1]=="Prio" and "P" or "R"
    local ok, accepted, reason, receipt = pcall(function()
        if ledger then
            -- Prune plain metadata on admission too: timers can be delayed.
            -- reserve() expires ledger entries internally, so its discarded
            -- expiry list must not leave an unbounded transport-side queue.
            local t=now()
            for ticket,job in pairs(deferred_jobs)do
                if t>=job.entry.deadline or M.clients[job.name]~=job.peer then
                    ledger:unknown(ticket,t);deferred_jobs[ticket]=nil
                end
            end
            local order={}
            for _,ticket in ipairs(deferred_order)do if deferred_jobs[ticket] then order[#order+1]=ticket end end
            deferred_order=order
            for who,bound in pairs(deferred_bindings)do
                if M.clients[who]~=bound.peer then ledger:invalidate(bound.binding);deferred_bindings[who]=nil end
            end
            local count=0;for _ in pairs(deferred_jobs)do count=count+1 end
            if count>=128 then return false,'busy' end
            if type(M.pending_owner)~='function' then return false,'unavailable' end
            local owner=M.pending_owner(stream,guild)
            if owner~=false then
                if type(owner)~='table' or getmetatable(owner) or owner.epoch~=context.epoch then return false,'unavailable' end
                local binding=ledger:bind{name=name,server=context.server,client=context.client,
                    guild=owner.guild,epoch=context.epoch}
                if not binding then return false,'unavailable' end
                deferred_bindings[name]={peer=peer,binding=binding}
                reservation=ledger:reserve(binding,id,stream=='P' and 'priorities' or 'limits',legacy,now())
                if not reservation or reservation.status~='reserved' then reservation=nil;return false,'busy' end
            end
        end
        -- Owner lookup may reenter. Authenticate the invocation again before
        -- permitting its first mutation, without retaining a native wrapper.
        if api.has_authority()~=true or command_context~=context or M.epoch~=context.epoch
            or M.local_nonce~=context.server or M.clients[name]~=peer
            or peer.server~=context.server or peer.client~=context.client or peer.guild~=context.guild
            or (reservation and deferred~=ledger) then return false,'session_changed' end
        if M.on_command then return M.on_command(legacy, value, comp, context.token) end
        return false
    end)
    -- Bind the handler result before the following authority probe can dispatch
    -- a newer publication in a nested callback.
    local revisions = { P = peer.revisions.P, R = peer.revisions.R }
    if command_context == context then command_context = nil end
    if not ok then
        -- Error values may have throwing __tostring; the diagnostic sink may
        -- also fail. Neither may strand this peer's mutation reservation.
        pcall(function() log.warn("network edit handler failed: " .. tostring(accepted)) end)
    end
    -- Main re-proves authority before any Pal access. If that probe discovers
    -- a transition, this callback is no longer a server reply context either.
    local authority_ok, authority = pcall(api.has_authority)
    -- An unavailable proof is an unknown result, never a definite rejection.
    -- Cache only against the unchanged plain peer/session identity below.
    if not authority_ok then ok = false end
    if (authority_ok and authority ~= true) or M.epoch ~= context.epoch
        or M.local_nonce ~= context.server or M.clients[name] ~= peer
        or peer.server ~= context.server or peer.client ~= context.client
        or peer.guild ~= context.guild then
        if reservation then ledger:unknown(reservation.ticket,now()) end
        if peer.inflight == context then peer.inflight = nil end
        return false
    end
    if reservation and ledger~=deferred then ok=false end
    -- Pending memory acceptance is not a final outcome. Without the explicit
    -- deferred trial, keep the conservative unknown/timeout fallback. With it,
    -- only the reserved, matching receipt can enter the bounded completion queue.
    local pending = ok and accepted == false and reason == "pending"
    if pending then
        reason = "pending"
    elseif ok and accepted == "applied_unsaved" then
        reason = "save_failed"
    else
        accepted = ok and accepted == true
        reason = accepted and "applied" or (ok and rejection_reason(reason) or "handler_error")
    end
    peer.acks[id] = { command = legacy, accepted = accepted, reason = reason,
        revisions = revisions, unknown = not ok or pending }
    local record=peer.acks[id]
    if reservation then
        if pending and ledger==deferred then
            local entry=ledger:accepted(reservation.ticket,receipt,now())
            if entry then
                deferred_jobs[entry.ticket]={entry=entry,record=record,peer=peer,name=name,
                    stream=stream,epoch=context.epoch,server=context.server,client=context.client,guild=context.guild}
                deferred_order[#deferred_order+1]=entry.ticket
            else ledger:unknown(reservation.ticket,now()) end
        elseif ok and accepted==false then ledger:reject(reservation.ticket,now())
        else
            ledger:unknown(reservation.ticket,now());record.unknown=true
        end
    end
    if peer.inflight == context then peer.inflight = nil end
    peer.order[#peer.order + 1] = id
    if #peer.order > 128 then peer.acks[table.remove(peer.order, 1)] = nil end
    -- An exception may follow a write. No negative ACK can prove it did not
    -- apply; retain a bounded tombstone and let timeout/resync show actual state.
    if not ok or pending or record.unknown then return false end
    send_ack(comp, peer, id, accepted, reason, revisions)
    return accepted
end

local push_serial = 0
local function each_peer(comp, callback)
    push_serial = push_serial + 1
    local serial = push_serial
    local epoch, server = M.epoch, M.local_nonce
    local function active()
        local authority = api.has_authority()
        return authority == true and push_serial == serial and M.epoch == epoch
            and M.local_nonce == server
    end
    -- Plain peer records are captured before native discovery can reenter.
    -- A replaced peer must not inherit the old invocation's snapshot.
    local function recipient(name, peer)
        local client, guild, peer_server = peer.client, peer.guild, peer.server
        return function()
            return active() and rawequal(M.clients[name], peer)
                and peer.client == client and peer.guild == guild
                and peer.server == peer_server and peer_server == server
        end
    end
    local recipients, by_name = {}, {}
    for name, peer in pairs(M.clients) do
        local target = {name=name, peer=peer, current=recipient(name, peer)}
        recipients[#recipients+1], by_name[name] = target, target
    end
    if comp then
        local name = M.who(comp, active)
        local target = name and by_name[name]
        if not target or not target.current() then return false end
        local peer, current = target.peer, target.current
        local guild = push_phase("network push: direct guild", M.guild_of_sender, comp, current)
        return current() and guild == peer.guild and callback(comp, peer, guild, current) or false
    end
    if #recipients == 0 then return false end
    local live = {}
    local tx, sent = push_phase("network push: transmitters", transmitters, active), false
    if not active() then return false end
    -- Resolve from freshly enumerated actors, not their untyped outer wrappers.
    -- The /Script/ class may be cached by palapi; instances never escape here.
    local cls
    pcall(function() cls = api.cdo("/Script/Pal.PalNetworkBaseCampComponent") end)
    if not active() then return false end
    if cls then
        for _, transmitter in pairs(tx) do
            if not active() then return false end
            local c
            pcall(function() c = transmitter:GetComponentByClass(cls) end)
            if not active() then return false end
            local valid = api.valid(c)
            if not active() then return false end
            if valid then
                local name = M.who(c, active)
                if not active() then return false end
                local target = name and by_name[name]
                if target and target.current() then live[name] = c end
            end
        end
    end
    -- GetComponentByClass can miss the exact negotiated component. Preserve
    -- completeness with one lazy fallback; do not charge peer misses first.
    local missing = false
    for _, target in ipairs(recipients) do
        if target.current() and not live[target.name] then missing = true end
    end
    if not active() then return false end
    if missing then
        local components = push_phase("network push: component scan", FindAllOf, "PalNetworkBaseCampComponent") or {}
        if not active() then return false end
        for _, c in ipairs(components) do
            local valid = api.valid(c)
            if not active() then return false end
            if valid then
                local name = M.who(c, active)
                if not active() then return false end
                if name and by_name[name] then live[name] = c end
            end
        end
    end
    for _, target in ipairs(recipients) do
        if not active() then return false end
        local name, peer, current = target.name, target.peer, target.current
        local c = live[name]
        if c and current() then
            local guild = push_phase("network push: peer guild", guild_via, c, tx, current)
            if not active() then return false end
            if current() and guild == peer.guild then
                if callback(c, peer, guild, current) and current() then
                    sent = true; peer.at = now(); peer.misses = 0
                end
            elseif current() and guild ~= nil then
                -- Guild membership changed: force a new Welcome before sending.
                M.clients[name] = nil
            end
        elseif current() then
            peer.misses = (peer.misses or 0) + 1
            if peer.misses >= 3 then M.clients[name] = nil end
        end
    end
    return active() and sent
end

local function push_snapshot(comp, peer, stream, mode, rows, current)
    if not current() then return false end
    M.revisions[stream] = M.revisions[stream] + 1
    peer.next_revision[stream] = peer.next_revision[stream] + 1
    local revision = peer.next_revision[stream]
    local batch = push_phase("network push: encode snapshot", wire.snapshot,
        peer.server, peer.client, peer.guild, stream, revision, mode, rows)
    if not batch then
        log.warn("network snapshot refused: invalid or oversized " .. stream .. " data")
        return false
    end
    for _, msg in ipairs(batch) do
        if not current() then return false end
        if not push_phase("network push: send message", M.to_client, comp, msg, current) then return false end
        if not current() then return false end
    end
    peer.revisions[stream] = revision
    return true
end

-- Optional composition-root policy; standalone transport fixtures have no
-- persistence owner. Capture once BEFORE building rows, then check after every
-- callback/send boundary. A denied/throwing provider never means empty data.
local function publication_guard(stream,cfg)
    if M.publication_guard==nil then return function()return true end end
    local provider=M.publication_guard
    local ok,guard=pcall(provider,stream,cfg)
    if not ok or type(guard)~='function' then return nil end
    return function()
        if M.publication_guard~=provider then return false end
        local yes,current=pcall(guard)
        return yes and current==true and M.publication_guard==provider
    end
end

local function guard_publication(peer,current,publication)
    local epoch,server,client,guild=M.epoch,M.local_nonce,peer.client,peer.guild
    local name
    for key,value in pairs(M.clients)do if rawequal(value,peer)then name=key;break end end
    return function()
        if not current() or not publication() then return false end
        -- Publication can reenter; finish with plain identity checks, not
        -- another native callback that could open a new unchecked boundary.
        return name~=nil and M.epoch==epoch and M.local_nonce==server
            and rawequal(M.clients[name],peer) and peer.server==server
            and peer.client==client and peer.guild==guild
    end
end

function M.push_pals(rows_for, comp, only_key, extra)
    if not api.has_authority() or type(rows_for) ~= "function" then return false end
    local publication=publication_guard("P")
    if not publication then return false end
    if extra then
        local base=publication
        publication=function()return base() and extra()end
    end
    local built = {}
    return each_peer(comp, function(c, peer, guild, current)
        local peer_guard=snapshot_guard(c,peer,current)
        current=guard_publication(peer,peer_guard,publication)
        if not current() then return false end
        local rows = built[guild]
        if not rows then
            rows = {}
            local source, reason = push_phase("network push: roster", rows_for, guild)
            if not current() then return false end
            if type(source) ~= "table" then
                log.warn("stand data unavailable for " .. guild .. ": " ..
                    tostring(reason or "roster builder did not return a table"))
                return false
            end
            for _, row in ipairs(source) do
                if type(row) ~= "table" then
                    log.warn("stand data unavailable for " .. guild .. ": invalid roster row")
                    return false
                end
                if only_key == nil or row.key == only_key then
                    local ranks, prios = {}, {}
                    if not wire.pal_key(row.key) then return false end
                    for i = 1, M.WORKS do
                        local r = row.ranks and row.ranks[i] or 0
                        r = wire.integer(r, 0, 999)
                        local p
                        if row.prios then p = row.prios[i] end
                        local encoded = wire.priority(p)
                        if not r or not encoded then return false end
                        ranks[i], prios[i] = tostring(math.min(r, 9)), encoded
                    end
                    rows[#rows + 1] = row.key .. "|" .. table.concat(ranks) .. "|" .. table.concat(prios)
                end
            end
            built[guild] = rows
        end
        if only_key and #rows == 0 then return false end
        -- A delta must never be the first state a newly joined peer receives.
        if only_key and peer.revisions.P == 0 then return false end
        return push_snapshot(c, peer, "P", only_key and "D" or "F", rows, current)
    end)
end

function M.push_rules(caps, cfg, comp, extra)
    if not api.has_authority() then return false end
    local publication=publication_guard("R",cfg)
    if not publication then return false end
    if extra then
        local base=publication
        publication=function()return base() and extra()end
    end
    local built = {}
    return each_peer(comp, function(c, peer, guild, current)
        local peer_guard=snapshot_guard(c,peer,current)
        current=guard_publication(peer,peer_guard,publication)
        if not current() then return false end
        local rows = built[guild]
        if not rows then
            rows = {}
            for work, items in pairs(caps.all(cfg, guild)) do
                for item, amount in pairs(items) do
                    rows[#rows + 1] = work .. "|" .. item .. "|" .. tostring(amount)
                end
            end
            table.sort(rows)
            built[guild] = rows
        end
        return push_snapshot(c, peer, "R", "F", rows, current)
    end)
end

-- One queued receipt per invocation, with no retained UObject or guard closure.
-- Default-off; ordinary maintenance publishes module durability first. Empty
-- queues do no discovery/polling. Timeout never replays/cancels accepted bytes.
function M.complete_pending()
    if not deferred or deferred_busy or #deferred_order==0 then return false end
    local ledger=deferred
    deferred_busy=true
    local job,ticket,completed
    local ok,result=pcall(function()
        local expired=ledger:expire(now())
        if not expired then return false end
        for _,entry in ipairs(expired)do deferred_jobs[entry.ticket]=nil end
        repeat
            ticket=table.remove(deferred_order,1)
            job=ticket and deferred_jobs[ticket]
        until job or not ticket
        if not job then return false end
        local function live()
            return deferred==ledger and deferred_jobs[ticket]==job
                and M.epoch==job.epoch and M.local_nonce==job.server
                and M.clients[job.name]==job.peer and job.peer.server==job.server
                and job.peer.client==job.client and job.peer.guild==job.guild
                and job.peer.acks[job.entry.id]==job.record and now()<job.entry.deadline
        end
        if not live() or api.has_authority()~=true or not live() then return false end
        -- Reacquire and prove recipient in THIS callback; a stored name alone
        -- is never an ownership proof and no component is put into the queue.
        local comp=live_client(job.name,live)
        if not comp or not live() then return true end -- retry bounded by deadline
        local publication
        local function current()
            if not live() or api.has_authority()~=true or not live() then return false end
            if M.guild_of_sender(comp,live)~=job.guild or not live() then return false end
            if publication and not publication() then return false end
            return live() -- pure fence after every callback above
        end
        if not current() then return false end
        -- Avoid a second native receipt query while normal maintenance still
        -- reports pending. This precheck is not the final snapshot proof.
        local ready=publication_guard(job.stream)
        if not ready or not ready() then return true end
        if not current() or type(M.pending_status)~='function' then return false end
        local receipt={};for k,v in pairs(job.entry.receipt)do receipt[k]=v end
        local status,guard=M.pending_status(job.stream,receipt)
        if not current() then return false end
        if type(status)~='table' or getmetatable(status) then return false end
        if status.state=='saving' or status.state=='pending' then return true end
        if status.state~='saved' or type(status.body)~='string' or math.type(status.revision)~='integer'
            or status.revision<job.entry.receipt.revision
            or status.request_revision~=job.entry.receipt.revision or type(guard)~='function' then return false end
        publication=guard
        if not current() or type(M.publish_pending)~='function' then return false end
        local before=job.peer.revisions[job.stream]
        local sent=M.publish_pending(job.stream,comp,current)
        local revisions={P=job.peer.revisions.P,R=job.peer.revisions.R}
        if not current() then return false end
        if sent~=true then return true end
        local revision=revisions[job.stream]
        if math.type(revision)~='integer' or revision<=before then return false end
        local done=ledger:complete(ticket,{receipt=job.entry.receipt,
            covered_revision=status.revision,snapshot_revision=revision},now())
        if not done or not current() then return false end
        -- Freeze a durable result ONLY after full guarded snapshot delivery.
        job.record.accepted,job.record.reason,job.record.unknown=true,'applied',false
        job.record.revisions=revisions;completed=true
        send_ack(comp,job.peer,job.entry.id,true,'applied',revisions,current)
        return false
    end)
    if job and deferred_jobs[ticket]==job then
        if ok and result==true and deferred==ledger then
            deferred_order[#deferred_order+1]=ticket
        else
            if not completed then ledger:unknown(ticket,now()) end
            deferred_jobs[ticket]=nil
        end
    end
    deferred_busy=false
    return completed==true
end

local function finish_entry(entry, status, reason)
    if entry.id then requests[entry.id] = nil end
    if entry.cell then cells[entry.cell] = nil end
    notify_edit(entry, status, reason)
end

local function settle(entry)
    if not entry.accepted then return end
    local stream = entry.cell and "P" or "R"
    local needed = entry.revision or 0
    if needed <= (entry.base_revision or 0) or not receiver
        or receiver.resync[stream] or receiver.revisions[stream] < needed then return end
    -- A later durable write of this file covers earlier accepted dirty edits.
    -- An unrelated file, a stale ack, or a snapshot by itself proves no save.
    if entry.unsaved and entry.id <= durable_ack[stream] then entry.unsaved = false end
    if not entry.unsaved then
        durable_ack[stream] = math.max(durable_ack[stream], entry.id)
        if M.save_failures[stream] and M.save_failures[stream] <= durable_ack[stream] then
            M.save_failures[stream] = nil
        end
        if wire.ready(receiver) then set_status("ready") end
    end
    if entry.cell and entry.desired ~= entry.sent_value then
        requests[entry.id] = nil
        entry.id, entry.accepted, entry.unsaved, entry.due = nil, nil, nil, now() + COALESCE
        notify_edit(entry, "pending")
    else
        finish_entry(entry, entry.unsaved and "applied_unsaved" or "accepted",
            entry.unsaved and "save_failed" or nil)
    end
end

-- Which side is older decides the advice (round 3): "ask the host to update
-- the server" is wrong when the server is the newer one. Welcome and
-- Incompatible both carry the server's schema; anything else keeps the
-- neutral reason.
function M.mismatch_reason(schema, fallback)
    schema = tonumber(schema)
    if schema and schema > M.SCHEMA then return "server_newer" end
    if schema and schema < M.SCHEMA then return "server_older" end
    return fallback
end

function M.receive_state(message)
    if api.has_authority() ~= false then return false end
    local p = wire.parts(message)
    if not p then return false end
    if p[1] == PREFIX .. "Welcome" then
        if #p ~= 7 or p[4] ~= M.local_nonce then return false end
        if tonumber(p[2]) ~= M.SCHEMA or tonumber(p[3]) ~= M.WORKS then
            set_status("incompatible", M.mismatch_reason(p[2], "schema_or_work_width")); return false
        end
        if not wire.token(p[5], 64) or not wire.token(p[6])
            or not wire.integer(p[7], 1, 2147483647) then return false end
        if receiver and (receiver.server ~= p[5] or receiver.guild ~= p[6]) then
            -- A server restart or guild change needs a fresh local nonce. Old
            -- requests and delayed snapshots can no longer belong to that join.
            local epoch = M.epoch
            M.begin_session(epoch)
            set_status("connecting", "server_session_changed")
            M.hello()
            return false
        end
        if not receiver then receiver = wire.receiver(p[5], M.local_nonce, p[6]) end
        M.server_nonce, M.guild, M.server_guild = p[5], p[6], p[6]
        hello_tries = 0
        if not wire.ready(receiver) then set_status("connecting", "awaiting_snapshots") end
        return send_up(wire.envelope("C", p[5], M.local_nonce, p[6]) .. "|" .. p[7], 0)
    end
    if p[1] == PREFIX .. "Incompatible" or p[1] == PREFIX .. "Reset"
        or p[1] == PREFIX .. "PalReset" or p[1] == PREFIX .. "Pal"
        or p[1] == PREFIX .. "Rule" or p[1] == PREFIX .. "Done" or p[1] == PREFIX .. "PalDone" then
        if not receiver then
            local schema = p[1] == PREFIX .. "Incompatible" and p[2] or nil
            set_status("incompatible", M.mismatch_reason(schema, "server_requires_matching_mod"))
        end
        return false
    end
    if not receiver or p[1] ~= "PWP_V2" or p[3] ~= receiver.server
        or p[4] ~= receiver.client or p[5] ~= receiver.guild then return false end
    if p[2]=='L' then
        if #p~=6 or (p[6]~='settings_restart_required' and p[6]~='settings_recovering') then return false end
        if unavailable_reason=='settings_restart_required' then return true end
        unavailable_reason=p[6]
        if unavailable_reason=='settings_recovering' and not recovery_retry_at then
            recovery_retry_at=now()+math.min(30,5*2^recovery_retries)
        elseif unavailable_reason=='settings_restart_required' then recovery_retry_at=nil end
        wire.invalidate(receiver,'P');wire.invalidate(receiver,'R')
        clear_stock_view()
        requests,cells={},{}
        M.pals,M.rules={},{}
        M.pals_gen,M.pending_gen=M.pals_gen+1,M.pending_gen+1
        set_status('unavailable',unavailable_reason,true)
        return true
    end
    if unavailable_reason then return false end
    -- Malformed/unknown S kinds must also stay out of the P/R error path.
    if p[6] == 'S' then
        return receive_stock_state(message)
    end
    if p[2] == "A" then
        if #p ~= 10 or (p[7] ~= "0" and p[7] ~= "1" and p[7] ~= "2") then return false end
        local id = wire.integer(p[6], 1, 2147483647)
        local pr, rr = wire.integer(p[9], 0, 2147483647), wire.integer(p[10], 0, 2147483647)
        local entry = id and requests[id]
        if not entry or not pr or not rr then return false end
        if p[7] == "0" then
            local reason=rejection_reason(p[8])
            finish_entry(entry, "rejected", reason)
            -- Rejection changes no confirmed data. Retain snapshot readiness,
            -- or existing uncertainty; it cannot repair a missing snapshot.
            -- Force the callback after on_edit; ready preserves save failures.
            if wire.ready(receiver) then set_status("ready",reason,true)
            else set_status(M.status,M.status_reason,true) end
        else
            local stream = entry.cell and "P" or "R"
            entry.accepted, entry.revision = true, entry.cell and pr or rr
            entry.unsaved = p[7] == "2" and id > durable_ack[stream]
            if entry.unsaved then
                M.save_failures[stream] = math.max(M.save_failures[stream] or 0, id)
                if wire.ready(receiver) then set_status("ready") end
            end
            if not entry.cell then limits_changed() end
            notify_edit(entry, entry.unsaved and "applied_unsaved" or "acknowledged",
                entry.unsaved and "save_failed" or "awaiting_snapshot")
            settle(entry)
        end
        return true
    end
    local target = receiver
    local event, err = wire.receive(target, message, now())
    if err then
        if err ~= "stale_revision" and err ~= "wrong_session" then set_status("connecting", err) end
        return false
    end
    if not event then return true end
    local metadata = { server_session = event.session, session = M.epoch, epoch = M.epoch,
        client_session = event.client_session, stream = event.stream, mode = event.mode,
        revision = event.revision, guild = event.guild }
    if event.stream == "P" then
        if not wire.commit(target, event) then return false end
        local into = event.mode == "F" and {} or M.pals
        for _, row in ipairs(event.rows) do into[row.key] = { ranks = row.ranks, prios = row.prios } end
        M.pals, M.pals_gen = into, M.pals_gen + 1
    else
        local ok, result = pcall(function()
            if M.on_snapshot then return M.on_snapshot(event.rows, metadata) end
            if not M.on_state then return false end
            M.on_state(PREFIX .. "Reset", metadata)
            for _, row in ipairs(event.rows) do
                M.on_state(PREFIX .. "Rule|" .. row.work .. "|" .. row.item .. "|" .. row.amount, metadata)
            end
            return M.on_state(PREFIX .. "Done", metadata)
        end)
        if receiver ~= target or M.epoch ~= metadata.epoch or unavailable_reason then return false end
        if not ok or result ~= true or not wire.commit(target, event) then
            wire.invalidate(target, "R")
            set_status("connecting", "snapshot_apply_failed")
            return false
        end
        -- Every edit in any guild sends every peer a fresh R snapshot, most
        -- of them with the rows they already had. Only a real change drops
        -- the verdict and asks for a count; otherwise every open panel on the
        -- server flickered and re-requested at once (round 3, about 50 ms of
        -- server walks per panel per edit).
        local changed = #event.rows ~= #M.rules
        for i = 1, #event.rows do
            if changed then break end
            local a, b = event.rows[i], M.rules[i]
            changed = a.work ~= b.work or a.item ~= b.item or a.amount ~= b.amount
        end
        M.rules = event.rows
        if changed then limits_changed() end
    end
    if wire.ready(receiver) then set_status("ready") end
    for _, entry in pairs(requests) do settle(entry) end
    return true
end

-- Kept for callers from an older hot-loaded UI. This no longer accepts bare rows.
function M.on_pal_message(message) return M.receive_state(message) end
function M.clear_pal_incoming()
    if receiver then
        wire.invalidate(receiver, "P")
        set_status("connecting", "snapshot_invalidated")
    end
end

function M.pending_priority(key, work)
    local entry = cells[tostring(key) .. "|" .. tostring(work)]
    if not entry then return nil, false end
    return wire.decode_priority(entry.desired), true, entry.status
end

function M.request_prio(key, work, prio)
    local encoded = wire.priority(prio)
    if not wire.pal_key(key) or not wire.integer(work, 1, M.WORKS) or not encoded then return false end
    if not can_edit() then return false end
    local cell = key .. "|" .. work
    local entry = cells[cell]
    if not entry then
        local count = 0
        for _ in pairs(cells) do count = count + 1 end
        if count >= 128 then return false end
        entry = { cell = cell, key = key, work = work }
        cells[cell] = entry
    end
    entry.desired, entry.due, entry.expires = encoded, now() + COALESCE, now() + ACK_TIMEOUT
    notify_edit(entry, "pending")
    return true -- queued locally, explicitly not an acknowledgement
end

function M.request(kind, work, item, amount)
    local parts = kind == "clear" and { "Clear", work, item } or { "Set", work, item, tostring(amount) }
    if (kind ~= "clear" and kind ~= "set") or not wire.edit(parts)
        or not can_edit() then return false end
    local count = 0
    for _ in pairs(requests) do count = count + 1 end
    if count >= 128 then return false end
    sequence = sequence + 1
    if sequence > 2147483647 then return false end
    local entry = { id = sequence, command = table.concat(parts, "|"), sent_at = now(), work = work,
        base_revision = receiver.revisions.R }
    requests[sequence] = entry
    local sent = send_up(wire.envelope("Q", receiver.server, receiver.client, receiver.guild)
        .. "|" .. sequence .. "|" .. entry.command, 0)
    if not sent then finish_entry(entry, "rejected", "transport_unavailable"); return false end
    notify_edit(entry, "pending")
    return true
end

function M.poll()
    if api.has_authority() ~= false then return end
    local t = now()
    if unavailable_reason then
        if unavailable_reason=='settings_recovering' and recovery_retry_at and t>=recovery_retry_at then
            local retries=math.min(3,recovery_retries+1)
            local epoch=M.epoch
            M.begin_session(epoch) -- discard partial state; old packets have the old nonce
            recovery_retries=retries
            M.hello() -- only matching negotiation plus both snapshots can make ready
        end
        return -- terminal locks never initiate a retry
    end
    if receiver and wire.expire(receiver, t) then set_status("connecting", "snapshot_timeout") end
    for _, entry in pairs(requests) do
        if t - entry.sent_at >= ACK_TIMEOUT then
            -- An absent ack says nothing about whether the server applied the
            -- edit. Discard optimism and request confirmed state again.
            -- Keep the affected stream unready until a full refresh; a healthy
            -- snapshot of the other file cannot resolve this edit's outcome.
            if receiver then wire.invalidate(receiver, entry.cell and "P" or "R") end
            finish_entry(entry, "timed_out", entry.accepted and "snapshot_timeout" or "ack_timeout")
            set_status("connecting", entry.accepted and "snapshot_timeout" or "ack_timeout")
        end
    end
    for _, entry in pairs(cells) do
        if not entry.id and t >= entry.expires then finish_entry(entry, "timed_out", "queue_timeout") end
    end
    local retry_delay = math.min(30, 5 * 2 ^ math.max(0, hello_tries - 1))
    if M.status == "connecting" and (not hello_at or t - hello_at >= retry_delay) then
        if hello_tries >= 4 then set_status("connecting", "handshake_timeout") end
        M.hello() -- bounded backoff; late server availability remains recoverable
    end
    if not can_edit() then return end
    for _, entry in pairs(cells) do
        if not entry.id and t >= entry.due then
            sequence = sequence + 1
            if sequence > 2147483647 then finish_entry(entry, "rejected", "request_ids_exhausted"); return end
            entry.id, entry.sent_value, entry.sent_at = sequence, entry.desired, t
            entry.base_revision = receiver.revisions.P
            requests[sequence] = entry
            local msg = wire.envelope("Q", receiver.server, receiver.client, receiver.guild)
                .. "|" .. sequence .. "|Prio|" .. entry.key .. "|" .. entry.work .. "|" .. entry.desired
            if not send_up(msg, 0) then
                finish_entry(entry, "rejected", "transport_unavailable")
                set_status("rejected", "transport_unavailable")
            end
        end
    end
end

M.begin_session(0)

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

    local authority = api.has_authority()
    if authority == nil then
        log.say("transport: authority is unknown; echo test deferred")
        return false
    end
    local where = authority and "authority" or "client"
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

-- On-demand plain-data diagnostics only: no requests, refreshes or engine reads.
function M.report_storage()
    local t, s, interest, event = now(), M.storage_stats, stock.interest, stock.view
    local guild = interest and interest.guild or M.guild
    local selected = interest and interest.selected
    local view = M.storage_view(guild, selected)
    local count, stone = 'unknown', 'unknown'
    if view.verified then
        count = 0
        for _ in pairs(view.totals) do count = count + 1 end
        stone = tostring(view.totals.Stone or 0) -- complete verified scope only
    end
    local age, expiry, remaining = 'unknown', 'unknown', 'unknown'
    if event and event.epoch == M.epoch and event.storage.verified then
        -- A diagnostic may describe an expired cached sample, but its totals
        -- above remain unknown once storage_view stops verifying that sample.
        age = tostring(event.storage.age_ms + math.max(0, math.ceil((t-event.received_at)*1000)))
        expiry = string.format('%.3f',event.expires_at)
        remaining = tostring(math.floor((event.expires_at-t)*1000))
    end
    log.say(string.format('  storage counters (module lifetime): accepted_requests=%d builds=%d packets_sent=%d transmitter_censuses=%d component_fallback_censuses=%d queue_peak=%d',
        s.requests,s.builds,s.packets,s.transmitter_walks,s.component_fallbacks,s.queue_peak))
    log.say(string.format('  storage client: open=%s epoch=%s guild=%s requested_camp=%s request_ids_issued=%d pending=%s',
        tostring(stock.open),tostring(M.epoch),guild or 'unavailable',selected or 'auto',stock.serial,
        stock.pending and stock.pending.id or 'none'))
    log.say(string.format('  storage view: scope=%s camp=%s choices=%d verified=%s item_count=%s Stone=%s',
        view.scope or 'unavailable',view.camp or 'none',#view.choices,tostring(view.verified),tostring(count),stone))
    log.say(string.format('  storage cached sample: age_ms=%s expires_at=%s remaining_ms=%s (local clock now=%.3f)',
        age,expiry,remaining,t))
    local limits, verdicts, held = view.limits, 0, 0
    if type(limits) == 'table' then
        for _ in pairs(limits.verdicts or {}) do verdicts = verdicts + 1 end
        for _ in pairs(limits.stopped or {}) do held = held + 1 end
    end
    log.say(string.format('  server limit state: item_limits_on_rocks=%s verdicts=%s items_with_rocks_held=%s',
        tostring(M.server_item_limits), limits and tostring(verdicts) or 'unknown',
        limits and tostring(held) or 'unknown'))
end

function M.report()
    log.say("transport:")
    log.say("  sync: " .. M.status .. (M.status_reason and " (" .. M.status_reason .. ")" or ""))
    log.say("  protocol schema: " .. M.SCHEMA .. ", work columns: " .. M.WORKS)
    log.say("  server guild: " .. (M.server_guild or "unavailable"))
    log.say("  hooks installed: " .. tostring(M.installed))
    local authority = api.has_authority()
    local role = authority == nil and "unknown" or (authority and "authority" or "client")
    log.say("  role: " .. role)
    log.say(string.format("  sent up %d, received up %d, seen leaving %d",
        M.stats.sent_up, M.stats.got_up, M.stats.saw_up))
    log.say("  last send went through: " ..
        (M.stats.owner_route or "nothing yet"))
    log.say(string.format("  sent down %d, received down %d",
        M.stats.sent_down, M.stats.got_down))
    log.say(string.format("  echo sent %d, returned %d",
        M.stats.echo_sent, M.stats.echo_returned))
    M.report_storage()

    local known = 0
    for _ in pairs(M.clients) do known = known + 1 end
    log.say("  modded clients heard from: " .. known)

    -- Which object a send would actually go through, and how many are on
    -- offer. This is here to settle why a long-lived client stops being able
    -- to send: the suspicion is that a reconnect leaves the previous
    -- session's components in memory, FindFirstOf keeps answering with a dead
    -- one, and the RPC is dropped on an object whose connection is gone.
    -- If that is right, the count climbs across reconnects and the name below
    -- changes to one that no longer works. If the count and name hold steady
    -- while sending stops, the fault is elsewhere and this rules it out.
    local seen = 0
    pcall(function()
        local all = FindAllOf("PalNetworkBaseCampComponent")
        seen = #(all or {})
    end)
    local pick, owned_pick = nil, nil
    pcall(function() pick = full_name(api.network_component()) end)
    pcall(function() owned_pick = full_name((owned_component())) end)
    log.say("  base camp components in memory: " .. seen)
    log.say("  a send would use: " .. (pick or "none"))
    log.say("  owned lookup finds: " .. (owned_pick or "none"))

    -- The object graph, because the first guess at it was wrong. The
    -- component is not on the player: it is the BaseCamp component of a
    -- PalNetworkTransmitter actor sitting in the persistent level, and there
    -- is more than one. Which transmitter belongs to this player is the whole
    -- question, so the owner of each is printed next to the local
    -- controller's name rather than assumed.
    local pcname
    pcall(function() pcname = full_name(api.player_controller()) end)
    log.say("  local controller: " .. (pcname or "none"))

    local tx
    pcall(function() tx = FindAllOf("PalNetworkTransmitter") end)
    for i, t in ipairs(tx or {}) do
        if api.valid(t) then
            local owner, tname
            pcall(function() tname = full_name(t) end)
            pcall(function() owner = full_name(t:GetOwner()) end)
            log.say(string.format("  transmitter %d: %s", i, tname or "?"))
            log.say(string.format("     owner: %s", owner or "none"))
        end
    end

    local comps
    pcall(function() comps = FindAllOf("PalNetworkBaseCampComponent") end)
    for i, c in ipairs(comps or {}) do
        if api.valid(c) then
            local cname, couter
            pcall(function() cname = full_name(c) end)
            pcall(function() couter = full_name(c:GetOuter()) end)
            log.say(string.format("  component %d: %s", i, cname or "?"))
            log.say(string.format("     outer: %s", couter or "none"))
        end
    end

    if M.stats.last_error then
        log.say("  last error: " .. M.stats.last_error)
    end

    if M.stats.echo_sent > 0 and M.stats.echo_returned == 0 then
        log.say("  no echo acknowledgement yet; outgoing hook counts do not prove delivery.")
    end
end

M.PREFIX = PREFIX
M.split = wire.parts

return M
