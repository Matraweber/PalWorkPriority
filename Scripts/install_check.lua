-- Is a Steam Workshop copy of this mod switched on next to a manual install?
--
-- The game's mod loader (Mods/ManagedMods, Mods/PalModSettings.ini) installs
-- Workshop mods into the same folder a manual install uses. Measured on
-- 2026-10-20 (docs/g7-install-2026-10-20.md): with the Workshop copy switched
-- on, the loader installed 0.4.1 over a manual 0.5.0 on the next start; with
-- 0.4.1 already loader-managed, a manual 0.5.0 extracted over it ran, but the
-- loader still owns those file names and deletes them when that copy updates
-- or is removed. Running a different version than the loader manages is the
-- signal. Plain file reads only; anything unreadable means "no warning".
local M = {}

local function read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local text = f:read('a')
    f:close()
    return text
end

-- dir: this mod's folder (ends in a slash). version: the running version.
-- Returns nil when there is nothing to say, or {managed = <version or nil>}.
function M.check(dir, version, reader)
    reader = reader or read
    if type(dir) ~= 'string' or type(version) ~= 'string' then return nil end
    -- Only the official layout has a loader: <game>/Mods/NativeMods/UE4SS/Mods/<mod>/.
    local mods = dir:match('^(.*[\\/][Mm]ods[\\/])[Nn]ative[Mm]ods[\\/]')
    if not mods then return nil end
    local settings = reader(mods .. 'PalModSettings.ini')
    if type(settings) ~= 'string' then return nil end
    local active = false
    for line in settings:gmatch('[^\r\n]+') do
        if line:match('^%s*ActiveModList%s*=%s*PalWorkPriority%s*$') then active = true end
    end
    if not active then return nil end
    local info = reader(mods .. 'ManagedMods/PalWorkPriority/Info.json')
    local managed = type(info) == 'string' and info:match('"Version"%s*:%s*"([^"]+)"') or nil
    if managed == version then return nil end
    return { managed = managed }
end

function M.text(found, version)
    if found.managed == nil then
        return 'Pal Work Priority: the Steam Workshop copy is switched on in the game\'s mod list but not installed yet. '
            .. 'On the next start the game will install it over this version (' .. version .. '). '
            .. 'Use one copy: switch the Workshop copy off or unsubscribe, or remove this manual install.'
    end
    return 'Pal Work Priority ' .. version .. ' is installed by hand, but the Steam Workshop copy (' .. found.managed
        .. ') is also switched on. The game may replace or delete these files when that copy updates or is removed. '
        .. 'Use one copy: update the Workshop copy, or switch it off or unsubscribe and reinstall this version.'
end

-- One short clause for the panel's sub line, which has room for one line.
function M.short(found)
    if found.managed == nil then
        return 'Steam Workshop copy also on, not installed yet: use one copy.'
    end
    return 'Steam Workshop copy ' .. found.managed .. ' also on: use one copy.'
end

-- Set by main.lua at load: {text = <log text>, short = <panel clause>} or nil.
-- SendSystemToPlayerChat was tried first: the engine accepted the call and the
-- singleplayer chat never showed the line (2026-10-20), so the warning lives in
-- the log and on the Production Limits panel instead.
M.current = nil

return M
