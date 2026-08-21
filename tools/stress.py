"""Drive the chest sweep as hard as the command channel allows.

    python tools/stress.py            240 seconds of hammering
    python tools/stress.py 600

The sweep crashed once in twenty seven minutes at its normal rate, which is not
a rate anything can be tested against. This sets the stock interval to zero so
every pass sweeps, then forces passes continuously.

Passes are spaced about a second apart on purpose rather than fired in a batch.
The fault being hunted is a chest's slot array changing while it is read, so
the game needs time between sweeps for pals to actually deposit something. A
burst inside one frame races nothing.

Reports first blood: the crash, its breadcrumb, and how many sweeps it took.
"""

import io
import os
import re
import subprocess
import sys
import time

MOD = (r"C:\Program Files (x86)\Steam\steamapps\common\Palworld"
       r"\Mods\NativeMods\UE4SS\Mods\PalWorkPriority")
TRIGGER = os.path.join(MOD, "remote.txt")
LOG = os.path.join(MOD, "priority.log")
TRACE = os.path.join(MOD, "trace.txt")
U = (r"C:\Program Files (x86)\Steam\steamapps\common\Palworld"
     r"\Mods\NativeMods\UE4SS\UE4SS.log")
CRASHES = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Pal", "Saved", "Crashes")

PER_POLL = 3          # passes per write; the mod reads the file once a second


def read(p):
    try:
        return io.open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def up():
    return subprocess.run(
        ["powershell.exe", "-NoProfile", "-Command",
         "if (Get-Process Palworld* -ErrorAction SilentlyContinue) {'y'} else {'n'}"],
        capture_output=True, text=True).stdout.strip().endswith("y")


def send(lines):
    io.open(TRIGGER, "w", encoding="utf-8").write(
        "%.3f\n%s\n" % (time.time(), "\n".join(lines)))


def newest_crash():
    best, when = None, 0
    if os.path.isdir(CRASHES):
        for n in os.listdir(CRASHES):
            f = os.path.join(CRASHES, n)
            if os.path.isdir(f) and os.path.getmtime(f) > when:
                best, when = f, os.path.getmtime(f)
    return best, when


def main(argv):
    limit = int(argv[0]) if argv else 240
    if not up():
        print("the game is not running")
        return 2

    start = time.time()
    send(["pwp sweep 0"])
    time.sleep(2.0)
    print("sweep interval set to 0; forcing passes for up to %ds" % limit)
    print("(the mod reads the trigger once a second, so this is roughly "
          "%d passes a second)" % PER_POLL)
    sys.stdout.flush()

    sent = 0
    while time.time() - start < limit:
        send(["pwp run"] * PER_POLL)
        sent += PER_POLL
        time.sleep(1.05)

        if not up():
            el = int(time.time() - start)
            print("")
            print("=== game gone after %ds, ~%d passes forced ===" % (el, sent))
            print("breadcrumb: " + read(TRACE).strip())
            where, when = newest_crash()
            if where and when > start:
                m = re.search(r"<ErrorMessage>(.*?)</ErrorMessage>",
                              read(os.path.join(where, "CrashContext.runtime-xml")), re.S)
                print("CRASHED: " + (m.group(1).strip() if m else "?"))
            else:
                print("no crash dump newer than this run, so it was closed")
            return 1

        if "Ref was not function" in read(U):
            print("")
            print("ref error after %ds, ~%d passes" % (int(time.time()-start), sent))
            return 1

    print("")
    print("=== survived %ds, ~%d passes forced, every one sweeping ===" % (limit, sent))
    ticks = len(re.findall(r"INFO (?:tick|manual|world load):", read(U)))
    print("passes in the log this session: %d" % ticks)
    print("breadcrumb: " + read(TRACE).strip())
    print("")
    print("normal rate is one sweep per thirty seconds, so this is worth "
          "roughly %d minutes of ordinary play" % int(sent * 30 / 60))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
