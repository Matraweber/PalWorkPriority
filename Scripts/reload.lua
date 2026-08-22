-- Swap the panel's code without restarting the game.
--
-- UE4SS offers two reload switches and its own settings file says what both
-- do: "reload all mods". Tried on 21 August, EnableAutoReloadingLuaMods
-- restarted five mods when one file changed, wiped UE4SS.log, and swapped code
-- into a running test session twice, which is three different ways of ruining
-- an evening. There is no per-mod switch to find.
--
-- This is that switch, built small. Only the two modules that draw the UI are
-- replaced. The scheduler, the hooks, the transport and the rules keep running
-- untouched, which matters: a registered hook cannot be unregistered, so
-- anything holding one must never be swapped. panel and overlay register
-- nothing with UE4SS, which is exactly what makes them safe and is worth
-- rechecking before adding a third name to the list.
--
-- The trigger is a file rather than a keybind, and that is the point of the
-- whole thing. While the panel holds the input mode UE4SS never sees a key
-- press, which is precisely when the panel is the thing being worked on.
--
--     python tools/remote.py reload
--
-- What survives a swap: the rules, the pals' assignments, the icons already
-- resolved, and the world. What does not: the panel's widgets, torn down first
-- on purpose, because the code that made them is about to go away and widgets
-- outliving their code is how this mod got its duplicate panel.

local log = require("log")

local M = {}

-- Only these. Adding a module that registers a hook or holds a timer would
-- turn a reload into a duplicate of both.
-- icons joins the list now that its scheduling went through clock.lua: it
-- registers nothing with UE4SS any more, which was the whole reason for the
-- rule that a module holding a hook must never be swapped. Its caches reset
-- with it, which costs one re-resolve per icon and is what a reload is for.
--
-- panel must come after icons: it is reloaded too, so its own require picks
-- up whichever icons table is current when it runs.
local SWAPPED = { "icons", "overlay", "panel" }

-- Every module ever swapped out, kept forever on purpose.
--
-- UE4SS holds Lua registry references to callbacks it has been given. When a
-- swapped module becomes garbage, those references stop being functions, and
-- UE4SS's answer is not to skip the callback: it removes the hook driving the
-- engine tick, and the mod goes silent until the game restarts.
--
-- That is not a guess. It is the same failure that took most of 21 August to
-- find, and the log line naming it, "Ref was not function, removing hook",
-- was written by UE4SS every time it happened.
--
-- Holding the old table keeps its functions alive and their upvalues with
-- them. A few leaked tables per reload, against a game using several
-- gigabytes, is not worth a moment's thought.
local kept = {}

function M.now()
    local panel = package.loaded["panel"]
    local overlay = package.loaded["overlay"]
    local icons = package.loaded["icons"]

    -- Down before out. A widget whose module has been replaced is a widget
    -- nothing can reach to close, and it stays on screen for the session.
    pcall(function() if panel and panel.open then panel.toggle() end end)
    pcall(function() if panel and panel.reset then panel.reset() end end)
    pcall(function() if overlay and overlay.hide then overlay.hide() end end)
    pcall(function() if overlay and overlay.reset then overlay.reset() end end)

    -- The outgoing icons module takes its queue and its clock entry with it.
    -- Read here, while package.loaded still names the OLD module: below this
    -- point the table has been replaced, and shutting down the new one would
    -- stop the pump that is about to be needed. Without it the old pump kept
    -- beating against a module that had already been discarded, doing eight
    -- blocking loads a beat on its behalf.
    pcall(function() if icons and icons.shutdown then icons.shutdown() end end)

    for _, name in ipairs(SWAPPED) do
        local old = package.loaded[name]
        if old ~= nil then kept[#kept + 1] = old end
        package.loaded[name] = nil
    end

    -- loadfile, not require.
    --
    -- Clearing package.loaded and calling require again looks like it works:
    -- it returns a table, reports no error, and resets every bit of module
    -- state. It does not read the file. UE4SS keeps the compiled chunk of its
    -- own accord, so require hands back the same code it compiled at startup,
    -- and a reload has therefore never once loaded an edit. Proven rather than
    -- suspected: a log line put at the top of panel.lua, deployed, reloaded,
    -- and never printed, while the file on disk plainly contained it.
    --
    -- That also explains why this feature felt useless enough to be deleted
    -- in a rollback and blamed twice for crashes: it was doing half its job
    -- silently.
    --
    -- Reading the file and running the chunk is the whole fix.
    local broken = {}
    for _, name in ipairs(SWAPPED) do
        local path = (M.scripts_dir or "") .. name .. ".lua"
        local chunk, load_err = loadfile(path)
        if not chunk then
            broken[#broken + 1] = name .. ": " .. tostring(load_err)
        else
            local ok, result = pcall(chunk)
            if not ok then
                broken[#broken + 1] = name .. ": " .. tostring(result)
            else
                -- A module returns its table; require would have stored it,
                -- so this stores it in the same place for anything that
                -- requires it later.
                package.loaded[name] = result
            end
        end
    end

    if #broken > 0 then
        -- Said loudly, because a module that failed to load leaves the mod
        -- half swapped and whatever happens next will be confusing.
        for _, why in ipairs(broken) do
            log.warn("reload failed, " .. why)
        end
        return false
    end

    -- The holders re-resolve, or they keep calling the module that was just
    -- thrown away. Reloading without this looks like reloading doing nothing,
    -- which is a whole evening on its own if it is not written down.
    if M.rewire then
        -- The result is checked. It used to be a bare pcall, so a rewire that
        -- threw was swallowed and the next line still announced success -
        -- while main.lua carried on calling the modules that were just
        -- discarded. That is the "reloading looks like it did nothing"
        -- evening described three lines up, wearing a confirmation message.
        local ok, err = pcall(M.rewire)
        if not ok then
            log.warn("reload loaded the new code but could not rewire the " ..
                "holders, so the old modules are still in use: " .. tostring(err))
            return false
        end
    end

    log.say("reloaded " .. table.concat(SWAPPED, " and ") ..
        ", the panel key will draw the new code")
    return true
end

-- Set by main.lua, which holds panel as a local and has to be told to look
-- the module up again.
M.rewire = nil

-- Set by main.lua: where the .lua files actually live, so the chunk can be
-- read from disk rather than taken from UE4SS's cache.
M.scripts_dir = nil

return M
