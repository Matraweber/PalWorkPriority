"""Run the headless test server.

    python tools/server.py start      boot it, wait for the mod to come up
    python tools/server.py stop       graceful local REST shutdown; never force kill
    python tools/server.py status
    python tools/server.py freshworld re-copy the singleplayer world (server off)

The server loads the world at boot with no title screen and no person, which
is the whole point: the scheduler, the hooks and the crash all live server
side, so the entire test loop runs without anyone at a keyboard. The client
is only needed to look at the panel.

The world is a copy of the singleplayer save; the original is never written.
"""

import glob
import io
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
import re
import uuid

from paths import resolve
from stress import LogTail, StressFailure, configured_executables, select_processes

# Found rather than written down.
#
# This used to be one developer's own save path, which carried their Windows
# user name and their SteamID64 into a public repository. Neither belongs in a
# file anyone else clones. The newest world under the local save directory is
# what someone running this wants anyway - it is the one they were just
# playing - and PWP_SP_WORLD overrides when it is not.
def _newest_sp_world():
    root = os.path.join(os.environ.get("LOCALAPPDATA", ""),
                        "Pal", "Saved", "SaveGames")
    best, best_at = None, -1
    for account in glob.glob(os.path.join(root, "*")):
        for world in glob.glob(os.path.join(account, "*")):
            level = os.path.join(world, "Level.sav")
            if not os.path.isfile(level):
                continue
            at = os.path.getmtime(level)
            if at > best_at:
                best, best_at = world, at
    return best


SP_WORLD = os.environ.get("PWP_SP_WORLD") or _newest_sp_world()


def ps(cmd):
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", cmd],
                            capture_output=True, text=True, timeout=15,
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "server control command failed")
    return result.stdout.strip()


def quoted(value):
    return "'" + str(value).replace("'", "''") + "'"


def running(p):
    return bool(server_processes(p))


def server_processes(p):
    return select_processes(configured_executables(dict(p, server=True), include_launcher=True), query=ps)


def read(path):
    try:
        return io.open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def wait_ready(tail, alive, timeout=300, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    while clock() < deadline:
        if not alive():
            raise StressFailure("server process exited before authority readiness")
        for line in tail.read():
            if "PWP_READY " not in line:
                continue
            fields = dict(pair.split("=", 1) for pair in line.split("PWP_READY ", 1)[1].split() if "=" in pair)
            if fields.get("role") != "authority" or fields.get("settings") != "available":
                raise StressFailure("server could not prove authority and available settings")
            if not fields.get("session", "").isdigit() or not fields.get("version"):
                raise StressFailure("malformed readiness marker")
            return fields
        sleep(min(1, max(0, deadline-clock())))
    raise StressFailure("no new authority-ready marker; a Lua boot banner is insufficient")


def start(p):
    try:
        if running(p):
            print("already running; fresh authority readiness is unverified")
            return 1
        # Do not start a test we already know cannot request normal shutdown.
        # Live listener ownership and process exit are still checked by stop().
        from server_control import rest_config
        rest_config(p["root"])
        # Keep history and consume only bytes appended after this launch.
        tail = LogTail(Path(p["log"]))
        ps("Start-Process -WindowStyle Hidden -FilePath %s -WorkingDirectory %s -ErrorAction Stop"
           % (quoted(p["exe"]), quoted(p["root"])))
        print("server starting...")
        ready = wait_ready(tail, lambda: running(p))
        # A launcher alone cannot establish that the server is still alive.
        if not select_processes(configured_executables(dict(p, server=True)), query=ps):
            raise StressFailure("server image is not running after the readiness marker")
        print("authority ready, version %s, session %s; run stress to verify completed passes"
              % (ready["version"], ready["session"]))
        return 0
    except (StressFailure, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        print("server acceptance failed: " + str(exc))
        return 1


def stop(p):
    from server_control import graceful_stop
    try:
        targets = server_processes(p)
        graceful_stop(p, targets, processes=lambda: server_processes(p), shell=ps)
        print("graceful server exit observed; verify saved data separately" if targets else "already stopped")
        return 0
    except (StressFailure, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        print("server stop failed: " + str(exc))
        return 1


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
    if not SP_WORLD or not (Path(SP_WORLD) / "Level.sav").is_file():
        raise ValueError("no valid singleplayer source world found")
    base = (Path(p["root"]) / "Pal" / "Saved" / "SaveGames" / "0").resolve()
    base.mkdir(parents=True, exist_ok=True)
    source = Path(SP_WORLD).resolve()
    dst = (base / source.name).resolve()
    if dst.parent != base or dst == source or base in source.parents:
        raise ValueError("world target/source is outside the isolated copy contract")
    suffix = uuid.uuid4().hex
    staging, backup = base / (".copy-" + suffix), base / (dst.name + ".backup-" + suffix)
    shutil.copytree(source, staging)
    if dst.exists():
        dst.rename(backup)
    try:
        staging.rename(dst)
    except OSError:
        if backup.exists() and not dst.exists():
            backup.rename(dst)
        raise
    print("world copied; source unchanged and any previous test world retained as a backup")
    return 0


def main(argv):
    p, argv = resolve(argv)
    p, _ = resolve(["--server"])   # this tool is always about the server
    verb = argv[0] if argv else "status"
    return {"start": start, "stop": stop, "status": status,
            "freshworld": freshworld}.get(verb, status)(p)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
