-- An item id in, a Texture2D out.
--
-- Palworld keeps every item icon in one folder under a name that pairs the
-- item with a category:
--
--   /Game/Others/InventoryItemIcon/Texture/T_itemicon_Material_CopperIngot
--
-- The category cannot be worked out from the id, which is the whole
-- difficulty. icondex.lua records the pairing for everything readable in the
-- shipped pak, but the pak's index is compressed and that list is a good
-- subset rather than the whole set, so there are three more ways to find one
-- and each is tried in turn:
--
--   1. the generated table, which is exact and instant
--   2. textures the game already has in memory, which covers anything it has
--      drawn since launch regardless of what the table knows
--   3. asking the engine to load each category in turn, which is the slow
--      one and is rationed
--
-- Every answer is remembered, including "there is no icon", so a given id
-- costs its search once per session and nothing afterwards.

local log = require("log")
local api = require("palapi")
local icondex = require("icondex")

local M = {}

-- id (lowercased) -> texture, or false once the search has failed
local cache = {}

-- icon name -> true once a load has been asked for, so it is asked once
local requested = {}

-- id (lowercased) -> how many frames it has been waited for, and how far
-- through the category list it has got
local waited = {}
local probing = {}

-- Frames to keep looking before giving up on a name we believe in. At ten a
-- second this is a few seconds, which is long enough for a load to finish and
-- short enough that a genuinely missing icon stops costing anything.
local PATIENCE = 60

-- id (lowercased) -> icon name, built from whatever is loaded right now
local sighted = nil
local sighted_at = 0
local SIGHT_TTL = 60          -- seconds before another look around is allowed

-- Ordered by how much of the table each accounts for, so the common case
-- costs one attempt rather than fifteen. Lowercase "food" is not a mistake:
-- the game ships both spellings.
local CATEGORIES = {
    "Food", "Material", "Accessory", "Armor", "Weapon", "Consume",
    "Essential", "Ammo", "food", "Relic", "PalSphere", "Blueprint",
    "QuestItem", "PalAwakening", "SphereModule", "Glider", "Salvage",
    "Jewelry",
}

-- How many unknown ids may be searched the hard way per drawn frame.
--
-- The panel redraws ten times a second and a full page is forty eight tiles.
-- Searching every unknown one at once would stall the frame that opened the
-- picker, which is the moment responsiveness is most obvious. Rationed like
-- this a page fills in over a moment or two instead, and the ones the table
-- already knows are there immediately.
local HARD_PER_FRAME = 2
local hard_budget = 0

local PREFIX = "T_itemicon_"

local function alive(o)
    if o == nil then return false end
    local ok, yes = pcall(function() return o:IsValid() end)
    return ok and yes == true
end

-- "Material_Stone" -> the object, or nil.
--
-- The table stores the tail only, because the T_itemicon_ prefix is on every
-- one of the eight hundred and it is noise to repeat. Putting it back is this
-- function's job, and forgetting to was why the first attempt resolved
-- nothing at all: every path it asked for was missing its first eleven
-- characters, and a missing asset and a misspelled one look identical.
local function fetch(tail)
    local name = PREFIX .. tail
    local path = icondex.FOLDER .. name
    local object = path .. "." .. name

    local found
    pcall(function() found = StaticFindObject(object) end)
    if alive(found) then return found end

    -- Not in memory yet. LoadAsset starts it, but the object is not there by
    -- the time the call returns: Stone resolved and Wood did not, and the
    -- only difference between them was that Stone happened to be loaded
    -- already. So ask once and let a later frame find it.
    if not requested[tail] then
        requested[tail] = true
        pcall(function() LoadAsset(path) end)
        pcall(function() found = StaticFindObject(object) end)
        if alive(found) then return found end
    end

    return nil
end

-- Everything the game currently has loaded, keyed by item id.
--
-- One pass over every texture in memory is far too expensive to repeat per
-- icon, so it is done at most once a minute and answers for every id at once.
local function look_around()
    local now = os.clock()
    if sighted and (now - sighted_at) < SIGHT_TTL then return sighted end

    local found = {}
    local textures = FindAllOf("Texture2D") or {}

    for _, tex in ipairs(textures) do
        if alive(tex) then
            -- GetFullName, not GetName. GetName looked like the obvious
            -- one and quietly returned nothing on this build, so every
            -- texture was skipped and this whole fallback reported an empty
            -- room while forty eight icons sat in it.
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
    end

    sighted, sighted_at = found, now
    return found
end

-- Called once per drawn frame, before any icons are asked for.
function M.new_frame()
    hard_budget = HARD_PER_FRAME
end

-- The texture for an item id, or nil when there is none to be had.
function M.get(item_id)
    if type(item_id) ~= "string" or item_id == "" then return nil end

    local key = item_id:lower()

    local known = cache[key]
    if known ~= nil then
        -- A texture can be freed under us between frames, so a remembered one
        -- is still checked before it is handed out.
        if known == false then return nil end
        if alive(known) then return known end
        cache[key] = nil
    end

    -- A name we believe in, either recorded or seen in memory.
    local name = icondex.NAMES[key] or look_around()[key]

    if name then
        local tex = fetch(name)
        if tex then
            cache[key] = tex
            return tex
        end

        -- Waited on rather than searched for. Falling through to the category
        -- walk here is what cost a second per item: eighteen loads for an
        -- asset whose name was already known and merely not finished loading.
        waited[key] = (waited[key] or 0) + 1
        if waited[key] < PATIENCE then return nil end

        cache[key] = false
        M.last_missing = item_id .. " (waited on " .. name .. ")"
        return nil
    end

    -- No name. Walk the categories, one per frame rather than eighteen at
    -- once, because each is a load that may not answer immediately anyway and
    -- doing them together stalls the frame for a second.
    if hard_budget <= 0 then return nil end
    hard_budget = hard_budget - 1

    local at = (probing[key] or 0) + 1
    probing[key] = at

    -- Twice through: the first pass asks for each, the second finds whichever
    -- of them arrived, since fetch only requests a given name once.
    if at > #CATEGORIES * 2 then
        cache[key] = false
        M.last_missing = item_id .. " (no table entry, no category matched)"
        return nil
    end

    local category = CATEGORIES[((at - 1) % #CATEGORIES) + 1]
    local tex = fetch(category .. "_" .. item_id)
    if tex then
        cache[key] = tex
        return tex
    end

    return nil
end

-- A world switch frees every texture we are holding.
function M.reset()
    cache = {}
    requested, waited, probing = {}, {}, {}
    sighted, sighted_at = nil, 0
    hard_budget = 0
end

function M.report()
    local hits, misses = 0, 0
    for _, value in pairs(cache) do
        if value == false then misses = misses + 1 else hits = hits + 1 end
    end

    log.say("icons:")
    log.say("  table entries: " .. M.count(icondex.NAMES))
    log.say("  resolved this session: " .. hits)
    log.say("  searched and not found: " .. misses)

    local seen = sighted and M.count(sighted) or 0
    log.say("  icon textures in memory at last look: " .. seen)

    if M.last_missing then
        log.say("  an example that failed: " .. M.last_missing)
    end
end

-- Four real ids, followed all the way to an object name. Says which of the
-- three routes answered and what it handed back, so a blank tile can be
-- blamed on the lookup or cleared of it.
function M.probe()
    log.say("icon lookup:")

    -- The ration exists to protect a frame, and this is not one.
    hard_budget = 99

    for _, id in ipairs({ "Stone", "Wood", "Berries", "PalSphere" }) do
        local from_table = icondex.NAMES[id:lower()]
        local tex = M.get(id)

        local full
        if tex then pcall(function() full = tex:GetFullName() end) end

        log.say(string.format("  %-10s table says %-22s got %s",
            id, tostring(from_table), tostring(full)))
    end
end

function M.count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

return M
