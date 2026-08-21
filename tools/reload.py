"""Deploy the Lua and tell the running game to pick it up.

    python tools/reload.py

No restart, no keypress, no UE4SS hot reload. The mod watches a trigger file
next to its log and swaps its two UI modules when the contents change; this
writes that file.

Why a file and not a key: while the panel holds the input mode UE4SS never
sees a key press, which is precisely when the panel is the thing being worked
on. A file can be written from outside the game at any moment, including while
the panel is open and eating everything.

What this does not reload is as important as what it does. Only panel.lua and
overlay.lua are swapped. A registered hook cannot be unregistered, so the
scheduler, the demand hooks and the network transport are left alone; swapping
those would give the game two of each rather than a fresh one.
"""

import io
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DEPLOY = os.path.join(HERE, "deploy.ps1")
MOD = (r"C:\Program Files (x86)\Steam\steamapps\common\Palworld"
       r"\Mods\NativeMods\UE4SS\Mods\PalWorkPriority")
TRIGGER = os.path.join(MOD, "reload.trigger")
LOG = os.path.join(MOD, "priority.log")


def main(argv):
    # Deploy first. Triggering a reload of code that has not been copied in
    # yet reloads the previous version, which looks exactly like the edit
    # having no effect.
    if "--no-deploy" not in argv:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-File", DEPLOY],
            capture_output=True, text=True)
        if result.returncode != 0:
            print("deploy failed:")
            print(result.stdout[-1500:])
            print(result.stderr[-1500:])
            return 1
        print("deployed")

    if not os.path.isdir(MOD):
        print("mod folder not found: " + MOD)
        return 2

    # Where the log had got to, so the lines this reload produces can be told
    # apart from everything before it.
    before = os.path.getsize(LOG) if os.path.exists(LOG) else 0

    io.open(TRIGGER, "w", encoding="utf-8").write(
        "%.3f\n" % time.time())
    print("triggered")

    # The mod looks once a second. Waiting a little longer than that and then
    # reading what it said is the whole point: a reload that failed to compile
    # says so in the log, and finding that out now is far cheaper than finding
    # it out from a screenshot of an unchanged panel.
    time.sleep(2.5)

    if not os.path.exists(LOG):
        print("no log yet")
        return 0

    with io.open(LOG, "r", encoding="utf-8", errors="replace") as f:
        f.seek(before)
        fresh = f.read().strip()

    if fresh:
        print("")
        print(fresh)
    else:
        print("the log said nothing, so the game is probably not running")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
