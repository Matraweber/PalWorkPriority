"""Run acknowledged scheduler passes; fail closed when the mod is inert.

Integration contract (implemented by main.lua, NOT this tool):
  request: pwp run <run-id> <request-id> <normal|sweep|dry>
  reply AFTER a successful, non-aborted scheduler pass:
    PWP_PASS run=<id> request=<n> pass=<distinct-id> session=<token>
             status=completed mode=<mode> camps=<positive-count> dry=<true|false>
  The reply is ONE log line. Rejected/aborted requests must use another status.
  The run/session/request fields must originate from that specific queued command.
  Sweep/dry overrides are per-request and must be restored even on failure.
  Normal/sweep require actual dry=false; dry mode requires actual dry=true.

This tool never deploys, changes persisted settings, or infers pass completion
from commands sent, ordinary tick logs, echo replies, or process liveness.
One command is outstanding at a time, avoiding remote.txt overwrite races.
A successful run demonstrates completed passes, not stutter-free gameplay.

  python tools/stress.py 240 --mode normal
  python tools/stress.py 240 --mode sweep --server
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

from paths import resolve

TOKEN = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MARKER = re.compile(r"(?:^|\[PalWorkPriority\]\s+)PWP_PASS\s+(.+)$")
FATAL = re.compile(r"Ref was not function|\[PalWorkPriority\]\s+ERROR\b")
MODES = ("normal", "sweep", "dry")


class StressFailure(RuntimeError):
    pass


@dataclass(frozen=True)
class Completion:
    run: str
    request: int
    pass_id: int
    session: str
    mode: str
    camps: int
    actual_dry: bool


class CompletionTracker:
    def __init__(self, run_id: str, mode: str):
        if not TOKEN.fullmatch(run_id) or mode not in MODES:
            raise ValueError("invalid run ID or mode")
        self.run_id, self.mode = run_id, mode
        self.session = None
        self.completed: dict[int, Completion] = {}
        self.pass_ids: set[int] = set()

    def consume(self, line: str, expected_request: int) -> Completion | None:
        match = MARKER.search(line.strip())
        if not match:
            return None
        fields = {}
        for pair in match.group(1).split():
            if "=" not in pair:
                raise StressFailure("malformed pass completion record")
            key, value = pair.split("=", 1)
            if key in fields:
                raise StressFailure("duplicate field in pass completion record")
            fields[key] = value
        # Old runs, periodic passes, and other observers cannot satisfy this run.
        if fields.get("run") != self.run_id:
            return None
        try:
            request, pass_id, camps = (int(fields[k]) for k in ("request", "pass", "camps"))
            session, mode, status = (fields[k] for k in ("session", "mode", "status"))
            dry = fields["dry"]
        except (KeyError, ValueError) as exc:
            raise StressFailure("incomplete pass completion record") from exc
        if dry not in ("true", "false") or (dry == "true") != (self.mode == "dry"):
            raise StressFailure("actual dry state does not match requested mode")
        actual_dry = dry == "true"
        if request != expected_request:
            # Duplicate delivery of an identical, already verified completion is harmless.
            old = self.completed.get(request)
            if old == Completion(self.run_id, request, pass_id, session, mode, camps, actual_dry) and status == "completed":
                return None
            raise StressFailure("completion does not match the outstanding request")
        if status != "completed" or camps <= 0:
            raise StressFailure(f"request {request} did not complete useful work: {status}, {camps} camps")
        if mode != self.mode or pass_id <= 0 or not TOKEN.fullmatch(session):
            raise StressFailure("invalid mode, pass ID, or session in completion")
        if self.session is not None and session != self.session:
            raise StressFailure("session changed during stress run")
        result = Completion(self.run_id, request, pass_id, session, mode, camps, actual_dry)
        if request in self.completed:
            if self.completed[request] != result:
                raise StressFailure("conflicting completion for the same request")
            return None
        if pass_id in self.pass_ids or (self.pass_ids and pass_id <= max(self.pass_ids)):
            raise StressFailure("pass IDs are not distinct and increasing")
        self.session = session
        self.completed[request] = result
        self.pass_ids.add(pass_id)
        return result


class LogTail:
    """Byte offsets exclude historical errors; truncation fails the evidence chain."""
    def __init__(self, path: Path):
        self.path = path
        self.offset = path.stat().st_size if path.exists() else 0
        self.pending = b""

    def read(self) -> list[str]:
        if not self.path.exists():
            if self.offset:
                raise StressFailure(f"log disappeared: {self.path}")
            return []
        if self.path.stat().st_size < self.offset:
            raise StressFailure(f"log rotated or truncated: {self.path}")
        with self.path.open("rb") as handle:
            handle.seek(self.offset)
            data = handle.read()
            self.offset = handle.tell()
        pieces = (self.pending + data).split(b"\n")
        self.pending = pieces.pop()
        return [line.decode("utf-8", "replace").rstrip("\r") for line in pieces]


def ps_literal(value) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def configured_executables(paths: dict, *, include_launcher=False) -> list[Path]:
    """Exact process images inside this installation; reject redirected targets."""
    root = Path(paths["root"]).resolve()
    family = "PalServer" if paths.get("server") else "Palworld"
    images = [root / "Pal" / "Binaries" / "Win64" / f"{family}-Win64-Shipping.exe"]
    if paths.get("server"):
        # The installed dedicated runtime also ships this exact headless image.
        images.append(root / "Pal" / "Binaries" / "Win64" / "PalServer-Win64-Shipping-Cmd.exe")
    if include_launcher:
        images.append(Path(paths.get("exe") or root / f"{family}.exe"))
    result = []
    for image in images:
        resolved = image.resolve()
        try:
            resolved.relative_to(root)
        except ValueError as exc:
            raise StressFailure("configured executable is outside the test installation") from exc
        result.append(resolved)
    return result


def query_processes(command: str) -> str:
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
        capture_output=True, text=True, timeout=15,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode:
        raise StressFailure(result.stderr.strip() or "process enumeration failed")
    return result.stdout.strip()


def select_processes(executables: list[Path], *, query=None) -> list[dict]:
    """Shared read-only selector. A name narrows discovery, never proves ownership."""
    allowed = {str(path.resolve()).casefold() for path in executables}
    names = sorted({path.stem for path in executables})
    if not allowed:
        raise StressFailure("no configured executable identity")
    name_array = "@(" + ",".join(ps_literal(name) for name in names) + ")"
    command = """
$ErrorActionPreference = 'Stop'
$selectedRows = @()
$candidateProcesses = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -in __NAMES__ })
foreach ($candidateProcess in $candidateProcesses) {
    $row = @{pid=$candidateProcess.Id; path=$null; started_ticks=$null; alive=$null}
    try { $row.path=$candidateProcess.Path } catch {}
    try { $row.started_ticks=[string]$candidateProcess.StartTime.ToUniversalTime().Ticks } catch {}
    try { $candidateProcess.Refresh(); $row.alive= -not $candidateProcess.HasExited } catch {}
    $selectedRows += $row
}
ConvertTo-Json -InputObject @($selectedRows) -Depth 3 -Compress
""".replace("__NAMES__", name_array)
    try:
        rows = json.loads((query or query_processes)(command))
    except (ValueError, TypeError) as exc:
        raise StressFailure("invalid process enumeration; ownership is unverified") from exc
    if not isinstance(rows, list):
        raise StressFailure("incomplete process enumeration; ownership is unverified")
    selected, seen = [], set()
    for row in rows:
        if not isinstance(row, dict):
            raise StressFailure("malformed process identity")
        if row.get("alive") is False:
            continue
        path = row.get("path")
        if not isinstance(path, str) or not path or not Path(path).is_absolute():
            raise StressFailure("process executable path unavailable; ownership is unverified")
        if str(Path(path).resolve()).casefold() not in allowed:
            continue
        pid, started = row.get("pid"), row.get("started_ticks")
        if (row.get("alive") is not True or type(pid) is not int or pid <= 0
                or not isinstance(started, str) or not re.fullmatch(r"[0-9]{1,19}", started)
                or int(started) <= 0 or pid in seen):
            raise StressFailure("process liveness/start identity unavailable or ambiguous")
        seen.add(pid)
        selected.append(row)
    return selected


def process_up(paths: dict) -> bool:
    # Only the game/server image qualifies, never a launcher or another installation.
    return bool(select_processes(configured_executables(paths)))


def send_request(trigger: Path, run_id: str, request: int, mode: str) -> None:
    if not trigger.is_file():
        raise StressFailure("remote.txt is missing; enable the developer channel before restarting")
    nonce = f"{run_id}-{request}"
    temporary = trigger.with_name(trigger.name + ".stress-" + run_id + ".tmp")
    payload = f"{nonce}\npwp run {run_id} {request} {mode}\n"
    try:
        temporary.write_text(payload, encoding="utf-8", newline="\n")
        os.replace(temporary, trigger)
    finally:
        temporary.unlink(missing_ok=True)


def run_protocol(*, duration: float, ack_timeout: float, minimum_passes: int,
                 tracker: CompletionTracker, send, read_lines, alive,
                 clock=time.monotonic, sleep=time.sleep) -> dict:
    if not math.isfinite(duration) or not math.isfinite(ack_timeout) or duration <= 0 or ack_timeout <= 0 or minimum_passes < 1:
        raise ValueError("duration, acknowledgement timeout and minimum passes must be positive")
    started, request = clock(), 0
    while clock() - started < duration:
        if not alive():
            raise StressFailure("game/server process is not running")
        request += 1
        send(tracker.run_id, request, tracker.mode)
        deadline = clock() + ack_timeout
        acknowledged = False
        while clock() < deadline:
            if not alive():
                raise StressFailure(f"process exited while request {request} was outstanding")
            for line in read_lines():
                if FATAL.search(line):
                    raise StressFailure("new runtime/mod error during stress: " + line[:300])
                completion = tracker.consume(line, request)
                acknowledged = acknowledged or completion is not None
            if acknowledged:
                break
            sleep(min(0.25, max(0, deadline - clock())))
        if not acknowledged:
            raise StressFailure(f"no completed pass for request {request} within {ack_timeout:g}s; mod may be inert")
        # Let the game advance between passes, never batch several into one callback.
        sleep(1.05)
    completed = len(tracker.completed)
    if completed < minimum_passes:
        raise StressFailure(f"only {completed} verified passes; need at least {minimum_passes}")
    if not alive():
        raise StressFailure("process exited before the final health check")
    # The last 1.05s belongs to the observation window too. Drain errors and
    # conflicting/replayed acknowledgements before recording a successful run.
    for line in read_lines():
        if FATAL.search(line):
            raise StressFailure("new runtime/mod error during stress: " + line[:300])
        tracker.consume(line, request)
    if not alive():
        raise StressFailure("process exited during the final health check")
    return {
        "run": tracker.run_id, "session": tracker.session, "mode": tracker.mode,
        "actual_dry": next(iter(tracker.completed.values())).actual_dry,
        "elapsed_seconds": clock() - started, "commands_sent": request,
        "completed_passes": completed, "pass_ids": sorted(tracker.pass_ids),
        "evidence": "command-bound completion records; frame times not measured",
    }


def main(argv=None) -> int:
    paths, argv = resolve(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("seconds", nargs="?", type=float, default=240)
    parser.add_argument("--mode", choices=MODES, default="normal")
    parser.add_argument("--ack-timeout", type=float, default=15)
    parser.add_argument("--min-passes", type=int, default=3)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)
    run_id = uuid.uuid4().hex
    try:
        trigger = Path(paths["remote"])
        if not trigger.is_file():
            raise StressFailure("remote.txt must exist before game startup; no command was sent")
        tails = [LogTail(Path(paths["log"])), LogTail(Path(paths["ue4ss_log"]))]
        # Read completions from priority.log only. UE4SS mirrors the same record.
        def lines():
            primary = tails[0].read()
            secondary = tails[1].read()
            return primary + [line for line in secondary if FATAL.search(line)]

        result = run_protocol(
            duration=args.seconds, ack_timeout=args.ack_timeout, minimum_passes=args.min_passes,
            tracker=CompletionTracker(run_id, args.mode),
            send=lambda run, request, mode: send_request(trigger, run, request, mode),
            read_lines=lines, alive=lambda: process_up(paths),
        )
        result["status"] = "passed"
        code = 0
    except (StressFailure, OSError, ValueError, subprocess.SubprocessError) as exc:
        result = {"run": run_id, "status": "failed", "reason": str(exc)}
        code = 1
    output = json.dumps(result, indent=2, sort_keys=True)
    print(output)
    if args.report:
        args.report.write_text(output + "\n", encoding="utf-8")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
