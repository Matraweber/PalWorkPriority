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
local function fetch(name)
    local path = icondex.FOLDER .. name
    local object = path .. "." .. name

    local found
    pcall(function() found = StaticFindObject(object) end)
    if alive(found) then return found end

    -- Not in memory. LoadAsset brings it in, and it is only worth asking for
    -- something we have reason to believe exists, which is why the callers
    -- above ration this one.
    pcall(function() LoadAsset(path) end)

    pcall(function() found = StaticFindObject(object) end)
    if alive(found) then return found end

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
            local full
            pcall(function() full = tex:GetName() end)

            if type(full) == "string" and full:sub(1, #PREFIX) == PREFIX then
                local rest = full:sub(#PREFIX + 1)
                local id = rest:match("^[^_]+_(.+)$") or rest
                local key = id:lower()
                if found[key] == nil then found[key] = full end
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

    -- 1. the generated table
    local name = icondex.NAMES[key]
    if name then
        local tex = fetch(name)
        if tex then
            cache[key] = tex
            return tex
        end
    end

    -- 2. whatever the game has already drawn
    local seen = look_around()[key]
    if seen then
        local tex = fetch(seen)
        if tex then
            cache[key] = tex
            return tex
        end
    end

    -- 3. the slow way, rationed
    if hard_budget <= 0 then return nil end
    hard_budget = hard_budget - 1

    for _, category in ipairs(CATEGORIES) do
        local tex = fetch(category .. "_" .. item_id)
        if tex then
            cache[key] = tex
            return tex
        end
    end

    -- Remembered as absent so the fifteen attempts above happen once and
    -- never again for this id.
    cache[key] = false
    return nil
end

-- A world switch frees every texture we are holding.
function M.reset()
    cache = {}
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
end

function M.count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

return M
