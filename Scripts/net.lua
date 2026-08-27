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

local M = {}

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
function M.to_server(command, value)
    -- The owned one when this is a client, because an unowned component is
    -- not a slower path here, it is a silent no-op. The old answer stays as
    -- the fallback so the authority - where ownership is not a question -
    -- behaves exactly as before.
    local comp, route = owned_component()

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
        comp, route = api.network_component(), "findfirst"
    end
    if not api.valid(comp) then return false end
    M.stats.owner_route = route

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
        -- Validated before it is asked its name. FindAllOf hands back
        -- everything it finds including objects on their way out, and
        -- GetFullName on one of those is a member call on freed memory - the
        -- pcall inside full_name cannot catch that, it never could. Every
        -- other FindAllOf loop in this codebase checks first.
        if api.valid(comp) and full_name(comp) == name then return comp end
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
local function transmitters()
    local out = {}
    for _, t in ipairs(FindAllOf("PalNetworkTransmitter") or {}) do
        if api.valid(t) then
            local n = full_name(t)
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
local function guild_via(comp, tx_by_name)
    local outer
    pcall(function() outer = comp:GetOuter() end)
    if not api.valid(outer) then return nil end

    local want = full_name(outer)
    if not want then return nil end

    local t = tx_by_name[want]
    if not api.valid(t) then return nil end

    local owner
    pcall(function() owner = t:GetOwner() end)
    if not api.valid(owner) then return nil end
    return api.guild_of(owner)
end

-- One message, one sender: the walk is worth it here and happens once.
function M.guild_of_sender(comp)
    if not api.valid(comp) then return nil end
    return guild_via(comp, transmitters())
end

function M.who(comp)
    if not api.valid(comp) then return nil end
    return full_name(comp)
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

local function remember(context)
    local comp = resolve(context)
    if comp == nil then return nil end

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

                pcall(function()
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

                    local comp = remember(Context)

                    if M.on_command then M.on_command(command, value, comp) end
                end)

                if _t0 then _b.ms = _b.ms + (os.clock() - _t0) * 1000 end
            end)
    end) end

    if not ok_down then ok_down = pcall(function()
        RegisterHook("/Script/Pal.PalNetworkBaseCampComponent:Notify_RequestClient_int32",
            function(Context, A, B, C)
                local _b = log.count("hook: net down")
                local _t0 = log.perf and os.clock() or nil

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

                    -- Stand data first, and it never reaches on_state.
                    --
                    -- on_state is main.lua's rule applier, which accumulates
                    -- into a batch and swaps it in on Done. Feeding pal lines
                    -- through it would have that batch grow entries it cannot
                    -- read and then write them over caps.txt. Two protocols
                    -- sharing one channel need to part company at the top of
                    -- the handler, not inside the consumer.
                    if M.on_pal_message(message) then return end

                    if M.on_state then M.on_state(message) end
                end)

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

function M.reset()
    M.clients = {}

    -- The stand cache goes with the world it describes.
    --
    -- This cleared only M.clients, so pal data from a previous session
    -- survived a world switch. The client grid's gate asks "is net.pals
    -- non-empty", which stale data satisfies - so the gate stopped meaning
    -- "the server has told me about THIS world" and started meaning "a server
    -- once told me about some world". A half-received batch left in
    -- pal_incoming would linger the same way.
    M.pals = {}
    M.pals_gen = M.pals_gen + 1
    M.clear_pal_incoming()
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
-- Per-pal ranks and priorities, server to client.
--
-- The stand grid needs two things for every cell: whether the pal CAN do that
-- work, and what priority it is set to. On a client the first is unobtainable
-- - GetWorkSuitabilityRank on a replicated pal is an access violation, not a
-- Lua error, so no pcall saves the process - and the second lives in a file
-- only the server reads. That is why the grid has always been authority-only.
--
-- Both are cheap to send. One line per pal carries fourteen ranks and
-- fourteen priorities as one character each, so a fourteen pal base is
-- fourteen short lines rather than four hundred values.
--
--   PWP_Pal|<key>|<ranks>|<prios>
--
-- ranks are '0'-'5' by work index, prios are '1'-'5', 'X' for never, '-' for
-- unset. Position IS the work type, which is why both strings are fixed
-- length and why a missing entry is a character rather than an omission.
M.pals = {}

-- Bumped whenever a batch lands, so a client can tell "nothing has changed"
-- from "I have not looked yet" without comparing tables.
M.pals_gen = 0

local function encode_ranks(ranks, n)
    local out = {}
    for t = 1, n do
        local r = ranks and ranks[t] or 0

        -- Clamped UP, not down to zero.
        --
        -- This mapped anything above 5 to '0', and '0' decodes as "cannot do
        -- this work" - so the cell was handed back to vanilla. Ranks DO exceed
        -- 5: suitability_rank prefers GetWorkSuitabilityRankWithCharacterRank,
        -- which folds in condenser rank, so an upgraded pal reads higher than
        -- its base. The effect was that a condensed pal lost exactly the work
        -- types it was best at, and only on a client, because only a client
        -- goes through this encoding.
        --
        -- Nine rather than five, because only "is it above zero" decides
        -- capability and a single character is what keeps the line short. The
        -- colour scale still tops out at 5; a rank is not a priority.
        if type(r) ~= "number" or r < 0 then r = 0 end
        if r > 9 then r = 9 end

        out[t] = tostring(math.floor(r))
    end
    return table.concat(out)
end

local function encode_prios(prios, n)
    local out = {}
    for t = 1, n do
        local p = prios and prios[t]
        if p == false then out[t] = "X"
        elseif type(p) == "number" and p >= 1 and p <= 5 then
            out[t] = tostring(math.floor(p))
        else out[t] = "-" end
    end
    return table.concat(out)
end

local function decode_ranks(text, n)
    local out = {}
    for t = 1, n do
        local c = text:sub(t, t)
        local v = tonumber(c)
        if v and v > 0 then out[t] = v end
    end
    return out
end

local function decode_prios(text, n)
    local out = {}
    for t = 1, n do
        local c = text:sub(t, t)
        if c == "X" then out[t] = false
        elseif c ~= "-" and c ~= "" then
            local v = tonumber(c)
            if v then out[t] = v end
        end
    end
    return out
end

-- rows_for(guild) returns { { key, ranks, prios }, ... } for that guild, and
-- is called by the caller's own code because only it can ask a pal for a rank.
--
-- A FUNCTION rather than a list, so each recipient gets their own guild's
-- pals. The first version took one flat list and sent it to everybody, which
-- handed every player the pal keys and priority table of every other guild on
-- the server - and it is those keys the write path then accepted. push_rules
-- has been per guild since it was written; this is the same rule on the same
-- channel.
-- only_key sends just that pal's row, as a bare Pal line with no Reset or
-- Done around it.
--
-- One changed cell used to re-push the entire table: PalReset, fourteen Pal
-- lines and PalDone, so sixteen RPCs to report one number. Measured on a
-- client, a single RPC costs about seventeen milliseconds of game thread, so
-- the round trip for one click was pushing four hundred, and it was visible as
-- a hitch on every click. Sending the one row that moved makes that one RPC.
--
-- The receiving end needed nothing new: a Pal line with no batch open already
-- merges straight into M.pals.
function M.push_pals(rows_for, comp, only_key)
    if type(rows_for) ~= "function" then return false end

    local n = M.WORKS

    -- One batch per guild, built on demand and reused, as push_rules does.
    local built = {}
    local function batch_for(guild)
        local cache_key = guild or "<none>"
        if built[cache_key] then return built[cache_key] end

        -- A recipient whose guild will not resolve is sent nothing.
        --
        -- Belt and braces: stand_rows refuses a nil guild too, so rows_for
        -- already answers empty. This is here because push_pals takes rows_for
        -- as an argument and cannot see what it does, and the cost of that
        -- assumption being wrong is one client receiving every guild's roster.
        --
        -- A full push still brackets with Reset and Done, so the client ends
        -- up holding an empty table rather than a stale one.
        if type(guild) ~= "string" or guild == "" then
            local empty = only_key and {}
                or { PREFIX .. "PalReset", PREFIX .. "PalDone" }
            built[cache_key] = empty
            return empty
        end

        local batch = {}
        if not only_key then batch[1] = PREFIX .. "PalReset" end

        for _, row in ipairs(rows_for(guild) or {}) do
            if type(row.key) == "string" and row.key ~= ""
                and (only_key == nil or row.key == only_key) then
                batch[#batch + 1] = string.format("%sPal|%s|%s|%s", PREFIX,
                    row.key, encode_ranks(row.ranks, n),
                    encode_prios(row.prios, n))
            end
        end

        -- An empty batch is the ordinary answer for a guild that does not own
        -- the pal that moved, not a failure.
        if not only_key then batch[#batch + 1] = PREFIX .. "PalDone" end

        built[cache_key] = batch
        return batch
    end

    if comp then
        for _, msg in ipairs(batch_for(M.guild_of_sender(comp))) do
            if not M.to_client(comp, msg) then return false end
        end
        return true
    end

    if next(M.clients) == nil then return false end

    -- Names resolved to components by one walk, and guilds by one more.
    --
    -- M.clients holds a NAME and a timestamp, never a component: an IsValid on
    -- a wrapper kept from an earlier frame is the stored-wrapper dereference
    -- this codebase is arranged around. Reading those entries as components is
    -- what made every push report sent=false while claiming fourteen pals.
    local live_by_name, resolved = {}, 0
    for _, c in ipairs(FindAllOf("PalNetworkBaseCampComponent") or {}) do
        if api.valid(c) then
            local nm = full_name(c)
            if nm then
                live_by_name[nm] = c
                resolved = resolved + 1
            end
        end
    end

    if resolved == 0 then
        log.debug("stand push: no components resolved, nothing sent")
        return false
    end

    local tx_by_name = transmitters()
    local sent = 0

    for name in pairs(M.clients) do
        local live = live_by_name[name]
        if live ~= nil then
            local ok = true
            for _, msg in ipairs(batch_for(guild_via(live, tx_by_name))) do
                if not M.to_client(live, msg) then
                    ok = false
                    break
                end
            end
            -- A client that took only part of a batch is left holding an
            -- unfinished one, so it is not counted as reached.
            if ok then sent = sent + 1 end
        end
    end

    return sent > 0
end

-- Applied on the client. Kept whole rather than merged, so a pal that leaves
-- the base stops being answered for instead of lingering at its last known
-- ranks.
local pal_incoming = nil

-- Reachable from M.reset, which is declared above this upvalue.
function M.clear_pal_incoming()
    pal_incoming = nil
end

function M.on_pal_message(message)
    if message == PREFIX .. "PalReset" then
        pal_incoming = {}
        return true
    end

    if message == PREFIX .. "PalDone" then
        if pal_incoming then
            M.pals = pal_incoming
            M.pals_gen = M.pals_gen + 1
            pal_incoming = nil

            -- Counted by walking, not by #. M.pals is keyed by pal key, so the
            -- length operator answers 0 however many are in it - which it did,
            -- reporting "0 pal(s)" while fourteen were on screen. A log line
            -- that contradicts the thing it is describing is worse than none.
            local n = 0
            for _ in pairs(M.pals) do n = n + 1 end
            log.debug("stand data: " .. n .. " pal(s) from the server")
        end
        return true
    end

    local key, ranks, prios =
        message:match("^" .. PREFIX .. "Pal|([^|]+)|([^|]*)|([^|]*)$")
    if key == nil then return false end

    local into = pal_incoming or M.pals
    into[key] = { ranks = decode_ranks(ranks, M.WORKS), prios = decode_prios(prios, M.WORKS) }

    -- A line outside a batch is a single-row update, and it is finished the
    -- moment it lands: there is no PalDone coming to commit it. So the
    -- generation moves here, or the grid holds the old number until something
    -- unrelated pushes a full table.
    --
    -- Inside a batch this must NOT move, or the grid repaints once per row and
    -- draws a half-applied table fourteen times over.
    if into == M.pals then
        M.pals_gen = M.pals_gen + 1
    end

    return true
end

function M.push_rules(caps, cfg, comp)
    -- One batch per guild, built on demand and reused.
    --
    -- Each client is sent only its own guild's ceilings, so a player never
    -- sees - or has their bases stopped by - a rule another guild set. Two
    -- clients in the same guild get identical lines, so the batch is cached
    -- by guild rather than rebuilt per recipient.
    --
    -- A nil guild is a real case, not an error: a player in no guild, or one
    -- the server cannot resolve yet. They get the unscoped rules only, which
    -- is what caps.all answers for nil, and never another guild's.
    local built = {}
    local function batch_for(guild)
        local key = guild or "<none>"
        if built[key] then return built[key] end

        local batch = { PREFIX .. "Reset" }
        for work, items in pairs(caps.all(cfg, guild)) do
            for item, amount in pairs(items) do
                batch[#batch + 1] =
                    string.format("%sRule|%s|%s|%d", PREFIX, work, item, amount)
            end
        end
        batch[#batch + 1] = PREFIX .. "Done"

        built[key] = batch
        return batch
    end

    -- One named target: a component the caller obtained inside the hook
    -- callback that is still on the stack. Used as given and never stored.
    if comp then
        for _, msg in ipairs(batch_for(M.guild_of_sender(comp))) do
            if not M.to_client(comp, msg) then return false end
        end
        return true
    end

    -- Nobody to tell. Checked before the two walks below rather than after,
    -- so a single player session pays nothing at all for being wired up to
    -- announce every rule it changes.
    if next(M.clients) == nil then return false end

    -- Everyone we have heard from, resolved once for the whole loop and
    -- then both asked its guild and sent to. Dropping a key during pairs is
    -- defined behaviour in Lua; adding one is not, and nothing here adds.
    --
    -- Note what M.clients stores: a name and a timestamp, never a component.
    -- An earlier M.broadcast lived here and said why - an IsValid on a
    -- component wrapper kept from an earlier frame is the same stored-wrapper
    -- dereference demand.lua was purged of, and on a busy server clients
    -- churn exactly like work objects. That function has been deleted (it was
    -- dead, and stale enough to hand M.to_client a name where it wants a
    -- component), but the rule it was written for is why the map below is
    -- built fresh on every push and never kept: every object in it came out of
    -- a walk inside this call, and api.valid is asked before a name is ever
    -- read off one. What the table holds between pushes is still only strings.

    -- Two walks for the whole push, not two per recipient.
    --
    -- live_client and guild_of_sender each read the entire object array, and
    -- both used to be called once per client: 2N full walks per rule change,
    -- at 10-19ms each on this build, synchronously on the game thread, every
    -- time somebody clicks a tile. Four clients was most of a tenth of a
    -- second of frozen game to deliver twenty short strings.
    --
    -- send_batch's comment made this exact argument once already, about
    -- sweeping per MESSAGE rather than per client. This is the same argument
    -- one level further out, and it is why that function is now gone: its job
    -- is done properly by resolving everything up front.
    local live_by_name, resolved = {}, 0
    for _, comp in ipairs(FindAllOf("PalNetworkBaseCampComponent") or {}) do
        if api.valid(comp) then
            local n = full_name(comp)
            if n then
                live_by_name[n] = comp
                resolved = resolved + 1
            end
        end
    end

    -- Nothing resolved while the register is not empty is a failed lookup, not
    -- proof that every player left at once. Dropping the whole register on it
    -- would be unrecoverable: nothing re-adds a client except a message from
    -- that client, so a single bad walk would silently cut off everybody until
    -- they each happened to edit something.
    if resolved == 0 and next(M.clients) ~= nil then
        log.debug("no base camp components resolved, so nothing was pushed " ..
            "and no client was dropped")
        return false
    end

    local tx_by_name = transmitters()

    -- Presence decides who stays, not the clock.
    --
    -- This used to drop any client that had not SENT anything for two
    -- minutes, checked before it asked whether the player was still there. A
    -- client only ever sends when it edits a rule, so a player who joined,
    -- received their rules and then simply played was deleted at the first
    -- push after their second minute - and nothing re-adds a client except a
    -- message from that client, so they quietly stopped receiving rules for
    -- the rest of the session.
    --
    -- The timestamp was never the right question. A player who leaves takes
    -- their component with them, so it stops resolving and the branch below
    -- drops them on the same push; a player who is still here resolves,
    -- whatever the clock says. CLIENT_TTL is gone rather than widened, because
    -- a longer wrong answer is still a wrong answer.
    local now = os.clock()
    local sent = 0
    -- A miss is a strike, not an eviction.
    --
    -- Both branches below used to drop the client outright, and nothing
    -- re-adds one except an inbound message - so a player who joined, got
    -- their rules and then simply PLAYED was never pushed to again, and their
    -- panel and grid froze for the rest of the session. That is the failure
    -- the old CLIENT_TTL was removed to prevent, coming back through the error
    -- path. A component can be briefly absent from a walk for ordinary reasons:
    -- a respawn, level streaming, a partial FindAllOf.
    local STRIKES = 3

    for name, entry in pairs(M.clients) do
        local live = live_by_name[name]
        if live == nil then
            entry.misses = (entry.misses or 0) + 1
            if entry.misses >= STRIKES then
                log.debug("dropping " .. name ..
                    " from the push list after " .. STRIKES .. " misses")
                M.clients[name] = nil
            end
        else
            local ok = true
            for _, msg in ipairs(batch_for(guild_via(live, tx_by_name))) do
                if not M.to_client(live, msg) then
                    ok = false
                    break
                end
            end
            if ok then
                -- Kept for "pwp net", which reports how long since each client
                -- was last reached. Nothing decides anything on it now.
                entry.at = now
                entry.misses = nil
                sent = sent + 1
            else
                entry.misses = (entry.misses or 0) + 1
                if entry.misses >= STRIKES then
                    log.debug("dropping " .. name ..
                        " from the push list after " .. STRIKES ..
                        " failed pushes")
                    M.clients[name] = nil
                end
            end
        end
    end
    return sent > 0
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

-- A priority edit, client to server.
--
-- prio is 1-5, false for never, or nil to drop the pal back to config policy.
-- Encoded as one character for the same reason the push is: the value is
-- small and fixed, and a character cannot be mistaken for a count.
function M.request_prio(key, value, prio)
    local c
    if prio == false then c = "X"
    elseif type(prio) == "number" then c = tostring(math.floor(prio))
    else c = "-" end

    return M.to_server(
        string.format("%sPrio|%s|%d|%s", PREFIX, key, value, c), 0)
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
    log.say(string.format("  sent up %d, received up %d, seen leaving %d",
        M.stats.sent_up, M.stats.got_up, M.stats.saw_up))
    log.say("  last send went through: " ..
        (M.stats.owner_route or "nothing yet"))
    log.say(string.format("  sent down %d, received down %d",
        M.stats.sent_down, M.stats.got_down))
    log.say(string.format("  echo sent %d, returned %d",
        M.stats.echo_sent, M.stats.echo_returned))

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
        if M.stats.saw_up == 0 then
            log.say("  the echo never even left: the call was made on a " ..
                "component the engine did not run it on.")
        else
            log.say("  the echo left this machine and did not come back, so " ..
                "it is the wire or the reply, not the call.")
        end
    end
end

M.PREFIX = PREFIX
M.split = split

return M
