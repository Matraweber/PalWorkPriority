"""Cut the game down to this mod alone, and put it back.

    python tools/solo.py on      only this mod loads
    python tools/solo.py off     everything back as it was

What this does not do is make Ctrl+R work.

UE4SS hot reload was the reason this script was written. It crashed the game
with a full mod list, which looked like a mod count problem, so the mods were
cut down to one. It crashed again, in the same place, tearing everything down.
That is twice, and the second time rules out the explanation the first one
suggested: the problem is this mod, not its neighbours.

Which is fair. Hot reload destroys the Lua state while a self rescheduling
timer is still pending against it, while hooks are still registered, and while
widgets we built are still in the viewport. Surviving that is real work with
an uncertain payoff, and every attempt costs a game session to find out.

So hot reload stays off, and this script is still worth running. Starting with
one mod instead of twenty seven is a much shorter restart, which is most of
what was wanted from Ctrl+R anyway.

"on" records the current state of mods.txt and the UE4SS settings before
touching either, and "off" restores exactly what was recorded rather than
guessing at defaults. Running "on" twice will not overwrite the record of what
normal looks like.

Run it from a working setup. What "off" restores is whatever "on" found, so
switching mods off by hand first and then running this records the half
switched off state as normal.

Switching mods off by hand is also what this exists to avoid. A blueprint mod
is a Lua mod plus a pak, and turning off only the Lua half leaves the loader
reaching for something that is not coming. That state crashes the game about a
minute into a session, with a stack that is entirely UE4SS and nothing to do
with whichever mod you were actually working on.
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

# Blueprint mods ship a pak here and are loaded by BPModLoaderMod, which is a
# Lua mod. Switching the Lua side off while the paks stay mounted leaves the
# loader trying to load mod actors that are no longer coming, and the game
# crashed roughly a minute into every session that was left in that state.
#
# So the paks move aside with the mods rather than being left behind. Renaming
# the folder is one operation and undoes in one.
LOGIC = os.path.join(
    r"C:\Program Files (x86)\Steam\steamapps\common\Palworld",
    "Pal", "Content", "Paks", "LogicMods")
LOGIC_HELD = LOGIC + ".solo-held"

# What stays on. Not just this mod: a blueprint mod is a pak plus the loader
# that mounts it, and switching the loader off makes the pak invisible. Solo
# mode did exactly that, and the widget class went missing in a way that
# looked like a bad cook rather than a missing neighbour.
#
# BPML_GenericFunctions is what BPModLoaderMod itself depends on.
KEEP = (
    "PalWorkPriority",
    "BPModLoaderMod",
    "BPML_GenericFunctions",
)


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
        if match and match.group(2) not in KEEP and match.group(4) != "0":
            out.append("%s%s%s0" % (match.group(1), match.group(2),
                                    match.group(3)))
            silenced += 1
        else:
            out.append(line)

    write(MODS, "\n".join(out) + "\n")
    print("  %d other mod(s) switched off, kept: %s"
          % (silenced, ", ".join(KEEP)))

    # Other people's blueprint paks move aside; the folder itself stays,
    # because this mod now ships a pak of its own that has to live in it.
    if os.path.isdir(LOGIC) and not os.path.isdir(LOGIC_HELD):
        os.makedirs(LOGIC_HELD)
        held = 0
        for name in os.listdir(LOGIC):
            if name.startswith("PalWorkPriority"):
                continue
            shutil.move(os.path.join(LOGIC, name),
                        os.path.join(LOGIC_HELD, name))
            held += 1
        print("  %d blueprint mod pak file(s) moved aside" % held)

    # Hot reload stays off. See the note at the top of this file.
    settings = read(SETTINGS)
    settings = set_ini(settings, "EnableHotReloadSystem", "0")
    settings = set_ini(settings, "ConsoleEnabled", "1")
    settings = set_ini(settings, "GuiConsoleEnabled", "1")
    settings = set_ini(settings, "GuiConsoleVisible", "1")
    write(SETTINGS, settings)
    print("  consoles on, hot reload deliberately left off")

    print("")
    print("Start the game. Restarts are still restarts, but with one mod")
    print("instead of twenty seven they are much shorter ones.")
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

    if os.path.isdir(LOGIC_HELD):
        if not os.path.isdir(LOGIC):
            os.rename(LOGIC_HELD, LOGIC)
            print("  blueprint mod paks put back")
        else:
            # A LogicMods folder appeared while we were away, which is the
            # normal case rather than a clash: this mod's own pak is
            # installed there during development. Merge rather than refuse,
            # and never overwrite what is already in place.
            moved, kept = 0, 0
            for name in os.listdir(LOGIC_HELD):
                source = os.path.join(LOGIC_HELD, name)
                target = os.path.join(LOGIC, name)
                if os.path.exists(target):
                    kept += 1
                    continue
                shutil.move(source, target)
                moved += 1

            if not os.listdir(LOGIC_HELD):
                os.rmdir(LOGIC_HELD)

            print("  blueprint mod paks put back (%d moved, %d already there)"
                  % (moved, kept))

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
