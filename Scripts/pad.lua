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

    log.say("pad probe:")
    log.say("  pad keys answered:      " .. pad_ok .. " of " .. #M.PAD)
    log.say("  keyboard keys answered: " .. key_ok .. " of " .. #M.KEYS)
    log.say("  could not be asked:     " .. unreadable)

    if pad_ok == 0 and key_ok == 0 then
        return "nothing could be read, so IsInputKeyDown is not usable here"
    end
    return string.format("readable: %d pad, %d keyboard", pad_ok, key_ok)
end

local SAMPLE_MS = 50
local ENTRY = "pad sample"

-- Watch for a few seconds and report everything that went down.
--
-- Sampled rather than asked once, because a report is only useful if the
-- player can press things while it runs. 50ms is well inside a deliberate
-- button press and cheap enough that the cost does not need arguing about,
-- and the entry cancels itself so nothing is left polling afterwards.
function M.sample(seconds)
    seconds = tonumber(seconds) or 4
    if seconds < 1 then seconds = 1 end
    if seconds > 20 then seconds = 20 end

    local ticks = math.floor((seconds * 1000) / SAMPLE_MS)
    local seen, order, n = {}, {}, 0

    clock.cancel(ENTRY)
    log.say("watching the pad for " .. seconds .. "s, press things now")

    clock.every(ENTRY, SAMPLE_MS, function()
        n = n + 1

        for _, list in ipairs({ M.PAD, M.KEYS }) do
            for _, name in ipairs(list) do
                if M.down(name) and not seen[name] then
                    seen[name] = true
                    order[#order + 1] = name
                end
            end
        end

        if n >= ticks then
            clock.cancel(ENTRY)
            if #order == 0 then
                log.say("pad sample: nothing went down in " .. seconds .. "s")
            else
                log.say("pad sample saw " .. #order .. ":")
                for _, name in ipairs(order) do
                    log.say("  " .. name)
                end
            end
        end
    end)

    return "sampling for " .. seconds .. "s, results follow in the log"
end

return M
