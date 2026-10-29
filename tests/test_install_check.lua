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
-- The old UE4SS layout next to the official one (audit H, 2026-10-28).
local OLD_MAIN = 'D:/Steam/steamapps/common/Palworld/Pal/Binaries/Win64/ue4ss/Mods/PalWorkPriority/Scripts/main.lua'
local DWMAPI = 'D:/Steam/steamapps/common/Palworld/Pal/Binaries/Win64/dwmapi.dll'
local OLD_DIR = 'D:/Steam/steamapps/common/Palworld/Pal/Binaries/Win64/ue4ss/Mods/PalWorkPriority'

-- A second copy of the mod there, Workshop copy off: warned, folder named.
files = { [SETTINGS] = OFF, [OLD_MAIN] = '-- old' }
found = check.check(dir, '0.5.0', reader)
assert(found and found.old_copy == OLD_DIR and not found.workshop and not found.old_ue4ss,
    'missed a second copy in the old UE4SS layout')
text = check.text(found, '0.5.0')
assert(text:find('Remove that folder', 1, true) and text:find(OLD_DIR, 1, true), text)
assert(not text:find('Workshop', 1, true), 'old-layout text talked about the Workshop')
assert(#check.short(found) <= 60 and check.short(found):find('remove it', 1, true))

-- A second UE4SS (its dwmapi.dll proxy) there, even without a copy of the mod.
files = { [DWMAPI] = 'MZ' }
found = check.check(dir, '0.5.0', reader)
assert(found and found.old_ue4ss == 'D:/Steam/steamapps/common/Palworld/Pal/Binaries/Win64' and not found.old_copy)
text = check.text(found, '0.5.0')
assert(text:find('Win64/dwmapi.dll found', 1, true) and text:find('If it is an old UE4SS', 1, true)
    and text:find('Win64/ue4ss', 1, true) and text:find('disable UE4SS in Vortex', 1, true), text)
-- Other loaders use that file name too (round 2, 2026-10-29): the text names
-- the condition rather than claiming it is UE4SS and ordering a delete.
assert(not text:find('a second UE4SS is installed', 1, true) and text:find('Other mod loaders', 1, true), text)
assert(check.short(found) == 'Pal/Binaries/Win64/dwmapi.dll found: if it is an old UE4SS, remove it (or disable UE4SS in Vortex).',
    check.short(found))

-- Both problems and the Workshop conflict: every one in the log, the second
-- copy (it can run the mod twice) on the panel line.
files = { [SETTINGS] = ON, [INFO] = '{ "Version": "0.4.1" }', [OLD_MAIN] = '', [DWMAPI] = '' }
found = check.check(dir, '0.5.0', reader)
assert(found.workshop and found.managed == '0.4.1' and found.old_copy and found.old_ue4ss)
text = check.text(found, '0.5.0')
assert(text:find('0.4.1', 1, true) and text:find('Remove that folder', 1, true) and text:find('dwmapi.dll', 1, true))
assert(check.short(found):find('Second copy', 1, true))

-- Windows paths: the folder is named with backslashes, as Explorer shows it.
files = { [OLD_MAIN] = '' }
found = check.check(backslash_dir, '0.5.0', slashed)
assert(found and found.old_copy == (OLD_DIR:gsub('/', '\\')), tostring(found and found.old_copy))
assert(check.text(found, '0.5.0'):find('Mods\\NativeMods\\UE4SS\\Mods', 1, true))

-- The dedicated server's normal layout is the old one: never checked.
files = { ['/home/srv/Pal/Binaries/Win64/dwmapi.dll'] = '' }
assert(check.check('/home/srv/Pal/Binaries/Win64/ue4ss/Mods/PalWorkPriority/', '0.5.0', reader) == nil)
-- Only the mod's own folder in ue4ss/Mods counts, not another mod's.
files = { ['D:/Steam/steamapps/common/Palworld/Pal/Binaries/Win64/ue4ss/Mods/OtherMod/Scripts/main.lua'] = '' }
assert(check.check(dir, '0.5.0', reader) == nil)
print('install_check: switched-off, same-version, managed-older, pending, layout, prefix and old-layout cases')
