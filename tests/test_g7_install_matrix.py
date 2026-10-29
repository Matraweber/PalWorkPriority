"""tools/g7_install_matrix.py with temporary directories and a fake tasklist
only: no game, no Steam, nothing under D:/ is touched. The tag checks read a
temporary git repository."""
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
REAL_RUN = subprocess.run


def git(repo, *args):
    return REAL_RUN(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                     "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", *args],
                    check=True, capture_output=True, text=True).stdout.strip()


def commit(repo, message):
    (repo / "log.txt").write_text(message + "\n", encoding="utf-8")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))


def tasklist(running=False, code=0):
    out = ("Palworld-Win64-Shipping.e  4242 Console  1  9,000,000 K\n" if running
           else "INFO: No tasks are running which match the specified criteria.\n")

    def run(args, **kw):
        if args[0] == "git" and args[1:3] == ["-C", str(g7.REPO)]:
            return REAL_RUN(args, **kw)  # the temporary repository's tags
        if args[0] != "tasklist":
            raise AssertionError("only tasklist and git may be started: %r" % (args,))
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
                     WS=tmp / "workshop/3786408856", BACKUPS=tmp / "backups", REPO=tmp / "repo")
        paths["REPO"].mkdir()
        git(paths["REPO"], "init", "-q")
        self.old_commit = commit(paths["REPO"], "the first 0.5.0 build")
        self.tagged = commit(paths["REPO"], "fixes, then the tag moved here")
        git(paths["REPO"], "tag", "-a", "v0.5.0", "-m", "Pal Work Priority 0.5.0")
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

    def release(self, kind, version="0.5.0", manifest=True, sha=None, commit=None, folder=None):
        """What tools/release.py leaves in build/release-<version>: the
        archive and a release.json naming its hash and source commit."""
        build = self.tmp / (folder or "build/release-%s" % version)
        archive = build / ("PalWorkPriority-%s-%s.zip" % (version, kind))
        archive.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive, "w") as z:
            if kind == "manual":
                z.writestr(MANUAL_ROOT + "Scripts/main.lua", 'local VERSION = "%s"\n' % version)
                z.writestr("Pal/Content/Paks/LogicMods/PalWorkPriority.pak", b"release pak")
                z.writestr("INSTALL.txt", "Pal Work Priority %s\n\n1. UE4SS first.\n" % version)
            else:
                z.writestr("Info.json", json.dumps({"Version": version}))
                z.writestr("Scripts/main.lua", 'local VERSION = "%s"\n' % version)
        if manifest:
            listed = sha or hashlib.sha256(archive.read_bytes()).hexdigest()
            write(build / ("PalWorkPriority-%s-release.json" % version), json.dumps(
                {"version": version, "source_commit": commit or self.tagged,
                 "archives": {kind: {"file": archive.name, "sha256": listed}}}))
        return archive

    def manual_zip(self, version="0.5.0", manifest=True, sha=None, commit=None, folder=None):
        return self.release("manual", version, manifest, sha, commit, folder)


class NoAsserts(unittest.TestCase):
    def test_guards_survive_python_O(self):
        code = ("import sys, subprocess; sys.path.insert(0, %r); import g7_install_matrix as g7; "
                "subprocess.run = lambda a, **k: subprocess.CompletedProcess(a, 0, stdout='Palworld-Win64-Shipping.e 1', stderr=''); "
                "g7.closed()" % str(ROOT / "tools"))
        r = subprocess.run([sys.executable, "-O", "-c", code], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("close the game first", r.stderr)


class G1GameClosed(unittest.TestCase):
    """tools/g1_workshop_route.py's game-closed guard (round 3: it was an
    assert, which python -O removes)."""

    def run_closed(self, stdout, code=0):
        script = ("import sys, subprocess; sys.path.insert(0, %r); import g1_workshop_route as g1; "
                  "subprocess.run = lambda a, **k: subprocess.CompletedProcess(a, %d, stdout=%r, stderr='broke'); "
                  "g1.closed()" % (str(ROOT / "tools"), code, stdout))
        return subprocess.run([sys.executable, "-O", "-c", script], capture_output=True, text=True)

    def test_running_game_refused_under_python_O(self):
        r = self.run_closed("Palworld-Win64-Shipping.e 1")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("close the game first", r.stderr)

    def test_failed_tasklist_refused(self):
        r = self.run_closed("", code=1)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("cannot be confirmed closed", r.stderr)

    def test_closed_game_passes(self):
        r = self.run_closed("INFO: No tasks are running which match the specified criteria.")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


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
            self.assertIn("close the game first", self.refused(g7.main, ["wipe", "--state", str(self.tmp)]))
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

    def test_restore_puts_back_managed_mods_and_moves_install_txt(self):
        # The loader installs its copy and touches another mod during the
        # matrix; the manual archive left INSTALL.txt in the game root.
        self.assertTrue((g7.GAME / "INSTALL.txt").is_file())
        write(g7.MANAGED / "PalWorkPriority/Info.json", '{"Version": "0.5.0"}')
        write(g7.MANAGED / "Other/Info.json", '{"Version": "2"}')
        code, out = self.restore_code()
        self.assertEqual(code, 0, out)
        self.assertIn("ManagedMods identical: True", out)
        self.assertEqual(sorted(p.name for p in g7.MANAGED.iterdir()), ["Other"])
        self.assertEqual((g7.MANAGED / "Other/Info.json").read_text(), '{"Version": "1"}')
        self.assertFalse((g7.GAME / "INSTALL.txt").exists())
        self.assertTrue((self.backup / "INSTALL.txt-from-game-root").is_file(), "moved, not deleted")
        self.assertEqual(len(list(self.backup.glob("ManagedMods-after-*"))), 1, "the changed copy is kept")

    def test_user_install_txt_in_the_game_root_is_left_alone(self):
        write(g7.GAME / "INSTALL.txt", "some other tool's notes\n")
        code, out = self.restore_code()
        self.assertEqual(code, 0, out)
        self.assertEqual((g7.GAME / "INSTALL.txt").read_text(encoding="utf-8"), "some other tool's notes\n")

    def test_changed_managed_mods_backup_refused(self):
        write(self.backup / "ManagedMods/Other/Info.json", '{"Version": "changed"}')
        self.assertIn("ManagedMods differs", self.refused(g7.restore, self.backup))
        self.assert_untouched()

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


class Wipe(Fixture):
    def test_wipe_without_state_refused(self):
        # Before prepare MOD is the dev install with its settings: no copy exists.
        self.assertIn("wipe needs --state", self.refused(g7.main, ["wipe"]))
        self.assertEqual((g7.MOD / "priorities.txt").read_text(encoding="utf-8"), "dev data\n")
        self.assertTrue(g7.PAK.is_file())

    def test_wipe_with_a_folder_that_is_no_backup_refused(self):
        self.assertIn("no state.json", self.refused(g7.main, ["wipe", "--state", str(self.tmp / "nowhere")]))
        self.assertTrue((g7.MOD / "priorities.txt").is_file())

    def test_wipe_after_restore_refused(self):
        backup = self.prepare()
        self.quiet(g7.manual, self.manual_zip())
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            g7.restore(backup)
        # The backup's dev install is back in the game: wiping now would delete it.
        self.assertIn("dev-PalWorkPriority is missing", self.refused(g7.main, ["wipe", "--state", str(backup)]))
        self.assertEqual((g7.MOD / "priorities.txt").read_text(encoding="utf-8"), "dev data\n")

    def test_wipe_with_the_prepare_backup(self):
        backup = self.prepare()
        self.quiet(g7.manual, self.manual_zip())
        _, out = self.quiet(g7.main, ["wipe", "--state", str(backup)])
        self.assertIn("no PalWorkPriority install left", out)
        self.assertFalse(g7.MOD.exists())
        self.assertFalse(g7.PAK.exists())
        self.assertTrue((backup / "dev-PalWorkPriority/priorities.txt").is_file())


class Manual(Fixture):
    def setUp(self):
        super().setUp()
        self.prepare()

    def test_matching_archive_extracts(self):
        _, out = self.quiet(g7.manual, self.manual_zip())
        self.assertIn("extracted 3 files", out)
        self.assertIn("built from %s = tag v0.5.0" % self.tagged, out)
        self.assertEqual(g7.PAK.read_bytes(), b"release pak")

    def test_self_consistent_build_of_another_commit_refused(self):
        # 2026-10-29 (round 3, tooling P2-2): the old build moved aside to
        # build/release-0.5.0-old still matches its own release.json.
        archive = self.manual_zip(commit=self.old_commit, folder="build/release-0.5.0-old")
        msg = self.refused(g7.manual, archive)
        self.assertIn("was built from %s, but tag v0.5.0 is %s" % (self.old_commit[:12], self.tagged[:12]), msg)
        self.assertFalse(g7.MOD.exists())
        self.assertFalse(g7.PAK.exists())

    def test_missing_tag_refused(self):
        msg = self.refused(g7.manual, self.manual_zip(version="0.5.1"))
        self.assertIn("tag v0.5.1 does not exist", msg)
        self.assertFalse(g7.MOD.exists())

    def test_damaged_member_refused_before_extracting(self):
        archive = self.manual_zip(manifest=False)
        data = bytearray(archive.read_bytes())
        at = data.index(b"release pak")
        data[at] ^= 1
        archive.write_bytes(bytes(data))
        msg = self.refused(g7.manual, archive, hashlib.sha256(bytes(data)).hexdigest())
        self.assertIn("damaged", msg)
        self.assertFalse(g7.PAK.exists())

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
        self.assertIn("extracted 3 files", out)
        self.assertIn("not tied to a tag", out)

    def test_sha256_option_must_agree_with_manifest(self):
        self.assertIn("differs from the release manifest", self.refused(g7.manual, self.manual_zip(), "1" * 64))
        self.assertFalse(g7.MOD.exists())

    def test_main_passes_sha256(self):
        archive = self.manual_zip(version="0.4.1", manifest=False)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        _, out = self.quiet(g7.main, ["manual", str(archive), "--sha256", digest])
        self.assertIn("extracted 3 files", out)

    def test_missing_archive_refused(self):
        self.assertIn("archive not found", self.refused(g7.manual, self.tmp / "missing.zip"))


class WorkshopContent(Fixture):
    def setUp(self):
        super().setUp()
        self.before = g7.tree(g7.WS)

    def test_tagged_build_replaces_the_files_and_keeps_workshop_json(self):
        _, out = self.quiet(g7.main, ["workshop-content", str(self.release("workshop"))])
        self.assertIn("built from %s = tag v0.5.0" % self.tagged, out)
        self.assertEqual(json.loads((g7.WS / "Info.json").read_text())["Version"], "0.5.0")
        self.assertEqual((g7.WS / ".workshop.json").read_text(), '{"publishedfileid": "3786408856"}')

    def test_missing_archive_leaves_the_workshop_folder_untouched(self):
        # Before, the folder was deleted first and the zip opened after.
        self.assertIn("archive not found", self.refused(g7.workshop_content, self.tmp / "missing.zip"))
        self.assertEqual(g7.tree(g7.WS), self.before)

    def test_unlisted_hash_and_other_commit_refused_untouched(self):
        self.assertIn("not the archive that was built",
                      self.refused(g7.workshop_content, self.release("workshop", sha="0" * 64)))
        self.assertEqual(g7.tree(g7.WS), self.before)
        old = self.release("workshop", commit=self.old_commit, folder="build/release-0.5.0-old")
        self.assertIn("but tag v0.5.0 is", self.refused(g7.workshop_content, old))
        self.assertEqual(g7.tree(g7.WS), self.before)

    def test_not_a_zip_refused_untouched(self):
        archive = self.tmp / "PalWorkPriority-0.5.0-workshop.zip"
        archive.write_bytes(b"not a zip")
        msg = self.refused(g7.workshop_content, archive, hashlib.sha256(b"not a zip").hexdigest())
        self.assertIn("cannot be read as a zip", msg)
        self.assertEqual(g7.tree(g7.WS), self.before)


if __name__ == "__main__":
    unittest.main()
