import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import release


def fixture_pak():
    # A structurally valid plain-index fixture, never loaded into the game.
    content = b"test fixture payload"
    index = b"../../../Pal/Content/Mods/PalWorkPriority/UI/WBP_WorkRules.uasset\0ModActor.uasset\0"
    footer = struct.pack("<IIQQ", 0x5A6F12E1, 8, len(content), len(index)) + hashlib.sha1(index).digest()
    return content + index + footer


def fixture_git(root, *args):
    return subprocess.run(["git", "-C", str(root), "-c", "user.name=Release Fixture",
                           "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                           "-c", "core.hooksPath=", "-c", "core.autocrlf=false", *args],
                          check=True, capture_output=True)


def commit(root, message="fixture change"):
    """release.py packages the committed bytes, so fixture edits are committed."""
    fixture_git(root, "add", "-A")
    fixture_git(root, "commit", "-q", "--allow-empty", "-m", message)


# Like the real repository: LF in git, and runtime/build output ignored, so a
# fixture build sees a clean tree.
FIXTURE_IGNORE = "build/\ncaps.txt\npriorities.txt\nremote.txt\npriority.log\naccidental.lua\n.workshop.json\n*.bak\n"


def source_tree(root):
    (root / "Scripts").mkdir(parents=True)
    (root / "tools").mkdir()
    fixture_git(root, "init", "-q")
    (root / ".gitattributes").write_text("* text=auto eol=lf\n", encoding="utf-8", newline="\n")
    (root / ".gitignore").write_text(FIXTURE_IGNORE, encoding="utf-8", newline="\n")
    info = {
        "Version": "1.2.3", "PackageName": "PalWorkPriority", "DebugMode": False,
        "InstallRule": [{"Type": "Lua", "Targets": ["./Scripts"]},
                        {"Type": "Lua", "IsServer": True, "Targets": ["./Scripts"]},
                        {"Type": "LogicMods", "Targets": ["./LogicMods/"]}],
    }
    (root / "Info.json").write_text(json.dumps(info), encoding="utf-8", newline="\n")
    for filename in ("README.md", "CHANGELOG.md", "LICENSE", "thumbnail.png"):
        (root / filename).write_bytes(b"fixture " + filename.encode())
    (root / "Scripts" / "main.lua").write_text('local VERSION = "1.2.3"\nreturn VERSION\n', encoding="utf-8", newline="\n")
    (root / "Scripts" / "config.lua").write_text("return { enabled = true }\n", encoding="utf-8", newline="\n")
    shutil.copyfile(ROOT / "tools" / "test_lua.py", root / "tools" / "test_lua.py")
    return root


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = source_tree(Path(self.temp.name) / "source")
        self.output = Path(self.temp.name) / "out"
        self.pak = Path(self.temp.name) / "reviewed.pak"
        self.pak.write_bytes(fixture_pak())
        self.expected = release.sha256(self.pak.read_bytes())
        (self.root / "docs").mkdir()
        self.contract = {"schema": 2, "path": release.PAK_LOGICAL,
                         "sha256": self.expected, "bytes": self.pak.stat().st_size,
                         "widgets": release.REQUIRED_WIDGETS}
        self.write_contract()
        commit(self.root, "fixture source")
        self.addCleanup(mock.patch.stopall)
        dependency_path = str(ROOT / ".test-deps")
        mock.patch.dict(os.environ, {"PYTHONPATH": dependency_path + os.pathsep + os.environ.get("PYTHONPATH", "")}).start()

    def write_contract(self):
        (self.root / release.ASSET_CONTRACT).write_text(json.dumps(self.contract), encoding="utf-8", newline="\n")

    def committed(self, name):
        return fixture_git(self.root, "cat-file", "blob", "HEAD:" + name).stdout

    def test_reviewed_contract_binds_the_asset_not_only_the_supplied_hash(self):
        data = self.pak.read_bytes().replace(b"test fixture payload", b"old! fixture payload")
        self.pak.write_bytes(data)
        # A valid footer and correct caller-provided hash are insufficient.
        with self.assertRaisesRegex(release.ReleaseFailure, "source's reviewed asset contract"):
            release.build(self.root, self.output, self.pak, release.sha256(data))
        self.assertFalse(self.output.exists())

    def test_missing_old_or_incomplete_contract_blocks(self):
        for contract in ({}, {**self.contract, "schema": 1},
                         {**self.contract, "widgets": {release.ASSET_CLASS: release.REQUIRED_WIDGETS[release.ASSET_CLASS]}},
                         {**self.contract, "bytes": 5400}):
            with self.subTest(contract=contract):
                self.contract, original = contract, self.contract
                self.write_contract()
                commit(self.root)
                with self.assertRaises(release.ReleaseFailure):
                    release.build(self.root, self.output, self.pak, self.expected)
                self.contract = original
        (self.root / release.ASSET_CONTRACT).unlink()
        commit(self.root)
        with self.assertRaisesRegex(release.ReleaseFailure, "contract is missing"):
            release.build(self.root, self.output, self.pak, self.expected)
        self.assertFalse(self.output.exists())

    def test_contract_change_during_compile_is_detected(self):
        def change_contract(_):
            # The sources are the commit's: a change is a new commit.
            self.contract["native_acceptance"] = "changed during validation"
            self.write_contract()
            commit(self.root)
        with mock.patch.object(release, "compile_gate", side_effect=change_contract):
            with self.assertRaisesRegex(release.ReleaseFailure, "changed during validation"):
                release.build(self.root, self.output, self.pak, self.expected)
        self.assertFalse(self.output.exists())

    def test_defaults_required_and_ambiguous_sources_rejected(self):
        config = self.root / "Scripts/config.lua"
        config.unlink()
        commit(self.root)
        with self.assertRaisesRegex(release.ReleaseFailure, "default configuration is missing"):
            release.build(self.root, self.output, self.pak, self.expected)
        config.write_text("return {}", encoding="utf-8", newline="\n")
        (self.root / "Scripts/default_config.lua").write_text("return {}", encoding="utf-8", newline="\n")
        commit(self.root)
        with self.assertRaisesRegex(release.ReleaseFailure, "ambiguous"):
            release.build(self.root, self.output, self.pak, self.expected)
        self.assertFalse(self.output.exists())

    def test_payload_compiler_checks_final_bytes_and_names(self):
        # Source files are valid; a broken packaging transformation must fail too.
        payload = {"Scripts/default_config.lua": b"return { broken = ) }"}
        with self.assertRaisesRegex(release.ReleaseFailure, "packaged Lua compile gate failed") as error:
            release.compile_payload_gate(self.root, payload)
        self.assertIn("default_config.lua", str(error.exception))

    def test_deterministic_archives_share_payload_hashes_and_exclude_runtime_files(self):
        for filename in ("caps.txt", "priorities.txt", "remote.txt", "priority.log", "accidental.lua", ".workshop.json"):
            (self.root / filename).write_text("must not ship", encoding="utf-8", newline="\n")
        (self.root / "Scripts" / "remote.txt").write_text("trigger", encoding="utf-8", newline="\n")
        (self.root / "Scripts" / "main.lua.bak").write_text("old", encoding="utf-8", newline="\n")
        first = release.build(self.root, self.output, self.pak, self.expected)
        second = release.build(self.root, Path(self.temp.name) / "second", self.pak, self.expected)
        self.assertEqual(first, second)
        # A repeat into the same output may reuse identical bytes, never silently replace a different build.
        self.assertEqual(first, release.build(self.root, self.output, self.pak, self.expected))
        workshop = self.output / first["archives"]["workshop"]["file"]
        manual = self.output / first["archives"]["manual"]["file"]
        with zipfile.ZipFile(workshop) as w, zipfile.ZipFile(manual) as m:
            manifest = json.loads(w.read("MANIFEST.json"))
            self.assertEqual(manifest["asset_contract"]["reviewed_contract"], self.contract)
            self.assertEqual(w.read("MANIFEST.json"), m.read(release.MANUAL_ROOT + "MANIFEST.json"))
            for name, expected in manifest["files"].items():
                self.assertEqual(release.sha256(w.read(name)), expected["sha256"])
                self.assertEqual(w.read(name), m.read(release.distribution_path(name, "manual")))
            install = m.read("INSTALL.txt").decode()
            self.assertIn("Alt+F1", install)
            # A server copy without enabled.txt is never started by UE4SS.
            self.assertIn("including the empty enabled.txt\nin it.", install)
            self.assertIn('If it says "config.lua rejected"', install)
            self.assertIn('If it says "did not start"', install)
            self.assertIn("delete config.lua and restart", install)
            self.assertNotIn("Scripts/config.lua", w.namelist())
            self.assertIn("Scripts/default_config.lua", w.namelist())
            self.assertIn(release.MANUAL_ROOT + "enabled.txt", m.namelist())
            for archive in (w, m):
                for name in archive.namelist():
                    self.assertNotIn(Path(name).name, ("caps.txt", "priorities.txt", "remote.txt", "priority.log", "accidental.lua", ".workshop.json", "main.lua.bak"))
                    self.assertEqual(archive.getinfo(name).date_time, release.FIXED_TIME)

    def test_default_output_is_the_folder_workshop_upload_reads(self):
        # tools/workshop_upload.py prepare reads build/release-<version>/.
        expected = self.root / "build" / "release-1.2.3"
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            code = release.main(["--root", str(self.root), "--pak", str(self.pak), "--pak-sha256", self.expected])
        self.assertEqual(code, 0, out.getvalue())
        self.assertEqual(sorted(p.name for p in expected.iterdir()),
                         ["PalWorkPriority-1.2.3-manual.zip", "PalWorkPriority-1.2.3-release.json",
                          "PalWorkPriority-1.2.3-workshop.zip"])
        self.assertFalse((self.root / "build" / "release").exists(), "the old unversioned default is gone")
        self.assertEqual(release.build(self.root, None, self.pak, self.expected),
                         json.loads((expected / "PalWorkPriority-1.2.3-release.json").read_text(encoding="utf-8")))

    def test_default_output_refuses_a_different_build_of_the_same_version(self):
        release.build(self.root, None, self.pak, self.expected)
        target = self.root / "build" / "release-1.2.3" / "PalWorkPriority-1.2.3-workshop.zip"
        target.write_bytes(b"an older build from another commit")
        with self.assertRaisesRegex(release.ReleaseFailure, "refusing to overwrite a different release"):
            release.build(self.root, None, self.pak, self.expected)
        self.assertEqual(target.read_bytes(), b"an older build from another commit")

    def test_missing_pak_blocks_before_creating_output(self):
        self.pak.unlink()
        with self.assertRaisesRegex(release.ReleaseFailure, "pak is absent"):
            release.build(self.root, self.output, self.pak, self.expected)
        self.assertFalse(self.output.exists())

    def test_wrong_asset_hash_corrupt_index_and_version_drift_block(self):
        with self.assertRaisesRegex(release.ReleaseFailure, "reviewed SHA"):
            release.build(self.root, self.output, self.pak, "0" * 64)
        corrupted = bytearray(self.pak.read_bytes())
        corrupted[25] ^= 1
        self.pak.write_bytes(corrupted)
        with self.assertRaisesRegex(release.ReleaseFailure, "index hash"):
            release.build(self.root, self.output, self.pak, release.sha256(corrupted))
        self.pak.write_bytes(fixture_pak())
        (self.root / "Scripts" / "main.lua").write_text('local VERSION = "9.9.9"\n', encoding="utf-8", newline="\n")
        commit(self.root)
        with self.assertRaisesRegex(release.ReleaseFailure, "versions differ"):
            release.build(self.root, self.output, self.pak, self.expected)
        self.assertFalse(self.output.exists())

    def test_real_compiler_rejects_syntax_custom_structural_check_misses(self):
        (self.root / "Scripts" / "bad.lua").write_text("local x = (1 + )", encoding="utf-8", newline="\n")
        commit(self.root)
        with self.assertRaisesRegex(release.ReleaseFailure, "Lua compile gate failed"):
            release.build(self.root, self.output, self.pak, self.expected)
        self.assertFalse(self.output.exists())

    def test_missing_compiler_gate_fails_closed(self):
        (self.root / "tools" / "test_lua.py").unlink()
        commit(self.root)
        with self.assertRaisesRegex(release.ReleaseFailure, "compiler gate"):
            release.build(self.root, self.output, self.pak, self.expected)

    def test_existing_different_release_is_not_overwritten(self):
        result = release.build(self.root, self.output, self.pak, self.expected)
        target = self.output / result["archives"]["manual"]["file"]
        target.write_bytes(b"keep this earlier artifact")
        with self.assertRaisesRegex(release.ReleaseFailure, "overwrite a different release"):
            release.build(self.root, self.output, self.pak, self.expected)
        self.assertEqual(target.read_bytes(), b"keep this earlier artifact")

    def test_crlf_working_copy_packages_the_committed_lf_bytes(self):
        # 2026-10-29 (round 3, tooling P2-1): 12 tracked Lua files had CRLF on
        # disk, git status was empty (eol=lf), and the archive held the CRLF
        # disk bytes instead of the commit's.
        # A CRLF copy committed through eol=lf: git stores LF, the disk keeps
        # CRLF, and the index records the CRLF size, so status stays clean.
        (self.root / "Scripts/main.lua").write_bytes(b'local VERSION = "1.2.3"\r\n-- edited\r\nreturn VERSION\r\n')
        commit(self.root, "edited from a CRLF editor")
        committed = self.committed("Scripts/main.lua")
        self.assertEqual(committed, b'local VERSION = "1.2.3"\n-- edited\nreturn VERSION\n')
        self.assertIn(b"\r", (self.root / "Scripts/main.lua").read_bytes())
        self.assertEqual(fixture_git(self.root, "status", "--porcelain").stdout.strip(), b"",
                         "the trap: git status does not show a CRLF working copy")
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            result = release.build(self.root, self.output, self.pak, self.expected)
        self.assertIn("packaged the committed bytes", err.getvalue())
        self.assertIn("Scripts/main.lua", err.getvalue())
        for kind in ("workshop", "manual"):
            with zipfile.ZipFile(self.output / result["archives"][kind]["file"]) as archive:
                name = "Scripts/main.lua" if kind == "workshop" else release.MANUAL_ROOT + "Scripts/main.lua"
                self.assertEqual(archive.read(name), committed, kind)
        manifest = json.loads(zipfile.ZipFile(self.output / result["archives"]["workshop"]["file"]).read("MANIFEST.json"))
        self.assertEqual(manifest["files"]["Scripts/main.lua"]["sha256"], release.sha256(committed))
        self.assertEqual(manifest["source_commit"], fixture_git(self.root, "rev-parse", "HEAD").stdout.decode().strip())

    def test_symlink_or_missing_source_is_not_a_regular_file(self):
        blob = subprocess.run(["git", "-C", str(self.root), "hash-object", "-w", "--stdin"], input=b"README.md",
                              capture_output=True, check=True).stdout.decode().strip()
        fixture_git(self.root, "update-index", "--add", "--cacheinfo", "120000,%s,linked.md" % blob)
        fixture_git(self.root, "commit", "-q", "-m", "a symlink in git")
        for name in ("linked.md", "absent.md"):
            with self.assertRaisesRegex(release.ReleaseFailure, "regular source file is missing: " + name):
                release.committed_files(self.root, "HEAD", ["README.md", name])

    def test_refusal_prints_the_move_aside_command(self):
        release.build(self.root, None, self.pak, self.expected)
        folder = self.root / "build" / "release-1.2.3"
        old_commit = fixture_git(self.root, "rev-parse", "HEAD").stdout.decode().strip()
        (self.root / "CHANGELOG.md").write_text("a later commit\n", encoding="utf-8", newline="\n")
        commit(self.root)
        before = {p.name: p.read_bytes() for p in folder.iterdir()}
        with self.assertRaises(release.ReleaseFailure) as cm:
            release.build(self.root, None, self.pak, self.expected)
        message = str(cm.exception)
        self.assertIn("never delete", message)
        self.assertIn("Rename-Item -LiteralPath '%s' -NewName 'release-1.2.3-%s'" % (folder.resolve(), old_commit[:7]),
                      message)
        self.assertEqual({p.name: p.read_bytes() for p in folder.iterdir()}, before, "the old build is untouched")
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            self.assertEqual(release.main(["--root", str(self.root), "--pak", str(self.pak),
                                           "--pak-sha256", self.expected]), 1)
        self.assertIn("Rename-Item", err.getvalue())

    def test_unsafe_archive_paths_are_refused(self):
        with self.assertRaisesRegex(release.ReleaseFailure, "unsafe"):
            release.write_archive(Path(self.temp.name) / "bad.zip", {"../outside": b"no"})


class SourceGateTests(unittest.TestCase):
    def test_dirty_repository_is_rejected(self):
        with mock.patch.object(release, "git", return_value=" M Scripts/main.lua"):
            with self.assertRaisesRegex(release.ReleaseFailure, "dirty"):
                release.clean_revision(ROOT)

    def test_actual_candidate_packages_from_disposable_clean_snapshot(self):
        # Exercise real Git selection and all candidate Lua, without committing
        # or cleaning the user's working tree. This is not native acceptance.
        with tempfile.TemporaryDirectory(prefix="pwp-release-regression-") as directory:
            root = Path(directory) / "source"
            root.mkdir()
            names = ["Info.json", "README.md", "CHANGELOG.md", "LICENSE", "thumbnail.png",
                     release.ASSET_CONTRACT, release.PAK_LOGICAL, "tools/test_lua.py"]
            names += [p.relative_to(ROOT).as_posix() for p in (ROOT / "Scripts").glob("*.lua")]
            for name in names:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, target)
            for args in (("init",), ("add", "."),
                         ("-c", "user.name=Release Fixture", "-c", "user.email=fixture@example.invalid",
                          "-c", "commit.gpgsign=false", "-c", "core.hooksPath=NUL",
                          "commit", "-m", "Disposable release regression snapshot")):
                subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)
            contract = json.loads((root / release.ASSET_CONTRACT).read_text(encoding="utf-8"))
            env = {"PYTHONPATH": str(ROOT / ".test-deps") + os.pathsep + os.environ.get("PYTHONPATH", "")}
            with mock.patch.dict(os.environ, env):
                result = release.build(root, Path(directory) / "out", root / release.PAK_LOGICAL, contract["sha256"])
            for kind, record in result["archives"].items():
                with self.subTest(distribution=kind), zipfile.ZipFile(Path(directory) / "out" / record["file"]) as archive:
                    install = Path(directory) / kind
                    archive.extractall(install)
                    mod = install if kind == "workshop" else install / release.MANUAL_ROOT
                    scripts = mod / "Scripts"
                    self.assertFalse((scripts / "config.lua").exists())
                    self.assertTrue((scripts / "default_config.lua").is_file())
                    self.assertFalse((mod / "async-trial").exists())
                    self.assertFalse((mod / "remote.txt").exists())
                    sys.path.insert(0, str(ROOT / ".test-deps"))
                    from lupa.lua54 import LuaRuntime
                    lua = LuaRuntime(unpack_returned_tuples=True)
                    lua.globals().PACKAGE_ROOT = mod.as_posix() + "/"
                    lua.execute('''
                        package.path = PACKAGE_ROOT .. 'Scripts/?.lua'
                        local configuration = require('configuration')
                        local cfg, why, fresh = configuration.load(PACKAGE_ROOT, PACKAGE_ROOT .. 'Scripts/')
                        assert(cfg and fresh, why)
                        local file = assert(io.open(PACKAGE_ROOT .. 'config.lua', 'wb'))
                        assert(file:write('return {work_priority={Mining=false,EmitFlame=2}}'))
                        assert(file:close())
                        cfg, why = configuration.load(PACKAGE_ROOT, PACKAGE_ROOT .. 'Scripts/')
                        assert(cfg and cfg.work_priority.Mining == false and cfg.work_priority.EmitFlame == 2, why)
                    ''')


if __name__ == "__main__":
    unittest.main()

