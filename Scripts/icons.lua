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
-- The same for StaticFindObject, which every drawn icon goes through.
-- Bumped whenever an id is written off, so a caller memoising a list built
-- from this can tell that the answer has changed.
M.gave_up_n = 0

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
-- Twelve, and the number comes from a measurement rather than a fear.
--
-- This was cut to three on the theory that LoadAsset was stalling the frame.
-- It is not: timed over five hundred loads it averages 0.3ms and has never
-- exceeded 2ms. The expensive call is StaticFindObject at 13ms, which is what
-- resolving an icon costs, and that is rationed by the panel instead.
--
-- Getting textures into memory quickly is what makes those lookups SUCCEED,
-- so starving the loader just meant the panel looked up the same icons over
-- and over and found nothing. Twelve loads is under 4ms a beat.
local PUMP_BATCH = 12

-- icon name -> whether its load actually produced an object. Written by the
-- pump, which is the only code that finds out.
local arrived = {}

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

-- One load, then wait, then the next.
local function pump_one()
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
        local path = object_path(name)
        -- The pump rides the clock, so this already runs on the game thread
        -- and the load happens in place, with no registration.
        --
        -- Timed, because this is the one call in the mod that can block the
        -- game thread for an unbounded stretch and nothing has ever measured
        -- it. Every guess at the picker's remaining lag has been an inference
        -- from a number that turned out to measure something else.
        local t0 = os.clock()
        pcall(function() LoadAsset(path) end)
        local took = (os.clock() - t0) * 1000

        M.load_ms = (M.load_ms or 0) + took
        M.loads = (M.loads or 0) + 1
        if took > M.worst_load then
            M.worst_load = took
            log.say(string.format("icon load %s took %.0fms (worst so far)",
                name, took))
        end

        -- Said out loud, because "the icon did not appear" has covered a
        -- failed lookup, a load that went nowhere, a texture that would
        -- not go on a brush and a brush with no size, and telling them
        -- apart from a screenshot has not been possible once.
        local landed
        pcall(function() landed = StaticFindObject(path) end)
        -- Debug, not say. log.say always writes to file, and to_file does an
        -- open/write/close per line - so filling one page of the picker was
        -- eight file opens per beat alongside eight blocking loads, on the
        -- game thread. Issue #1372's reporter mitigated this very crash class
        -- by taking file I/O out of hot callbacks. A load that fails is worth
        -- shouting about; a load that works is not.
        -- Recorded, not just logged.
        --
        -- This is the one place that knows whether a name resolves, and it
        -- was throwing the answer away - so the retry scan below re-asked the
        -- engine about all two dozen candidates, at roughly 10ms per
        -- StaticFindObject, once a second for every unresolved item on the
        -- page. That is the ADD tab's remaining lag, and it is a table lookup.
        arrived[name] = real(landed)

        -- A guess that misses is expected and silent. Only a name the index
        -- promised is worth shouting about.
        --
        -- log.say writes to file per line, and one unknown id queues two
        -- dozen guesses - so a single sweep of the picker wrote ninety six
        -- file opens on the game thread announcing that made-up paths do not
        -- exist. Issue #1372's reporter mitigated this very crash class by
        -- taking file I/O out of hot callbacks.
        if arrived[name] or guessed[name] then
            log.debug(string.format("icon load %-28s %s", name,
                arrived[name] and "arrived" or "did not arrive"))
        else
            log.say(string.format("icon load %-28s did not arrive", name))
        end
        guessed[name] = nil
    end

end

-- The pump rides a NAMED clock entry rather than a chain of one-shots.
--
-- A one-shot chain cannot be cancelled, and this module hot-reloads: the old
-- pump kept firing after the swap, draining the OLD queue at eight blocking
-- LoadAsset calls per beat and writing a log line each, on behalf of a module
-- that had already been thrown away. reload.lua's own rule says a module
-- holding a timer must not be swapped, and this was the module breaking it.
-- A name is something M.shutdown can cancel.
local PUMP_ENTRY = "icons_pump"

local function pump()
    for _ = 1, PUMP_BATCH do
        pump_one()
    end

    if #queue == 0 then
        pumping = false
        clock.cancel(PUMP_ENTRY)
    end
end

-- Called by the reloader before this module is replaced, so the outgoing copy
-- takes its queue and its timer with it.
function M.shutdown()
    queue, queued = {}, {}
    pumping = false
    clock.cancel(PUMP_ENTRY)
end

local function want(name, speculative)
    if requested[name] or queued[name] then return end

    if speculative then guessed[name] = true end
    queued[name] = true
    queue[#queue + 1] = name

    if not pumping then
        pumping = true
        clock.every(PUMP_ENTRY, PUMP_MS, pump)
    end
end

-- The object for an icon name, if it is in memory. Never stored.
--
-- Every loaded icon, found in ONE pass, for the length of one draw.
--
-- The picker's remaining lag was never loading. Measured 24 August with the
-- picker open: LoadAsset averages 1ms, and StaticFindObject averages 9.4ms and
-- gets asked once per tile - 17 finds, 160ms, which is the whole of it. A full
-- sweep of all 7072 textures in memory costs 26ms and answers for every tile
-- at once, so the break even is three icons and the picker draws eighteen.
--
-- This is the one place the module holds textures rather than names, and it is
-- allowed for exactly one reason: the map is built inside a draw and dropped
-- when that draw returns, so nothing here is ever read on a later frame. The
-- lifetime is enforced at both ends - draw_item_picker clears it going in, and
-- refresh clears it coming out - because a texture kept across a frame is the
-- use after free this file's every other rule exists to avoid.
local frame_tex = nil

-- When the last sweep ran, and how many loads had completed by then.
--
-- The sweep is per FRAME for object safety, and that was read as "once per
-- draw". It is once per draw that needs it, and a draw needs it whenever any
-- icon is still unresolved - so a page with a handful of items the index has
-- no name for swept 7,171 textures ten times a second, for as long as the
-- picker stayed open. Measured: twelve sweeps and 958ms across one page turn,
-- ~80ms each, which is the whole of the picker's lag. The page turn was never
-- special; it is just when anyone looks.
--
-- A second sweep can only find something the first did not if a load has
-- landed in between, so that is the gate. The interval is a safety net for
-- textures the game itself brings in without the pump noticing.
local swept_at = -1
local swept_loads = -1
local SWEEP_MIN_GAP = 0.5

local function sweep_frame()
    M.sweeps = (M.sweeps or 0) + 1
    local _t = os.clock()
    local out = {}

    for _, tex in ipairs(FindAllOf("Texture2D") or {}) do
        -- GetFName():ToString(), not GetFullName().
        --
        -- The leaf is all this needs, and GetFullName builds the whole
        -- "Class Package.Object" path to produce it - seven thousand times a
        -- sweep, which is the sweep. GetName() returns nothing on this build,
        -- which is why the original reached for GetFullName; the FName route
        -- is what PerfectPlacement walks widget trees with.
        local leaf
        pcall(function() leaf = tex:GetFName():ToString() end)

        if type(leaf) == "string" and leaf:sub(1, #PREFIX) == PREFIX then
            local rest = leaf:sub(#PREFIX + 1)
            if out[rest] == nil then out[rest] = tex end
        end
    end

    M.sweep_ms = (M.sweep_ms or 0) + (os.clock() - _t) * 1000
    return out
end

-- Only ever a lookup. Wanting something loaded is a separate matter, handled
-- above at its own pace, and a later frame is what finds it.
local function find(name)
    -- The sweep first, and only when one could tell us something new.
    if frame_tex == nil then
        local now = os.clock()
        -- Time only. Gating on "has a load landed since" looked precise and
        -- was useless: the pump lands twelve a beat, so the counter always
        -- differed and the sweep ran every frame anyway - 53 sweeps and 4.2
        -- seconds across four page turns, worse than before.
        if (now - swept_at) >= SWEEP_MIN_GAP then
            frame_tex = sweep_frame()
            swept_at, swept_loads = now, M.loads

            -- Hand the whole find to whoever registered for it, inside the
            -- frame that found it. The sweep resolves every loaded icon at
            -- once and the panel then throws all but the eighteen it is
            -- drawing away - so the next page sweeps again. Letting the panel
            -- pin what it did not ask for is what makes sweeps stop.
            if M.on_sweep then pcall(function() M.on_sweep(frame_tex) end) end
        else
            -- Everything misses this frame, which costs the tile its picture
            -- for a tenth of a second and costs the frame nothing at all.
            frame_tex = {}
        end
    end

    local hit = frame_tex[name]
    if hit ~= nil and real(hit) then return hit end

    -- A miss is a no, and taken as one. No lookup.
    --
    -- There WAS a StaticFindObject here, kept as a safety net on the grounds
    -- that the sweep "should" be authoritative but that a blank picker is not
    -- a thing to be casually right about. Then it was counted, over eight pages
    -- of a catalogue whose icons are mostly not resident:
    --
    --     sweep misses: 91, of which the lookup then found: 0
    --
    -- Ninety one lookups, 1097ms, and not one icon rescued. It could not be
    -- otherwise: FindAllOf and StaticFindObject read the same object array, so
    -- if the sweep did not see it, it is not loaded, and no amount of asking a
    -- second way will make it so. Loading it is what is needed, and want()
    -- below is what does that, at 0.3ms.
    --
    -- This is the whole of the browse case. Storage, whose icons are already
    -- resident, went 17 lookups to none as soon as the sweep landed; browsing
    -- everything stayed slow purely because every miss still paid 12ms to be
    -- told what the sweep had already established.
    M.sweep_misses = (M.sweep_misses or 0) + 1

    -- It was here once and it is not here now, so ask for it again.
    --
    -- Historically nothing held a reference to one of these textures except
    -- the Image currently drawing it: point that Image at a different item -
    -- change page, switch to the storage view, anything - and the old texture
    -- was unreferenced, the engine free to collect it, and the revisit found
    -- nothing. The panel now pins every icon it has shown (see pin() in
    -- panel.lua), so a revisit normally hits the sweep and never reaches
    -- here. This path remains for what pinning does not cover: the pin cap,
    -- and a world whose tree was rebuilt out from under the pins.
    --
    -- `requested` then made that permanent: it records that a load was asked
    -- for, want() returns early on it, and so the reload was never issued.
    -- Icons that had been drawing all session went blank after browsing away
    -- and back, and could not recover. Clearing the flag lets the pump fetch
    -- it again, which costs 0.3ms.
    --
    -- This is the same reason the module keeps names instead of textures: a
    -- texture is not ours and does not stay put. The flag has to follow the
    -- same rule as the thing it describes.
    if requested[name] then
        requested[name] = nil
        arrived[name] = nil
        queued[name] = nil
    end
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

-- Drops the frame's texture map.
--
-- Called on the way into a draw and again on the way out, so the textures the
-- sweep handed round are unreferenced the moment the draw that found them
-- ends. They are safe to use inside that draw and a use after free after it.
function M.new_frame()
    frame_tex = nil
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

-- Whether an item's icon is on screen-ready, without paying to fetch it.
--
-- get() ends in StaticFindObject, which walks the object array and cost about
-- ten milliseconds a call on this build. A tile asked it every frame purely to
-- decide between a picture and a name, so eleven tiles spent over a hundred
-- milliseconds per refresh, on a refresh that runs ten times a second. That is
-- the whole of "the ADD tab is super laggy": not loading, not drawing, one
-- lookup in a loop.
--
-- The answer is a boolean and booleans are safe to keep, unlike the texture it
-- came from. Once true it stays true: an icon that has loaded does not unload
-- while the panel is open, and a world change clears this with everything else.
local ready_ids = {}

-- Icons whose lookup came back empty, and the beat it was asked on.
--
-- Only the positive answer was remembered. A "no" fell through to M.get ->
-- find -> StaticFindObject, measured at about 10ms, once per tile per frame -
-- and an item that is named but not yet loaded answers no for as long as it
-- takes to load. Eighteen rows at ten frames a second is the whole budget
-- spent asking a question that cannot change within a second.
local not_ready = {}
local NOT_READY_S = 1.0

function M.ready(item_id)
    if type(item_id) ~= "string" or item_id == "" then return false end
    if ready_ids[item_id] then return true end

    -- A "no" is only ever "not yet", so it expires rather than sticking.
    local asked = not_ready[item_id]
    local now = os.clock()
    if asked and (now - asked) < NOT_READY_S then return false end

    if M.get(item_id) ~= nil then
        ready_ids[item_id] = true
        not_ready[item_id] = nil
        return true
    end

    not_ready[item_id] = now
    return false
end

function M.get(item_id)
    if type(item_id) ~= "string" or item_id == "" then return nil end

    local key = item_id:lower()

    local name = resolved[key]
    if name == false then return nil end

    if name == nil then
        name = icondex.NAMES[key] or look_around()[key] or self_named(key)
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
                        local found = find(alt)
                        if found ~= nil then
                            resolved[key] = alt
                            alternates[key] = nil
                            waited[key] = nil
                            return found
                        end
                    end
                end

                if not all_tried then return nil end
                alternates[key] = nil
            end

            resolved[key] = false
            M.gave_up_n = M.gave_up_n + 1
            return nil
        end
        resolved[key] = name
    end

    local texture = find(name)
    if texture ~= nil then
        -- Cleared on success, or M.unresolved reports every icon that was
        -- ever slow as though it were still pending.
        waited[key] = nil
        return texture
    end

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
        if not retried[key] and #queue == 0 and retries_left > 0 then
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
            for _, cat in ipairs(CATEGORIES) do
                local alt = cat .. "_" .. base
                if arrived[alt] then
                    local found = find(alt)
                    if found ~= nil then
                        resolved[key] = alt
                        alternates[key] = nil
                        waited[key] = nil
                        return found
                    end
                end
            end
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

    log.say("icon lookup bench:")
    log.say(string.format("  textures in memory:      %d", #all))
    log.say(string.format("  FindAllOf sweep:         %.1fms", sweep))
    log.say(string.format("  reading every name:      %.1fms  (%d named, %d item icons)",
        walk, named, icons_seen))
    log.say(string.format("  one sweep, all in:       %.1fms", sweep + walk))
    log.say(string.format("  StaticFindObject so far: %d finds, %.2fms average, %.0fms total",
        M.finds or 0, (M.finds or 0) > 0 and (M.find_ms / M.finds) or 0,
        M.find_ms or 0))
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
    ready_ids = {}
    not_ready = {}
    resolved, requested, waited = {}, {}, {}
    retried, alternates, idle_waits = {}, {}, {}
    arrived = {}
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
