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
local clock = require("clock")
local icondex = require("icondex")
local api = require("palapi")

local M = {}

-- What LoadAsset actually costs, reported by "pwp panel icons".
M.worst_load = 0
M.load_ms = 0
M.loads = 0
-- Bumped whenever an id is written off, so a caller memoising a list built
-- from this can tell that the answer has changed.
M.gave_up_n = 0

-- Explicit diagnostic lookups only; the demand path uses LoadAsset.
M.worst_find = 0
M.find_ms = 0
M.finds = 0

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
-- Strings cannot dangle. Cold requests load on the game-thread pump and
-- hand the fresh object directly to the panel to pin in an engine brush.
-- A draw without a usable pin reacquires by name within the same allowance.

-- id (lowercased) -> icon name, or false once it is known there is none
local resolved = {}

-- icon name -> true once a load has been asked for, so it is asked once
local requested = {}

-- Cold loads wait in FIFO order on the game-thread pump. A draw may only
-- reacquire a previously successful name, after the FIFO and within its budget.
local queue = {}
local queued = {}
-- Names queued on spec rather than because the index named them. A guess that
-- misses is the expected case, not news, so pump_one keeps it out of the log.
local guessed = {}
local pumping = false

-- The ration, and why it can finally be lifted.
--
-- 250 ms and one load at a time was set after nine LoadAsset calls in a
-- single frame took the game down. That was read as "loading is dangerous",
-- and it was not: the fault was the cross-thread scheduling that took three
-- days to find, and a mod that loaded more simply reached it sooner. With
-- everything on one game-thread heartbeat, the reason for the ration is gone.
--
-- A page is forty tiles. At one per 250 ms that is ten seconds of watching
-- names turn into pictures, which is what "the ADD tab is super laggy" was.
-- Eight per beat clears a page in half a second.
--
-- Still rationed rather than unbounded, because each of these is a blocking
-- load on the game thread and a filter that matches four hundred items should
-- not try to load four hundred textures in one frame.
local PUMP_MS = 100
-- Retain the twelve-attempt ceiling even when the clock does not advance.
local PUMP_BATCH = 12
-- Soft elapsed budget between loads. Historical averages do not bound a cold
-- asset: one native LoadAsset can exceed this, but no second load should then
-- compound the stall. Keep the count ceiling when the clock is coarse/quiet.
local PUMP_BUDGET_SECONDS = 0.004

-- Called synchronously with name -> fresh texture(s). A pump load sends a
-- singleton; the rare name-discovery fallback sends its current-call results.
-- Consumers must pin/use them before returning and must not retain wrappers.
-- No return value or pin-success acknowledgement is required by icons.
M.on_sweep = nil

-- Only primitive facts survive a callback, never a LoadAsset result.
local arrived = {}
local attempted_at = {}
local discovery_pending = {}
local discover
local PUMP_ENTRY = "icons_pump"
local pump
local function schedule()
    if not pumping then
        pumping = true
        clock.every(PUMP_ENTRY, PUMP_MS, function() pump() end)
    end
end

-- Draw fallback and the scheduled pump share the remaining load allowance.
-- Each scheduled beat starts a slice; without a timer, elapsed time renews it.
-- Callback/pinning time counts too. A single native operation can overrun.
local slice_at, slice_count, slice_seconds = -1, 0, 0
local function begin_slice()
    slice_at, slice_count, slice_seconds = os.clock(), 0, 0
end
local function room()
    if os.clock() - slice_at >= PUMP_MS / 1000 then begin_slice() end
    return slice_count < PUMP_BATCH and slice_seconds < PUMP_BUDGET_SECONDS
end

-- id (lowercased) -> frames spent waiting for a load to finish
local waited = {}

-- Ids whose recorded icon name failed and have had their one retry, and the
-- base name being retried under other categories.
local retried = {}
local alternates = {}

-- id -> how many draws it has waited for an idle queue to guess under.
local idle_waits = {}

-- A whole-session budget for speculative loads, so a list full of unknown
-- items cannot turn into hundreds of them.
-- Raised now that guesses also cover ids the index never had. Each one
-- queues a load per category, and they only go out while the queue is idle.
local RETRY_BUDGET = 80
local retries_left = RETRY_BUDGET

-- The category prefixes the shipped index actually uses. Ordered by how many
-- entries carry each, so the likeliest is asked for first.
local CATEGORIES = {
    "Food", "Material", "Accessory", "Armor", "Weapon", "Consume",
    "Essential", "Ammo", "food", "Relic", "PalSphere", "Blueprint",
    "QuestItem", "PalAwakening", "SphereModule", "Glider",
    -- The tail of the index. Rare, but the growth stones and the egg items
    -- live down here and they are the ones that came back blank.
    "Jewelry", "PalUpgradeStone", "PalUpgradeStone2", "PalUpgradeStone3",
    "PalUpgradeStone4", "PalEgg", "SkillUnlock", "SkillCard",
}

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

-- Icon names this mod worked out for itself, kept between sessions.
--
-- icondex covers 858 of about 2466 items, because the pak's directory index
-- is compressed and the generator can only read names embedded in
-- uncompressed asset data. Everything it misses is answered at runtime - by
-- look_around, which sweeps all 7072 loaded textures for 26ms, or by the
-- category guesser, which is bounded to a few ids per session on purpose.
--
-- Both answers were then thrown away when the game closed, so every session
-- paid the 26ms again the first time the picker met an id the index lacks.
-- That sweep was the whole of the 59ms first open measured after the frame
-- slice landed.
--
-- What is learned is a fact about the shipped game, not about this save: the
-- texture for an item id does not change. So it is written down, and the
-- second session onwards starts knowing it. The file grows to cover what a
-- player actually stores rather than the whole catalogue, which is the part
-- that matters.
--
-- The path is worked out here rather than handed in by main.lua, so this
-- module keeps hot reloading on its own.
local function mod_dir()
    local src = debug.getinfo(1, "S").source
    local scripts = src:sub(2):match("^(.*[\\/])") or ""
    return scripts:match("^(.*[\\/])[Ss]cripts[\\/]$") or scripts
end

local LEARNED_PATH = mod_dir() .. "iconnames.txt"
local learned = {}
local learned_dirty = false

local function load_learned()
    local f = io.open(LEARNED_PATH, "r")
    if not f then return 0 end

    local n = 0
    for line in f:lines() do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, name = line:match("^([^|]+)|(.+)$")
            if key and name then
                learned[key] = name
                n = n + 1
            end
        end
    end
    f:close()
    return n
end

-- Only ever adds. A name that is wrong for this build would be corrected by
-- the loader failing and the id being resolved again, and a name that is
-- merely unused costs one table entry.
local function learn(key, name)
    if type(name) ~= "string" or name == "" then return end
    if learned[key] == name then return end
    if learned[key] == nil and icondex.NAMES[key] == name then return end
    learned[key], learned_dirty = name, true
end

local function save_learned()
    if not learned_dirty then return false end

    local f, err = io.open(LEARNED_PATH, "wb")
    if not f then
        -- Said once, not once a beat: losing this costs a 26ms sweep next
        -- session, not correctness.
        if not M.learned_warned then
            M.learned_warned = true
            log.warn("could not write " .. LEARNED_PATH .. ": " ..
                tostring(err))
        end
        return false
    end

    f:write("# Pal Work Priority - item id to icon texture name.\n")
    f:write("# Worked out at runtime for ids icondex.lua does not cover.\n")
    f:write("# Safe to delete; it will be learned again.\n")

    -- Sorted, so the file does not reshuffle on every write.
    local keys = {}
    for key in pairs(learned) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        f:write(key .. "|" .. learned[key] .. "\n")
    end

    f:close()
    learned_dirty = false
    return true
end

-- Read once here, and again on every hot reload, which is what makes the
-- reload path safe: a swapped module starts from the file rather than from an
-- empty table, so nothing already known has to be swept for a second time.
do
    local n = load_learned()
    if n > 0 then
        log.debug("icons: " .. n .. " learned icon name(s) loaded")
    end
end

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

-- Validate only the wrapper returned by THIS native call. In particular,
-- neither arrival booleans nor a successful earlier pin make an old wrapper safe.
local function load_texture(name)
    requested[name] = true
    local t0 = os.clock()
    local ok, texture = pcall(LoadAsset, object_path(name))
    local valid = ok and real(texture)
    local took = (os.clock() - t0) * 1000
    M.load_ms = M.load_ms + took
    M.loads = M.loads + 1
    if took > M.worst_load then
        M.worst_load = took
        log.say(string.format("icon load %s took %.0fms (worst so far)", name, took))
    end
    arrived[name] = valid
    attempted_at[name] = os.clock()
    if valid then return texture end
end

local function pump_one()
    local name = table.remove(queue, 1)
    if not name then return end
    queued[name], guessed[name] = nil, nil
    local started = os.clock()
    local texture = load_texture(name)
    -- Hand off before another load can run. The callback is optional (closed
    -- panel, pin cap, construction failure); a draw can reacquire by name.
    if texture then
        -- Resolve guessed/wrong-category ids before the panel next asks for a
        -- pin by name. The association is a string; the texture is not cached.
        local base = name:match("^[^_]+_(.+)$")
        for key, candidate in pairs(alternates) do
            if candidate == base then
                resolved[key], waited[key], alternates[key] = name, nil, nil
                learn(key, name)
            end
        end
        if M.on_sweep then pcall(M.on_sweep, { [name] = texture }) end
    end
    slice_count = slice_count + 1
    slice_seconds = slice_seconds + os.clock() - started
    -- Start the cooldown at completion, including a single oversized load.
    slice_at = os.clock()
end

pump = function()
    begin_slice()
    for _ = 1, PUMP_BATCH do
        if #queue == 0 then break end
        pump_one()
        if slice_seconds >= PUMP_BUDGET_SECONDS then break end
    end

    -- Unknown/nonstandard names still need the game's resident-name fallback.
    -- It runs only on demand, after the FIFO, on a separate beat from loads.
    if #queue == 0 and slice_count == 0 and next(discovery_pending) then
        local started = os.clock()
        discover()
        slice_seconds = slice_seconds + os.clock() - started
        slice_at = os.clock()
    end
    if #queue == 0 and not next(discovery_pending) then
        pumping = false
        clock.cancel(PUMP_ENTRY)
        pcall(save_learned)
    end
end

-- Called by the reloader before this module is replaced, so the outgoing copy
-- takes its queue and its timer with it.
function M.shutdown()
    -- The outgoing module takes its queue with it, so anything it learned
    -- since the last drain would go too.
    pcall(save_learned)
    queue, queued, discovery_pending = {}, {}, {}
    pumping = false
    clock.cancel(PUMP_ENTRY)
end

local function want(name, speculative)
    if requested[name] or queued[name] then return end

    if speculative then guessed[name] = true end
    queued[name] = true
    queue[#queue + 1] = name

    schedule()
end

-- A cold draw only queues. The pump offers its fresh LoadAsset result to the
-- panel's existing pin callback; normal later draws read that engine-owned pin.
-- If no pin can serve this draw, reacquire a previously successful name here.
-- This uses the shared count/time allowance and never overtakes queued work.
-- No global object discovery and no wrapper cache is involved.
local function find(name)
    if queued[name] then return nil end
    if not requested[name] then want(name); return nil end
    if arrived[name] then
        if #queue > 0 or not room() then return nil end
        local started = os.clock()
        local texture = load_texture(name)
        slice_count = slice_count + 1
        slice_seconds = slice_seconds + os.clock() - started
        slice_at = os.clock()
        return texture
    end
    -- Failed/nil-return loads are not permanent evidence. Retrying through
    -- the FIFO also recovers textures that arrive late or are collected.
    if os.clock() - (attempted_at[name] or -1) >= 0.5 then
        requested[name] = nil
        want(name)
    end
    return nil
end

-- Rare fallback for names absent from the index and category guesses. Store
-- names only, and never make the tile that requested discovery pay for it.
-- A full native scan is still indivisible; the 60-second throttle and a separate
-- idle beat limit frequency, not that operation's maximum duration.
discover = function()
    local pending = discovery_pending
    discovery_pending = {}
    local started = os.clock()
    local found, textures = {}, {}
    for _, tex in ipairs(FindAllOf("Texture2D") or {}) do
        local leaf
        pcall(function() leaf = tex:GetFName():ToString() end)
        if type(leaf) == "string" and leaf:sub(1, #PREFIX) == PREFIX then
            local rest = leaf:sub(#PREFIX + 1)
            local id = rest:match("^[^_]+_(.+)$") or rest
            local key = id:lower()
            if found[key] == nil then found[key] = rest end
            if pending[key] and real(tex) then textures[rest] = tex end
        end
    end
    sighted, sighted_at = found, os.clock()
    M.sweeps = (M.sweeps or 0) + 1
    M.sweep_ms = (M.sweep_ms or 0) + (os.clock() - started) * 1000
    for key in pairs(pending) do
        local name = found[key]
        if name then
            resolved[key], waited[key], alternates[key] = name, nil, nil
            learn(key, name)
            arrived[name], requested[name] = true, true
        end
    end
    if next(textures) and M.on_sweep then pcall(M.on_sweep, textures) end
end

local function look_around(key)
    if sighted and os.clock() - sighted_at < SIGHT_TTL then return sighted end
    discovery_pending[key] = true
    schedule()
    return {}
end

-- Kept for the panel's scope contract. No textures are retained even between
-- get calls in a single draw, so errors/missed cleanup cannot age a wrapper.
function M.new_frame()
end

-- The texture for an item id, or nil when there is none to be had yet.
--
-- The result is good for this frame only. Do not keep it.
-- An id that is already an icon suffix.
--
-- The generated table is keyed by whatever the pak reader could pull out of a
-- path, and it does not always keep the whole of it: PalSphere_Giga is filed
-- under "giga", so looking up the item id found nothing and the tile fell back
-- to text while its icon sat in the table under another name.
--
-- Every value in the table is a real icon suffix, so an id that matches one is
-- its own answer. Built once, on demand, and remembered.
local self_names = nil

local function self_named(key)
    if self_names == nil then
        self_names = {}
        for _, suffix in pairs(icondex.NAMES) do
            self_names[tostring(suffix):lower()] = suffix
        end
    end
    return self_names[key]
end

-- Demand resolution. Missing opportunities (queued work or an exhausted
-- allowance) do not count as evidence that the icon does not exist.
function M.get(item_id)
    if type(item_id) ~= "string" or item_id == "" then return nil end

    local key = item_id:lower()

    local name = resolved[key]
    if name == false then return nil end

    if name == nil then
        name = learned[key] or icondex.NAMES[key] or self_named(key)
            or (sighted and sighted[key])
        if name == nil then
            -- Nothing recorded and nothing loaded that matches.
            --
            -- Guessing category names was tried once and removed, because it
            -- invented paths for every unknown id and asked the engine to
            -- load each of them - drowning the loader in speculation. What
            -- makes it affordable now is WHEN it runs: only while the queue
            -- is empty, so a guess can never delay an icon somebody is
            -- looking at, and only for a bounded number of ids per session.
            -- The index covers 858 of about 2466 items, so without this every
            -- id it missed is a blank square for the session.
            if not retried[key] then
                if #queue == 0 and retries_left > 0 then
                    retries_left = retries_left - 1
                    retried[key] = true
                    alternates[key] = item_id
                    for _, cat in ipairs(CATEGORIES) do
                        want(cat .. "_" .. item_id, true)
                    end
                    return nil
                end

                -- "Not now" is not "never".
                --
                -- Falling through to resolved = false here condemned an id
                -- for the session because the queue happened to be busy at
                -- the moment it was first drawn - and the first unknown id on
                -- a page fills the queue itself, so every other unknown id in
                -- that frame was written off. The budget could barely be
                -- spent and most of a page stayed blank. Asked again later
                -- instead, and only given up on once it has waited as long as
                -- a named icon would.
                idle_waits[key] = (idle_waits[key] or 0) + 1
                if idle_waits[key] < PATIENCE then return nil end
            end

            if alternates[key] then
                -- Decided as soon as the pump has been through every
                -- candidate, not after a hundred and fifty draws.
                --
                -- PATIENCE is right for a name the index promised, where the
                -- only question is whether the texture has finished loading.
                -- It is wrong here: every guess has either produced an object
                -- or provably not, and once the last one has been tried there
                -- is nothing left to wait for. Waiting anyway meant an id
                -- needed roughly fifty seconds ON SCREEN before it could be
                -- called missing, which made the answer useless to anything
                -- that wanted to act on it.
                local all_tried = true
                for _, cat in ipairs(CATEGORIES) do
                    local alt = cat .. "_" .. item_id
                    if arrived[alt] == nil then
                        all_tried = false
                    elseif arrived[alt] then
                        all_tried = false
                        local found = find(alt)
                        if found ~= nil then
                            resolved[key] = alt
                            learn(key, alt)
                            alternates[key] = nil
                            waited[key] = nil
                            return found
                        end
                    end
                end

                if not all_tried then return nil end
                alternates[key] = nil
            end

            local observed = look_around(key)[key]
            if discovery_pending[key] then return nil end
            if observed then
                resolved[key] = observed
                learn(key, observed)
                return find(observed)
            end
            resolved[key] = false
            M.gave_up_n = M.gave_up_n + 1
            return nil
        end
        resolved[key] = name
        learn(key, name)
    end

    -- Snapshot the queue BEFORE the lookup, because the lookup fills it.
    --
    -- The category retry below asks for an idle queue, which is its whole
    -- safety argument: guesses only run when there is nothing better to do.
    -- Asked after find(), that condition can never be true. find() returns nil
    -- only after calling want(name), and want either pushes the name or
    -- returns early BECAUSE the name is already queued - so #queue >= 1 either
    -- way, and the gate was unsatisfiable from the day it was written.
    --
    -- What it cost: an item whose icondex name is wrong - the lowercase food_
    -- scrape artefacts the note below names as the reason this feature exists
    -- - waited out its patience, fell past the dead branch to resolved=false,
    -- and was written off. gave_up then made producible() false, so the picker
    -- dropped the item and no limit could be set for it until the world
    -- reloaded. The twenty lines of reasoning under "Bounded twice over" had
    -- never run once.
    --
    -- Items missing from icondex entirely were always fine: the same test in
    -- the name == nil path above is reached before any find() and is genuinely
    -- satisfiable. It was only wrong names that were lost.
    local idle = (#queue == 0)

    local texture = find(name)
    if texture ~= nil then
        -- Cleared on success, or M.unresolved reports every icon that was
        -- ever slow as though it were still pending.
        waited[key] = nil
        return texture
    end

    if queued[name] or arrived[name] then return nil end
    -- Still loading. Waited on rather than given up on, but not for ever.
    waited[key] = (waited[key] or 0) + 1
    if waited[key] >= PATIENCE then
        -- One more try, under a different category, before giving up.
        --
        -- This is NOT the blanket guessing the note above rejects. That
        -- invented paths for every id the table did not know; this fires only
        -- for an id the table DID know, whose recorded path has now failed to
        -- arrive for a hundred and fifty frames - so the name is wrong rather
        -- than slow. The scrape is the reason: the pak's index is only partly
        -- readable from outside the engine, and its own output proves the
        -- damage, carrying "Food" and "food" as separate categories.
        --
        -- Bounded twice over: only for ids that have provably failed, and
        -- only across the categories the table already uses.
        -- Only while nothing real is waiting, and not for ever.
        --
        -- Each retry queues one speculative load per category, and the pump
        -- is a shared queue running eight blocking loads per beat. Firing
        -- them as soon as an item failed buried the icons the player was
        -- actually looking at under a backlog of guesses: a page that had
        -- drawn every icon a minute earlier came up almost entirely blank.
        -- Guesses wait for the queue to be empty, which is the definition of
        -- "nothing better to do", and stop after a bounded number.
        if not retried[key] and idle and retries_left > 0 then
            retries_left = retries_left - 1
            retried[key] = true
            local base = tostring(name):match("^[^_]+_(.+)$")
            if base then
                for _, cat in ipairs(CATEGORIES) do
                    local alt = cat .. "_" .. base
                    if alt ~= name then want(alt, true) end
                end
                alternates[key] = base
                waited[key] = 0
                return nil
            end
        elseif alternates[key] then
            -- Whichever of them landed is now this id's name.
            local base = alternates[key]
            local pending = false
            for _, cat in ipairs(CATEGORIES) do
                local alt = cat .. "_" .. base
                if queued[alt] or arrived[alt] == nil then pending = true end
                if arrived[alt] then
                    pending = true
                    local found = find(alt)
                    if found ~= nil then
                        resolved[key] = alt
                        learn(key, alt)
                        alternates[key] = nil
                        waited[key] = nil
                        return found
                    end
                end
            end
            if pending then return nil end
        elseif not retried[key] and not idle and retries_left > 0 then
            return nil
        end

        local observed = look_around(key)[key]
        if discovery_pending[key] then return nil end
        if observed then
            resolved[key], alternates[key], waited[key] = observed, nil, nil
            learn(key, observed)
            return find(observed)
        end
        alternates[key] = nil
        resolved[key] = false
        M.gave_up_n = M.gave_up_n + 1
        M.last_missing = item_id .. " (waited on " .. name .. ")"
    end
    return nil
end

-- Tried and rejected: resolving ahead of the draw.
--
-- A warm pass walked the picker's list a few ids per beat so the answers
-- would be known before anybody looked. It made things worse, measurably:
-- resolving an id means StaticFindObject, which is 13ms on this build, so
-- three per beat is 400ms of every second spent on the game thread - and it
-- never converged, because it walks each id ONCE. An id whose texture had not
-- finished loading was left unresolved and never revisited, so it queued the
-- load and threw the answer away. 2798 lookups, 37 seconds of game thread,
-- and 163 of 208 items still unresolved at the end of it.
--
-- Resolving on the draw is both cheaper and self-correcting: an icon that is
-- not ready yet leaves its token stale, so the next refresh asks again, and
-- the panel budgets how many may be asked per frame.

-- Tried and rejected: the game's own icon pointer.
--
-- PalStaticItemDataBase.IconTexture is a TSoftObjectPtr and
-- SetBrushFromSoftTexture takes one, which would have retired this whole file
-- - no path to build, no scraped category, no queue, right for every item
-- because it is what the game itself uses. It was built and measured.
--
-- On this build the call succeeds immediately and the texture streams in
-- later, so the brush is real and empty in between and the Image draws a
-- WHITE SQUARE. Reading the brush back to reject that does not help: the
-- resource reports valid while nothing is there, and the brush has already
-- been overwritten by the time the answer is known. A white square is worse
-- than an empty slot - this file already carries that lesson under "not a
-- missing icon, damage done by the code meant to cope with a missing icon".
--
-- Worth revisiting only with a way to ask whether the soft pointer has
-- actually resolved BEFORE writing the brush.

-- Has this id been written off?
--
-- The picker uses it as a filter, on evidence rather than a hunch. Every
-- iconless item checked against the wiki so far - Curry, Pal Growth Stone,
-- Iron Ore - is documented as unused: unobtainable, uncraftable, no drops, no
-- merchants. The game does not draw an icon for a thing that is not a thing,
-- so an id the loader has exhausted every route for is one a base cannot
-- produce, and offering it is the same error as offering a Pal drop.
--
-- Better than a list of names, which would need editing every patch.
-- Is one sweep cheaper than N lookups?
--
-- Measured 24 Aug with the picker open: StaticFindObject averages 9.12ms and
-- the picker pays it 17 times, which is 155ms and the whole of the lag.
-- LoadAsset, the thing that sounds expensive, is 1ms.
--
-- The alternative is to stop asking per icon. FindAllOf("Texture2D") walks the
-- object array ONCE and can answer for every tile in the same frame, and an
-- object obtained in the current call is safe to use in it - it is only
-- KEEPING one that is a use after free. So the question is purely arithmetic:
-- what does one sweep cost against 17 lookups at 9ms.
--
-- Reads only, and only calls this file already makes.
function M.bench()
    local t0 = os.clock()
    local all = FindAllOf("Texture2D") or {}
    local sweep = (os.clock() - t0) * 1000

    -- The sweep alone is not the comparison. look_around also reads a name off
    -- every texture, and that is where a walk like this usually spends itself.
    local t1 = os.clock()
    local named, icons_seen = 0, 0
    for _, tex in ipairs(all) do
        local full
        pcall(function() full = tex:GetFullName() end)
        if type(full) == "string" then
            named = named + 1
            if full:find("T_itemicon", 1, true) then icons_seen = icons_seen + 1 end
        end
    end
    local walk = (os.clock() - t1) * 1000

    -- The walk the sweep ACTUALLY pays. The GetFullName loop above is what
    -- look_around used to do and no longer does, so on its own it measures a
    -- call this mod stopped making - which matters when the number is being
    -- used to judge a UE4SS setting.
    local t3 = os.clock()
    local fnamed = 0
    for _, tex in ipairs(all) do
        local leaf
        pcall(function() leaf = tex:GetFName():ToString() end)
        if type(leaf) == "string" then fnamed = fnamed + 1 end
    end
    local fwalk = (os.clock() - t3) * 1000

    -- The other half of the comparison, which had never actually been run:
    -- the note in this file says StaticFindObject averages 9.4ms and gets
    -- asked once per tile, but "finds: 0" says it was never asked at all
    -- once the sweep took over, so that figure was inherited rather than
    -- measured. Timed here against a path known to be loaded.
    local probe_path, probe_got = nil, 0
    for key in pairs(resolved) do
        if type(resolved[key]) == "string" then
            probe_path = object_path(resolved[key])
            break
        end
    end
    local direct = -1
    if probe_path then
        local t2 = os.clock()
        for _ = 1, 20 do
            local o
            pcall(function() o = StaticFindObject(probe_path) end)
            if o ~= nil then probe_got = probe_got + 1 end
        end
        direct = (os.clock() - t2) * 1000 / 20
    end

    log.say("icon lookup bench:")
    log.say(string.format("  textures in memory:      %d", #all))
    log.say(string.format("  FindAllOf sweep:         %.1fms", sweep))
    log.say(string.format("  reading every name:      %.1fms  (%d named, %d item icons)",
        walk, named, icons_seen))
    log.say(string.format("  GetFName:ToString walk:  %.1fms  (%d named)",
        fwalk, fnamed))
    log.say(string.format("  one sweep, all in:       %.1fms", sweep + fwalk))
    log.say(string.format("  StaticFindObject so far: %d finds, %.2fms average, %.0fms total",
        M.finds or 0, (M.finds or 0) > 0 and (M.find_ms / M.finds) or 0,
        M.find_ms or 0))
    log.say(string.format("  StaticFindObject direct: %.2fms per call (%d/20 hit, %s)",
        direct, probe_got, tostring(probe_path)))
    log.say(string.format("  sweep misses:            %d, of which the lookup then found: %d",
        M.sweep_misses or 0, M.fallback_hits or 0))
    log.say(string.format("  sweeps run:              %d, %.0fms total",
        M.sweeps or 0, M.sweep_ms or 0))
    M.sweeps, M.sweep_ms = 0, 0

    return string.format("sweep %.0fms vs %d finds at %.1fms",
        sweep + walk, M.finds or 0,
        (M.finds or 0) > 0 and (M.find_ms / M.finds) or 0)
end

-- The icon name this id resolved to, if it has resolved. Exposed so the panel
-- can key its pins by the same thing the sweep is keyed by, which saves
-- keeping a reverse map that would only ever be built to be thrown away.
function M.name_for(item_id)
    if type(item_id) ~= "string" then return nil end
    local name = resolved[item_id:lower()]
    if name == false then return nil end
    return name
end

function M.gave_up(item_id)
    if type(item_id) ~= "string" then return false end
    return resolved[item_id:lower()] == false
end

-- Every id this has given up on, and every id it is still waiting for.
--
-- "some symbols are missing" is answerable from the inside: resolution either
-- found no name at all, or found one whose asset never arrived. Reading it
-- off thirteen screenshots is guesswork; this is the list.
function M.unresolved()
    local dead, waiting = {}, {}

    for key, name in pairs(resolved) do
        if name == false then
            dead[#dead + 1] = key
        elseif waited[key] and waited[key] > 0 then
            waiting[#waiting + 1] = key .. " (" .. tostring(name) .. ")"
        end
    end

    -- Ids mid-guess, which have no entry in `resolved` at all.
    --
    -- Reporting only what `resolved` knows about made this blind to exactly
    -- the state the newest retry path puts an id into: no name yet, guesses
    -- in flight. Those showed in neither list, so the one command written to
    -- answer "which symbols are missing" under-reported - and a reading of
    -- zero meant "nothing has been written off", not "everything has an
    -- icon". Two reviews caught the same gap independently.
    for key in pairs(alternates) do
        if resolved[key] == nil then
            waiting[#waiting + 1] = key .. " (guessing)"
        end
    end
    for key, n in pairs(idle_waits) do
        if resolved[key] == nil and not alternates[key] and n > 0 then
            waiting[#waiting + 1] = key .. " (queued behind others)"
        end
    end

    table.sort(dead)
    table.sort(waiting)
    return dead, waiting
end

-- A world switch invalidates nothing held here, since nothing is held, but
-- what is loaded changes and so does what is worth waiting for.
function M.reset()
    resolved, requested, waited = {}, {}, {}
    retried, alternates, idle_waits = {}, {}, {}
    arrived = {}
    attempted_at, discovery_pending = {}, {}
    pumping = false
    clock.cancel(PUMP_ENTRY)
    slice_at, slice_count, slice_seconds = -1, 0, 0
    retries_left = RETRY_BUDGET
    queue, queued, guessed = {}, {}, {}
    sighted, sighted_at = nil, 0
end

-- Put an item's icon straight onto an Image, the way the game does it.
--
-- The whole chain, every step read out of the running game rather than
-- guessed:
--
--   PalUtility::GetItemIDManager(world)         -> the manager
--   PalItemIDManager::GetStaticItemData(FName)  -> PalStaticItemDataBase
--   that object has SoftObjectProperty IconTexture
--   PalUtility::LoadIconToImage(world, path, image, callback)
--
-- The important part is that the path is read off the game's own data object
-- and handed straight back to the game's own loader. Nothing about the soft
-- reference is constructed here. Building that struct by hand from a header
-- is what crashed the game, and this never touches its shape at all.
--
-- Everything else in this file, the eight hundred entry table scraped out of
-- the pak, the queue, the rationing, the patience counter, exists because I
-- never asked whether the game would simply do this.
local said_once = false


-- Does the game hand out item icons itself?
--
-- Creative Menu's pak, extracted and read, never touches a texture path. It
-- goes through the game's own item data, and the running game names the
-- chain:
--
--   PalUtility::GetItemIDManager(world)           -> the manager
--   PalItemIDManager::GetStaticItemData(FName)    -> the item's data object
--   PalUtility::LoadIconToImage(world, path, image, callback)
--
-- If that data object carries the icon, then everything else in this file is
-- unnecessary: the eight hundred entry table scraped out of the pak, the load
-- queue, the rationing, the patience counter, and the four separate ways a
-- tile could come up blank.
--
-- This only looks. Names and types, never values, because reading a value off
-- a type that has not been confirmed is how every previous attempt at this
-- went wrong.
function M.data_probe()
    log.say("item data probe")

    local util = api.cdo("/Script/Pal.Default__PalUtility")
    local world = api.player_controller()

    if not util or not api.valid(world) then
        log.say("  no PalUtility or no world yet")
        return
    end

    local manager
    pcall(function() manager = util:GetItemIDManager(world) end)
    if not api.valid(manager) then
        log.say("  GetItemIDManager gave nothing")
        return
    end

    local data
    pcall(function() data = manager:GetStaticItemData(FName("Stone")) end)
    if not api.valid(data) then
        log.say("  GetStaticItemData for Stone gave nothing")
        return
    end

    local class
    pcall(function() class = data:GetClass():GetFName():ToString() end)
    log.say("  Stone data is a " .. tostring(class))

    -- What IconTexture actually is, in Lua's hands.
    --
    -- LoadIconToImage will not take three arguments, so the delegate is
    -- required, and guessing a delegate's shape is the same mistake that
    -- crashed the game on soft textures. But the path itself is right here on
    -- the data object, and a path is a string. If it can be read out, it
    -- replaces the 858 entry table of guesses with the game's own answer and
    -- feeds the loading route that already works.
    local icon
    pcall(function() icon = data.IconTexture end)

    log.say("  IconTexture is a " .. type(icon))

    if icon ~= nil then
        -- Safe questions first, so that if the last one takes the game down
        -- their answers are already in the log.
        --
        -- A TSoftObjectPtr userdata is the exact type LoadIconToImage wants,
        -- and it came from the game rather than being built here, so the one
        -- thing that crashed before cannot happen. What is left is the
        -- delegate, and whether this wrapper can be resolved without one.
        for _, how in ipairs({
            "Get", "LoadSynchronous", "IsValid", "IsNull",
            "ToSoftObjectPath", "GetAssetName", "GetLongPackageName",
            "ToString",
        }) do
            local value
            local ok = pcall(function() value = icon[how](icon) end)

            if ok and value ~= nil then
                local shown = tostring(value)
                pcall(function()
                    if type(value) ~= "string" then shown = value:ToString() end
                end)
                log.say(string.format("    %-18s -> %s", how, tostring(shown)))
            end
        end

        -- Directly, in case it is handed over as a plain table of fields.
        for _, field in ipairs({ "AssetPathName", "SubPathString", "AssetPath" }) do
            local value
            pcall(function() value = icon[field] end)
            if value ~= nil then
                local text = value
                pcall(function() text = value:ToString() end)
                log.say(string.format("    .%s = %s", field, tostring(text)))
            end
        end

        -- And plain tostring, which sometimes says more than any of them.
        log.say("    tostring -> " .. tostring(icon))

        -- Last, because it is the one that might not come back. A Lua
        -- function passed where a delegate is expected is the natural
        -- mapping, and it either works or it errors. This is not the same as
        -- inventing a struct's layout: nothing here is being constructed
        -- except a function, which Lua knows how to make.
        local image = api.cdo("/Script/UMG.Image")
        if image then
            local made
            pcall(function() made = StaticConstructObject(image, world) end)

            if made ~= nil then
                local ok = pcall(function()
                    util:LoadIconToImage(world, icon, made, function() end)
                end)
                log.say("    LoadIconToImage with a Lua function: " ..
                    (ok and "accepted" or "refused"))
            end
        end
    end

    local shown = 0
    pcall(function()
        data:GetClass():ForEachProperty(function(prop)
            if shown >= 24 then return end

            local pn, pc = "?", "?"
            pcall(function() pn = prop:GetFName():ToString() end)
            pcall(function() pc = prop:GetClass():GetFName():ToString() end)

            local low = pn:lower()
            if pc:find("Soft", 1, true) or low:find("icon")
                or low:find("texture") or low:find("image") then
                shown = shown + 1
                log.say("    " .. pc .. " " .. pn)
            end
        end)
    end)

    if shown == 0 then
        log.say("    nothing soft and nothing named like a picture")
    end
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
