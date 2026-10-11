import hashlib
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


def source_tree(root):
    (root / "Scripts").mkdir(parents=True)
    (root / "tools").mkdir()
    info = {
        "Version": "1.2.3", "PackageName": "PalWorkPriority", "DebugMode": False,
        "InstallRule": [{"Type": "Lua", "Targets": ["./Scripts"]},
                        {"Type": "Lua", "IsServer": True, "Targets": ["./Scripts"]},
                        {"Type": "LogicMods", "Targets": ["./LogicMods/"]}],
    }
    (root / "Info.json").write_text(json.dumps(info), encoding="utf-8")
    for filename in ("README.md", "CHANGELOG.md", "LICENSE", "thumbnail.png"):
        (root / filename).write_bytes(b"fixture " + filename.encode())
    (root / "Scripts" / "main.lua").write_text('local VERSION = "1.2.3"\nreturn VERSION\n', encoding="utf-8")
    (root / "Scripts" / "config.lua").write_text("return { enabled = true }\n", encoding="utf-8")
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
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(release, "clean_revision", return_value="a" * 40).start()
        mock.patch.object(release, "tracked_lua", side_effect=lambda root: sorted(
            p.relative_to(root).as_posix() for p in (root / "Scripts").glob("*.lua"))).start()
        dependency_path = str(ROOT / ".test-deps")
        mock.patch.dict(os.environ, {"PYTHONPATH": dependency_path + os.pathsep + os.environ.get("PYTHONPATH", "")}).start()

    def write_contract(self):
        (self.root / release.ASSET_CONTRACT).write_text(json.dumps(self.contract), encoding="utf-8")

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
                with self.assertRaises(release.ReleaseFailure):
                    release.build(self.root, self.output, self.pak, self.expected)
                self.contract = original
        (self.root / release.ASSET_CONTRACT).unlink()
        with self.assertRaisesRegex(release.ReleaseFailure, "contract is missing"):
            release.build(self.root, self.output, self.pak, self.expected)
        self.assertFalse(self.output.exists())

    def test_contract_change_during_compile_is_detected(self):
        def change_contract(_):
            self.contract["native_acceptance"] = "changed during validation"
            self.write_contract()
        with mock.patch.object(release, "compile_gate", side_effect=change_contract):
            with self.assertRaisesRegex(release.ReleaseFailure, "changed during validation"):
                release.build(self.root, self.output, self.pak, self.expected)
        self.assertFalse(self.output.exists())

    def test_defaults_required_and_ambiguous_sources_rejected(self):
        config = self.root / "Scripts/config.lua"
        config.unlink()
        with self.assertRaisesRegex(release.ReleaseFailure, "default configuration is missing"):
            release.build(self.root, self.output, self.pak, self.expected)
        config.write_text("return {}", encoding="utf-8")
        (self.root / "Scripts/default_config.lua").write_text("return {}", encoding="utf-8")
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
            (self.root / filename).write_text("must not ship", encoding="utf-8")
        (self.root / "Scripts" / "remote.txt").write_text("trigger", encoding="utf-8")
        (self.root / "Scripts" / "main.lua.bak").write_text("old", encoding="utf-8")
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
            self.assertIn("Alt+F1", m.read("INSTALL.txt").decode())
            self.assertNotIn("Scripts/config.lua", w.namelist())
            self.assertIn("Scripts/default_config.lua", w.namelist())
            self.assertIn(release.MANUAL_ROOT + "enabled.txt", m.namelist())
            for archive in (w, m):
                for name in archive.namelist():
                    self.assertNotIn(Path(name).name, ("caps.txt", "priorities.txt", "remote.txt", "priority.log", "accidental.lua", ".workshop.json", "main.lua.bak"))
                    self.assertEqual(archive.getinfo(name).date_time, release.FIXED_TIME)

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
        (self.root / "Scripts" / "main.lua").write_text('local VERSION = "9.9.9"\n', encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseFailure, "versions differ"):
            release.build(self.root, self.output, self.pak, self.expected)
        self.assertFalse(self.output.exists())

    def test_real_compiler_rejects_syntax_custom_structural_check_misses(self):
        (self.root / "Scripts" / "bad.lua").write_text("local x = (1 + )", encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseFailure, "Lua compile gate failed"):
            release.build(self.root, self.output, self.pak, self.expected)
        self.assertFalse(self.output.exists())

    def test_missing_compiler_gate_fails_closed(self):
        (self.root / "tools" / "test_lua.py").unlink()
        with self.assertRaisesRegex(release.ReleaseFailure, "compiler gate"):
            release.build(self.root, self.output, self.pak, self.expected)

    def test_existing_different_release_is_not_overwritten(self):
        result = release.build(self.root, self.output, self.pak, self.expected)
        target = self.output / result["archives"]["manual"]["file"]
        target.write_bytes(b"keep this earlier artifact")
        with self.assertRaisesRegex(release.ReleaseFailure, "overwrite a different release"):
            release.build(self.root, self.output, self.pak, self.expected)
        self.assertEqual(target.read_bytes(), b"keep this earlier artifact")

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

