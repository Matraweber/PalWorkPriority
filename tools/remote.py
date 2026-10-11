"""Drive the panel in the running game, from outside it.

    python tools/remote.py open
    python tools/remote.py open,snap
    python tools/remote.py "mode item,snap"
    python tools/remote.py close
    python tools/remote.py cmd stat fps

Writes an instruction to an already-enabled developer channel, then prints
new log output. This does NOT deploy code by default. Use --deploy explicitly
to run the checked deployment step. --no-deploy remains accepted for older
test instructions. Log output is not a command-bound completion receipt;
use stress.py to verify scheduler passes.

    python tools/remote.py reload

swaps panel, overlay and icons in the running game. Those three register no
hooks and hold no timers, which is what makes them safe to replace; a change
to anything else still needs the game restarted.

This docstring used to say the opposite, that reloading was deliberately not
here. That was true of the version which swapped modules on its own whenever a
file changed - never proved safe, and blamed twice for faults it did not
cause. What replaced it only ever reloads because a command asked it to.
"""

import io
import os
import subprocess
import sys
import time
import uuid

from paths import resolve

HERE = os.path.dirname(os.path.abspath(__file__))

DEPLOY = os.path.join(HERE, "deploy.ps1")
P, _ = resolve(sys.argv[1:])
MOD = P["mod"]
TRIGGER = P["remote"]
LOG = P["log"]

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
    argv = [a for a in argv if a != "--server"]
    if "--deploy" in argv and "--no-deploy" in argv:
        print("choose either --deploy or --no-deploy")
        return 2
    words = [a for a in argv if a not in ("--no-deploy", "--deploy")]
    if not words:
        print(__doc__)
        return 2

    commands = [c.strip() for c in " ".join(words).split(",") if c.strip()]
    commands = [("cmd " + SNAP) if c == "snap" else c for c in commands]
    wants_snap = any(c == "cmd " + SNAP for c in commands)

    if "--deploy" in argv:
        cmd = ["powershell.exe", "-NoProfile", "-File", DEPLOY]
        if P["server"]:
            cmd += ["-GamePath", P["root"]]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print("deploy failed:")
            print(result.stdout[-1200:])
            print(result.stderr[-1200:])
            return 1

    if not os.path.isdir(MOD):
        print("mod folder not found: " + MOD)
        return 2

    if not os.path.isfile(TRIGGER):
        print("remote.txt must exist before game startup to enable the developer channel; no command was sent")
        return 2

    before_log = os.path.getsize(LOG) if os.path.exists(LOG) else 0
    before_time = time.time()

    temporary = TRIGGER + '.' + uuid.uuid4().hex + '.tmp'
    try:
        with io.open(temporary, "w", encoding="utf-8", newline="\n") as handle:
            handle.write("%s\n%s\n" % (uuid.uuid4().hex, "\n".join(commands)))
        os.replace(temporary, TRIGGER)
    finally:
        if os.path.exists(temporary): os.remove(temporary)
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
            return 1
    else:
        print("no mod log appeared; execution is unverified")
        return 1

    if wants_snap:
        shot = newest_png(before_time)
        print("")
        print("screenshot: " + (shot or "none appeared"))

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
