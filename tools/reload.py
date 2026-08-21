"""Drive the running game from outside it.

    python tools/reload.py                 deploy, then reload the UI modules
    python tools/reload.py open snap       open the panel and photograph it
    python tools/reload.py close
    python tools/reload.py cmd stat fps

No restart, no keypress, no UE4SS hot reload. The mod watches a trigger file
next to its log; this writes it, waits, and prints whatever the mod said in
response.

Why a file and not a key: while the panel holds the input mode UE4SS never
sees a key press, which is precisely when the panel is the thing being worked
on. A file can be written from outside at any moment.

Why the game photographs itself: the alternative is asking a person to alt tab
and screenshot, and alt tabbing is what stops the game ticking. "snap" runs a
console command in the game and a png appears next to the save data, which
this then finds and reports.

What is never reloaded matters as much as what is. Only panel.lua and
overlay.lua are swapped. A registered hook cannot be unregistered, so the
scheduler, the demand hooks and the transport are left alone; swapping those
would give the game two of each rather than a fresh one.
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
TRIGGER = os.path.join(MOD, "reload.trigger")
LOG = os.path.join(MOD, "priority.log")

SAVED = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Pal", "Saved")

# UI capture rather than a plain screenshot: without showui the panel, which
# is the only reason for taking one, is the one thing missing from it.
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
    commands = " ".join(words).split(",") if words else ["reload"]
    commands = [c.strip() for c in commands if c.strip()]

    # "snap" is shorthand, so the console command lives in one place.
    commands = [("cmd " + SNAP) if c == "snap" else c for c in commands]
    wants_snap = any(c.startswith("cmd " + SNAP) for c in commands)

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

    before_log = os.path.getsize(LOG) if os.path.exists(LOG) else 0
    before_time = time.time()

    # The nonce first, so writing the same command twice still registers as a
    # change, then one instruction per line.
    body = "%.3f\n%s\n" % (time.time(), "\n".join(commands))
    io.open(TRIGGER, "w", encoding="utf-8").write(body)
    print("sent: " + ", ".join(commands))

    # The mod looks once a second, and a screenshot takes a moment to reach
    # disk after the command that asks for it.
    time.sleep(4.0 if wants_snap else 2.5)

    if os.path.exists(LOG):
        with io.open(LOG, "r", encoding="utf-8", errors="replace") as f:
            f.seek(before_log)
            fresh = f.read().strip()
        if fresh:
            print("")
            print(fresh)
        else:
            print("the log said nothing, so the game is probably not running")

    if wants_snap:
        shot = newest_png(before_time)
        print("")
        print("screenshot: " + (shot or "none appeared"))

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
