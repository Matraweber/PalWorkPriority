-- An item id in, a Texture2D out.
--
-- Palworld keeps every item icon in one folder under a name that pairs the
-- item with a category:
--
--   /Game/Others/InventoryItemIcon/Texture/T_itemicon_Material_CopperIngot
--
-- The category cannot be worked out from the id, which is the whole
-- difficulty. icondex.lua records the pairing for everything readable in the
-- shipped pak, and anything it missed is picked up from the icons the game
-- already has in memory.
--
-- Nothing here holds a texture between frames. That is the important part
-- rather than an implementation detail, for the reason set out below.

local log = require("log")
local icondex = require("icondex")

local M = {}

-- Why only names are remembered
--
-- The first version cached the texture object and checked it was still valid
-- before handing it back. That crashed the game with an access violation
-- reading address 0x19, which is a member read on a pointer no longer there.
--
-- A texture loaded on demand is owned by nothing on the Lua side. The engine
-- is free to collect it, and once it has, the wrapper kept here is dangling.
-- Asking whether it is valid does not help: IsValid is itself a member call,
-- so the check is the crash, and pcall does not catch an access violation
-- because it is not a Lua error.
--
-- Strings cannot dangle. The name is remembered and the object looked up
-- fresh each time it is wanted, which costs a hash lookup in the engine's
-- object table and removes the failure mode entirely. Once a texture is on an
-- Image's brush the engine holds a real reference to it, so the repeated
-- lookup keeps finding the same one.

-- id (lowercased) -> icon name, or false once it is known there is none
local resolved = {}

-- icon name -> true once a load has been asked for, so it is asked once
local requested = {}

-- Names waiting their turn, and one flag saying a turn is already scheduled.
--
-- Loads go out one at a time, spaced apart, and this is not tidiness. Asking
-- for one asset works; asking for nine at once, which is what a page of tiles
-- did the moment the object path started working, killed the game with an
-- access violation on a garbage pointer. Nothing in a draw loop should be
-- issuing a blocking package load, let alone nine of them in a frame.
local queue = {}
local queued = {}
local pumping = false

-- Slow enough to be gentle, quick enough that a page fills while you look at
-- it. A tile shows its name until its icon arrives, so the wait is legible
-- rather than blank.
local PUMP_MS = 250

-- id (lowercased) -> frames spent waiting for a load to finish
local waited = {}

-- id (lowercased) -> icon name, from whatever is loaded right now
local sighted = nil
local sighted_at = 0
local SIGHT_TTL = 60          -- seconds before another look around is allowed

-- Frames to keep looking before giving up on a name we believe in. At ten a
-- second this is fifteen seconds, which is generous, because giving up early
-- on an icon that would have arrived is the worse mistake: the tile falls
-- back to a name for the rest of the session and there is nothing to suggest
-- waiting a little longer would have worked.
local PATIENCE = 150

local PREFIX = "T_itemicon_"

-- Is this object real?
--
-- StaticFindObject does not answer with nil when it fails. It hands back a
-- wrapper that is not nil and is not an object either, and putting one of
-- those on a brush is what drew a white square in every tile. Dropping this
-- check was an overcorrection: the crash came from checking an object kept
-- since an earlier frame, not from checking one at all.
--
-- Asking a freed object whether it is valid is the crash. Asking one the
-- engine produced a moment ago inside this same call is not, because nothing
-- has had the chance to collect it in between. The rule is about age, not
-- about the question.
local function real(o)
    if o == nil then return false end
    local ok, yes = pcall(function() return o:IsValid() end)
    return ok and yes == true
end

local function object_path(name)
    local leaf = PREFIX .. name
    return icondex.FOLDER .. leaf .. "." .. leaf
end

-- The load itself, as one function made once.
--
-- Not written inline at the call, because an anonymous function there is a
-- fresh closure every quarter second, UE4SS keeps a Lua registry reference to
-- each one, and when Lua collects them its answer is to remove the hook that
-- drives the engine tick. That killed five sessions before the log line
-- naming it was read properly. One function, one reference, nothing to
-- collect.
local loading_name = nil
local loading_path = nil

local function do_load()
    local name, path = loading_name, loading_path
    if path == nil then return end

    pcall(function() LoadAsset(path) end)

    -- Said out loud, because "the icon did not appear" has covered a failed
    -- lookup, a load that went nowhere, a texture that would not go on a
    -- brush and a brush with no size, and telling those apart from a
    -- screenshot has not been possible once.
    local landed
    pcall(function() landed = StaticFindObject(path) end)
    log.say(string.format("icon load %-28s %s", tostring(name),
        real(landed) and "arrived" or "did not arrive"))
end

-- One load, then wait, then the next.
local function pump()
    local name = table.remove(queue, 1)

    if name then
        queued[name] = nil
        requested[name] = true

        -- The object path, not the package path, and this is measured rather
        -- than assumed. Asked for the package it reports no error and loads
        -- nothing; asked for the full object path the texture is there by the
        -- next line. Silent success on the wrong argument is what made this
        -- look like a threading problem, then a timing problem, then a
        -- caching problem.
        --
        -- On the game thread, since the panel's tick is not it. Finding an
        -- object is a lookup and works from anywhere. Loading one is real
        -- engine work and does not.
        loading_name = name
        loading_path = object_path(name)
        ExecuteInGameThread(do_load)
    end

    if #queue > 0 then
        ExecuteWithDelay(PUMP_MS, pump)
    else
        pumping = false
    end
end

local function want(name)
    if requested[name] or queued[name] then return end

    queued[name] = true
    queue[#queue + 1] = name

    if not pumping then
        pumping = true
        ExecuteWithDelay(PUMP_MS, pump)
    end
end

-- The object for an icon name, if it is in memory. Never stored.
--
-- Only ever a lookup. Wanting something loaded is a separate matter, handled
-- above at its own pace, and a later frame is what finds it.
local function find(name)
    local found
    pcall(function() found = StaticFindObject(object_path(name)) end)
    if real(found) then return found end

    want(name)
    return nil
end

-- Icon names the game currently has loaded, keyed by item id.
--
-- One pass over every texture in memory is far too expensive to repeat per
-- icon, so it happens at most once a minute and answers for every id at once.
-- Only names are taken from it, never the objects.
local function look_around()
    local now = os.clock()
    if sighted and (now - sighted_at) < SIGHT_TTL then return sighted end

    local found = {}

    for _, tex in ipairs(FindAllOf("Texture2D") or {}) do
        -- GetFullName, not GetName, which returns nothing on this build.
        -- These come straight from the engine within this call, so they are
        -- live and reading them is safe. What must not happen is keeping one.
        local full
        pcall(function() full = tex:GetFullName() end)

        if type(full) == "string" then
            local leaf = full:match("([^/.]+)$") or ""
            if leaf:sub(1, #PREFIX) == PREFIX then
                local rest = leaf:sub(#PREFIX + 1)
                local id = rest:match("^[^_]+_(.+)$") or rest
                local key = id:lower()
                if found[key] == nil then found[key] = rest end
            end
        end
    end

    sighted, sighted_at = found, now
    return found
end

-- Kept for the panel's convenience. There is no per frame ration any more,
-- now that nothing here fires eighteen speculative loads at once.
function M.new_frame()
end

-- The texture for an item id, or nil when there is none to be had yet.
--
-- The result is good for this frame only. Do not keep it.
function M.get(item_id)
    if type(item_id) ~= "string" or item_id == "" then return nil end

    local key = item_id:lower()

    local name = resolved[key]
    if name == false then return nil end

    if name == nil then
        name = icondex.NAMES[key] or look_around()[key]
        if name == nil then
            -- Nothing recorded and nothing loaded that matches. Guessing at
            -- category names was tried and removed: it invented paths, asked
            -- the engine to load each of them, and bought coverage the table
            -- and a look around the running game mostly had already.
            resolved[key] = false
            return nil
        end
        resolved[key] = name
    end

    local texture = find(name)
    if texture ~= nil then return texture end

    -- Still loading. Waited on rather than given up on, but not for ever.
    waited[key] = (waited[key] or 0) + 1
    if waited[key] >= PATIENCE then
        resolved[key] = false
        M.last_missing = item_id .. " (waited on " .. name .. ")"
    end
    return nil
end

-- The icon's name for an id, without loading a thing.
--
-- For the soft texture route, which hands the engine a path and lets it
-- stream the texture on its own schedule. That is how a grid of icons appears
-- whole rather than one every quarter second: the queue below exists because
-- nine LoadAsset calls in a frame killed the game, and a path costs nothing
-- to hand over.
--
-- Deliberately does not look around the running game, since that is a sweep
-- over every texture in memory and this is called once per tile.
function M.name_for(item_id)
    if type(item_id) ~= "string" or item_id == "" then return nil end

    local key = item_id:lower()
    local name = resolved[key]

    if name == false then return nil end
    if name == nil then
        name = icondex.NAMES[key]
        if name == nil then return nil end
        resolved[key] = name
    end

    return name
end

M.FOLDER = icondex.FOLDER
M.PREFIX = PREFIX

-- A world switch invalidates nothing held here, since nothing is held, but
-- what is loaded changes and so does what is worth waiting for.
function M.reset()
    resolved, requested, waited = {}, {}, {}
    queue, queued = {}, {}
    sighted, sighted_at = nil, 0
end

function M.count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

function M.report()
    local named, absent = 0, 0
    for _, value in pairs(resolved) do
        if value == false then absent = absent + 1 else named = named + 1 end
    end

    log.say("icons:")
    log.say("  table entries: " .. M.count(icondex.NAMES))
    log.say("  ids with a name: " .. named)
    log.say("  ids with no icon: " .. absent)
    log.say("  loads asked for: " .. M.count(requested))
    log.say("  loads still queued: " .. #queue)

    local waiting = 0
    for _ in pairs(waited) do waiting = waiting + 1 end
    log.say("  still waiting on a load: " .. waiting)

    local seen = sighted and M.count(sighted) or 0
    log.say("  icon textures in memory at last look: " .. seen)

    if M.last_missing then
        log.say("  an example that failed: " .. M.last_missing)
    end
end

-- Does LoadAsset do anything, and if so what does it want?
--
-- Stone and CopperOre resolve while Wood and Berries do not, and all four are
-- the same kind of asset in the same folder. The obvious reading is that the
-- two that worked were already in memory and the load is achieving nothing,
-- but that is a guess, and guesses have been expensive here.
--
-- So this asks. Manganese ore is the subject because a copper age base will
-- not have caused its icon to be loaded by anything else, which the items in
-- storage cannot promise. Three things are separated: the package path, the
-- full object path, and simply waiting, since a load that is merely slow
-- looks exactly like a load that never happened.
function M.load_test()
    local leaf = "T_itemicon_Material_ManganeseOre"
    local package = icondex.FOLDER .. leaf
    local object = package .. "." .. leaf

    local function look(when)
        local o
        pcall(function() o = StaticFindObject(object) end)

        local valid = false
        if o ~= nil then pcall(function() valid = o:IsValid() end) end

        log.say(string.format("  %-26s found=%s", when, tostring(valid)))
        return valid
    end

    log.say("load test on " .. leaf)
    look("before anything")

    ExecuteInGameThread(function()
        local ok = pcall(function() LoadAsset(package) end)
        log.say("  LoadAsset(package) raised no error: " .. tostring(ok))
        look("after package path")

        ok = pcall(function() LoadAsset(object) end)
        log.say("  LoadAsset(object) raised no error: " .. tostring(ok))
        look("after object path")
    end)

    ExecuteWithDelay(3000, function()
        look("three seconds later")
    end)
end

-- Four real ids followed all the way to an object name, to tell a lookup
-- problem from a drawing one.
function M.probe()
    log.say("icon lookup:")

    for _, id in ipairs({ "Stone", "Wood", "Berries", "PalSphere" }) do
        local from_table = icondex.NAMES[id:lower()]
        local texture = M.get(id)

        local full
        if texture ~= nil then
            pcall(function() full = texture:GetFullName() end)
        end

        log.say(string.format("  %-10s table says %-22s got %s",
            id, tostring(from_table), tostring(full)))
    end
end

return M
