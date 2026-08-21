"""Wait for the game to die and say what it was in the middle of.

    python tools/watch.py

Waits for Palworld to appear, waits for it to go, then reports the breadcrumb
that was in flight, whether a crash dump was written, and what the mod said
last. The point is that a crash reports itself rather than needing somebody to
notice it and describe it.

A dump newer than the moment the game started is a crash. A dump older than
that is the previous one still sitting there, and saying so is the difference
between evidence and a guess.
"""

import io
import os
import re
import subprocess
import sys
import time

MOD = (r"C:\Program Files (x86)\Steam\steamapps\common\Palworld"
       r"\Mods\NativeMods\UE4SS\Mods\PalWorkPriority")
LOG = os.path.join(MOD, "priority.log")
TRACE = os.path.join(MOD, "trace.txt")
CRASHES = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Pal", "Saved", "Crashes")


def running():
    out = subprocess.run(
        ["powershell.exe", "-NoProfile", "-Command",
         "if (Get-Process Palworld* -ErrorAction SilentlyContinue) { 'y' } else { 'n' }"],
        capture_output=True, text=True).stdout.strip()
    return out.endswith("y")


def read(path):
    try:
        with io.open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def newest_crash():
    best, when = None, 0
    if os.path.isdir(CRASHES):
        for name in os.listdir(CRASHES):
            full = os.path.join(CRASHES, name)
            if os.path.isdir(full) and os.path.getmtime(full) > when:
                best, when = full, os.path.getmtime(full)
    return best, when


def main():
    waited = 0
    while not running():
        time.sleep(5)
        waited += 5
        if waited > 3600:
            print("the game never started")
            return 1

    started = time.time()
    print("game is up at " + time.strftime("%H:%M:%S"))
    sys.stdout.flush()

    while running():
        time.sleep(3)

    gone = time.time()
    print("")
    print("=== gone at " + time.strftime("%H:%M:%S", time.localtime(gone)) +
          ", after " + str(int(gone - started)) + "s ===")
    print("")
    print("breadcrumb in flight: " + (read(TRACE) or "(empty)"))
    print("")

    where, when = newest_crash()
    if where and when > started:
        print("CRASHED. dump at " + time.strftime("%H:%M:%S", time.localtime(when)))
        xml = os.path.join(where, "CrashContext.runtime-xml")
        m = re.search(r"<ErrorMessage>(.*?)</ErrorMessage>", read(xml), re.S)
        if m:
            print("  " + m.group(1).strip())
        print("  " + where)
    else:
        print("no dump newer than this run, so it was closed rather than crashed")

    print("")
    print("last of the mod log:")
    for line in read(LOG).splitlines()[-6:]:
        print("  " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
