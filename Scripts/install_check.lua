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
--
-- The same check looks for the old UE4SS layout next to the official one
-- (audit H, 2026-10-28): a second copy of this mod in
-- <game>/Pal/Binaries/Win64/ue4ss/Mods/PalWorkPriority, or a second UE4SS
-- there (its dwmapi.dll proxy). The official loader keeps UE4SS in
-- Mods/NativeMods/UE4SS and puts no dwmapi.dll in Pal/Binaries/Win64 (the
-- 2026-10-28 Vortex run, docs/vortex-2026-10-28.md); Vortex's own UE4SS
-- management or an old manual install does, and then mods can load twice.
-- On a dedicated server that layout is the normal one, and a mod running
-- from it is never checked.
local M = {}

local function read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local text = f:read('a')
    f:close()
    return text
end

-- Opened and closed, never read: a DLL is no text to load.
local function exists(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    f:close()
    return true
end

-- The Workshop half: {workshop = true, managed = <version or nil>} or nil.
local function workshop(mods, version, reader)
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
    return { workshop = true, managed = managed }
end

-- dir: this mod's folder (ends in a slash). version: the running version.
-- Returns nil when there is nothing to say, or a table with any of:
--   workshop = true, managed = <version or nil>   the Workshop copy is on
--   old_copy = <folder>    a second copy of this mod in the old layout
--   old_ue4ss = <folder>   a second UE4SS (dwmapi.dll) in Pal/Binaries/Win64
-- reader and present are for tests. A test reader also answers present, so
-- a test never looks at the real disk.
function M.check(dir, version, reader, present)
    if not present then
        present = reader and function(path) return reader(path) ~= nil end or exists
    end
    reader = reader or read
    if type(dir) ~= 'string' or type(version) ~= 'string' then return nil end
    -- Only the official layout has a loader: <game>/Mods/NativeMods/UE4SS/Mods/<mod>/.
    local game, mods_name = dir:match('^(.*[\\/])([Mm]ods[\\/])[Nn]ative[Mm]ods[\\/]')
    if not game then return nil end
    local found = workshop(game .. mods_name, version, reader) or {}
    -- Named the way the player will look for it, with the separator the game
    -- handed us (a backslash on Windows).
    local sep = dir:find('\\', 1, true) and '\\' or '/'
    local win64 = game .. table.concat({ 'Pal', 'Binaries', 'Win64' }, sep)
    local old = win64 .. sep .. table.concat({ 'ue4ss', 'Mods', 'PalWorkPriority' }, sep)
    if present(old .. sep .. 'Scripts' .. sep .. 'main.lua') then found.old_copy = old end
    if present(win64 .. sep .. 'dwmapi.dll') then found.old_ue4ss = win64 end
    if next(found) == nil then return nil end
    found.sep, found.native = sep, table.concat({ 'Mods', 'NativeMods', 'UE4SS', 'Mods' }, sep)
    return found
end

local function workshop_text(found, version)
    if found.managed == nil then
        return 'Pal Work Priority: the Steam Workshop copy is switched on in the game\'s mod list but not installed yet. '
            .. 'On the next start the game will install it over this version (' .. version .. '). '
            .. 'Use one copy: switch the Workshop copy off or unsubscribe, or remove this manual install.'
    end
    return 'Pal Work Priority ' .. version .. ' is installed by hand, but the Steam Workshop copy (' .. found.managed
        .. ') is also switched on. The game may replace or delete these files when that copy updates or is removed. '
        .. 'Use one copy: update the Workshop copy, or switch it off or unsubscribe and reinstall this version.'
end

local function old_layout_text(found)
    local parts = {}
    if found.old_copy then
        parts[#parts + 1] = 'Pal Work Priority: a second copy of this mod is in ' .. found.old_copy
            .. ', the old UE4SS layout. Remove that folder. The copy the game\'s mod loader runs is the one in '
            .. found.native .. '.'
    end
    if found.old_ue4ss then
        -- The file name alone does not prove UE4SS: other loaders and tools
        -- install a dwmapi.dll too (review round 2, 2026-10-29), so the text
        -- says what to do if it is one, not to delete it.
        local sep = found.sep
        parts[#parts + 1] = 'Pal Work Priority: ' .. found.old_ue4ss .. sep .. 'dwmapi.dll found. '
            .. 'If it is an old UE4SS next to the one from the game\'s mod loader, mods can load twice: '
            .. 'remove it and the folder ' .. found.old_ue4ss .. sep .. 'ue4ss'
            .. ' after moving any mods you still use to ' .. found.native
            .. ' (or disable UE4SS in Vortex). Other mod loaders use the same file name; keep it if it is one of them.'
    end
    return table.concat(parts, ' ')
end

-- The log text: every problem found, each in its own plain sentences.
function M.text(found, version)
    local parts = {}
    if found.workshop then parts[#parts + 1] = workshop_text(found, version) end
    if found.old_copy or found.old_ue4ss then parts[#parts + 1] = old_layout_text(found) end
    return table.concat(parts, ' ')
end

-- One short clause for the panel's sub line, which has room for one line.
-- A second copy of the mod comes first: it can run the mod twice.
function M.short(found)
    if found.old_copy then return 'Second copy in Pal/Binaries/Win64/ue4ss: remove it.' end
    if found.old_ue4ss then
        return 'Pal/Binaries/Win64/dwmapi.dll found: if it is an old UE4SS, remove it (or disable UE4SS in Vortex).'
    end
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
