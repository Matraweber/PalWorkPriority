"""tools/g7_install_matrix.py with temporary directories and a fake tasklist
only: no game, no Steam, nothing under D:/ is touched."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import g7_install_matrix as g7

MANUAL_ROOT = "Mods/NativeMods/UE4SS/Mods/PalWorkPriority/"


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))


def tasklist(running=False, code=0):
    out = ("Palworld-Win64-Shipping.e  4242 Console  1  9,000,000 K\n" if running
           else "INFO: No tasks are running which match the specified criteria.\n")

    def run(args, **kw):
        if args[0] != "tasklist":
            raise AssertionError("only tasklist may be started: %r" % (args,))
        return subprocess.CompletedProcess(args, code, stdout=out, stderr="tasklist broke" if code else "")
    return run


class Fixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        self.tmp = tmp
        game = tmp / "Palworld"
        mods = game / "Mods/NativeMods/UE4SS/Mods"
        paths = dict(GAME=game, MODS=mods, MOD=mods / "PalWorkPriority",
                     PAK=game / "Pal/Content/Paks/LogicMods/PalWorkPriority.pak",
                     SETTINGS=game / "Mods/PalModSettings.ini", MANAGED=game / "Mods/ManagedMods",
                     WS=tmp / "workshop/3786408856", BACKUPS=tmp / "backups")
        patcher = mock.patch.multiple(g7, **paths)
        patcher.start()
        self.addCleanup(patcher.stop)
        run = mock.patch.object(g7.subprocess, "run", tasklist())
        run.start()
        self.addCleanup(run.stop)
        # The dev install the matrix moves aside and restores.
        write(g7.MOD / "Scripts/main.lua", 'local VERSION = "0.5.0-dev"\n')
        write(g7.MOD / "priorities.txt", "dev data\n")
        write(g7.PAK, b"dev pak")
        write(g7.SETTINGS, "[PalModSettings]\r\nbGlobalEnableMod=True\r\n")
        write(g7.MODS / "mods.txt", "PalWorkPriority : 1\r\n")
        write(g7.MANAGED / "Other/Info.json", '{"Version": "1"}')
        write(g7.WS / "Info.json", '{"Version": "0.4.1"}')
        write(g7.WS / ".workshop.json", '{"publishedfileid": "3786408856"}')

    def quiet(self, fn, *args):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            result = fn(*args)
        return result, out.getvalue()

    def refused(self, fn, *args):
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as cm:
            fn(*args)
        self.assertIsInstance(cm.exception.code, str, "a refusal exits with a message")
        return cm.exception.code

    def prepare(self):
        _, out = self.quiet(g7.prepare)
        return Path(out.strip().splitlines()[-1])

    def manual_zip(self, version="0.5.0", manifest=True, sha=None):
        build = self.tmp / ("build/release-%s" % version)
        archive = build / ("PalWorkPriority-%s-manual.zip" % version)
        archive.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr(MANUAL_ROOT + "Scripts/main.lua", 'local VERSION = "%s"\n' % version)
            z.writestr("Pal/Content/Paks/LogicMods/PalWorkPriority.pak", b"release pak")
        if manifest:
            listed = sha or hashlib.sha256(archive.read_bytes()).hexdigest()
            write(build / ("PalWorkPriority-%s-release.json" % version), json.dumps(
                {"archives": {"manual": {"file": archive.name, "sha256": listed}}}))
        return archive


class NoAsserts(unittest.TestCase):
    def test_guards_survive_python_O(self):
        code = ("import sys, subprocess; sys.path.insert(0, %r); import g7_install_matrix as g7; "
                "subprocess.run = lambda a, **k: subprocess.CompletedProcess(a, 0, stdout='Palworld-Win64-Shipping.e 1', stderr=''); "
                "g7.closed()" % str(ROOT / "tools"))
        r = subprocess.run([sys.executable, "-O", "-c", code], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("close the game first", r.stderr)


class Closed(Fixture):
    def test_running_game_refused_with_message(self):
        with mock.patch.object(g7.subprocess, "run", tasklist(running=True)):
            self.assertIn("close the game first", self.refused(g7.closed))

    def test_closed_game_passes(self):
        self.assertIsNone(g7.closed())

    def test_failed_tasklist_refused(self):
        with mock.patch.object(g7.subprocess, "run", tasklist(code=1)):
            self.assertIn("cannot be confirmed closed", self.refused(g7.closed))

    def test_every_command_checks_first(self):
        with mock.patch.object(g7.subprocess, "run", tasklist(running=True)):
            self.assertIn("close the game first", self.refused(g7.main, ["wipe"]))
        self.assertTrue(g7.MOD.is_dir(), "wipe did not run")
        self.assertTrue(g7.PAK.is_file())


class Restore(Fixture):
    def setUp(self):
        super().setUp()
        self.backup = self.prepare()
        self.assertFalse(g7.MOD.exists(), "prepare moved the dev install aside")
        # A test install from the matrix, which restore replaces.
        self.quiet(g7.manual, self.manual_zip())
        write(g7.WS / "Info.json", '{"Version": "0.5.0"}')

    def restore_code(self):
        with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit) as cm:
            g7.restore(self.backup)
        return cm.exception.code, out.getvalue()

    def assert_untouched(self):
        self.assertIn("0.5.0", (g7.MOD / "Scripts/main.lua").read_text(encoding="utf-8"))
        self.assertEqual(g7.PAK.read_bytes(), b"release pak")
        self.assertEqual(json.loads((g7.WS / "Info.json").read_text())["Version"], "0.5.0")
        self.assertTrue((self.backup / "workshop-3786408856").is_dir())

    def test_round_trip(self):
        code, out = self.restore_code()
        self.assertEqual(code, 0, out)
        self.assertIn("identical: True", out)
        self.assertEqual((g7.MOD / "priorities.txt").read_text(encoding="utf-8"), "dev data\n")
        self.assertEqual(g7.PAK.read_bytes(), b"dev pak")
        self.assertEqual(json.loads((g7.WS / "Info.json").read_text())["Version"], "0.4.1")

    def test_changed_dev_tree_refused_before_wipe(self):
        write(self.backup / "dev-PalWorkPriority/priorities.txt", "changed\n")
        self.assertIn("dev-PalWorkPriority differs", self.refused(g7.restore, self.backup))
        self.assert_untouched()

    def test_missing_backup_pak_refused_before_wipe(self):
        (self.backup / "dev-LogicMods/PalWorkPriority.pak").unlink()
        self.assertIn("PalWorkPriority.pak is missing", self.refused(g7.restore, self.backup))
        self.assert_untouched()

    def test_changed_workshop_backup_refused_before_rmtree(self):
        (self.backup / "workshop-3786408856/.workshop.json").unlink()
        self.assertIn("workshop-3786408856 differs", self.refused(g7.restore, self.backup))
        self.assert_untouched()

    def test_missing_settings_backup_refused(self):
        (self.backup / "mods.txt").unlink()
        self.assertIn("mods.txt is missing", self.refused(g7.restore, self.backup))
        self.assert_untouched()

    def test_old_state_without_settings_hashes_still_restores(self):
        state = json.loads((self.backup / "state.json").read_text())
        del state["settings"], state["mods_txt"]
        (self.backup / "state.json").write_text(json.dumps(state))
        code, out = self.restore_code()
        self.assertEqual(code, 0, out)

    def test_no_state_refused(self):
        self.assertIn("--state", self.refused(g7.restore, None))
        self.assertIn("no state.json", self.refused(g7.restore, self.tmp / "nowhere"))
        self.assert_untouched()

    def test_main_restore_needs_state(self):
        self.assertIn("--state", self.refused(g7.main, ["restore"]))
        self.assert_untouched()


class Manual(Fixture):
    def setUp(self):
        super().setUp()
        self.prepare()

    def test_matching_archive_extracts(self):
        _, out = self.quiet(g7.manual, self.manual_zip())
        self.assertIn("extracted 2 files", out)
        self.assertEqual(g7.PAK.read_bytes(), b"release pak")

    def test_hash_mismatch_refused_before_extracting(self):
        msg = self.refused(g7.manual, self.manual_zip(sha="0" * 64))
        self.assertIn("not the archive that was built", msg)
        self.assertFalse(g7.MOD.exists())
        self.assertFalse(g7.PAK.exists())

    def test_rebuilt_archive_next_to_old_manifest_refused(self):
        archive = self.manual_zip()
        with zipfile.ZipFile(archive, "a") as z:
            z.writestr("extra.txt", "rebuilt")
        self.assertIn("not the archive that was built", self.refused(g7.manual, archive))
        self.assertFalse(g7.MOD.exists())

    def test_without_manifest_needs_sha256(self):
        archive = self.manual_zip(version="0.4.1", manifest=False)
        self.assertIn("--sha256", self.refused(g7.manual, archive))
        self.assertFalse(g7.MOD.exists())
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.assertIn("not the archive", self.refused(g7.manual, archive, "f" * 64))
        _, out = self.quiet(g7.manual, archive, digest.upper())
        self.assertIn("extracted 2 files", out)

    def test_sha256_option_must_agree_with_manifest(self):
        self.assertIn("differs from the release manifest", self.refused(g7.manual, self.manual_zip(), "1" * 64))
        self.assertFalse(g7.MOD.exists())

    def test_main_passes_sha256(self):
        archive = self.manual_zip(version="0.4.1", manifest=False)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        _, out = self.quiet(g7.main, ["manual", str(archive), "--sha256", digest])
        self.assertIn("extracted 2 files", out)

    def test_missing_archive_refused(self):
        self.assertIn("archive not found", self.refused(g7.manual, self.tmp / "missing.zip"))


if __name__ == "__main__":
    unittest.main()
