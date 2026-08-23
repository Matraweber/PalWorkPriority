"""Turn cooked assets into a LogicMod pak, and put it where the game looks.

The wiki's route is Package Project from the editor, which builds, cooks,
stages and paks the whole game to get at one chunk. That is a very long way
round for two assets, and it is a GUI action besides.

This does the last part directly: take what the cook produced under
Saved/Cooked, write an UnrealPak response file with the in-pak paths the game
expects, and pak it.

    python tools/pak_mod.py            build and install
    python tools/pak_mod.py --stage    build only, do not touch the game

The in-pak path is the part worth getting right. A pak's contents are named
relative to the engine's Content root, so `/Game/Mods/PalWorkPriority` in the
editor has to appear as `../../../Pal/Content/Mods/PalWorkPriority` in the
pak. Read out of a working mod's pak rather than guessed: tools/pakinfo.py
prints exactly this for CreativeMenu.
"""

import io
import os
import subprocess
import sys

# Overridable, and not one machine's layout.
#
# These were absolute paths on the developer's own disk, which is both useless
# to anyone else and a way of publishing a user name. Set PWP_MODDING_KIT and
# PWP_UE to point at your own copies; the defaults are only the usual install
# locations.
KIT = os.environ.get("PWP_MODDING_KIT", r"C:\PalworldModdingKit")
ENGINE = os.environ.get("PWP_UE", r"C:\Program Files\Epic Games\UE_5.1")

UNREALPAK = os.path.join(ENGINE, "Engine", "Binaries", "Win64", "UnrealPak.exe")
COOKED = os.path.join(KIT, "Saved", "Cooked", "Windows", "Pal", "Content",
                      "Mods", "PalWorkPriority")

MOD = "PalWorkPriority"
IN_PAK = "../../../Pal/Content/Mods/" + MOD

GAME = (r"C:\Program Files (x86)\Steam\steamapps\common\Palworld"
        r"\Pal\Content\Paks\LogicMods")

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "build")
PAK = os.path.join(OUT_DIR, MOD + ".pak")
RESPONSE = os.path.join(OUT_DIR, MOD + ".response.txt")

# Cooked output holds more than the assets themselves. Only these belong in
# the pak; the rest is bookkeeping the game neither reads nor expects.
KEEP = (".uasset", ".uexp", ".ubulk", ".umap")


def cooked_files():
    found = []
    for root, _dirs, names in os.walk(COOKED):
        for name in names:
            if not name.lower().endswith(KEEP):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, COOKED).replace("\\", "/")
            found.append((full, IN_PAK + "/" + rel))
    return sorted(found)


def main(argv):
    if not os.path.exists(UNREALPAK):
        print("UnrealPak not found: " + UNREALPAK)
        return 2

    if not os.path.isdir(COOKED):
        print("nothing cooked yet: " + COOKED)
        print("run the cook first, then this.")
        return 2

    files = cooked_files()
    if not files:
        print("cooked folder exists but holds no assets")
        return 2

    if not os.path.isdir(OUT_DIR):
        os.makedirs(OUT_DIR)

    print("packing %d file(s):" % len(files))
    lines = []
    for source, inside in files:
        print("  %-52s %d bytes" % (inside.split("/")[-1],
                                    os.path.getsize(source)))
        lines.append('"%s" "%s"' % (source, inside))

    io.open(RESPONSE, "w", encoding="utf-8").write("\n".join(lines) + "\n")

    result = subprocess.run(
        [UNREALPAK, PAK, "-Create=" + RESPONSE, "-compress"],
        capture_output=True, text=True)

    ok = result.returncode == 0 and os.path.exists(PAK)
    if not ok:
        print("")
        print("UnrealPak failed (exit %d)" % result.returncode)
        print(result.stdout[-2000:])
        print(result.stderr[-2000:])
        return 1

    print("")
    print("built %s, %d bytes" % (PAK, os.path.getsize(PAK)))

    if "--stage" in argv:
        print("staged only, the game was not touched")
        return 0

    if not os.path.isdir(GAME):
        os.makedirs(GAME)

    target = os.path.join(GAME, MOD + ".pak")
    io.open(target, "wb").write(io.open(PAK, "rb").read())
    print("installed to " + target)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
