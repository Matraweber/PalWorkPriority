-- Resource ceilings per work type, editable in game.
--
-- config.lua owns the defaults in work_caps. This is the layer on top, one
-- entry per ceiling set with "!pwp limit", and it outranks config the same
-- way store.lua outranks it for priorities.
--
-- A ceiling suspends a work type once the base already holds that much of
-- the item, so the pals fenced to it fall through to the next priority
-- instead of producing something nobody needs.

local log = require("log")
local workdefs = require("workdefs")

local M = {}

-- What a rule is allowed to be, in one place.
--
-- Everything that can write a ceiling goes through this: the chat command,
-- the panel, a client's request arriving over the network, and a server's
-- push arriving at a client. Before, the network paths went straight into
-- M.data and then to disk, so anything that could send the FName could put
-- arbitrary keys into the host's caps.txt - and an amount of zero read as
-- "capped at zero", which suspends that work type permanently.
--
-- The bounds are deliberately generous. This is not trying to guess what a
-- sensible limit is; it is refusing values that could not have come from a
-- person using the mod.
M.MAX_CEILING = 9999999
M.MAX_ID_LEN = 64

-- Returns ok, why, and the ceiling as a clean integer.
function M.valid_rule(work_name, item, ceiling)
    if not workdefs.is_known(work_name) then
        return false, "unknown work type '" .. tostring(work_name) .. "'"
    end

    if type(item) ~= "string" or item == "" or #item > M.MAX_ID_LEN
        or item:find("[^%w_%.%-]") ~= nil then
        return false, "implausible item id '" .. tostring(item) .. "'"
    end

    local n = tonumber(ceiling)
    if n == nil or n ~= math.floor(n) or n < 1 or n > M.MAX_CEILING then
        -- Zero is refused rather than clamped. It is the one value that looks
        -- like a limit and behaves like a permanent shutdown of the work
        -- type, and nothing in the UI can produce it - the ladder starts at
        -- 100 and a typed zero already cancels.
        return false, "ceiling out of range: " .. tostring(ceiling)
    end

    return true, nil, math.floor(n)
end

-- What a click or an arrow key walks a ceiling through. Ceilings run into the
-- thousands, so a step of one would be useless, and the steps coarsen as the
-- numbers grow.
--
-- Here rather than in a screen, because two screens walk it and both had
-- their own idea of where it lived. ui.lua kept it as a local and panel.lua
-- simply used the name, which in Lua is a nil global: adding a rule from the
-- picker threw "attempt to index a nil value (global 'LADDER')" every time,
-- and the arrow keys and right click on a ceiling were dead for the same
-- reason. All of it silent, because the click handler is wrapped in a pcall
-- that discarded the message.
M.LADDER = {
    100, 250, 500, 1000, 2000, 3000, 5000,
    7500, 10000, 15000, 20000, 30000, 50000,
}

M.path = nil

-- guild key -> work name -> { [item id] = ceiling }
--
-- Guild keyed since 23 August. Before that it was work -> item -> ceiling for
-- the whole machine, which is right in single player and wrong the moment two
-- guilds share a server: a ceiling one guild set suspended that work at every
-- base on the box, including bases its guild had never seen.
--
-- The key is api.guid_key of the guild's FGuid, which a camp answers with
-- through GetGroupIdBelongTo and a player through
-- PlayerState.GuildBelongTo.Id. Both were measured returning the same value
-- for the same guild, and that shared id is the whole basis of the scoping.
M.data = {}

-- Rules that predate guild scoping, and rules from a machine that cannot say
-- which guild it is acting for.
--
-- These apply to every guild that has not set its own ceiling for the same
-- work and item, so upgrading does not silently drop limits somebody was
-- relying on - an existing caps.txt keeps working, and the first guild edit
-- for a given item takes over from it. A wildcard is the conservative choice
-- here: adopting the old lines into whichever guild happened to load first
-- would hand one guild's settings to another.
M.ANY_GUILD = "*"

-- One record per line: Guild|WorkType|ItemId|Ceiling, and the three field
-- form that predates guilds is still read. Flat text for the same reason
-- priorities.txt is flat: a truncated line costs one ceiling where half a
-- written Lua table costs the whole file.
local function parse_line(line)
    local guild, work, item, ceiling =
        line:match("^([%w%*%-]+)|(%a+)|([%w_%.%-]+)|(%d+)$")

    if not guild then
        work, item, ceiling = line:match("^(%a+)|([%w_%.%-]+)|(%d+)$")
        guild = M.ANY_GUILD
    end
    if not work then return nil end

    -- A whole number in range, or the line is dropped.
    --
    -- "99999999999999999999" matches (%d+), overflows Lua 5.4's integer parse
    -- and comes back as a float that math.floor cannot bring back. It loaded
    -- cleanly and destroyed the next write, and caps.save is not debounced, so
    -- the very first rule change took every guild's ceilings with it - inside
    -- a bare pcall, so nothing was logged. math.tointeger asks exactly the
    -- question the writer is about to ask.
    ceiling = math.tointeger(tonumber(ceiling))
    if ceiling == nil or ceiling < 1 or ceiling > M.MAX_CEILING then
        return nil
    end
    return guild, work, item, ceiling
end

local function put(guild, work, item, ceiling)
    M.data[guild] = M.data[guild] or {}
    M.data[guild][work] = M.data[guild][work] or {}
    M.data[guild][work][item] = ceiling
end

function M.load(path)
    M.path = path
    M.data = {}

    local f = io.open(path, "r")
    if not f then return 0 end

    local count, legacy = 0, 0
    for line in f:lines() do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local guild, work, item, ceiling = parse_line(line)
            if work then
                put(guild, work, item, ceiling)
                count = count + 1
                if guild == M.ANY_GUILD then legacy = legacy + 1 end
            end
        end
    end
    f:close()

    log.debug("loaded " .. count .. " stock limit(s)")
    if legacy > 0 then
        log.debug(legacy .. " of them predate guild scoping and apply to " ..
            "any guild that has not set its own")
    end
    return count
end

-- Written on every edit rather than debounced. Priorities are clicked in
-- bursts and batch nicely; a ceiling is one typed command at a time, and
-- the debounce only buys a lost write if the game closes first.
function M.save()
    if not M.path then return false end

    -- A client owns no rules file.
    --
    -- This guard was deleted when the write was made atomic, and two comments
    -- elsewhere still cite it as the reason a client cannot push a ruleset -
    -- one in this file and one in main.lua. Nothing reaches it today, because
    -- set/clear short-circuit on M.submit and apply_set/apply_clear are only
    -- called from the authority-gated message handler. It is back because
    -- those comments are load-bearing for the next person who adds a caller.
    if M.submit then return false end

    -- Built in memory, written to a temp file, then renamed into place. The
    -- reasoning is store.save's, and it matters more here: this save is not
    -- debounced, so it runs on every single rule change.
    local out = {
        "# Pal Work Priority - stock limits set with !pwp limit.\n",
        "# Guild|WorkType|ItemId|Ceiling\n",
        "# A guild of " .. M.ANY_GUILD .. " applies to any guild that " ..
            "has not set its own.\n",
    }

    -- Sorted so the file does not reshuffle on every write.
    local guilds = {}
    for guild in pairs(M.data) do guilds[#guilds + 1] = guild end
    table.sort(guilds)

    local dropped = 0
    for _, guild in ipairs(guilds) do
        local works = {}
        for work in pairs(M.data[guild]) do works[#works + 1] = work end
        table.sort(works)

        for _, work in ipairs(works) do
            local items = {}
            for item in pairs(M.data[guild][work]) do
                items[#items + 1] = item
            end
            table.sort(items)

            for _, item in ipairs(items) do
                local n = math.tointeger(M.data[guild][work][item])
                if n == nil then
                    dropped = dropped + 1
                else
                    out[#out + 1] = string.format("%s|%s|%s|%d\n",
                        guild, work, item, n)
                end
            end
        end
    end

    if dropped > 0 then
        log.warn(dropped .. " ceiling(s) could not be written and were " ..
            "dropped. A value that is not a whole number is the usual cause.")
    end

    local tmp = M.path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then
        log.warn("could not write " .. tmp .. ": " .. tostring(err))
        return false
    end

    local wrote = pcall(function() f:write(table.concat(out)) end)
    f:close()

    if not wrote then
        os.remove(tmp)
        log.warn("could not write " .. tmp .. ", the existing file is intact")
        return false
    end

    -- Remove then rename: Lua's os.rename will not replace an existing file on
    -- Windows. The temp file holds the new content if the process dies between.
    os.remove(M.path)
    local moved, mv_err = os.rename(tmp, M.path)
    if not moved then
        -- Put it back by hand rather than leave nothing there.
        --
        -- The remove has already happened by this point, so returning here
        -- would delete the live file outright - worse than the truncating
        -- write this replaced. Nothing ever reads .tmp back, so it is not a
        -- recovery path on its own.
        log.warn("could not move " .. tmp .. " into place: " ..
            tostring(mv_err) .. ", writing the ceilings directly")

        local back = io.open(M.path, "wb")
        if not back then return false end
        local ok_back = pcall(function() back:write(table.concat(out)) end)
        back:close()
        if not ok_back then return false end
        os.remove(tmp)
    end

    -- After the write, not before: a listener should never be told about a
    -- ruleset that failed to reach the disk. pcall'd because a push walks the
    -- object array and talks to the network, and none of that is worth losing
    -- a saved rule over.
    -- Told, and said if telling failed. Same reasoning as store.fire_change:
    -- on the authority this callback is what pushes a ruleset to every client,
    -- so a discarded error meant the rules were saved and nobody was informed.
    if M.on_change == nil then
        -- Authority only: a client sets M.submit and has no listener by
        -- design, because its edits go up as requests. (M.save already refuses
        -- on a client, so this is belt and braces.)
        if M.submit == nil then
            log.warn("ceilings changed but nothing is listening, so no " ..
                "client will be told")
        end
    else
        local ok_tell, tell_err = pcall(M.on_change)
        if not ok_tell then
            log.warn("telling the clients about a ceiling change failed: " ..
                tostring(tell_err))
        end
    end

    return true
end

-- Set by main.lua on a client. When present, an edit is a request sent to
-- whoever owns the world rather than a local write, so two players cannot
-- drift apart and a client cannot invent rules the server never agreed to.
M.submit = nil

-- Which machine this is, decided after the world loads.
--
-- false means not yet asked, and that is deliberately not the same as "I am
-- the authority". Undecided used to fall through to the local write, so for
-- the twenty seconds between a world loading and main.lua working out where
-- it was, a client's ceiling edit wrote a file the server never reads. The change
-- showed on screen, went nowhere, and was overwritten by the next push from
-- the server, which reads exactly like the feature being broken.
--
-- A refused click with a reason is a far better twenty seconds than a
-- silently discarded one.
M.decided = false

local function undecided()
    if M.decided then return false end
    log.say("still working out whether this is a server or a client, " ..
        "try that again in a moment")
    return true
end

-- Called after any change that reached the file, set by main.lua.
--
-- The rules were pushed to clients from exactly one place: the handler for an
-- inbound client message. So a client that edited something got everyone's
-- copy updated, and the host editing the same rule in its own panel told
-- nobody - connected players kept drawing the previous ruleset until they
-- happened to edit something themselves or respawned. For a mod whose point
-- is that a base behaves the same for everyone in it, that is the wrong way
-- round.
--
-- Hung off save() rather than off the six edit sites, because a seventh edit
-- site is the likeliest thing to be added next and it would forget. save() is
-- the one place every committed change already passes through, and it is
-- refused on a client, so this cannot fire from a machine with no authority.
--
-- caps stays ignorant of the network. It says the rules moved; main.lua
-- decides that means a push, exactly as it does for submit above.
M.on_change = nil

-- A write with no guild is refused rather than widened.
--
-- Every write names the guild it is for. When the caller cannot say which
-- guild it is acting for, the answer is to refuse and say so - NOT to fall
-- back to the wildcard, which would apply the ceiling to every guild on the
-- server. That widening is exactly the bug guild scoping exists to fix, and a
-- silent fallback would reintroduce it at the one moment nobody is watching.
local function writable_guild(guild, what)
    if type(guild) == "string" and guild ~= "" then return guild end
    log.warn("refused to " .. what ..
        " a rule with no guild: this machine cannot say which guild it is " ..
        "acting for, and a rule without one would cap every base on the server")
    return nil
end

-- Returns whether the rule was taken. The authority path used to discard
-- apply_set's answer, so a refused rule looked exactly like an accepted one
-- to every caller - including the panel, which then reported a limit it had
-- not set.
function M.set(work_name, item, ceiling, guild)
    if undecided() then return false end
    if M.submit then
        return M.submit("set", work_name, item, ceiling, guild)
    end
    return M.apply_set(work_name, item, ceiling, guild)
end

function M.clear(work_name, item, guild)
    if undecided() then return false end
    if M.submit then return M.submit("clear", work_name, item, 0, guild) end
    return M.apply_clear(work_name, item, guild)
end

-- The write itself, with no opinion about who asked for it. The authority
-- calls these directly; a client only ever reaches them through a message
-- coming back down.
--
-- Applies a rule that came from somewhere else - a client's request on the
-- host, or the host's push on a client. Refuses anything that does not pass
-- M.valid_rule, and says why.
function M.apply_set(work_name, item, ceiling, guild)
    local ok, why, clean = M.valid_rule(work_name, item, ceiling)
    if not ok then
        log.warn("refused a rule from the network: " .. why)
        return false
    end

    guild = writable_guild(guild, "set")
    if not guild then return false end

    put(guild, work_name, item, clean)

    -- The save's answer IS the answer.
    --
    -- M.save has five ways to return false - no path, a write that would not
    -- open, a formatting failure, a rename that could not happen. All were
    -- discarded here, and the caller in main.lua trusts this `true`: it then
    -- says the limit was set, in chat, and pushes it to every client. The
    -- ceiling was on screen everywhere and gone at the next restart.
    return M.save()
end

function M.apply_clear(work_name, item, guild)
    -- A clear cannot invent data, but it can still be junk, and letting junk
    -- through means the log reports work types that do not exist.
    if not workdefs.is_known(work_name) or type(item) ~= "string" then
        log.warn("refused a clear from the network: " ..
            tostring(work_name) .. " / " .. tostring(item))
        return false
    end

    guild = writable_guild(guild, "clear")
    if not guild then return false end

    local by_guild = M.data[guild]
    local by_work = by_guild and by_guild[work_name]
    if by_work == nil or by_work[item] == nil then
        -- Names the common case rather than failing mute. A rule inherited
        -- from before guild scoping is real and visible in the panel, but it
        -- belongs to the wildcard, so a guild scoped clear cannot reach it.
        -- That is a different problem from a clear for a rule nobody set, and
        -- the two used to look identical from the log.
        local shared = M.data[M.ANY_GUILD]
        if shared and shared[work_name] and shared[work_name][item] then
            log.say(string.format(
                "%s %s is a shared limit from before guild rules, so it was " ..
                "not removed for one guild", work_name, item))
        end
        return false
    end

    by_work[item] = nil
    if next(by_work) == nil then by_guild[work_name] = nil end
    if next(by_guild) == nil then M.data[guild] = nil end
    -- The save's answer IS the answer, as in apply_set above.
    return M.save()
end

-- The client's whole view, replaced by what the server pushed.
--
-- Validated the same way an inbound request is. A client trusting a server
-- unconditionally sounds reasonable right up until the "server" is anything
-- that can send the FName, and the client then draws a panel full of rules
-- its own host never set. Bounded as well: a push is a batch, and a batch is
-- the easy way to make a client allocate until it dies.
--
-- The server pushes only the receiving guild's rules, so a row without a
-- guild belongs to the guild being pushed to, and lands under the wildcard
-- where the client's own reads will still find it.
M.MAX_RULES = 500

function M.replace_all(rows)
    M.data = {}

    local kept, refused = 0, 0
    for _, row in ipairs(rows or {}) do
        if kept >= M.MAX_RULES then
            refused = refused + 1
        else
            local ok, _, clean = M.valid_rule(row.work, row.item, row.amount)
            if ok then
                local guild = row.guild
                if type(guild) ~= "string" or guild == "" then
                    guild = M.ANY_GUILD
                end
                put(guild, row.work, row.item, clean)
                kept = kept + 1
            else
                refused = refused + 1
            end
        end
    end

    if refused > 0 then
        log.warn("dropped " .. refused ..
            " rule(s) the server sent that do not look like rules")
    end
    return kept
end

-- Legacy rules become the owning guild's, once it is unambiguous who that is.
--
-- The wildcard carries rules written before guild scoping, and it earns its
-- keep exactly once: at the upgrade. After that it is a bucket nobody owns,
-- which is why a guild cannot remove a rule from it - the rule is not theirs
-- to remove, and deleting it for everyone would be the cross guild reach the
-- scoping exists to prevent. The panel could show a limit, say it removed it,
-- and change nothing.
--
-- On a machine where every base camp belongs to one guild the ambiguity is
-- not real: those rules were that guild's all along. They are adopted, the
-- wildcard is emptied, and from then on every rule has an owner and Remove
-- works on all of them. Where camps span guilds nothing is moved, because
-- there is no honest way to pick an heir - those stay shared until each guild
-- sets its own.
--
-- A rule the guild has already set wins: it is the more specific of the two
-- and was written later.
-- Said once per session, when there is something to adopt and a guild that
-- could take it. Nothing is changed here.
local offered = false

function M.offer_adopt(guild)
    if offered then return false end
    local shared = M.data[M.ANY_GUILD]
    if shared == nil or next(shared) == nil then return false end
    if type(guild) ~= "string" or guild == "" or guild == M.ANY_GUILD then
        return false
    end

    local n = 0
    for _, items in pairs(shared) do
        for _ in pairs(items) do n = n + 1 end
    end

    offered = true
    log.say(string.format(
        "%d limit(s) predate guild rules and apply to every guild that has " ..
        "not set its own. Every base camp loaded here belongs to one guild, " ..
        "so they can be made that guild's with '!pwp adopt' - or left shared, " ..
        "which is what they do now.", n))
    log.say("  on a server with more than one guild, check the others are " ..
        "not relying on them first: adopting cannot be undone")
    return true
end

function M.adopt_wildcard(guild)
    local shared = M.data[M.ANY_GUILD]
    if shared == nil or next(shared) == nil then return 0 end
    if type(guild) ~= "string" or guild == "" or guild == M.ANY_GUILD then
        return 0
    end

    local moved, kept = 0, 0
    for work, items in pairs(shared) do
        for item, ceiling in pairs(items) do
            local own = M.data[guild] and M.data[guild][work]
            if own and own[item] ~= nil then
                kept = kept + 1
            else
                put(guild, work, item, ceiling)
                moved = moved + 1
            end
        end
    end

    M.data[M.ANY_GUILD] = nil
    M.save()

    log.say(string.format(
        "adopted %d limit(s) from before guild rules into this guild%s",
        moved,
        kept > 0 and (", " .. kept .. " already set here and kept") or ""))
    return moved
end

-- ---------------------------------------------------------------------------
-- The merged view the scheduler reads
-- ---------------------------------------------------------------------------

-- Every ceiling in force for one guild, in precedence order:
--
--   cfg.work_caps        written into config.lua, applies to the whole server
--   M.data[ANY_GUILD]    set before guild scoping existed
--   M.data[guild]        set by that guild, and wins
--
-- A nil guild sees only the first two. That is deliberate: a camp whose guild
-- cannot be read must not inherit some other guild's ceilings.
local function merged_for(cfg, guild)
    local out = {}

    for work, items in pairs((cfg or {}).work_caps or {}) do
        if type(items) == "table" then
            out[work] = {}
            for item, ceiling in pairs(items) do out[work][item] = ceiling end
        end
    end

    local function layer(key)
        for work, items in pairs(M.data[key] or {}) do
            out[work] = out[work] or {}
            for item, ceiling in pairs(items) do out[work][item] = ceiling end
        end
    end

    layer(M.ANY_GUILD)
    if type(guild) == "string" and guild ~= M.ANY_GUILD then layer(guild) end

    return out
end

-- Ceilings for one work type in one guild. Returns nil when nothing caps this
-- work type at all, so the caller can skip the check entirely rather than
-- walking an empty table.
function M.for_work(cfg, work_name, guild)
    local all = merged_for(cfg, guild)
    local items = all[work_name]
    if items == nil or next(items) == nil then return nil end
    return items
end

-- Whether anything caps anything at all.
--
-- The scheduler only pays to read chest contents when this is true, so a
-- limit set in game has to be visible here. Reading only cfg.work_caps would
-- leave totals empty and the new ceiling would never fire, which looks
-- exactly like the ceiling being broken.
--
-- Asked across every guild on purpose: this decides whether the pass reads
-- storage at all, and the pass covers every camp on the machine.
function M.any(cfg)
    if next(M.data) ~= nil then return true end
    local from_cfg = cfg.work_caps
    return type(from_cfg) == "table" and next(from_cfg) ~= nil
end

-- Every ceiling in force for one guild, work name -> item -> ceiling, for
-- listing and for drawing the panel.
function M.all(cfg, guild)
    return merged_for(cfg, guild)
end

return M
