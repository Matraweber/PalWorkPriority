-- Drive the panel from outside the game.
--
-- A file next to the log is read once a second, and each line after the first
-- is an instruction:
--
--     open / close      the panel
--     mode item / list  which screen it shows
--     cmd <console>     run a console command
--     pwp <words>       any of the mod's own commands, as typed in chat
--     reload            swap the panel's code, no restart
--
-- The first line is a nonce, so writing the same instruction twice still
-- counts as a change.
--
-- Why a file rather than a keybind: while the panel holds the input mode
-- UE4SS never sees a key press, which is exactly when the panel is the thing
-- being worked on. A file can be written at any moment from outside.
--
-- Why cmd earns its place: "cmd shot showui" makes the game photograph
-- itself, and a png on disk can be read directly. The alternative is asking
-- somebody to alt tab and screenshot, and alt tabbing is what stops the game
-- ticking in the first place.
--
-- What this deliberately does not do is reload code. An earlier version
-- swapped modules in package.loaded and that is not in here: it was never
-- proved safe, it was blamed twice for faults it did not cause, and the value
-- it added was small next to the confusion it created. This file only ever
-- calls functions that were already running.

local log = require("log")
local api = require("palapi")
local panel = require("panel")
local reload = require("reload")

local M = {}

-- Set by main.lua, next to priority.log.
M.path = nil

-- Set by main.lua once its commands exist. A function rather than a require,
-- because main already requires this file and requiring it back would be a
-- loop.
--
-- Singleplayer has no chat box, so every command the mod documents was
-- reachable only on a server. That is most of its controls, off and status
-- and run and scope among them, unreachable in the mode it is developed in.
M.command = nil

local EVERY = 1.0          -- seconds between looks at the file
local last = nil
local checked_at = 0

-- Queued rather than scheduled.
--
-- Handing UE4SS an anonymous function means it keeps a Lua registry
-- reference to it, and references to short lived closures have gone bad on
-- this build in a way that removes the hook driving the engine tick. The tick
-- is already on the game thread, so passing it a string to run costs no new
-- callback at all.
local pending = nil

-- This module is not itself swapped, so its panel is the one from before the
-- reload unless it is told otherwise. Missing this makes a reload look like it
-- did nothing at all.
function M.rewire()
    panel = require("panel")
end

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

local function run(line)
    line = line:match("^%s*(.-)%s*$")
    if line == "" then return end

    if line == "open" or line == "close" then
        local wanted = (line == "open")
        if panel.open ~= wanted then
            pcall(function() panel.toggle() end)
        end
        log.say("panel is now " .. (panel.open and "open" or "closed"))
        return
    end

    local screen = line:match("^mode%s+(%a+)$")
    if screen then
        if panel.set_screen and panel.set_screen(screen) then
            log.say("panel screen: " .. screen)
        else
            log.warn("no such screen: " .. screen)
        end
        return
    end

    if line == "reload" then
        reload.now()
        return
    end

    local words = line:match("^pwp%s+(.+)$")
    if words then
        if M.command then
            M.command(words)
        else
            log.warn("pwp: commands are not wired up yet")
        end
        return
    end

    local command = line:match("^cmd%s+(.+)$")
    if command then
        pending = command
        return
    end

    log.warn("trigger: do not understand " .. line)
end

-- Called from the tick, already on the game thread.
function M.drain()
    local command = pending
    if command == nil then return end
    pending = nil

    local lib = api.cdo("/Script/Engine.Default__KismetSystemLibrary")
    local pc = api.player_controller()

    if not lib or not api.valid(pc) then
        log.warn("cmd: no player controller, so no console")
        return
    end

    pcall(function() lib:ExecuteConsoleCommand(pc, command, pc) end)
    log.say("cmd: " .. command)
end

-- Called from the tick. One small file read a second.
function M.poll()
    local now = os.clock()
    if (now - checked_at) < EVERY then return end
    checked_at = now

    local text = contents()
    if text == nil then return end

    -- The first look only records, so a launch does not act on whatever the
    -- file happened to hold from last time.
    if last == nil then
        last = text
        return
    end

    if text == last then return end
    last = text

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
