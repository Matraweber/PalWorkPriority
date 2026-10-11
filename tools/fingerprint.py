"""Read-only candidate/source/install/process identities; JSON goes to stdout.

No deployment, game launch, command trigger, save access or network operation.
A mapped UE4SS module proves a process/module path at observation time. Its file
hash is an ON-DISK hash, never a claimed hash of the loaded memory image.
Logs are historical/unbound observations, even when their timestamps are recent.

  python tools/fingerprint.py
  python tools/fingerprint.py --server
  python tools/fingerprint.py --candidate build/release/PalWorkPriority-0.5.0-rc1-manual.zip
  python tools/fingerprint.py --game-root D:/Games/Palworld --workshop-root D:/Steam/steamapps/workshop/content/1623730
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import zipfile

sys.dont_write_bytecode = True
from paths import resolve

MOD = "PalWorkPriority"
WORKSHOP_ID = "3786408856"
DEPENDENCY_ID = "3625223587"
MANUAL_ROOT = f"Mods/NativeMods/UE4SS/Mods/{MOD}/"
MAX_TEXT = 8 * 1024 * 1024
MAX_MEMBERS = 512
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
VERSION = re.compile(r'\blocal\s+VERSION\s*=\s*["\']([^"\']+)["\']')
BANNER = re.compile(r"\[PalWorkPriority\]\s+Pal Work Priority\s+([A-Za-z0-9_.-]+)\s+loaded\b")
STAMP = re.compile(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?:\.(\d+))?")


def utc(seconds: float | None) -> str | None:
    if seconds is None:
        return None
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_identity(path: Path) -> dict:
    result = {"path": str(path.absolute()), "state": "unknown"}
    try:
        if path.is_symlink():
            return {**result, "state": "symlink_not_followed"}
        with path.open("rb") as handle:
            before = os.fstat(handle.fileno())
            checksum = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                checksum.update(chunk)
            after = os.fstat(handle.fileno())
        current = path.stat()
        signature = lambda stat: (stat.st_size, stat.st_mtime_ns, stat.st_ino)
        if signature(before) != signature(after) or signature(after) != signature(current):
            return {**result, "state": "changed_during_read"}
        return {**result, "state": "present", "bytes": after.st_size,
                "modified_utc": utc(after.st_mtime), "sha256": checksum.hexdigest()}
    except FileNotFoundError:
        return {**result, "state": "absent"}
    except OSError as exc:
        return {**result, "state": "unreadable", "error": str(exc)}


def text_file(path: Path, limit=MAX_TEXT) -> str | None:
    try:
        if path.is_symlink() or path.stat().st_size > limit:
            return None
        return path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return None


def version_info(text: str | None) -> str | None:
    try:
        data = json.loads(text or "")
        value = data.get("Version", data.get("version"))
        return value if isinstance(value, str) else None
    except (ValueError, AttributeError):
        return None


def summarize_files(files: dict, info_text: str | None, main_text: str | None) -> dict:
    hashes = {name: identity.get("sha256") for name, identity in sorted(files.items())}
    main_match = VERSION.search(main_text or "")
    declared = version_info(info_text)
    main_version = main_match.group(1) if main_match else None
    complete = {"Info.json", "Scripts/main.lua"} <= files.keys() and all(
        identity.get("state") == "present" for identity in files.values())
    return {
        "files": files, "declared_version": declared, "main_version": main_version,
        "version_consistent": declared == main_version if declared and main_version else None,
        "file_set_sha256": digest(json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode()) if complete else None,
        "identity_scope": "on-disk source/package bytes; does not establish loaded Lua",
    }


def mod_directory(root: Path, *, source=False) -> dict:
    files = {"Info.json": file_identity(root / "Info.json")}
    scripts = root / "Scripts"
    scan_error = None
    try:
        lua_files = sorted(scripts.glob("*.lua")) if not scripts.is_symlink() else []
    except OSError as exc:
        scan_error = str(exc)
        lua_files = []
    legacy_config = None
    collisions = []
    for path in lua_files[:MAX_MEMBERS]:
        if path.name == "config.lua":
            if not source:
                legacy_config = file_identity(path)
                continue
            name = "Scripts/default_config.lua"
        else:
            name = "Scripts/" + path.name
        if name in files:
            collisions.append(name)
        files[name] = file_identity(path)
    if not any(name == "Scripts/main.lua" for name in files):
        files["Scripts/main.lua"] = file_identity(scripts / "main.lua")
    result = summarize_files(files, text_file(root / "Info.json"), text_file(scripts / "main.lua"))
    result.update(path=str(root.absolute()), state="present" if root.is_dir() else "absent",
                  legacy_editable_config=legacy_config, ambiguous_names=collisions,
                  scan_error=scan_error,
                  scan_complete=len(lua_files) <= MAX_MEMBERS and not (scan_error or collisions or scripts.is_symlink()))
    result["pak"] = file_identity(root / "LogicMods" / f"{MOD}.pak")
    if not result["scan_complete"]:
        result["file_set_sha256"] = None
    return result


def candidate_identity(path: Path | None, source: Path) -> dict:
    if path is None:
        return {"kind": "working_tree_unpackaged", **mod_directory(source, source=True)}
    if path.is_dir():
        return {"kind": "directory", **mod_directory(path, source=True)}
    archive_id = file_identity(path)
    result = {"kind": "archive", "path": str(path.absolute()), "archive": archive_id}
    if archive_id["state"] != "present":
        return {**result, "state": archive_id["state"]}
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            names = [entry.filename for entry in entries]
            if len(entries) > MAX_MEMBERS or sum(e.file_size for e in entries) > MAX_ARCHIVE_BYTES:
                return {**result, "state": "inspection_limit"}
            if len({name.casefold() for name in names}) != len(names) or any(
                    name.startswith("/") or ":" in name or "\\" in name or ".." in name.split("/") for name in names):
                return {**result, "state": "invalid_archive_members"}
            if "Scripts/main.lua" in names and MANUAL_ROOT + "Scripts/main.lua" in names:
                return {**result, "state": "ambiguous_layout"}
            prefix = "" if "Scripts/main.lua" in names else MANUAL_ROOT
            files, texts = {}, {}
            for entry in entries:
                if not entry.filename.startswith(prefix):
                    continue
                relative = entry.filename.removeprefix(prefix)
                if relative == "Info.json" or re.fullmatch(r"Scripts/[A-Za-z0-9_]+\.lua", relative):
                    data = archive.read(entry)
                    logical = "Scripts/default_config.lua" if relative == "Scripts/config.lua" else relative
                    if logical in files:
                        return {**result, "state": "ambiguous_config"}
                    files[logical] = {"state": "present", "bytes": len(data), "sha256": digest(data)}
                    if relative in ("Info.json", "Scripts/main.lua"):
                        texts[relative] = data.decode("utf-8-sig", "replace")
            pak_name = f"LogicMods/{MOD}.pak" if not prefix else f"Pal/Content/Paks/LogicMods/{MOD}.pak"
            pak = {"state": "absent"}
            if pak_name in names:
                data = archive.read(pak_name)
                pak = {"state": "present", "bytes": len(data), "sha256": digest(data)}
            after = file_identity(path)
            if archive_id.get("sha256") != after.get("sha256"):
                return {**result, "state": "changed_during_read"}
            return {**result, "state": "present" if "Scripts/main.lua" in files else "unrecognized_layout",
                    **summarize_files(files, texts.get("Info.json"), texts.get("Scripts/main.lua")), "pak": pak}
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        return {**result, "state": "unreadable_archive", "error": str(exc)}


def source_identity(root: Path) -> dict:
    result = mod_directory(root, source=True)
    command = ["git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", str(root)]
    try:
        outputs = []
        for args in (["rev-parse", "HEAD"],
                     ["status", "--porcelain", "--untracked-files=normal"],
                     ["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD"]):
            completed = subprocess.run(command + args, capture_output=True, timeout=15)
            if completed.returncode:
                result["git"] = {"state": "unknown", "error": completed.stderr.decode("utf-8", "replace")[:300]}
                return result
            outputs.append(completed.stdout)
        result["git"] = {
            "state": "observed", "commit": outputs[0].decode().strip(),
            "dirty": bool(outputs[1].strip()), "status_sha256": digest(outputs[1]),
            "tracked_diff_sha256": digest(outputs[2]),
            "note": "file_set_sha256 covers current module bytes including untracked modules",
        }
    except (OSError, subprocess.SubprocessError) as exc:
        result["git"] = {"state": "unknown", "error": str(exc)}
    return result


def query_processes(pattern: str) -> dict:
    """Get process paths/start times and mapped UE4SS paths without injecting code."""
    if os.name != "nt":
        return {"state": "unknown", "error": "Windows process inspection unavailable", "processes": []}
    if not re.fullmatch(r"[A-Za-z0-9_*]+", pattern):
        raise ValueError("invalid process-name pattern")
    script = r'''
$ErrorActionPreference = 'Stop'
$records = @()
try {
    $candidateProcesses = @(Get-Process | Where-Object { $_.ProcessName -like '__PATTERN__' })
    foreach ($candidateProcess in $candidateProcesses) {
        $row = @{ pid=$candidateProcess.Id; name=$candidateProcess.ProcessName; path=$null;
            started_unix=$null; modules_state='unknown'; ue4ss_modules=@(); errors=@(); alive_at_end=$null }
        try { $row.path=$candidateProcess.Path } catch { $row.errors += 'process path unavailable' }
        try { $row.started_unix=([DateTimeOffset]$candidateProcess.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()/1000.0 }
        catch { $row.errors += 'process start time unavailable' }
        try {
            foreach ($loadedModule in $candidateProcess.Modules) {
                if ($loadedModule.ModuleName -ieq 'UE4SS.dll') {
                    $row.ue4ss_modules += @{path=$loadedModule.FileName; name=$loadedModule.ModuleName}
                }
            }
            $row.modules_state='observed'
        } catch { $row.errors += 'module enumeration unavailable or incomplete' }
        try { $candidateProcess.Refresh(); $row.alive_at_end= -not $candidateProcess.HasExited }
        catch { $row.errors += 'process liveness recheck unavailable' }
        $records += $row
    }
    @{state='observed'; processes=@($records)} | ConvertTo-Json -Depth 6 -Compress
} catch { @{state='unknown'; processes=@(); error=$_.Exception.Message} | ConvertTo-Json -Depth 6 -Compress }
'''.replace("__PATTERN__", pattern)
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            capture_output=True, text=True, timeout=20, creationflags=subprocess.CREATE_NO_WINDOW,
        )
        if result.returncode:
            return {"state": "unknown", "error": result.stderr[-300:], "processes": []}
        value = json.loads(result.stdout)
        if not isinstance(value, dict) or not isinstance(value.get("processes"), list):
            raise ValueError("incomplete process query")
        return value
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return {"state": "unknown", "error": str(exc), "processes": []}


def under(path: str, root: Path) -> bool:
    try:
        Path(path).resolve().relative_to(root.resolve())
        return True
    except (ValueError, OSError):
        return False


def loaded_evidence(query: dict, game_root: Path) -> dict:
    records, observed, launchers, uncertain = [], [], [], False
    for process in query.get("processes", []):
        row = dict(process)
        path = process.get("path")
        row["in_target_root"] = under(path, game_root) if path else None
        row["shipping_process"] = bool(path and Path(path).name.lower().endswith("-shipping.exe"))
        row["started_utc"] = utc(process.get("started_unix"))
        row["mapped_runtime"] = []
        if path and row["in_target_root"]:
            row["executable_on_disk"] = file_identity(Path(path))
        relevant = row["in_target_root"] is True and row["shipping_process"]
        if row["in_target_root"] and not row["shipping_process"]:
            launchers.append(row)
        if (relevant or not path) and process.get("alive_at_end") is not True:
            uncertain = True
        if relevant and process.get("alive_at_end") is True:
            observed.append(row)
            for module in process.get("ue4ss_modules", []):
                row["mapped_runtime"].append({
                    "mapped_path": module["path"], "on_disk_identity": file_identity(Path(module["path"])),
                    "loaded_image_sha256": None,
                    "hash_proof": "unknown: mapped path observed, loaded image bytes not attested",
                })
        if not path:
            uncertain = True
        records.append(row)
    state = ("running" if observed else "unknown" if uncertain or query.get("state") != "observed"
             else "launcher_only" if launchers else "absent")
    runtime = "unknown"
    if observed and any(p["mapped_runtime"] for p in observed):
        runtime = "mapped_module_observed_hash_unverified"
    elif observed and all(p.get("modules_state") == "observed" for p in observed):
        runtime = "not_observed_in_current_module_lists"
    return {
        "process_state": state, "query_state": query.get("state", "unknown"),
        "query_error": query.get("error"), "processes": records, "runtime_state": runtime,
        "mod_loaded_state": "unknown" if state != "absent" else "not_running",
        "mod_loaded_reason": "no process-bound Lua identity attestation; installed files and banners are not loaded-byte proof",
        "pak_mounted_state": "unknown",
    }


def log_evidence(path: Path, process_rows: list, captured_at: float) -> dict:
    """Do not use mtime or even a fresh banner as proof of a current loaded build."""
    result = {"path": str(path.absolute()), "loaded_identity_proof": "none"}
    try:
        if path.is_symlink():
            return {**result, "state": "symlink_not_followed"}
        before = path.stat()
        with path.open("rb") as handle:
            handle.seek(max(0, before.st_size - 256 * 1024))
            text = handle.read(256 * 1024).decode("utf-8", "replace")
    except FileNotFoundError:
        return {**result, "state": "absent"}
    except OSError as exc:
        return {**result, "state": "unreadable", "error": str(exc)}
    last = None
    for line in text.splitlines():
        banner = BANNER.search(line)
        if not banner:
            continue
        when = STAMP.search(line)
        timestamp = None
        if when:
            try:
                timestamp = datetime.strptime(when.group(1), "%Y-%m-%d %H:%M:%S").astimezone().timestamp()
            except ValueError:
                pass
        last = {"declared_version": banner.group(1), "timestamp_utc": utc(timestamp)}
        starts = [p["started_unix"] for p in process_rows
                  if p.get("shipping_process") and p.get("in_target_root") and p.get("alive_at_end") is True
                  and p.get("started_unix") is not None]
        if timestamp is None:
            classification = "undated_unbound"
        elif timestamp > captured_at + 5:
            classification = "future_timestamp_unbound"
        elif starts and timestamp < min(starts):
            classification = "older_than_current_process"
        elif starts:
            classification = "after_process_start_but_not_process_bound"
        else:
            classification = "historical_or_unbound_no_current_process_proof"
        last["classification"] = classification
    return {**result, "state": "present", "bytes": before.st_size, "modified_utc": utc(before.st_mtime),
            "last_banner_in_bounded_tail": last, "tail_limit_bytes": 256 * 1024}


def steam_identity(game_root: Path, server: bool) -> dict:
    """Local Steam metadata is a declaration, separate from executable hashes."""
    appid = "2394010" if server else "1623730"
    if game_root.parent.name.lower() != "common" or game_root.parent.parent.name.lower() != "steamapps":
        return {"state": "unknown", "build_id": None, "reason": "not a standard Steam library path"}
    manifest = game_root.parent.parent / f"appmanifest_{appid}.acf"
    text = text_file(manifest)
    values = dict(re.findall(r'"(appid|buildid|installdir)"\s+"([^"\r\n]+)"', text or ""))
    matches = values.get("appid") == appid and values.get("installdir", "").casefold() == game_root.name.casefold()
    return {"metadata": file_identity(manifest), "state": "declared" if matches else "unknown",
            "app_id": appid, "build_id": values.get("buildid") if matches else None,
            "identity_scope": "local Steam manifest declaration; not proof of loaded game revision"}


def collect(source: Path, game_root: Path, *, server=False, candidate=None, workshop_root=None,
            process_query=None, captured_at=None) -> dict:
    captured_at = time.time() if captured_at is None else captured_at
    source, game_root = source.resolve(), game_root.resolve()
    roots = [
        ("native", game_root / "Mods/NativeMods/UE4SS"),
        ("legacy_binaries_ue4ss", game_root / "Pal/Binaries/Win64/ue4ss"),
        ("legacy_binaries_flat", game_root / "Pal/Binaries/Win64"),
        ("legacy_root_ue4ss", game_root / "ue4ss"),
    ]
    candidates = [(label, runtime / "Mods" / MOD) for label, runtime in roots]
    installed = []
    runtime_files = []
    logs = []
    for label, runtime in roots:
        runtime_files.append({"layout": label, **file_identity(runtime / "UE4SS.dll")})
    for label, mod in candidates:
        if mod.is_dir():
            installed.append({"layout": label, **mod_directory(mod)})
            logs.append(mod / "priority.log")
    if workshop_root is None and game_root.parent.name.lower() == "common" and game_root.parent.parent.name.lower() == "steamapps":
        workshop_root = game_root.parent.parent / "workshop/content/1623730"
    cache, advertised = None, None
    if workshop_root:
        workshop_root = Path(workshop_root)
        cache = mod_directory(workshop_root / WORKSHOP_ID, source=True)
        advertised_info = workshop_root / DEPENDENCY_ID / "Info.json"
        advertised = {"metadata": file_identity(advertised_info),
                      "declared_version": version_info(text_file(advertised_info)),
                      "identity_scope": "cached dependency advertisement, not installed or loaded runtime proof"}
    query = process_query if process_query is not None else query_processes("PalServer*" if server else "Palworld*")
    loaded = loaded_evidence(query, game_root)
    executable_names = ("PalServer.exe", "Pal/Binaries/Win64/PalServer-Win64-Shipping.exe") if server else (
        "Palworld.exe", "Pal/Binaries/Win64/Palworld-Win64-Shipping.exe")
    candidate_result = candidate_identity(candidate, source)
    for installation in installed:
        left, right = candidate_result.get("file_set_sha256"), installation.get("file_set_sha256")
        installation["matches_candidate_code_on_disk"] = left == right if left and right else None
    return {
        "schema": 1, "captured_utc": utc(captured_at), "target": "server" if server else "client",
        "game_root": str(game_root), "source": source_identity(source), "candidate": candidate_result,
        "game_executables_on_disk": [file_identity(game_root / name) for name in executable_names],
        "game_steam_metadata": steam_identity(game_root, server),
        "runtime_files_on_disk": runtime_files, "installations": installed,
        "duplicate_install_candidates": [entry["path"] for entry in installed] if len(installed) > 1 else [],
        "duplicate_loads_confirmed": None,
        "workshop_cache": cache, "advertised_dependency": advertised,
        "pak_files_on_disk": [file_identity(game_root / "Pal/Content/Paks/LogicMods" / f"{MOD}.pak"),
                              file_identity(game_root / "Mods/LogicMods" / f"{MOD}.pak")],
        "loaded": loaded,
        "log_observations": [log_evidence(path, loaded["processes"], captured_at) for path in logs],
        "limits": [
            "Known installation layouts only; absence here does not inventory arbitrary renamed mods.",
            "Version declarations and current disk hashes do not prove the bytes loaded by an earlier process.",
            "No loaded Lua/runtime memory attestation, pak mounting proof, frame times or compatibility verdict.",
            "Log banners never establish current loaded identity, regardless of file modification time.",
            "This is a sequential inventory, not an atomic snapshot; files can change after each hash is read.",
        ],
    }


def main(argv=None) -> int:
    paths, argv = resolve(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--game-root", type=Path, default=Path(paths["root"]))
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--workshop-root", type=Path)
    args = parser.parse_args(argv)
    report = collect(args.source, args.game_root, server=paths["server"],
                     candidate=args.candidate, workshop_root=args.workshop_root)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0  # An inventory, not a release-acceptance or live-test success signal.


if __name__ == "__main__":
    raise SystemExit(main())
