"""Hold one FTP login open so an agent can drive the server without the password.

You run this in your own terminal and type the login once; it stays connected
and carries out a fixed set of actions queued in a file. The password lives only
in this process's memory (used to reconnect) and is never written or printed.

    python tools/ftp_session.py [--tls]

Queue: test-results/ftp-session/queue.txt, one line per request:
    <id> ls <remote dir>
    <id> tail <remote file> <bytes>         last bytes of a file (logs)
    <id> get <remote file>                  whole file, at most 5 MB
    <id> install <zip> <tag>                ftp_deploy_server install (backup + readback)
    <id> rollback <backup name>
    <id> quit
Results: test-results/ftp-session/out/<id>.txt (and <id>.bin for get/tail).
Lines already in the queue when this starts are ignored, never replayed.
Anything else is refused. Ctrl+C ends the session.
"""
import argparse
import ftplib
import getpass
import io
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ftp_deploy_server as deploy  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
HOME = ROOT / "test-results" / "ftp-session"
QUEUE = HOME / "queue.txt"
OUT = HOME / "out"
ZIP_DIRS = [Path(r"D:\PalWorkPriority-backups\server-upload").resolve(), ROOT.resolve()]
GET_LIMIT = 5 * 1024 * 1024


class Session:
    def __init__(self, tls):
        self.tls = tls
        self.host = input("FTP host (from the GPortal panel): ").strip()
        self.port = int(input("FTP port [21]: ").strip() or "21")
        self.user = input("FTP user: ").strip()
        self._pw = getpass.getpass("FTP password (hidden): ")
        self.ftp = None
        self.connect()

    def connect(self):
        ftp = ftplib.FTP_TLS(timeout=30) if self.tls else ftplib.FTP(timeout=30)
        ftp.connect(self.host, self.port)
        ftp.login(self.user, self._pw)
        if self.tls:
            ftp.prot_p()
        self.ftp = ftp

    def call(self, fn):
        try:
            return fn(self.ftp)
        except (ftplib.error_temp, OSError, EOFError):
            self.connect()  # one reconnect, then let the error surface
            return fn(self.ftp)


def zip_allowed(path):
    p = Path(path).resolve()
    return p.suffix == ".zip" and p.is_file() and any(d in p.parents for d in ZIP_DIRS)


def tail(ftp, path, nbytes):
    size = ftp.size(path)
    start = max(0, size - nbytes)
    buf = io.BytesIO()
    ftp.retrbinary("RETR " + path, buf.write, rest=start)
    return buf.getvalue()[-nbytes:], size


def handle(session, rid, op, args):
    lines = []
    say = lines.append
    ok = True
    if op == "ls" and len(args) == 1:
        say("\n".join(sorted(session.call(lambda f: deploy.names(f, args[0])))))
    elif op == "tail" and len(args) == 2 and args[1].isdigit():
        data, size = session.call(lambda f: tail(f, args[0], min(int(args[1]), GET_LIMIT)))
        (OUT / f"{rid}.bin").write_bytes(data)
        say(f"size {size}, wrote last {len(data)} bytes to {rid}.bin")
    elif op == "get" and len(args) == 1:
        size = session.call(lambda f: f.size(args[0]))
        if size > GET_LIMIT:
            ok = False
            say(f"refused: {size} bytes is over the 5 MB limit; use tail")
        else:
            data = session.call(lambda f: deploy.fetch(f, args[0]))
            (OUT / f"{rid}.bin").write_bytes(data)
            say(f"wrote {len(data)} bytes to {rid}.bin")
    elif op == "install" and len(args) == 2:
        if not zip_allowed(args[0]):
            ok = False
            say("refused: zip must be an existing .zip under the server-upload folder or the repo")
        else:
            files = deploy.lua_files(args[0])
            say(f"{len(files)} Lua files from {args[0]}")
            ok = session.call(lambda f: deploy.do_install(f, files, args[1], say=say))
    elif op == "rollback" and len(args) == 1:
        ok = session.call(lambda f: deploy.do_rollback(f, args[0], say=say))
    else:
        ok = False
        say(f"refused: unknown or malformed request '{op} {' '.join(args)}'")
    status = "OK" if ok else "FAILED"
    (OUT / f"{rid}.txt").write_text(status + "\n" + "\n".join(lines) + "\n", encoding="utf-8")
    print(f"[{time.strftime('%H:%M:%S')}] {rid} {op}: {status}")


def main():
    p = argparse.ArgumentParser(description="Hold an FTP login open for queued server actions.")
    p.add_argument("--tls", action="store_true")
    a = p.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    QUEUE.touch()
    seen = len(QUEUE.read_text(encoding="utf-8").splitlines())  # never replay old requests
    session = Session(a.tls)
    print(f"connected. Watching {QUEUE} (Ctrl+C to stop)")
    last_noop = time.time()
    while True:
        rows = QUEUE.read_text(encoding="utf-8").splitlines()
        for row in rows[seen:]:
            parts = row.split()
            if len(parts) >= 2:
                rid, op, args = parts[0], parts[1], parts[2:]
                if op == "quit":
                    (OUT / f"{rid}.txt").write_text("OK\nsession closed\n", encoding="utf-8")
                    session.ftp.quit()
                    print("quit requested, session closed")
                    return
                try:
                    handle(session, rid, op, args)
                except Exception as e:  # report, keep the session alive
                    (OUT / f"{rid}.txt").write_text(f"FAILED\n{type(e).__name__}: {e}\n", encoding="utf-8")
                    print(f"{rid} {op}: error {type(e).__name__}")
        seen = len(rows)
        if time.time() - last_noop > 30:
            try:
                session.ftp.voidcmd("NOOP")
            except Exception:
                session.connect()
            last_noop = time.time()
        time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("stopped")
