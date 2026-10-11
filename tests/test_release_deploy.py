"""Deployment safety tests use isolated fake game directories only."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "nt" and shutil.which("powershell.exe"), "Windows PowerShell required")
class DeploySafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pwp-deploy-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        (self.source / "tools").mkdir(parents=True)
        (self.source / "Scripts").mkdir()
        shutil.copyfile(ROOT / "tools" / "deploy.ps1", self.source / "tools" / "deploy.ps1")
        shutil.copyfile(ROOT / "tools" / "test_lua.py", self.source / "tools" / "test_lua.py")
        shutil.copyfile(ROOT / "tools" / "paths.py", self.source / "tools" / "paths.py")
        (self.source / "Scripts" / "main.lua").write_text("return true\n", encoding="utf-8")
        (self.source / "Scripts" / "config.lua").write_text("return { enabled = true }\n", encoding="utf-8")
        (self.source / "Info.json").write_text('{"Version":"fixture"}', encoding="utf-8")
        self.game = self.base / "fake-game"
        self.mods = self.game / "Mods" / "NativeMods" / "UE4SS" / "Mods"
        self.target = self.mods / "PalWorkPriority"
        (self.target / "Scripts").mkdir(parents=True)
        (self.target / "Scripts" / "main.lua").write_text("old code\n", encoding="utf-8")
        (self.target / "Scripts" / "config.lua").write_text("return { enabled = false }\n", encoding="utf-8")
        (self.target / "priorities.txt").write_bytes(b"pal|1|X\n")
        (self.target / "caps.txt").write_bytes(b"guild|Mining|Stone|100\n")
        (self.mods / "mods.txt").write_text("Keybinds : 1\nOtherMod : 1\n", encoding="utf-8")

    def invoke(self, *extra, discover=False, override=None):
        environment = os.environ.copy()
        environment["PWP_CLIENT_ROOT"] = str(override or self.game)
        environment["PYTHONIOENCODING"] = "cp1252"
        environment["PYTHONPATH"] = str(ROOT / ".test-deps") + os.pathsep + environment.get("PYTHONPATH", "")
        return subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             str(self.source / "tools" / "deploy.ps1"),
             *([] if discover else ["-GamePath", str(self.game)]), *extra],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            env=environment, timeout=30,
        )

    def assert_saves_unchanged(self):
        self.assertEqual((self.target / "priorities.txt").read_bytes(), b"pal|1|X\n")
        self.assertEqual((self.target / "caps.txt").read_bytes(), b"guild|Mining|Stone|100\n")

    def test_default_target_uses_validated_discovery(self):
        result = self.invoke(discover=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.target / "Scripts" / "main.lua").read_text(), "return true\n")
        self.assert_saves_unchanged()

    def test_invalid_discovery_does_not_touch_target(self):
        before = {str(p.relative_to(self.game)): p.read_bytes() for p in self.game.rglob("*") if p.is_file()}
        result = self.invoke(discover=True, override=self.base / "missing-game")
        self.assertNotEqual(result.returncode, 0)
        after = {str(p.relative_to(self.game)): p.read_bytes() for p in self.game.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_unicode_discovery_preserves_exact_target(self):
        unicode_game = self.base / "Spiele-ä-日本語"
        shutil.copytree(self.game, unicode_game)
        result = self.invoke(discover=True, override=unicode_game)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        relative = self.target.relative_to(self.game)
        self.assertEqual((unicode_game / relative / "Scripts" / "main.lua").read_text(), "return true\n")
        self.assertEqual((self.target / "Scripts" / "main.lua").read_text(), "old code\n")

    def test_discovery_preserves_unicode_whitespace_suffix(self):
        exact_game = self.base / (self.game.name + "\u00a0")
        shutil.copytree(self.game, exact_game)
        before = {str(p.relative_to(self.game)): p.read_bytes() for p in self.game.rglob("*") if p.is_file()}
        result = self.invoke(discover=True, override=exact_game)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        relative = self.target.relative_to(self.game)
        self.assertEqual((exact_game / relative / "Scripts" / "main.lua").read_text(), "return true\n")
        self.assertEqual(before, {str(p.relative_to(self.game)): p.read_bytes() for p in self.game.rglob("*") if p.is_file()})

    def test_malformed_discovery_stdout_fails_without_writes(self):
        root = str(self.game).encode("utf-8")
        for output, code in ((b"", 0), (b"\n", 0), (b" \t\n", 0),
                             (root + b"\nnoise\n", 0), (root + b"\n\n", 0),
                             (b"relative\n", 0), (b"C:relative\n", 0),
                             (root + b"\x00\n", 0), (root + b"\xff\n", 0),
                             (root + b"\n", 1)):
            with self.subTest(output=output, code=code):
                (self.source / "tools" / "paths.py").write_text(
                    f"import sys\nsys.stdout.buffer.write({output!r})\nsys.exit({code})\n", encoding="ascii")
                before = {str(p.relative_to(self.game)): p.read_bytes() for p in self.game.rglob("*") if p.is_file()}
                result = self.invoke(discover=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(before, {str(p.relative_to(self.game)): p.read_bytes() for p in self.game.rglob("*") if p.is_file()})

    def test_explicit_target_bypasses_invalid_discovery(self):
        (self.source / "tools" / "paths.py").write_text("raise AssertionError('discovery must not run')\n", encoding="ascii")
        result = self.invoke(override=self.base / "missing")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_saves_unchanged()

    def test_legacy_configuration_and_entire_old_code_generation_are_preserved(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.target / "config.lua").read_text(), "return { enabled = false }\n")
        backups = list((self.target / "backups").glob("deploy-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "legacy-config.lua").read_bytes(), (self.target / "config.lua").read_bytes())
        self.assertEqual((backups[0] / "Scripts" / "main.lua").read_text(), "old code\n")
        self.assertEqual((self.target / "Scripts" / "main.lua").read_text(), "return true\n")
        self.assert_saves_unchanged()
        self.assertEqual((self.mods / "mods.txt").read_text().splitlines()[0], "PalWorkPriority : 1")

    def test_existing_root_configuration_is_never_replaced(self):
        (self.target / "config.lua").write_text("return { user_choice = 42 }\n", encoding="utf-8")
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.target / "config.lua").read_text(), "return { user_choice = 42 }\n")
        self.assert_saves_unchanged()

    def test_real_lua_syntax_failure_leaves_game_directory_untouched(self):
        (self.source / "Scripts" / "main.lua").write_text("local x = (1 + )", encoding="utf-8")
        before = {str(path.relative_to(self.game)): path.read_bytes() for path in self.game.rglob("*") if path.is_file()}
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        after = {str(path.relative_to(self.game)): path.read_bytes() for path in self.game.rglob("*") if path.is_file()}
        self.assertEqual(before, after)

    def test_missing_compiler_gate_leaves_game_directory_untouched(self):
        (self.source / "tools" / "test_lua.py").unlink()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.target / "backups").exists())
        self.assertEqual((self.target / "Scripts" / "main.lua").read_text(), "old code\n")
        self.assert_saves_unchanged()

    def test_recovery_markers_refuse_deploy_and_disable_without_any_writes(self):
        for name in (".settings-cutover", "async-trial/launch.lua", "async-trial/receipt.lua"):
            for directory in (False, True):
                for extra in ((), ("-Remove",)):
                    with self.subTest(marker=name, directory=directory, extra=extra):
                        marker = self.target / name
                        marker.parent.mkdir(parents=True, exist_ok=True)
                        if directory:
                            marker.mkdir()
                        else:
                            marker.write_bytes(b"preserve; never execute")
                        before = {str(p.relative_to(self.game)): p.read_bytes()
                                  for p in self.game.rglob("*") if p.is_file()}
                        paths = {str(p.relative_to(self.game)) for p in self.game.rglob("*")}
                        try:
                            result = self.invoke(*extra)
                            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                            self.assertIn("settings recovery", result.stdout + result.stderr)
                            self.assertEqual(before, {str(p.relative_to(self.game)): p.read_bytes()
                                                     for p in self.game.rglob("*") if p.is_file()})
                            self.assertEqual(paths, {str(p.relative_to(self.game)) for p in self.game.rglob("*")})
                        finally:
                            if directory:
                                marker.rmdir()
                            else:
                                marker.unlink()

    def test_invalid_trial_ancestor_refuses_without_mutation(self):
        (self.target / "async-trial").write_bytes(b"not a directory")
        for extra in ((), ("-Remove",)):
            with self.subTest(extra=extra):
                before = {str(p.relative_to(self.game)): p.read_bytes()
                          for p in self.game.rglob("*") if p.is_file()}
                paths = {str(p.relative_to(self.game)) for p in self.game.rglob("*")}
                result = self.invoke(*extra)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("settings recovery", result.stdout + result.stderr)
                self.assertEqual(before, {str(p.relative_to(self.game)): p.read_bytes()
                                         for p in self.game.rglob("*") if p.is_file()})
                self.assertEqual(paths, {str(p.relative_to(self.game)) for p in self.game.rglob("*")})

    def test_marker_created_during_compilation_prevents_code_activation(self):
        for compile_number in (1, 2):
            with self.subTest(compile_number=compile_number):
                marker = self.target / ".settings-cutover"
                counter = self.base / "compile-count"
                counter.write_text("0", encoding="ascii")
                (self.source / "tools" / "test_lua.py").write_text(
                    "from pathlib import Path\n"
                    f"counter=Path({str(counter)!r})\n"
                    "n=int(counter.read_text())+1; counter.write_text(str(n))\n"
                    f"if n=={compile_number}: Path({str(marker)!r}).write_bytes(b'preserve')\n",
                    encoding="utf-8")
                before_code = (self.target / "Scripts" / "main.lua").read_bytes()
                before_mods = (self.mods / "mods.txt").read_bytes()
                result = self.invoke()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("settings recovery", result.stdout + result.stderr)
                self.assertEqual((self.target / "Scripts" / "main.lua").read_bytes(), before_code)
                self.assertEqual((self.mods / "mods.txt").read_bytes(), before_mods)
                self.assertFalse((self.target / "backups").exists())
                self.assertFalse((self.target / "config.lua").exists())
                self.assertEqual(marker.read_bytes(), b"preserve")
                self.assert_saves_unchanged()
                marker.unlink()

    def test_remove_disables_without_deleting_player_data_or_code(self):
        result = self.invoke("-Remove")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PalWorkPriority : 0", (self.mods / "mods.txt").read_text())
        self.assertEqual((self.target / "Scripts" / "main.lua").read_text(), "old code\n")
        self.assert_saves_unchanged()


if __name__ == "__main__":
    unittest.main()
