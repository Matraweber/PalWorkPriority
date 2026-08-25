-- Reading a gamepad, which UE4SS keybinds cannot do.
--
-- Every key this mod binds goes through RegisterKeyBind, and that reads the
-- keyboard and nothing else. A controller press never reaches it. On a Steam
-- Deck that means the panel opens only if the player first maps a button to
-- Alt+F1 in Steam Input, and once it is open nothing on the pad moves the
-- selection.
--
-- The way in is the PlayerController rather than UE4SS. IsInputKeyDown,
-- WasInputKeyJustPressed and GetInputAnalogKeyState are reflected UFunctions
-- on APlayerController, and they take an FKey, which UE4SS marshals from a
-- plain Lua table with a KeyName field. FreeCam and FullSphereSummon both read
-- their pads exactly this way on this exact build, which is the proof the
-- shape works before any of it goes near the game.
--
-- It matters for the keyboard too, and that is not a side benefit. While the
-- panel holds UI-only input UE4SS never sees a key press. That is why the
-- reload trigger is a file rather than a keybind, and reload.lua says so. The
-- arrow keys are bound through the same RegisterKeyBind, so on that reading
-- they are bound and dead precisely when the panel is open, which is the only
-- time they do anything. Polling the controller does not care about the input
-- mode, so one mechanism would answer both.
--
-- Would. This module measures first and decides nothing: M.sample watches for
-- a few seconds and reports what it actually saw, so the claim above gets
-- checked against the game rather than assumed.

local M = {}

-- Bumped by hand when this file changes, so a report says which copy ran.
M.VERSION = 7

local api = require("palapi")
local log = require("log")
local clock = require("clock")

-- Built once, at load. An FName is an index into the engine's name table
-- rather than an object, so holding one is not the stored-wrapper hazard that
-- holding a UObject would be, and rebuilding these every tick would be pure
-- waste. FreeCam keeps them as module locals for the same reason.
local function fkey(name)
    local k
    pcall(function() k = { KeyName = FName(name) } end)
    return k
end

-- What a pad offers, in the order a report should read.
M.PAD = {
    "Gamepad_DPad_Up", "Gamepad_DPad_Down",
    "Gamepad_DPad_Left", "Gamepad_DPad_Right",
    "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right",
    "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top",
    "Gamepad_LeftShoulder", "Gamepad_RightShoulder",
    "Gamepad_LeftTrigger", "Gamepad_RightTrigger",
    "Gamepad_Special_Left", "Gamepad_Special_Right",
    "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick",
}

-- The keyboard half of the same question. These are the keys the panel
-- already binds, asked through the controller instead of through UE4SS, so a
-- sample taken with the panel open says whether polling survives the UI route
-- when RegisterKeyBind does not.
M.KEYS = {
    "Up", "Down", "Left", "Right", "Enter", "Escape", "SpaceBar",
}

local keys = {}
local function key_for(name)
    local k = keys[name]
    if k == nil then
        k = fkey(name) or false
        keys[name] = k
    end
    if k == false then return nil end
    return k
end

-- One read. Returns true, false, or nil when the question could not be asked.
--
-- pc comes from the current call and is not kept: a controller wrapper stored
-- across a beat is the use-after-free this mod has been bitten by before.
function M.down(name)
    local k = key_for(name)
    if k == nil then return nil end

    local pc = api.player_controller()
    if not pc then return nil end

    local state
    local ok = pcall(function() state = pc:IsInputKeyDown(k) end)
    if not ok then return nil end
    return state == true
end

-- Is anything at all readable, and is a pad connected?
--
-- "No pad" and "pads cannot be read on this build" look identical from a
-- single quiet sample, so this separates them: the keyboard names go through
-- the same call, and a keyboard that answers while a pad never does means the
-- reading works and nothing is plugged in.
function M.probe()
    local pad_ok, key_ok, unreadable = 0, 0, 0

    for _, name in ipairs(M.PAD) do
        local v = M.down(name)
        if v == nil then unreadable = unreadable + 1 else pad_ok = pad_ok + 1 end
    end
    for _, name in ipairs(M.KEYS) do
        local v = M.down(name)
        if v == nil then unreadable = unreadable + 1 else key_ok = key_ok + 1 end
    end

    log.say("pad probe (pad.lua v" .. tostring(M.VERSION) .. "):")
    log.say("  pad keys answered:      " .. pad_ok .. " of " .. #M.PAD)
    log.say("  keyboard keys answered: " .. key_ok .. " of " .. #M.KEYS)
    log.say("  could not be asked:     " .. unreadable)

    if pad_ok == 0 and key_ok == 0 then
        return "nothing could be read, so IsInputKeyDown is not usable here"
    end
    return string.format("readable: %d pad, %d keyboard", pad_ok, key_ok)
end

local SAMPLE_MS = 50

-- Opening the panel from a pad.
--
-- A chord rather than a button, and not for elegance. While the panel is shut
-- the game has its input and we cannot take it away, so whatever is bound here
-- ALSO does whatever the game has it doing. A single free button would open
-- the panel and throw a sphere at the same time. Two held together is a
-- gesture the game does not use for anything.
--
-- The pair was picked against what is actually installed rather than by taste:
-- LeftTrigger, LeftShoulder, Special_Right, FaceButton_Left and both stick
-- clicks are claimed by FreeCam or FullSphereSummon. RightShoulder and
-- Special_Left are free in both.
M.OPEN_CHORD = { "Gamepad_RightShoulder", "Gamepad_Special_Left" }

local chord_was = false

-- True on the beat the chord closes, not while it is held.
function M.open_asked()
    local all = true
    for _, name in ipairs(M.OPEN_CHORD) do
        if M.down(name) ~= true then all = false break end
    end

    local fired = all and not chord_was
    chord_was = all
    return fired
end

local WATCH = "pad watch"

-- Log presses as they happen, until told to stop.
--
-- The timed sample needs the player pressing things during a window someone
-- else opened, which cannot be arranged over a trigger file. This just runs:
-- switch it on, press whatever, read the log afterwards. No synchronising.
--
-- Edge triggered, so holding a button writes one line rather than twenty a
-- second. The previous state lives in the closure, so a fresh copy of this
-- module starts clean, and the entry is keyed by a constant name, which means
-- "watch off" still finds a watch that an older copy of the module started.
function M.watch(on)
    if on == false then
        clock.cancel(WATCH)
        return "pad watch off"
    end

    local was = {}
    local beats = 0

    clock.every(WATCH, SAMPLE_MS, function()
        -- Proof of life, because three results in a row have now rested on
        -- nothing being logged, and "nothing was pressed", "nothing could be
        -- read" and "this entry stopped running" all look identical from the
        -- outside. A silence that comes with a heartbeat is a measurement; a
        -- silence without one is just a dead loop.
        beats = beats + 1
        if beats % 100 == 0 then
            local pc = api.player_controller()
            log.say(string.format(
                "pad watch alive, %ds, controller %s",
                math.floor(beats * SAMPLE_MS / 1000),
                pc and "yes" or "NO"))
        end

        for _, list in ipairs({ M.PAD, M.KEYS }) do
            for _, name in ipairs(list) do
                local now = M.down(name) == true
                if now and not was[name] then
                    log.say("pad: " .. name .. " down")
                end
                was[name] = now
            end
        end
    end)

    return "pad watch on, press things and it will say what it saw"
end

return M
