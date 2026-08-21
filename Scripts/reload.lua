-- Swap the panel's code without restarting the game.
--
-- UE4SS has a hot reload key and it is not usable here. It tears down every
-- Lua mod installed rather than the one being worked on, and it crashed the
-- game both times it was tried, including with the mod list cut to three.
--
-- This is much smaller and therefore much safer. Only the two modules that
-- draw the UI are replaced. The scheduler, the hooks, the network transport
-- and the rules all keep running untouched, which matters: a registered hook
-- cannot be unregistered, so anything holding one must never be reloaded.
--
-- The trigger is a file rather than a keybind, and that is the point of the
-- whole thing. While the panel holds the input mode UE4SS never sees a key
-- press, which is exactly when the panel is the thing being worked on. A file
-- can be touched from outside the game at any moment.
--
--     python tools/reload.py        or any write to reload.trigger
--
-- What survives a swap: every icon already resolved, the rules, the pals'
-- assignments, and the world. What does not: the panel's widgets, which are
-- torn down first on purpose, because the code that made them is about to go
-- away and widgets outliving their code is how this mod got its duplicate
-- panel and two of its crashes.

local log = require("log")

local M = {}

-- Set by main.lua, next to priority.log.
M.path = nil

-- Only these. Adding a module that registers a hook or holds a timer would
-- turn a reload into a duplicate of both.
local SWAPPED = { "panel", "overlay" }

local EVERY = 1.0          -- seconds between looks at the file
local last = nil
local checked_at = 0

-- Every module ever swapped out, kept for ever on purpose.
--
-- UE4SS holds Lua registry references to callbacks it has been given. When a
-- swapped module became garbage, those references stopped being functions,
-- and UE4SS's answer to that is not to skip the callback: it removes the hook
-- driving the engine tick. The mod then goes silent and nothing short of a
-- restart brings it back, which cost two sessions before the log line naming
-- it turned up.
--
-- Holding the old table keeps its functions alive, and their upvalues with
-- them. It leaks a few tables per reload, which against a game using several
-- gigabytes is not worth a moment's thought.
local kept = {}

local function contents()
    if not M.path then return nil end

    local text
    pcall(function()
        local f = io.open(M.path, "r")
        if f then
            text = f:read("*a")
            f:close()
        end
    end)
    return text
end

function M.now()
    local panel = package.loaded["panel"]
    local overlay = package.loaded["overlay"]

    -- Down before out. A widget whose module has been replaced is a widget
    -- nothing can reach to close, and it stays on screen for the rest of the
    -- session.
    pcall(function() if panel and panel.open then panel.toggle() end end)
    pcall(function() if panel and panel.reset then panel.reset() end end)
    pcall(function() if overlay and overlay.teardown then overlay.teardown() end end)

    for _, name in ipairs(SWAPPED) do
        local old = package.loaded[name]
        if old ~= nil then kept[#kept + 1] = old end
        package.loaded[name] = nil
    end

    local broken = {}
    for _, name in ipairs(SWAPPED) do
        local ok, err = pcall(require, name)
        if not ok then
            broken[#broken + 1] = name .. ": " .. tostring(err)
        end
    end

    if #broken == 0 then
        -- The fresh overlay has never asked for the blueprint class, and the
        -- thing that used to ask fires once at world load and has long since
        -- gone. Without this every reload silently drops the panel back onto
        -- the hand built canvas, which looks like the blueprint having broken.
        local fresh = package.loaded["overlay"]
        if fresh and fresh.prepare then
            pcall(function() fresh.prepare() end)
        end

        log.say("reloaded " .. table.concat(SWAPPED, " and ") ..
            ", press the panel key to see it")
        return true
    end

    -- Said loudly, because a module that failed to load leaves the mod
    -- half swapped and the next thing to happen will be confusing.
    for _, why in ipairs(broken) do
        log.warn("reload failed, " .. why)
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
--
-- The trigger file carries more than "something changed". Its first line is a
-- nonce so that writing the same command twice still counts as a change, and
-- every line after it is an instruction.
--
--     reload            swap panel and overlay
--     open / close      the panel, without a keybind
--     cmd <console>     run a console command
--
-- open and close are here for the same reason the trigger is a file at all:
-- while the panel holds the input mode UE4SS never sees a key, so the panel
-- cannot be opened by the person who most needs to open it. This can.
--
-- cmd is what makes the game able to photograph itself. "cmd shot showui"
-- writes a png next to the save data, which is a far better way to find out
-- what the panel looks like than asking someone to alt tab and screenshot it.

local api = require("palapi")

local function console(command)
    local lib = api.cdo("/Script/Engine.Default__KismetSystemLibrary")
    local pc = api.player_controller()

    if not lib or not api.valid(pc) then
        log.warn("cmd: no player controller, so no console")
        return
    end

    ExecuteInGameThread(function()
        pcall(function() lib:ExecuteConsoleCommand(pc, command, pc) end)
        log.say("cmd: " .. command)
    end)
end

local function run(line)
    line = line:match("^%s*(.-)%s*$")
    if line == "" then return end

    if line == "reload" then
        M.now()
        return
    end

    if line == "open" or line == "close" then
        local panel = package.loaded["panel"]
        if not panel then return end

        local wanted = (line == "open")
        if panel.open ~= wanted then
            pcall(function() panel.toggle() end)
        end
        log.say("panel is now " .. (panel.open and "open" or "closed"))
        return
    end

    local command = line:match("^cmd%s+(.+)$")
    if command then
        console(command)
        return
    end

    log.warn("trigger: do not understand " .. line)
end

-- Called from the tick. Cheap: one small file read a second.
function M.poll()
    local now = os.clock()
    if (now - checked_at) < EVERY then return end
    checked_at = now

    local text = contents()
    if text == nil then return end

    -- The first look only records. Otherwise every launch would act on
    -- whatever the file happened to hold from last time.
    if last == nil then
        last = text
        return
    end

    if text == last then return end
    last = text

    -- The first line is the nonce and is not an instruction.
    local first = true
    for line in text:gmatch("%C+") do
        if first then
            first = false
        else
            pcall(function() run(line) end)
        end
    end
end

return M
