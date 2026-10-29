"""Build deterministic Workshop and manual archives from one clean source tree.

No native build or game access occurs. A reviewed, existing pak and its expected
SHA-256 are required. Both archives carry the same logical manifest and identical
Lua/asset bytes. Native widget compatibility remains a separate acceptance gate.

  python tools/release.py --pak LogicMods/PalWorkPriority.pak --pak-sha256 <hash>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

MOD = "PalWorkPriority"
MANUAL_ROOT = f"Mods/NativeMods/UE4SS/Mods/{MOD}/"
PAK_LOGICAL = f"LogicMods/{MOD}.pak"
FIXED_TIME = (1980, 1, 1, 0, 0, 0)
ASSET_CLASS = "/Game/Mods/PalWorkPriority/UI/WBP_WorkRules.WBP_WorkRules_C"
ASSET_CONTRACT = "docs/asset-contract.json"
# WorkRules 4 / StandInput 3: controller buttons (docs/controller-routes-2026-10-22.md).
REQUIRED_WIDGETS = {
    ASSET_CLASS: {"field": "PWP_InputContract", "version": 4},
    "/Game/Mods/PalWorkPriority/UI/WBP_StandInput.WBP_StandInput_C":
        {"field": "PWP_Contract", "version": 3},
}


class ReleaseFailure(RuntimeError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(root: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if result.returncode:
        raise ReleaseFailure(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def clean_revision(root: Path) -> str:
    if git(root, "status", "--porcelain", "--untracked-files=normal"):
        raise ReleaseFailure("release source is dirty; commit the reviewed source and tests first")
    return git(root, "rev-parse", "HEAD")


def validate_pak(data: bytes, expected_sha256: str) -> dict:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha256):
        raise ReleaseFailure("supply the reviewed pak's full SHA-256")
    if sha256(data) != expected_sha256.lower():
        raise ReleaseFailure("pak does not match its reviewed SHA-256")
    # Check the plain index's bounds and hash, without executing Unreal tooling.
    at = data.rfind(struct.pack("<I", 0x5A6F12E1), max(0, len(data) - 1024))
    if at < 0 or at + 44 > len(data):
        raise ReleaseFailure("pak footer missing or truncated")
    version, offset, size = struct.unpack_from("<IQQ", data, at + 4)
    if not (1 <= version <= 11) or size <= 0 or offset + size > at:
        raise ReleaseFailure("unsupported pak version or invalid index bounds")
    expected_index = data[at + 24:at + 44]
    if hashlib.sha1(data[offset:offset + size]).digest() != expected_index:
        raise ReleaseFailure("pak index hash mismatch (encrypted indexes are not accepted by this builder)")
    return {
        "sha256": sha256(data), "bytes": len(data), "pak_version": version,
        "required_panel_class": ASSET_CLASS,
        "validation": "reviewed artifact hash and plain index integrity; native asset contract requires live acceptance",
    }


def tracked_lua(root: Path) -> list[str]:
    paths = git(root, "ls-files", "--", "Scripts").splitlines()
    lua = sorted(path for path in paths if re.fullmatch(r"Scripts/[A-Za-z0-9_]+\.lua", path))
    if "Scripts/main.lua" not in lua:
        raise ReleaseFailure("tracked Scripts/main.lua missing")
    # Every Lua source considered by the compiler must be in the same reviewed set.
    if sorted(p.relative_to(root).as_posix() for p in (root / "Scripts").glob("*.lua")) != lua:
        raise ReleaseFailure("untracked or unsupported Lua filename in Scripts")
    return lua


def reviewed_asset_contract(root: Path, data: bytes) -> dict:
    """Bind asset expectations to reviewed bytes, not a caller's arbitrary hash.

    Widget versions are review declarations, not claims of binary introspection
    or present-build native acceptance. Changing the pak requires contract review.
    """
    path = root / ASSET_CONTRACT
    if not path.is_file() or path.is_symlink():
        raise ReleaseFailure("reviewed asset contract is missing")
    try:
        contract = json.loads(path.read_text(encoding="utf-8-sig"))
    except (ValueError, UnicodeError) as exc:
        raise ReleaseFailure("invalid reviewed asset contract") from exc
    if not isinstance(contract, dict) or contract.get("schema") != 2:
        raise ReleaseFailure("unsupported reviewed asset contract schema")
    if contract.get("path") != PAK_LOGICAL or contract.get("widgets") != REQUIRED_WIDGETS:
        raise ReleaseFailure("reviewed asset contract lacks the required widget contracts")
    if contract.get("sha256") != sha256(data) or contract.get("bytes") != len(data):
        raise ReleaseFailure("pak differs from the source's reviewed asset contract")
    return contract


def collect_payload(root: Path, pak: Path, expected_sha256: str, revision: str) -> tuple[dict, dict]:
    if not pak.is_file():
        raise ReleaseFailure(f"required pak is absent: {pak}")
    pak_data = pak.read_bytes()
    contract = validate_pak(pak_data, expected_sha256)
    contract["reviewed_contract"] = reviewed_asset_contract(root, pak_data)
    required = ["Info.json", "README.md", "CHANGELOG.md", "LICENSE", "thumbnail.png"] + tracked_lua(root)
    payload = {}
    for relative in required:
        path = root / relative
        if not path.is_file() or path.is_symlink():
            raise ReleaseFailure(f"required regular source file is missing: {relative}")
        payload[relative] = path.read_bytes()
    try:
        info = json.loads(payload["Info.json"].decode("utf-8-sig"))
    except (ValueError, UnicodeError) as exc:
        raise ReleaseFailure("invalid Info.json") from exc
    version = info.get("Version", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
        raise ReleaseFailure("invalid release version")
    if info.get("PackageName") != MOD or info.get("DebugMode") is not False:
        raise ReleaseFailure("package name/debug release contract does not match")
    match = re.search(r'local\s+VERSION\s*=\s*["\']([^"\']+)', payload["Scripts/main.lua"].decode("utf-8-sig"))
    if not match or match.group(1) != version:
        raise ReleaseFailure("Info.json and main.lua versions differ")
    rules = info.get("InstallRule", [])
    if not any(r.get("Type") == "LogicMods" and "./LogicMods/" in r.get("Targets", []) for r in rules):
        raise ReleaseFailure("Info.json does not install the required LogicMods asset")
    for server in (False, True):
        if not any(r.get("Type") == "Lua" and bool(r.get("IsServer", False)) == server
                   and "./Scripts" in r.get("Targets", []) for r in rules):
            raise ReleaseFailure("Info.json must install Scripts on clients and servers")
    # Do not overwrite a pre-0.5 user's editable Scripts/config.lua when
    # extracting an update. The runtime migrates that legacy file first.
    if "Scripts/config.lua" in payload:
        if "Scripts/default_config.lua" in payload:
            raise ReleaseFailure("ambiguous default configuration sources")
        payload["Scripts/default_config.lua"] = payload.pop("Scripts/config.lua")
    if "Scripts/default_config.lua" not in payload:
        raise ReleaseFailure("required default configuration is missing")
    payload[PAK_LOGICAL] = pak_data
    manifest = {
        "schema": 1, "mod": MOD, "version": version, "source_commit": revision,
        "asset_contract": contract,
        "files": {name: {"sha256": sha256(data), "bytes": len(data)} for name, data in sorted(payload.items())},
    }
    return payload, manifest


def distribution_path(logical: str, kind: str) -> str:
    if kind == "workshop":
        return logical
    if logical == PAK_LOGICAL:
        return f"Pal/Content/Paks/LogicMods/{MOD}.pak"
    return MANUAL_ROOT + logical


def archive_entries(payload: dict[str, bytes], manifest: dict, kind: str) -> dict[str, bytes]:
    entries = {distribution_path(name, kind): value for name, value in payload.items()}
    manifest_name = "MANIFEST.json" if kind == "workshop" else MANUAL_ROOT + "MANIFEST.json"
    entries[manifest_name] = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode("utf-8")
    if kind == "manual":
        entries[MANUAL_ROOT + "enabled.txt"] = b""
        entries["INSTALL.txt"] = (
            f"Pal Work Priority {manifest['version']}\n\n"
            "1. UE4SS first. Subscribe to Experimental UE4SS for Palworld\n"
            "   https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587\n"
            "   Switch it on in the game's Mod Management and start the game once.\n"
            "   After that the folder Mods\\NativeMods\\UE4SS exists in your Palworld folder.\n\n"
            "2. Close the game. Back up your world and, when you update, the folder\n"
            "   Mods\\NativeMods\\UE4SS\\Mods\\PalWorkPriority.\n\n"
            "3. Find your Palworld folder. In Steam, right-click Palworld, then\n"
            "   Manage > Browse local files.\n\n"
            "4. Extract this zip into exactly that folder and let it merge the folders.\n"
            "   Some tools add the zip's name as an extra folder at the end of the\n"
            "   target. Remove that part before you extract. You get\n"
            "   Mods\\NativeMods\\UE4SS\\Mods\\PalWorkPriority and\n"
            "   Pal\\Content\\Paks\\LogicMods\\PalWorkPriority.pak.\n"
            "   Your priorities, limits and settings stay when you update.\n\n"
            "5. Check that this file exists in your Palworld folder.\n"
            "   Mods\\NativeMods\\UE4SS\\Mods\\PalWorkPriority\\Scripts\\main.lua\n"
            "   If it does not, the files went into the wrong folder.\n\n"
            "6. Start the game and open a Monitoring Stand. It works when the stand\n"
            "   shows numbers, and a click changes one. 1 is the highest priority,\n"
            "   5 the lowest and X means never. Left click raises toward 1, and 1\n"
            "   wraps to X. Right click lowers toward X.\n"
            "   No stand yet? Alt+F1 opens the Production Limits panel, which proves\n"
            "   the mod loaded.\n\n"
            "Did it load? Open priority.log in the PalWorkPriority folder.\n"
            "It should say \"Pal Work Priority " + manifest["version"] + " loaded\".\n\n"
            "Use one copy only. If the Steam Workshop copy is switched on in the game's\n"
            "mod list, switch it off or unsubscribe first.\n\n"
            "With Vortex, turn off in Settings > Mods \"Manage modding requirements (UE4SS,\n"
            "Unreal Pak Tool) automatically\". Otherwise Vortex adds a second UE4SS.\n"
            "Updating from 0.4.1 in Vortex? Install this version next to it, start\n"
            "the game once, then remove 0.4.1. Your config.lua edits are kept.\n\n"
            "Multiplayer. The server and every player need exactly this version.\n"
            "A dedicated server must run Windows and needs UE4SS. From this zip it\n"
            "needs only the PalWorkPriority folder. See README.md for the steps.\n\n"
            "More help is in README.md inside the PalWorkPriority folder.\n"
        ).encode("utf-8")
    return entries


def write_archive(path: Path, entries: dict[str, bytes]) -> None:
    # ZIP_STORED also avoids compressor-version differences between build machines.
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in sorted(entries.items()):
            if name.startswith("/") or "\\" in name or ".." in name.split("/"):
                raise ReleaseFailure("unsafe archive member")
            metadata = zipfile.ZipInfo(name, date_time=FIXED_TIME)
            metadata.create_system = 3
            metadata.external_attr = 0o100644 << 16
            archive.writestr(metadata, data)


def verify_archive(path: Path, entries: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path) as archive:
        if len(archive.namelist()) != len(entries) or set(archive.namelist()) != set(entries):
            raise ReleaseFailure("archive member list differs from the clean staging manifest")
        for name, data in entries.items():
            if archive.read(name) != data:
                raise ReleaseFailure(f"archive hash mismatch: {name}")


def compile_gate(root: Path) -> None:
    checker = root / "tools" / "test_lua.py"
    if not checker.is_file():
        raise ReleaseFailure("real Lua compiler gate tools/test_lua.py is missing")
    result = subprocess.run([sys.executable, str(checker), "--compile-only"], cwd=root,
                            capture_output=True, text=True)
    if result.returncode:
        raise ReleaseFailure("Lua compile gate failed:\n" + result.stdout + result.stderr)


def compile_payload_gate(root: Path, payload: dict[str, bytes]) -> None:
    # Compile the exact immutable snapshot under its final installed names.
    # The source gate alone cannot cover packaging transformations/omissions.
    with tempfile.TemporaryDirectory(prefix="pwp-package-compile-") as directory:
        stage = Path(directory)
        (stage / "tools").mkdir()
        (stage / "Scripts").mkdir()
        shutil.copyfile(root / "tools" / "test_lua.py", stage / "tools" / "test_lua.py")
        for name, data in payload.items():
            if re.fullmatch(r"Scripts/[A-Za-z0-9_]+\.lua", name):
                (stage / name).write_bytes(data)
        env = os.environ.copy()
        env["PYTHONPATH"] = str(root / ".test-deps") + os.pathsep + env.get("PYTHONPATH", "")
        result = subprocess.run([sys.executable, str(stage / "tools" / "test_lua.py"), "--compile-only"],
                                cwd=stage, env=env, capture_output=True, text=True)
        if result.returncode:
            raise ReleaseFailure("packaged Lua compile gate failed:\n" + result.stdout + result.stderr)


def build(root: Path, output: Path, pak: Path, expected_sha256: str) -> dict:
    root, output, pak = root.resolve(), output.resolve(), pak.resolve()
    revision = clean_revision(root)
    payload, manifest = collect_payload(root, pak, expected_sha256, revision)
    compile_gate(root)
    compile_payload_gate(root, payload)
    if clean_revision(root) != revision:
        raise ReleaseFailure("source revision changed during validation")
    # Check bytes again after the compiler; it must compile exactly what we package.
    checked_payload, checked_manifest = collect_payload(root, pak, expected_sha256, revision)
    if checked_payload != payload or checked_manifest != manifest:
        raise ReleaseFailure("source/asset bytes changed during validation")
    output.mkdir(parents=True, exist_ok=True)
    result = {"version": manifest["version"], "source_commit": revision, "archives": {}}
    with tempfile.TemporaryDirectory(prefix=".pwp-release-", dir=output) as scratch:
        for kind in ("workshop", "manual"):
            filename = f"{MOD}-{manifest['version']}-{kind}.zip"
            destination = output / filename
            entries = archive_entries(payload, manifest, kind)
            staged = Path(scratch) / filename
            write_archive(staged, entries)
            verify_archive(staged, entries)
            if destination.exists() and destination.read_bytes() != staged.read_bytes():
                raise ReleaseFailure(f"refusing to overwrite a different release: {destination}")
            result["archives"][kind] = {"file": filename, "sha256": sha256(staged.read_bytes())}
        # Validate both distributions before publishing either file into the output folder.
        for record in result["archives"].values():
            os.replace(Path(scratch) / record["file"], output / record["file"])
        manifest_path = Path(scratch) / "release.json"
        manifest_path.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        os.replace(manifest_path, output / f"{MOD}-{manifest['version']}-release.json")
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--pak", type=Path)
    parser.add_argument("--pak-sha256", required=True)
    args = parser.parse_args(argv)
    try:
        result = build(args.root, args.output or args.root / "build" / "release",
                       args.pak or args.root / PAK_LOGICAL, args.pak_sha256)
    except (ReleaseFailure, OSError, subprocess.SubprocessError) as exc:
        print(f"RELEASE BLOCKED: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

