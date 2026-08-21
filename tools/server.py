"""Run the headless test server.

    python tools/server.py start      boot it, wait for the mod to come up
    python tools/server.py stop
    python tools/server.py status
    python tools/server.py freshworld re-copy the singleplayer world (server off)

The server loads the world at boot with no title screen and no person, which
is the whole point: the scheduler, the hooks and the crash all live server
side, so the entire test loop runs without anyone at a keyboard. The client
is only needed to look at the panel.

The world is a copy of the singleplayer save; the original is never written.
"""

import io
import os
import re
import shutil
import subprocess
import sys
import time

from paths import resolve

SP_WORLD = (r"C:\Users\user\AppData\Local\Pal\Saved\SaveGames"
            r"\STEAMID64\31141B9948FE8B9A8B4CC399974DDDF1")


def ps(cmd):
    return subprocess.run(["powershell.exe", "-NoProfile", "-Command", cmd],
                          capture_output=True, text=True).stdout.strip()


def running(p):
    return ps("if (Get-Process %s -ErrorAction SilentlyContinue) {'y'} else {'n'}"
              % p["process"]).endswith("y")


def read(path):
    try:
        return io.open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def start(p):
    if running(p):
        print("already running")
        return 0
    # Truncate the mod log so "this session" is unambiguous.
    try:
        io.open(p["log"], "w").close()
    except OSError:
        pass
    ps("Start-Process -FilePath '%s' -WorkingDirectory '%s'"
       % (p["exe"], p["root"]))
    print("server starting...")
    for _ in range(60):
        time.sleep(5)
        log = read(p["log"])
        if "loaded (enabled" in log:
            print("mod is up:")
            for ln in log.splitlines()[-3:]:
                print("  " + ln)
            return 0
        if not running(p):
            print("server process exited during boot; UE4SS.log tail:")
            for ln in read(p["ue4ss_log"]).splitlines()[-8:]:
                print("  " + ln)
            return 1
    print("timed out waiting for the mod to announce itself; log tail:")
    for ln in read(p["ue4ss_log"]).splitlines()[-8:]:
        print("  " + ln)
    return 1


def stop(p):
    ps("Get-Process %s -ErrorAction SilentlyContinue | Stop-Process -Force"
       % p["process"])
    time.sleep(2)
    print("stopped" if not running(p) else "still running")
    return 0


def status(p):
    up = running(p)
    print("server: " + ("running" if up else "not running"))
    if up:
        log = read(p["log"])
        for ln in log.splitlines()[-5:]:
            print("  " + ln)
        print("trace: " + read(p["trace"]).strip())
    return 0


def freshworld(p):
    if running(p):
        print("stop the server first")
        return 1
    dst = os.path.join(p["root"], "Pal", "Saved", "SaveGames", "0",
                       os.path.basename(SP_WORLD))
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(SP_WORLD, dst)
    print("world re-copied from the singleplayer save (original untouched)")
    return 0


def main(argv):
    p, argv = resolve(argv)
    p, _ = resolve(["--server"])   # this tool is always about the server
    verb = argv[0] if argv else "status"
    return {"start": start, "stop": stop, "status": status,
            "freshworld": freshworld}.get(verb, status)(p)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
