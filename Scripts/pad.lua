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
M.VERSION = 15

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

    -- The movement and action keys, which are here to catch a controller that
    -- is not arriving as a controller.
    --
    -- Steam Input can present a pad to the game as keyboard and mouse, and
    -- then every Gamepad_* FKey is dead forever while the player is visibly
    -- walking around. That is indistinguishable from "the mod broke" unless
    -- these are sampled: if pushing the stick lights up W, the game is being
    -- handed keystrokes and no amount of fixing the pad reader will help.
    "W", "A", "S", "D", "E", "Q", "F", "Tab", "LeftShift",
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
    -- "Answered" means the call succeeded, NOT that anything was pressed.
    -- Reading "16 of 16" as "16 buttons are dead" is a mistake that was
    -- actually made, and it sent an investigation down a false trail, so the
    -- wording says which question it answers.
    log.say("  pad keys readable:      " .. pad_ok .. " of " .. #M.PAD
        .. "  (readable, not pressed)")
    log.say("  keyboard keys readable: " .. key_ok .. " of " .. #M.KEYS)

    -- Anything actually down right now, which is the question a person asking
    -- "does my controller work" is really asking.
    local down = {}
    for _, list in ipairs({ M.PAD, M.KEYS }) do
        for _, name in ipairs(list) do
            if M.down(name) then down[#down + 1] = name end
        end
    end
    log.say("  down right now:         "
        .. (#down == 0 and "nothing" or table.concat(down, ", ")))
    log.say("  could not be asked:     " .. unreadable)

    -- Do the names we are asking about even resolve?
    --
    -- Never checked until now, and it is the one link in the chain that can
    -- fail completely silently. FName(str) for a name the engine has not
    -- registered yields None, and IsInputKeyDown(None) is false for every
    -- button forever, which looks exactly like a controller nobody pressed.
    local sample = { "Gamepad_DPad_Up", "Gamepad_FaceButton_Bottom", "Up" }
    for _, name in ipairs(sample) do
        local k = key_for(name)
        local got = "no FKey built"
        if k then
            got = "unreadable"
            pcall(function() got = k.KeyName:ToString() end)
        end
        log.say(string.format("  name %-26s -> %s", name, got))
    end

    -- Analog, which answers a different question from the buttons.
    --
    -- A button reads false whether it is up or whether nothing is plugged in.
    -- The sticks distinguish those: a connected pad almost always has some
    -- drift, so any non-zero here means the game is seeing a device, and all
    -- of them being exactly 0.0 alongside dead buttons is what a disconnected
    -- or sleeping controller looks like.
    local pc = api.player_controller()
    if pc then
        for _, axis in ipairs({
            "Gamepad_LeftX", "Gamepad_LeftY",
            "Gamepad_RightX", "Gamepad_RightY",
            "Gamepad_LeftTriggerAxis", "Gamepad_RightTriggerAxis",
        }) do
            local k = key_for(axis)
            local v
            if k then pcall(function() v = pc:GetInputAnalogKeyState(k) end) end
            log.say(string.format("  %-26s %s", axis, tostring(v)))
        end
    end

    if pad_ok == 0 and key_ok == 0 then
        return "nothing could be read, so IsInputKeyDown is not usable here"
    end
    return string.format("readable: %d pad, %d keyboard", pad_ok, key_ok)
end

local SAMPLE_MS = 50

-- Driving the panel from a pad.
--
-- Gamepad only, deliberately. The arrow keys already reach the panel through
-- their RegisterKeyBind now that the route is Game-and-UI, and polling them
-- here as well would move the selection twice per press.
--
-- The verbs are the ones the panel already understands, so this adds a reader
-- and nothing else: no new navigation model, no second idea of where the
-- selection is.
local DRIVE = {
    { "Gamepad_DPad_Up",            "up" },
    { "Gamepad_DPad_Down",          "down" },
    { "Gamepad_DPad_Left",          "left" },
    { "Gamepad_DPad_Right",         "right" },
    { "Gamepad_FaceButton_Bottom",  "enter" },
}

-- Buttons that act once per press, never on a repeat.
--
-- LeftShoulder is FullSphereSummon's summon button. That mod reads the pad
-- only during the game's own summon action, so taking it here is safe while
-- this panel is up. Shoulders for tabs is what every console menu does.
local TAPS = {
    { "Gamepad_FaceButton_Right",  "close" },
    { "Gamepad_LeftShoulder",      "tab_prev" },
    { "Gamepad_RightShoulder",     "tab_next" },
    { "Gamepad_FaceButton_Left",   "remove" },

    -- Paging, where a pad expects it. The alternative was walking the
    -- selection down past a grid of forty tiles to reach a pager nobody knows
    -- is there.
    --
    -- LeftTrigger is FreeCam's modifier and FullSphereSummon's cancel-aim.
    -- Neither can fire from it alone: FreeCam needs it held WITH
    -- Special_Right, and cancel-aim only means anything while aiming, which
    -- cannot be happening with this panel up.
    { "Gamepad_LeftTrigger",       "page_prev" },
    { "Gamepad_RightTrigger",      "page_next" },
}

-- Held down means repeat, at a menu's pace rather than a poll's.
--
-- In milliseconds, converted to ticks against whatever rate the caller
-- actually runs at. The previous version counted ticks directly and assumed
-- 100ms, so moving this onto the 16ms loop would have made a held d-pad
-- sprint at six times the intended speed with nothing in the code to say so.
local FIRST_REPEAT_MS = 340
local NEXT_REPEAT_MS = 110

-- Set by whoever drives this. Defaults to the slow beat, so a caller that
-- forgets gets the old cadence rather than a runaway one.
M.tick_ms = 100

local function ticks(ms)
    local n = math.floor(ms / (M.tick_ms or 100) + 0.5)
    if n < 1 then n = 1 end
    return n
end

local held = {}

local function pressed_verbs()
    local out, n = nil, 0

    for _, entry in ipairs(DRIVE) do
        local name, verb = entry[1], entry[2]
        local down = M.down(name) == true
        local h = held[name]

        if not down then
            held[name] = nil
        elseif h == nil then
            held[name] = 1
            n = n + 1
            out = out or {}
            out[n] = verb
        else
            h = h + 1
            -- enter does not repeat. A held confirm firing every 200ms would
            -- walk down a list of rules deleting things.
            local first, gap = ticks(FIRST_REPEAT_MS), ticks(NEXT_REPEAT_MS)
            if verb ~= "enter" and h >= first
                and ((h - first) % gap) == 0 then
                n = n + 1
                out = out or {}
                out[n] = verb
            end
            held[name] = h
        end
    end

    return out
end

-- Called on the beat while the panel is open.
--
-- The actions are passed in rather than required, so this module never has to
-- know what a panel is. Anything missing from the table is simply not bound.
function M.drive(actions)
    local verbs = pressed_verbs()
    if verbs and actions.nav then
        for _, verb in ipairs(verbs) do
            pcall(actions.nav, verb)
        end
    end

    for _, entry in ipairs(TAPS) do
        local name, action = entry[1], entry[2]
        local down = M.down(name) == true

        if not down then
            held[name] = nil
        elseif not held[name] then
            held[name] = 1
            local fn = actions[action]
            if fn then pcall(fn) end
        end
    end
end

-- Forget what was held, so a button still down when the panel shuts does not
-- fire the instant it reopens.
function M.forget()
    held = {}
end

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

    if fired then
        -- Mark the chord's buttons as already held.
        --
        -- RightShoulder is half of this chord AND tab_next. The panel calls
        -- forget() before this, so without seeding, the shoulder the player is
        -- still holding reads as a brand new press on the very next tick and
        -- the panel opens on the wrong tab. It survives today only because the
        -- opening beat happens to find an empty hits table, which is luck
        -- rather than design and would break the moment the draw order shifts.
        for _, name in ipairs(M.OPEN_CHORD) do
            held[name] = 1
        end
    end

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
            -- Counted in BEATS, not in the interval this entry ASKED for.
            -- clock's floor is BEAT_MS, so a request below it runs at the
            -- floor, and reporting beats * SAMPLE_MS understated elapsed time
            -- by more than two to one. Every timing read off this line was
            -- wrong in the same direction.
            log.say(string.format(
                "pad watch alive, ~%ds (%d beats), controller %s",
                math.floor(beats * 100 / 1000), beats,
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
