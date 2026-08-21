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

-- Read by "pwp status": seconds since the chain last beat. A chain that
-- stops beating is exactly the silent failure UE4SS produces when it drops
-- its engine-tick hook, and the number makes it visible from outside.
M.last_beat = 0

local body   -- forward declaration, arm() references it

local function arm(mygen)
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

body = function(mygen)
    if mygen ~= gen then return end   -- a world switch retired this chain

    M.last_beat = os.clock()

    for name, e in pairs(entries) do
        e.owed = e.owed + BEAT_MS
        if e.owed >= e.every then
            e.owed = 0
            local ok, err = pcall(e.fn)
            if not ok then
                log.warn("clock entry '" .. name .. "' threw: " .. tostring(err))
            end
            if e.once then entries[name] = nil end
        end
    end

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
    log.say("clock: " .. (has_delayed
        and "delayed-action API (game-thread timers)"
        or "fallback chain (ExecuteWithDelay -> ExecuteInGameThread)"))
    arm(gen)
end

-- On world switch: retire the running chain and arm a fresh one. Entries
-- survive; their functions must cope with a fresh world, which they already
-- had to under the old loops.
function M.reset()
    gen = gen + 1
    if armed then arm(gen) end
end

return M
