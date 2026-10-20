-- install_check: a Steam Workshop copy switched on next to a manual install
-- (G7, measured 2026-10-20). Only a running version that differs from what the
-- game's mod loader manages, while the Workshop copy is switched on, warns.
local check = require('install_check')

local dir = 'D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS/Mods/PalWorkPriority/'
local files
local function reader(path)
    return files[path]
end
local SETTINGS = 'D:/Steam/steamapps/common/Palworld/Mods/PalModSettings.ini'
local INFO = 'D:/Steam/steamapps/common/Palworld/Mods/ManagedMods/PalWorkPriority/Info.json'
local ON = '[PalModSettings]\r\nbGlobalEnableMod=True\r\nActiveModList=UE4SSExperimentalPW\r\nActiveModList=PalWorkPriority\r\n'
local OFF = '[PalModSettings]\r\nActiveModList=UE4SSExperimentalPW\r\nActiveModList=CreativeMenu\r\n'

-- Workshop copy switched off: nothing to say, whatever the loader managed.
files = { [SETTINGS] = OFF, [INFO] = '{ "Version": "0.4.1" }' }
assert(check.check(dir, '0.5.0', reader) == nil, 'warned with the Workshop copy switched off')

-- Switched on and the loader manages this very version: a Workshop install.
files = { [SETTINGS] = ON, [INFO] = '{\n  "ModName": "Pal Work Priority",\n  "Version": "0.5.0"\n}' }
assert(check.check(dir, '0.5.0', reader) == nil, 'warned on a plain Workshop install')

-- Switched on, the loader manages 0.4.1, 0.5.0 runs (manual over Workshop).
files = { [SETTINGS] = ON, [INFO] = '{ "Version" : "0.4.1" }' }
local found = check.check(dir, '0.5.0', reader)
assert(found and found.managed == '0.4.1', 'missed a manual install over a managed Workshop copy')
local text = check.text(found, '0.5.0')
assert(text:find('0.4.1', 1, true) and text:find('0.5.0', 1, true) and text:find('Use one copy', 1, true))
assert(check.short(found) == 'Steam Workshop copy 0.4.1 also on: use one copy.', 'panel clause changed')
assert(#check.short(found) <= 60, 'panel clause too long for the sub line')

-- Switched on but not installed yet: the next start installs it over this one.
files = { [SETTINGS] = ON }
found = check.check(dir, '0.5.0', reader)
assert(found and found.managed == nil, 'missed a Workshop copy that is about to be installed')
assert(check.text(found, '0.5.0'):find('next start', 1, true))
assert(check.short(found):find('not installed yet', 1, true) and #check.short(found) <= 64)

-- Not the official layout (a dedicated server's ue4ss/Mods) or unreadable: silent.
assert(check.check('/home/srv/Pal/Binaries/Win64/ue4ss/Mods/PalWorkPriority/', '0.5.0', reader) == nil)
files = {}
assert(check.check(dir, '0.5.0', reader) == nil, 'unreadable settings became a warning')
-- Windows hands the mod a backslash path; io.open accepts the mixed result.
local function slashed(p) return files[(p:gsub('\\', '/'))] end
local backslash_dir = (dir:gsub('/', '\\'))
assert(check.check(backslash_dir, '0.5.0', slashed) == nil)
files = { [SETTINGS] = ON, [INFO] = '{ "Version": "0.4.1" }' }
found = check.check(backslash_dir, '0.5.0', slashed)
assert(found and found.managed == '0.4.1', 'Windows path separators not handled')

-- A line that only starts with the name is another mod.
files = { [SETTINGS] = '[PalModSettings]\r\nActiveModList=PalWorkPriorityExtras\r\n' }
assert(check.check(dir, '0.5.0', reader) == nil, 'matched another mod by prefix')
print('install_check: switched-off, same-version, managed-older, pending, layout and prefix cases')
