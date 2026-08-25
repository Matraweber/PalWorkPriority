-- The game's full item list, for the rule picker.
--
-- A rule can target something the base has never held, so the list cannot be
-- built from chest contents. It comes from DT_ItemDataTable, which carries
-- 2466 rows on game revision 82182.
--
-- Getting at those rows took a live probe rather than a guess, and the two
-- results worth keeping are:
--
--   RowMap the PROPERTY is not readable. It reads back as a TrivialObject,
--   the same live-looking wrapper UE4SS hands out for any name at all, and
--   calling ForEach on it fails. It is not a property on this build.
--
--   That is narrower than it first read, and worth stating precisely: the
--   UDataTable METHODS are exported by this UE4SS - FindRow, GetRowMap,
--   GetRowNames, ForEachRow and GetAllRows are all present as bindings. So
--   "the rows cannot be reached" was never true; only that one property is
--   out. If a lookup by row key is ever wanted, table:FindRow(key) is the
--   route, and it is how the localized text tables would be read directly
--   if PalUIUtility.GetItemName ever stops answering.
--
--   GetDataTableRowNames takes the destination as its SECOND argument and
--   fills it. Called with one argument it raises "UFunction expected 2
--   parameters, received 1", and its return value is not the list.
--
-- The filled entries are RemoteUnrealParam wrappers around FNames, so each
-- one needs :get() and then :ToString() before it is a string.

local log = require("log")
local api = require("palapi")

local M = {}

local ITEM_TABLE = "/Game/Pal/DataTable/Item/DT_ItemDataTable.DT_ItemDataTable"

M.ids = nil        -- sorted list of item ids
M.lower = nil      -- parallel list, lowercased once for searching

local function read_rows()
    local lib = api.cdo("/Script/Engine.Default__DataTableFunctionLibrary")
    if not lib then
        log.warn("DataTableFunctionLibrary unavailable, so no item list")
        return nil
    end

    local tbl
    pcall(function() tbl = StaticFindObject(ITEM_TABLE) end)
    if not api.valid(tbl) then
        log.warn("item data table not found at " .. ITEM_TABLE)
        return nil
    end

    local raw = {}
    local ok, err = pcall(function() lib:GetDataTableRowNames(tbl, raw) end)
    if not ok then
        log.warn("could not read item rows: " .. tostring(err))
        return nil
    end

    local ids = {}
    for _, entry in ipairs(raw) do
        local name
        pcall(function()
            local fname = entry:get()
            if fname then name = fname:ToString() end
        end)
        if type(name) == "string" and name ~= "" and name ~= "None" then
            ids[#ids + 1] = name
        end
    end

    return ids
end

-- Built once and kept. Reading 2466 rows is not free, and the item list does
-- not change while the game is running.
function M.load()
    if M.ids then return M.ids end

    local ids = read_rows()
    if ids == nil or #ids == 0 then
        -- Cache the failure as an empty list rather than nil, so a picker
        -- retries once per world rather than once per keystroke.
        M.ids, M.lower = {}, {}
        return M.ids
    end

    -- Sorted the way the list is READ, not the way the ids happen to be
    -- spelled.
    --
    -- A plain table.sort is ASCII ordinal, so every id starting with a
    -- lowercase letter lands after every id starting with an uppercase one:
    -- "bone" sorted last of the whole table, after "Yakushima_Ingot001", and
    -- "Pal_crystal_L" sorted away from the Pal items it belongs beside. A
    -- player looking for Bone under B never found it, which is a worse
    -- findability problem than any missing icon.
    --
    -- The key lowercases and turns underscores into the spaces the panel
    -- draws, so the order matches the names on screen. Built once into a
    -- table rather than computed inside the comparator, which would recompute
    -- it O(n log n) times for 2466 ids.
    local key = {}
    for _, id in ipairs(ids) do
        key[id] = id:lower():gsub("_", " ")
    end
    table.sort(ids, function(a, b)
        if key[a] ~= key[b] then return key[a] < key[b] end
        -- Same display key, different ids: keep it deterministic.
        return a < b
    end)

    -- Two keys per id: the raw id, and what the panel actually draws.
    --
    -- Only the raw id was indexed, while the picker displays the transformed
    -- form - underscores become spaces and camel case is split. So "CopperOre"
    -- was shown as "Copper Ore" and searched as "copperore", and typing the
    -- name on screen found nothing. Measured across the ids the picker shows,
    -- 157 of 198 could not be found by typing their own displayed name.
    --
    -- Both are kept rather than swapping one for the other, because anyone who
    -- learned to type the internal id should not lose that.
    local lower, disp = {}, {}
    for i, id in ipairs(ids) do
        lower[i] = id:lower()
        disp[i] = M.display_name(id):lower()
    end

    M.ids, M.lower, M.disp = ids, lower, disp
    log.debug("item list: " .. #ids .. " id(s)")
    return M.ids
end

-- Dropped on a world switch along with everything else, since the table
-- object behind it is an engine wrapper.
function M.reset()
    M.ids = nil
    M.lower = nil
end

-- Substring match, case insensitive, capped so a single letter cannot try to
-- draw two thousand rows. Exact and prefix matches come first: typing "wood"
-- should offer Wood before Wood_Refined.
-- The name the GAME gives an item, or nil.
--
-- The transform below can only rearrange the internal id, and a third of these
-- ids are outright renames with no lexical overlap at all: CopperOre is "Ore",
-- IronIngot is "Refined Ingot", MachineParts is "Nail", Pal_crystal_S is
-- "Paldium Fragment". No amount of splitting camel case reaches those.
--
-- PalUIUtility.GetItemName takes an item id and returns the localized display
-- name, in whichever of the game's sixteen languages is active. It is
-- reflected - it appears in this mod's own ForEachFunction dump, and that
-- enumeration only sees reflected UFunctions - with the signature
--
--   GetItemName(ObjectProperty WorldContextObject,
--               NameProperty StaticItemId,
--               TextProperty outName)
--
-- THE ARGUMENT MUST BE FName(id), NEVER THE BARE STRING. UE4SS's
-- push_nameproperty calls get_userdata<FName> with no type check, so a Lua
-- string makes it dereference null, and that is an access violation pcall
-- cannot catch. It is upstream issue #1360 and it is still open. This is the
-- single most dangerous line in the file.
--
-- The FText is converted to a string immediately and the wrapper is never
-- kept, which is the rule BetterSearch and PalBaseInfoGrid both follow. An
-- empty result counts as a miss rather than as a name: reading FText off a
-- property is documented to return "" sometimes, and cut content genuinely
-- has no name.
local name_memo = {}

M.resolved, M.unresolved = 0, 0

function M.real_name(id)
    local hit = name_memo[id]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end

    -- A missing utility or controller is NOT an answer.
    --
    -- load() can run before the world is up, and memoizing that as "this item
    -- has no name" would freeze the fallback in place for the rest of the
    -- session - permanently wrong, and invisible, because a plausible name
    -- would still be drawn. Only a call that actually completed is recorded.
    local util = api.cdo("/Script/Pal.Default__PalUIUtility")
    if not util then return nil end

    -- Any live world context does; the controller is the one this mod already
    -- resolves, and it is used in this call and not kept.
    local pc = api.player_controller()
    if not pc then return nil end

    local got
    pcall(function()

        local box = {}
        util:GetItemName(pc, FName(id), box)

        -- The out-param's casing is not consistent across UE4SS builds, so
        -- both spellings are tried rather than assumed.
        local ft = box.outName or box.OutName
        if ft == nil then return end

        local text
        pcall(function() text = ft:ToString() end)
        if type(text) ~= "string" then return end

        text = text:match("^%s*(.-)%s*$") or ""

        -- "en Text" is not a name, it is UE saying it has no row for this.
        --
        -- When a localized text lookup misses, the FText resolves to the
        -- culture code followed by "Text" - "en Text" here, "de Text" on a
        -- German client. Only an EMPTY result was being rejected, so 88 ids
        -- came back holding that placeholder and were drawn as if the game had
        -- named them. Matched by shape rather than by the literal, since the
        -- culture is whatever the player is running.
        --
        -- Genuinely worth having as a signal rather than just filtering out:
        -- every one of the 88 is cut, debug or NPC-only content - names like
        -- Debug_Handgun_IvyCling, FarmCrop_Tmp, GatlingGun_NPC_GrassBoss. The
        -- game having no name for something is the most reliable evidence
        -- available that a player can never hold it.
        if text ~= "" and not text:match("^%a[%a%-]* Text$") then
            got = text
        end
    end)

    name_memo[id] = got or false
    if got then M.resolved = M.resolved + 1
    else M.unresolved = M.unresolved + 1 end
    return got
end

-- Does the game have a name for this at all?
--
-- False means the localized lookup returned its placeholder, which in practice
-- means cut, debug or NPC-only content. Used by the picker to keep such things
-- out of a list a player is choosing from.
function M.named(id)
    return M.real_name(id) ~= nil
end

-- What the panel draws for an id, and the only definition of it.
--
-- Lives here rather than in panel.lua because the search index has to be built
-- from the same string the player reads. Two copies of this rule is precisely
-- how the grid and the scheduler once disagreed about a priority, and the
-- README already tells that story about store.effective.
function M.display_name(id)
    -- What the game calls it, when the game will say.
    --
    -- Measured on this build: all 2466 ids resolve, none come back unnamed,
    -- and the whole list costs 25ms once. The transform below stays as the
    -- fallback for a world that is not up yet, and for any future id the game
    -- has no string for.
    local real = M.real_name and M.real_name(id)
    if real then return real end

    local out = {}
    for chunk in tostring(id):gmatch("[^_%s]+") do
        -- Two capitals before the next word, not one. The single-capital form
        -- turned "AIcore" into "A Icore"; a run is what the rule is for, so
        -- HPMedicine still becomes HP Medicine.
        chunk = chunk:gsub("(%l)(%u)", "%1 %2"):gsub("(%u%u)(%u%l)", "%1 %2")
        out[#out + 1] = chunk
    end
    local name = table.concat(out, " ")
    if name == "" then return tostring(id) end
    return name
end

function M.search(text, limit)
    M.load()
    limit = limit or 40

    if type(text) ~= "string" or text == "" then
        local out = {}
        for i = 1, math.min(limit, #M.ids) do out[i] = M.ids[i] end
        return out
    end

    local want = text:lower()
    local exact, prefix, rest = {}, {}, {}

    for i, id in ipairs(M.lower) do
        -- Either key matches, and the better of the two decides the rank, so
        -- typing a displayed name is not punished for being the second key.
        local shown = M.disp and M.disp[i] or id

        if id == want or shown == want then
            exact[#exact + 1] = M.ids[i]
        elseif id:sub(1, #want) == want or shown:sub(1, #want) == want then
            prefix[#prefix + 1] = M.ids[i]
        elseif id:find(want, 1, true) or shown:find(want, 1, true) then
            rest[#rest + 1] = M.ids[i]
        end
    end

    local out = {}
    for _, group in ipairs({ exact, prefix, rest }) do
        for _, id in ipairs(group) do
            if #out >= limit then return out end
            out[#out + 1] = id
        end
    end
    return out
end

return M
