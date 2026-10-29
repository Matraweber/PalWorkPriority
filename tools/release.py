"""Build deterministic Workshop and manual archives from one clean source tree.

No native build or game access occurs. A reviewed, existing pak and its expected
SHA-256 are required. Both archives carry the same logical manifest and identical
Lua/asset bytes. Native widget compatibility remains a separate acceptance gate.

  python tools/release.py --pak LogicMods/PalWorkPriority.pak --pak-sha256 <hash>

The tracked sources are packaged as committed at HEAD (git's blobs, read
with git cat-file), not as they sit on disk: with eol=lf, git status does not
report a working copy whose line endings differ, so disk bytes need not be the
commit's bytes. The archive layout is the same either way. The pak is the
file --pak names, bound by --pak-sha256 and the committed asset contract.

The default output is build/release-<version>, the folder
tools/workshop_upload.py prepare reads. A folder that already holds a
different build of the same version is refused, never overwritten: move it
aside first (the refusal prints the rename command).

Order for a retag: move the old build aside, commit, move the tag, push the
tag (git push --force origin v<version>), build, then
tools/workshop_upload.py prepare. prepare refuses until the public tag is the
commit the build came from.
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


def git_bytes(root: Path, *args: str, stdin: bytes | None = None) -> bytes:
    result = subprocess.run(["git", "-C", str(root), *args], input=stdin, capture_output=True)
    if result.returncode:
        raise ReleaseFailure(result.stderr.decode("utf-8", "replace").strip() or "git command failed")
    return result.stdout


def committed_files(root: Path, revision: str, names: list[str]) -> dict[str, bytes]:
    """Each path's bytes as committed at revision: the blob itself, without
    checkout filters, so a CRLF working copy of an eol=lf file cannot slip
    into the archive. Only regular files (mode 100644/100755) count."""
    listing = git_bytes(root, "ls-tree", "-r", "-z", "--full-tree", revision, "--", *names)
    found = {}
    for record in listing.split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        mode, kind, oid = meta.decode("ascii").split()
        found[path.decode("utf-8")] = (mode, kind, oid)
    for name in names:
        mode, kind, _ = found.get(name, ("", "", ""))
        if kind != "blob" or mode not in ("100644", "100755"):
            raise ReleaseFailure(f"required regular source file is missing: {name}")
    # One git process for every blob: "<oid> blob <size>\n<bytes>\n" per object.
    output = git_bytes(root, "cat-file", "--batch",
                       stdin="".join(found[name][2] + "\n" for name in names).encode("ascii"))
    files, at = {}, 0
    for name in names:
        end = output.index(b"\n", at)
        oid, kind, size = output[at:end].decode("ascii").split()
        if oid != found[name][2] or kind != "blob":
            raise ReleaseFailure(f"git returned another object for {name}")
        start = end + 1
        files[name] = output[start:start + int(size)]
        at = start + int(size) + 1
    return files


def working_copy_drift(root: Path, committed: dict[str, bytes]) -> list[str]:
    """Tracked files whose disk bytes are not the committed bytes (for
    example CRLF line endings, which git status does not report)."""
    return sorted(name for name, data in committed.items()
                  if not (root / name).is_file() or (root / name).read_bytes() != data)


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


def tracked_lua(root: Path, revision: str) -> list[str]:
    paths = git(root, "ls-tree", "-r", "--name-only", "--full-tree", revision, "--", "Scripts").splitlines()
    lua = sorted(path for path in paths if re.fullmatch(r"Scripts/[A-Za-z0-9_]+\.lua", path))
    if "Scripts/main.lua" not in lua:
        raise ReleaseFailure("tracked Scripts/main.lua missing")
    # Every Lua source considered by the compiler must be in the same reviewed set.
    if sorted(p.relative_to(root).as_posix() for p in (root / "Scripts").glob("*.lua")) != lua:
        raise ReleaseFailure("untracked or unsupported Lua filename in Scripts")
    return lua


def reviewed_asset_contract(root: Path, revision: str, data: bytes) -> dict:
    """Bind asset expectations to reviewed bytes, not a caller's arbitrary hash.

    Widget versions are review declarations, not claims of binary introspection
    or present-build native acceptance. Changing the pak requires contract review.
    The contract is read as committed at revision.
    """
    try:
        text = committed_files(root, revision, [ASSET_CONTRACT])[ASSET_CONTRACT]
    except ReleaseFailure as exc:
        raise ReleaseFailure("reviewed asset contract is missing") from exc
    try:
        contract = json.loads(text.decode("utf-8-sig"))
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
    contract["reviewed_contract"] = reviewed_asset_contract(root, revision, pak_data)
    required = ["Info.json", "README.md", "CHANGELOG.md", "LICENSE", "thumbnail.png"] + tracked_lua(root, revision)
    payload = committed_files(root, revision, required)
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
            "It should say \"Pal Work Priority " + manifest["version"] + " loaded\".\n"
            "If it says \"did not start\", the line before it names the setting.\n"
            "Fix it in config.lua, or delete config.lua and restart.\n\n"
            "Use one copy only. If the Steam Workshop copy is switched on in the game's\n"
            "mod list, switch it off or unsubscribe first.\n\n"
            "With Vortex, turn off in Settings > Mods \"Manage modding requirements (UE4SS,\n"
            "Unreal Pak Tool) automatically\". Otherwise Vortex adds a second UE4SS.\n"
            "Updating from 0.4.1 in Vortex? Install this version next to it, start\n"
            "the game once, then remove 0.4.1. Your config.lua edits are kept.\n\n"
            "Multiplayer. The server and every player need exactly this version.\n"
            "A dedicated server must run Windows and needs UE4SS. From this zip it\n"
            "needs only the PalWorkPriority folder, including the empty enabled.txt\n"
            "in it. Without that file UE4SS does not start the mod. See README.md\n"
            "for the steps.\n\n"
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


def default_output(root: Path, version: str) -> Path:
    """build/release-<version>: where tools/workshop_upload.py looks."""
    return root / "build" / f"release-{version}"


def move_aside_command(output: Path, version: str) -> str:
    """The PowerShell line that renames an existing release folder out of the
    way, named after the commit its release.json records (else "-old")."""
    suffix = "old"
    try:
        old = json.loads((output / f"{MOD}-{version}-release.json").read_text(encoding="utf-8"))
        if re.fullmatch(r"[0-9a-f]{40}", str(old.get("source_commit", ""))):
            suffix = old["source_commit"][:7]
    except (OSError, ValueError, AttributeError):
        pass
    return f"Rename-Item -LiteralPath '{output}' -NewName '{output.name}-{suffix}'"


def build(root: Path, output: Path | None, pak: Path, expected_sha256: str) -> dict:
    root, pak = root.resolve(), pak.resolve()
    revision = clean_revision(root)
    payload, manifest = collect_payload(root, pak, expected_sha256, revision)
    sources = {name: data for name, data in payload.items() if name != PAK_LOGICAL}
    if "Scripts/config.lua" in tracked_lua(root, revision):  # packaged as default_config.lua
        sources["Scripts/config.lua"] = sources.pop("Scripts/default_config.lua")
    drift = working_copy_drift(root, sources)
    if drift:
        print(f"note: packaged the committed bytes of {revision[:12]}; {len(drift)} working-copy file(s) "
              f"differ (line endings?): {', '.join(drift[:5])}{' ...' if len(drift) > 5 else ''}", file=sys.stderr)
    # The version is known only from the validated Info.json.
    output = (output if output is not None else default_output(root, manifest["version"])).resolve()
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
                raise ReleaseFailure(
                    f"refusing to overwrite a different release: {destination}. Move the old folder aside "
                    f"(rename it, never delete it), then build again:\n  {move_aside_command(output, manifest['version'])}")
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
    parser.add_argument("--output", type=Path, help="default: build/release-<version>")
    parser.add_argument("--pak", type=Path)
    parser.add_argument("--pak-sha256", required=True)
    args = parser.parse_args(argv)
    try:
        result = build(args.root, args.output, args.pak or args.root / PAK_LOGICAL, args.pak_sha256)
    except (ReleaseFailure, OSError, subprocess.SubprocessError) as exc:
        print(f"RELEASE BLOCKED: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

