"""Turn the game into a development environment, and back again.

UE4SS can hot reload Lua mods with Ctrl+R, which would replace a two minute
restart with about a second. It was tried and it crashed the game, and the log
said why: it does not reload one mod, it tears down and reloads every Lua mod
installed. Twenty seven of them here, most belonging to other people.

There is no way to scope it to one mod. There is a way to be the only mod.

    python tools/solo.py on      only this mod loads, Ctrl+R works
    python tools/solo.py off     everything back as it was

"on" records the current state of mods.txt and the UE4SS settings before
touching either, and "off" restores exactly what was recorded rather than
guessing at defaults. Running "on" twice will not overwrite the record of what
normal looks like.
"""

import io
import os
import re
import shutil
import sys

UE4SS = (r"C:\Program Files (x86)\Steam\steamapps\common\Palworld"
         r"\Mods\NativeMods\UE4SS")

MODS = os.path.join(UE4SS, "Mods", "mods.txt")
SETTINGS = os.path.join(UE4SS, "UE4SS-settings.ini")

MODS_SAVED = MODS + ".solo-backup"
SETTINGS_SAVED = SETTINGS + ".solo-backup"

KEEP = "PalWorkPriority"


def read(path):
    return io.open(path, "rb").read().decode("utf-8", errors="replace")


def write(path, text):
    io.open(path, "wb").write(text.encode("utf-8"))


def set_ini(text, key, value):
    pattern = re.compile(r"^(%s\s*=\s*)(\S*)\s*$" % re.escape(key), re.M)
    if not pattern.search(text):
        print("  ! %s not found in settings" % key)
        return text
    return pattern.sub(lambda m: m.group(1) + value, text, count=1)


def turn_on():
    if os.path.exists(MODS_SAVED):
        print("already in solo mode, or a backup was left behind.")
        print("run 'off' first if you want to start again.")
        return 1

    shutil.copy2(MODS, MODS_SAVED)
    shutil.copy2(SETTINGS, SETTINGS_SAVED)
    print("recorded the current setup")

    out, silenced = [], 0
    for line in read(MODS).splitlines():
        match = re.match(r"^(\s*)([A-Za-z0-9_]+)(\s*:\s*)(\d+)\s*$", line)
        if match and match.group(2) != KEEP and match.group(4) != "0":
            out.append("%s%s%s0" % (match.group(1), match.group(2),
                                    match.group(3)))
            silenced += 1
        else:
            out.append(line)

    write(MODS, "\n".join(out) + "\n")
    print("  %d other mod(s) switched off, %s left on" % (silenced, KEEP))

    settings = read(SETTINGS)
    settings = set_ini(settings, "EnableHotReloadSystem", "1")
    settings = set_ini(settings, "ConsoleEnabled", "1")
    settings = set_ini(settings, "GuiConsoleEnabled", "1")
    settings = set_ini(settings, "GuiConsoleVisible", "1")
    write(SETTINGS, settings)
    print("  hot reload and the consoles are on")

    print("")
    print("Start the game. From then on:")
    print("  deploy, then Ctrl+R. No restart.")
    print("Run 'python tools/solo.py off' when you want your mods back.")
    return 0


def turn_off():
    if not os.path.exists(MODS_SAVED):
        print("no backup found, so nothing to restore.")
        return 1

    shutil.copy2(MODS_SAVED, MODS)
    shutil.copy2(SETTINGS_SAVED, SETTINGS)
    os.remove(MODS_SAVED)
    os.remove(SETTINGS_SAVED)

    print("mods.txt and UE4SS-settings.ini are back as they were")
    print("hot reload is off again, which is how it should be with a full")
    print("mod list. Restart the game.")
    return 0


def main(argv):
    if len(argv) != 1 or argv[0] not in ("on", "off"):
        print(__doc__)
        return 2
    return turn_on() if argv[0] == "on" else turn_off()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
