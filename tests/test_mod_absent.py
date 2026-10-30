"""tools/mod_absent.py with temporary directories and a fake tasklist only:
no game, nothing under D:/ is touched (round 4, tooling P3-7)."""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import mod_absent as ma

CLOSED = "INFO: No tasks are running which match the specified criteria.\n"


def tasklist(stdout=CLOSED, code=0):
    def run(args, **kw):
        if args[0] != "tasklist":
            raise AssertionError("only tasklist may be started: %r" % (args,))
        return subprocess.CompletedProcess(args, code, stdout=stdout, stderr="broke" if code else "")
    return run


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))


class Fixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        game = tmp / "Palworld"
        mods = game / "Mods/NativeMods/UE4SS/Mods"
        patcher = mock.patch.multiple(ma, GAME=game, MODS=mods, MOD=mods / "PalWorkPriority",
                                      PAK=game / "Pal/Content/Paks/LogicMods/PalWorkPriority.pak",
                                      BACKUPS=tmp / "backups")
        patcher.start()
        self.addCleanup(patcher.stop)
        run = mock.patch.object(ma.subprocess, "run", tasklist())
        run.start()
        self.addCleanup(run.stop)
        write(ma.MOD / "Scripts/main.lua", 'local VERSION = "0.5.0"\n')
        write(ma.MOD / "priorities.txt", "dev data\n")
        write(ma.PAK, b"dev pak")
        self.mods_txt = b"Other : 1\r\nPalWorkPriority : 1\r\n"
        write(ma.MODS / "mods.txt", self.mods_txt)

    def refused(self, fn, *args):
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as cm:
            fn(*args)
        self.assertIsInstance(cm.exception.code, str, "a refusal exits with a message")
        return cm.exception.code

    def remove(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            ma.main(["remove"])
        return Path(out.getvalue().splitlines()[0])

    def restore_code(self, q):
        with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit) as cm:
            ma.main(["restore", str(q)])
        return cm.exception.code, out.getvalue()


class Closed(Fixture):
    def test_running_game_refused(self):
        with mock.patch.object(ma.subprocess, "run", tasklist("Palworld-Win64-Shipping.e  4242 Console\n")):
            self.assertIn("close the game first", self.refused(ma.main, ["remove"]))
        self.assertTrue(ma.MOD.is_dir())

    def test_failed_tasklist_refused(self):
        # The exit code used to be ignored: an empty stdout read as "closed".
        with mock.patch.object(ma.subprocess, "run", tasklist("", code=1)):
            self.assertIn("cannot be confirmed closed", self.refused(ma.main, ["remove"]))
        self.assertTrue(ma.MOD.is_dir())


class NoAsserts(unittest.TestCase):
    def test_guard_survives_python_O(self):
        code = ("import sys, subprocess; sys.path.insert(0, %r); import mod_absent as ma; "
                "subprocess.run = lambda a, **k: subprocess.CompletedProcess(a, 0, stdout='Palworld-Win64-Shipping.e 1', stderr=''); "
                "ma.main(['remove'])" % str(ROOT / "tools"))
        r = subprocess.run([sys.executable, "-O", "-c", code], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("close the game first", r.stderr)


class RemoveRestore(Fixture):
    def test_round_trip(self):
        q = self.remove()
        self.assertFalse(ma.MOD.exists())
        self.assertFalse(ma.PAK.exists())
        self.assertEqual((ma.MODS / "mods.txt").read_bytes(), b"Other : 1\r\nPalWorkPriority : 0\r\n")
        code, out = self.restore_code(q)
        self.assertEqual(code, 0, out)
        self.assertIn("0 hash mismatches", out)
        self.assertEqual((ma.MOD / "priorities.txt").read_text(encoding="utf-8"), "dev data\n")
        self.assertEqual((ma.MODS / "mods.txt").read_bytes(), self.mods_txt)

    def test_remove_without_a_single_enabled_line_moves_nothing(self):
        write(ma.MODS / "mods.txt", b"PalWorkPriority : 0\r\n")
        self.assertIn("no single enabled", self.refused(ma.main, ["remove"]))
        self.assertTrue(ma.MOD.is_dir())
        self.assertFalse(ma.BACKUPS.exists(), "no quarantine folder is created")

    def test_restore_checks_the_quarantine_before_moving(self):
        # The old restore moved first and found a changed file only after.
        q = self.remove()
        write(q / "PalWorkPriority/priorities.txt", "changed while away\n")
        msg = self.refused(ma.main, ["restore", str(q)])
        self.assertIn("does not match its manifest", msg)
        self.assertIn("PalWorkPriority/priorities.txt", msg)
        self.assertFalse(ma.MOD.exists(), "nothing was moved back")
        self.assertTrue((q / "LogicMods/PalWorkPriority.pak").is_file())
        self.assertEqual((ma.MODS / "mods.txt").read_bytes(), b"Other : 1\r\nPalWorkPriority : 0\r\n")

    def test_restore_refuses_a_missing_or_extra_file(self):
        q = self.remove()
        (q / "LogicMods/PalWorkPriority.pak").unlink()
        self.assertIn("LogicMods/PalWorkPriority.pak", self.refused(ma.main, ["restore", str(q)]))
        write(q / "LogicMods/PalWorkPriority.pak", b"dev pak")
        write(q / "PalWorkPriority/extra.txt", "new")
        self.assertIn("PalWorkPriority/extra.txt", self.refused(ma.main, ["restore", str(q)]))
        self.assertFalse(ma.MOD.exists())

    def test_restore_refuses_while_the_mod_is_present(self):
        q = self.remove()
        write(ma.MOD / "Scripts/main.lua", "a fresh install\n")
        self.assertIn("already present", self.refused(ma.main, ["restore", str(q)]))
        self.assertTrue((q / "PalWorkPriority/priorities.txt").is_file())

    def test_restore_of_a_folder_without_manifest_refused(self):
        self.remove()
        self.assertIn("no manifest.sha256", self.refused(ma.main, ["restore", str(ma.BACKUPS)]))


if __name__ == "__main__":
    unittest.main()
