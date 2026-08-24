-- The mod's one heartbeat, on the game thread.
--
-- Everything periodic in this mod used to ride LoopAsync, whose callback runs
-- on a background thread. UE4SS's own maintainers deprecated it in PR #1128
-- with the sentence that explains three days of crashes: "Lua is intended to
-- be single threaded. LoopAsync was never safe even for purely Lua
-- operations, let alone game thread." Scheduling from that thread while the
-- game thread ran hook callbacks tore the Lua registry, which surfaced as
-- either "Ref was not function, removing hook" or an access violation with a
-- pointer that decoded to the ASCII of one of our own log strings.
--
-- So: ONE self-re-arming chain, driven by the delayed-action API that PR
-- #1128 added (present in the exact UE4SS.dll this install runs, verified by
-- a binary scan). The callback runs on the game thread and re-arms itself at
-- the end, which means registry writes happen on the game thread and there is
-- exactly one registration in flight, ever. That is BreedingHelper's
-- single-flight rule taken to its limit: their comments call refs "the
-- registry-corruption vector" and their 100 ms ticker survives where ours
-- died.
--
-- Builds without the API fall back to InfiniteWeightInCamp's shape, an
-- ExecuteWithDelay chain re-armed from inside ExecuteInGameThread, which its
-- author ships under the comment "Crash-safe: no LoopAsync".
--
-- Everything that wants running registers here. Nothing else in the mod may
-- call LoopAsync, ExecuteAsync, or schedule its own timers.

local log = require("log")

local M = {}

local BEAT_MS = 100

-- name -> { every = ms, owed = ms, fn = f }. Insertion order is not
-- guaranteed by pairs and nothing here needs it.
local entries = {}

-- One-shots ride the same chain: they are entries that remove themselves.
local once_n = 0

-- A world switch must kill the old chain rather than let it touch fresh
-- state: the body checks its generation and dies quietly when stale, and
-- reset() arms a new chain.
local gen = 0
local armed = false

-- Which arming primitive this build offers, decided once at load and logged,
-- so a session's transcript says which path it ran.
local has_delayed = type(ExecuteInGameThreadWithDelay) == "function"

-- Better again: ONE persistent loop, registered once for the session.
--
-- The chain below re-arms itself every beat, and each re-arm is an
-- ExecuteInGameThreadWithDelay - which ShinyPals' pump.lua dissects at the
-- UE4SS source level: every call allocates a coroutine and takes two Lua
-- registry slots off a shared, unlocked free list (upstream issue #1180).
-- One in flight at a time was this file's discipline, and it held; but ten
-- registry churns a second, all session, is still ten chances a second at
-- the exact race that produced "Ref was not function, removing hook".
--
-- LoopInGameThreadWithDelay registers ONCE and fires forever on the game
-- thread: one reference, zero churn. PerfectPlacement's runtime.lua is built
-- on it. Verified present in this exact UE4SS.dll by binary scan, the same
-- way has_delayed was.
local has_loop = type(LoopInGameThreadWithDelay) == "function"

-- Read by "pwp status": seconds since the chain last beat. A chain that
-- stops beating is exactly the silent failure UE4SS produces when it drops
-- its engine-tick hook, and the number makes it visible from outside.
M.last_beat = 0

local body   -- forward declaration, arm() references it

local looping = false

local function arm(mygen)
    if has_loop then
        -- One registration for the whole session. The loop outlives world
        -- switches - it is a timer, not a world object - so gen is checked
        -- inside the body and reset() has nothing to kill or re-arm. arm()
        -- being called again (start after reset) must not stack a second
        -- loop, hence the latch.
        if looping then return end
        looping = true
        LoopInGameThreadWithDelay(BEAT_MS, function()
            -- body() re-arms the CHAIN paths; under the loop that call is
            -- absorbed by the latch above, so the loop stays the only driver.
            body(gen)
        end)
        return
    end

    if has_delayed then
        -- Game-thread timer from PR #1128: no background thread anywhere.
        ExecuteInGameThreadWithDelay(BEAT_MS, function() body(mygen) end)
    else
        -- Fallback: the timer thread's only job is to bounce into the game
        -- thread; the re-arm (the registry write that matters) happens back
        -- here, inside the game-thread body.
        ExecuteWithDelay(BEAT_MS, function()
            ExecuteInGameThread(function() body(mygen) end)
        end)
    end
end

-- Reused across beats so a healthy chain allocates nothing per tick.
local due = {}

-- The work of one beat, split out so body() can run it under pcall and still
-- re-arm afterwards no matter what it does.
-- palapi is not required at the top of this file on purpose: clock.lua is the
-- one module with no dependencies beyond log, and it stays that way. Resolved
-- lazily, once, and only to open and close the controller memo around a beat.
local palapi = nil

local function beat()
    -- Two passes, and the split is not tidiness. An entry's fn may call
    -- M.once or M.every - icons.lua re-arms its own pump from inside its
    -- pump, and every command handler that starts a timer runs from the ui
    -- entry - and both of those ASSIGN A NEW KEY to `entries`. The Lua manual
    -- makes adding a field during a pairs traversal undefined behaviour;
    -- removing one is fine. When it bites, `next` raises "invalid key to
    -- 'next'" from the loop itself, which is OUTSIDE the pcall below and so
    -- escapes before arm() runs. The chain never re-arms and the whole mod
    -- goes silent with nothing in the log - indistinguishable from UE4SS
    -- dropping its engine tick, which is the exact failure this file exists
    -- to prevent.
    --
    -- So: decide what is due while only reading, then call while only the
    -- second loop is live. New keys added by a callback land in `entries` and
    -- are picked up next beat, which is what one-shots want anyway.
    local n = 0
    for name, e in pairs(entries) do
        e.owed = e.owed + BEAT_MS
        if e.owed >= e.every then
            e.owed = 0
            n = n + 1
            due[n] = name
        end
    end

    for i = 1, n do
        local name = due[i]
        due[i] = nil
        local e = entries[name]
        -- A callback earlier in this batch may have cancelled a later one.
        if e then
            local ok, err = pcall(e.fn)
            if not ok then
                log.warn("clock entry '" .. name .. "' threw: " .. tostring(err))
            end
            if e.once then entries[name] = nil end
        end
    end
end

body = function(mygen)
    -- Under the persistent loop mygen is always the CURRENT gen (read at
    -- fire time), so this line only ever retires stale CHAIN links. The
    -- loop itself survives world switches by design.
    if mygen ~= gen then return end

    M.last_beat = os.clock()

    -- beat() is already careful, and it still runs under pcall: the one thing
    -- this chain must never do is stop. An error raised anywhere in the
    -- scheduling logic - not in a callback, which has its own pcall, but in
    -- the loop around them - would otherwise escape before the re-arm below
    -- and silently end the mod. So the failure is logged and the heartbeat
    -- continues. (This catches Lua errors only; an access violation is not
    -- catchable and never was.)
    -- One controller lookup for the whole beat, not one per caller.
    --
    -- Opened and closed around the work rather than left on, so nothing holds
    -- an engine object between beats. The close runs whatever the beat did,
    -- which is why it is not inside the pcall with it.
    if palapi == nil then
        pcall(function() palapi = require("palapi") end)
    end
    if palapi and palapi.pc_memo_begin then pcall(palapi.pc_memo_begin) end

    local ok, err = pcall(beat)

    if palapi and palapi.pc_memo_end then pcall(palapi.pc_memo_end) end

    if not ok then
        log.warn("clock beat threw: " .. tostring(err))
    end

    -- Unconditional, and deliberately last: whatever went wrong above, the
    -- heartbeat survives it. A chain that stops re-arming takes the mod with
    -- it.
    arm(mygen)
end

-- Register or replace a repeating entry. fn runs on the game thread.
function M.every(name, ms, fn)
    entries[name] = { every = ms, owed = 0, fn = fn }
end

function M.cancel(name)
    entries[name] = nil
end

-- Run once, ms from now, on the game thread. Replaces every one-shot
-- ExecuteWithDelay in the mod, and with ms = 0 it is "defer to the next
-- beat", which replaces bare ExecuteInGameThread calls made from code that
-- is already on the game thread.
function M.once(ms, fn)
    once_n = once_n + 1
    entries["once#" .. once_n] = { every = ms, owed = 0, fn = fn, once = true }
end

function M.start()
    if armed then return end
    armed = true
    log.say("clock: " .. (has_loop
        and "persistent game-thread loop (one registration, no churn)"
        or has_delayed
        and "delayed-action chain (game-thread timers)"
        or "fallback chain (ExecuteWithDelay -> ExecuteInGameThread)"))
    arm(gen)
end

-- On world switch: retire the running chain and arm a fresh one. Entries
-- survive; their functions must cope with a fresh world, which they already
-- had to under the old loops.
function M.reset()
    gen = gen + 1
    -- The chain needs a fresh link armed under the new gen; the loop just
    -- keeps firing and reads the new gen at its next beat.
    if armed and not looping then arm(gen) end
end

return M
