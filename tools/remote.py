"""Drive the panel in the running game, from outside it.

    python tools/remote.py open
    python tools/remote.py open,snap
    python tools/remote.py "mode item,snap"
    python tools/remote.py close
    python tools/remote.py cmd stat fps

Deploys the Lua first, writes the instruction file the mod watches, waits, and
prints whatever the mod said in reply. A snap also reports the png the game
wrote, which can then be read directly.

This does not reload code. Changing Lua still needs the game restarted. The
version that swapped modules while running was never proved safe, was blamed
twice for faults it did not cause, and is deliberately not here.
"""

import io
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))

DEPLOY = os.path.join(HERE, "deploy.ps1")
MOD = (r"C:\Program Files (x86)\Steam\steamapps\common\Palworld"
       r"\Mods\NativeMods\UE4SS\Mods\PalWorkPriority")
TRIGGER = os.path.join(MOD, "remote.txt")
LOG = os.path.join(MOD, "priority.log")

SAVED = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Pal", "Saved")

# With the UI, since the panel is the only reason for taking one.
SNAP = "shot showui"


def newest_png(since):
    best, when = None, since
    for root, _dirs, names in os.walk(SAVED):
        for name in names:
            if not name.lower().endswith(".png"):
                continue
            full = os.path.join(root, name)
            stamp = os.path.getmtime(full)
            if stamp > when:
                best, when = full, stamp
    return best


def main(argv):
    words = [a for a in argv if a != "--no-deploy"]
    if not words:
        print(__doc__)
        return 2

    commands = [c.strip() for c in " ".join(words).split(",") if c.strip()]
    commands = [("cmd " + SNAP) if c == "snap" else c for c in commands]
    wants_snap = any(c == "cmd " + SNAP for c in commands)

    if "--no-deploy" not in argv:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-File", DEPLOY],
            capture_output=True, text=True)
        if result.returncode != 0:
            print("deploy failed:")
            print(result.stdout[-1200:])
            print(result.stderr[-1200:])
            return 1

    if not os.path.isdir(MOD):
        print("mod folder not found: " + MOD)
        return 2

    before_log = os.path.getsize(LOG) if os.path.exists(LOG) else 0
    before_time = time.time()

    io.open(TRIGGER, "w", encoding="utf-8").write(
        "%.3f\n%s\n" % (time.time(), "\n".join(commands)))
    print("sent: " + ", ".join(commands))

    # The mod looks once a second, and a screenshot takes a moment to reach
    # disk after the command asking for it.
    time.sleep(4.0 if wants_snap else 2.5)

    if os.path.exists(LOG):
        with io.open(LOG, "r", encoding="utf-8", errors="replace") as f:
            f.seek(before_log)
            fresh = f.read().strip()
        if fresh:
            print("")
            print(fresh)
        else:
            print("the log said nothing, so the mod is not running or the "
                  "world is not loaded yet")

    if wants_snap:
        shot = newest_png(before_time)
        print("")
        print("screenshot: " + (shot or "none appeared"))

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
