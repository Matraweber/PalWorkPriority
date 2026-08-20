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

-- The object for an icon name, if it is in memory. Never stored.
local function find(name)
    local leaf = PREFIX .. name
    local path = icondex.FOLDER .. leaf
    local object = path .. "." .. leaf

    local found
    pcall(function() found = StaticFindObject(object) end)
    if real(found) then return found end

    -- Not in memory yet. LoadAsset starts a load but the object is not there
    -- by the time the call returns, so this asks once and a later frame is
    -- what finds it. Once per name, because repeating it every frame is
    -- asking the engine to load something it is already loading.
    if not requested[name] then
        requested[name] = true
        pcall(function() LoadAsset(path) end)

        pcall(function() found = StaticFindObject(object) end)
        if real(found) then return found end
    end

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

-- A world switch invalidates nothing held here, since nothing is held, but
-- what is loaded changes and so does what is worth waiting for.
function M.reset()
    resolved, requested, waited = {}, {}, {}
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

    local waiting = 0
    for _ in pairs(waited) do waiting = waiting + 1 end
    log.say("  still waiting on a load: " .. waiting)

    local seen = sighted and M.count(sighted) or 0
    log.say("  icon textures in memory at last look: " .. seen)

    if M.last_missing then
        log.say("  an example that failed: " .. M.last_missing)
    end
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
