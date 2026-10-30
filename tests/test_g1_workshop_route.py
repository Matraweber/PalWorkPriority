"""tools/g1_workshop_route.py with temporary directories and a fake tasklist
only: no game, no Steam, nothing under D:/ is touched (round 4, tooling
P3-8). The tag checks read a temporary git repository."""
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
import g1_workshop_route as g1
import g7_install_matrix as g7

REAL_RUN = subprocess.run


def git(repo, *args):
    return REAL_RUN(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                     "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", *args],
                    check=True, capture_output=True, text=True).stdout.strip()


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))


def fake_run(args, **kw):
    if args[0] == "git":
        return REAL_RUN(args, **kw)
    if args[0] != "tasklist":
        raise AssertionError("only tasklist and git may be started: %r" % (args,))
    return subprocess.CompletedProcess(args, 0, stdout="INFO: No tasks are running.\n", stderr="")


class Fixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = self.tmp = Path(self._tmp.name)
        game = tmp / "Palworld"
        mods = game / "Mods/NativeMods/UE4SS/Mods"
        paths = dict(GAME=game, MODS=mods, MOD=mods / "PalWorkPriority",
                     PAK=game / "Pal/Content/Paks/LogicMods/PalWorkPriority.pak",
                     SETTINGS=game / "Mods/PalModSettings.ini", MANAGED=game / "Mods/ManagedMods",
                     WS=tmp / "workshop/3786408856", BACKUPS=tmp / "backups")
        for module in (g1, g7):
            patcher = mock.patch.multiple(module, **{k: v for k, v in paths.items() if hasattr(module, k)})
            patcher.start()
            self.addCleanup(patcher.stop)
        repo = tmp / "repo"
        repo.mkdir()
        git(repo, "init", "-q")
        (repo / "log.txt").write_text("x\n", encoding="utf-8")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "release")
        git(repo, "tag", "-a", "v0.5.0", "-m", "0.5.0")
        self.commit = git(repo, "rev-parse", "HEAD")
        patcher = mock.patch.object(g7, "REPO", repo)
        patcher.start()
        self.addCleanup(patcher.stop)
        run = mock.patch.object(g1.subprocess, "run", fake_run)
        run.start()
        self.addCleanup(run.stop)
        write(g1.MOD / "Scripts/main.lua", 'local VERSION = "0.5.0-dev"\n')
        write(g1.MOD / "priorities.txt", "dev data\n")
        write(g1.PAK, b"dev pak")
        write(g1.SETTINGS, "[PalModSettings]\r\nbGlobalEnableMod=True\r\n")
        write(g1.MODS / "mods.txt", "PalWorkPriority : 1\r\n")
        write(g1.MANAGED / "Other/Info.json", '{"Version": "1"}')
        write(g1.WS / "Info.json", '{"Version": "0.4.1"}')
        write(g1.WS / ".workshop.json", '{"publishedfileid": "3786408856"}')
        with contextlib.redirect_stdout(io.StringIO()) as out:
            g1.prepare()
        self.backup = Path(out.getvalue().strip().splitlines()[-1])

    def loader_installs(self):
        """What the game's loader does on launch with the item active."""
        write(g1.MOD / "Scripts/main.lua", 'local VERSION = "0.4.1"\n')
        write(g1.PAK, b"0.4.1 pak")
        write(g1.MANAGED / "PalWorkPriority/Info.json", '{"Version": "0.4.1"}')
        write(g1.MANAGED / "Other/Info.json", '{"Version": "2"}')

    def release(self, sha=None, commit=None):
        build = self.tmp / "build/release-0.5.0"
        archive = build / "PalWorkPriority-0.5.0-workshop.zip"
        build.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("Info.json", json.dumps({"Version": "0.5.0"}))
            z.writestr("Scripts/main.lua", 'local VERSION = "0.5.0"\n')
        write(build / "PalWorkPriority-0.5.0-release.json", json.dumps(
            {"version": "0.5.0", "source_commit": commit or self.commit,
             "archives": {"workshop": {"file": archive.name,
                                       "sha256": sha or hashlib.sha256(archive.read_bytes()).hexdigest()}}}))
        return archive

    def refused(self, *argv):
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as cm:
            g1.main(list(argv))
        self.assertIsInstance(cm.exception.code, str, "a refusal exits with a message")
        return cm.exception.code

    def run_main(self, *argv):
        with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit) as cm:
            g1.main(list(argv))
        return cm.exception.code, out.getvalue()


class Update(Fixture):
    def test_tagged_build_replaces_the_files(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            g1.main(["update", str(self.release()), "--state", str(self.backup)])
        self.assertIn("built from %s = tag v0.5.0" % self.commit, out.getvalue())
        self.assertEqual(json.loads((g1.WS / "Info.json").read_text())["Version"], "0.5.0")
        self.assertEqual((g1.WS / ".workshop.json").read_text(), '{"publishedfileid": "3786408856"}')

    def test_unlisted_hash_or_other_commit_refused_before_rmtree(self):
        before = g1.tree(g1.WS)
        msg = self.refused("update", str(self.release(sha="0" * 64)), "--state", str(self.backup))
        self.assertIn("not the archive that was built", msg)
        self.assertEqual(g1.tree(g1.WS), before)
        msg = self.refused("update", str(self.release(commit="1" * 40)), "--state", str(self.backup))
        self.assertIn("but tag v0.5.0 is", msg)
        self.assertEqual(g1.tree(g1.WS), before)

    def test_update_needs_state(self):
        self.assertIn("update needs --state", self.refused("update", str(self.release())))


class Restore(Fixture):
    def test_round_trip_puts_back_managed_mods(self):
        self.loader_installs()
        code, out = self.run_main("restore", "--state", str(self.backup))
        self.assertEqual(code, 0, out)
        self.assertIn("ManagedMods identical: True", out)
        self.assertEqual((g1.MOD / "priorities.txt").read_text(encoding="utf-8"), "dev data\n")
        self.assertEqual(g1.PAK.read_bytes(), b"dev pak")
        self.assertEqual(sorted(p.name for p in g1.MANAGED.iterdir()), ["Other"])
        self.assertEqual((g1.MANAGED / "Other/Info.json").read_text(), '{"Version": "1"}')
        after = list(self.backup.glob("after-*"))
        self.assertEqual(len(after), 1)
        self.assertTrue((after[0] / "ManagedMods/PalWorkPriority/Info.json").is_file(), "kept, not deleted")

    def test_second_restore_moves_nothing(self):
        # The old restore moved the restored dev install into after/ and
        # then crashed on the missing dev-PalWorkPriority.
        self.loader_installs()
        self.run_main("restore", "--state", str(self.backup))
        code, out = self.run_main("restore", "--state", str(self.backup))
        self.assertEqual(code, 0, out)
        self.assertIn("already restored", out)
        self.assertEqual((g1.MOD / "priorities.txt").read_text(encoding="utf-8"), "dev data\n")
        self.assertEqual(len(list(self.backup.glob("after-*"))), 1)

    def test_changed_backup_refused_before_anything_moves(self):
        self.loader_installs()
        write(self.backup / "dev-PalWorkPriority/priorities.txt", "changed\n")
        self.assertIn("dev-PalWorkPriority differs", self.refused("restore", "--state", str(self.backup)))
        self.assertIn("0.4.1", (g1.MOD / "Scripts/main.lua").read_text(encoding="utf-8"))
        self.assertTrue((g1.MANAGED / "PalWorkPriority").is_dir())
        self.assertEqual(list(self.backup.glob("after-*")), [])

    def test_changed_managed_mods_backup_refused(self):
        write(self.backup / "ManagedMods/Other/Info.json", '{"Version": "changed"}')
        self.assertIn("ManagedMods is missing or differs", self.refused("restore", "--state", str(self.backup)))

    def test_restore_needs_state(self):
        self.assertIn("restore needs --state", self.refused("restore"))
        self.assertIn("no state.json", self.refused("restore", "--state", str(self.tmp)))


if __name__ == "__main__":
    unittest.main()
