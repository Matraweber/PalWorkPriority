"""tools/workshop_upload.py with temporary directories and fakes only: no
Steam, no uploader, no PowerShell, nothing under D:/ is touched."""
import ast
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
import workshop_upload as wu

ITEM = wu.ITEM

# The uploader's status texts after OK, copied from PalworldModUploader
# MainWindow.xaml.cs (OnItemSubmitted, UploadButton_Click, startup).
PUBLISHED = ["Workshop item submitted successfully."]
WARNINGS = [
    "Submitted, but failed to update metadata: Access to the path is denied.",
    "Submitted, but failed to open Steam page: The system cannot find the file specified.",
]
ERRORS = [
    "Error: Steam I/O failure during update.",
    "You must accept the Steam Workshop legal agreement before uploading.",
    "Submission failed due to an unknown error.",
    "Submission failed: k_EResultLimitExceeded",
    "Upload canceled because DebugMode could not be disabled.",
    "Upload canceled by user.",
    "Failed to read workshop subscriptions: k_EResultFail",
    "Submitting workshop update...",
    "",
    None,
]

CHANGELOG = """# Changelog

## 0.5.0

Intro line for the tagged release.

### Fixed

- TAGGED FIX TEXT

## 0.4.1

- older
"""


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", *args],
                   check=True, capture_output=True)


def json_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


class Fixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        self.repo = tmp / "repo"
        self.subscribed = tmp / "steam" / ITEM
        self.root = tmp / "ws"
        self.uploader = tmp / "uploader" / "PalworldModUploader.exe"
        self.uploader.parent.mkdir(parents=True)
        self.make_repo("0.5.0")
        self.set_subscribed("0.4.1", recorded="0.4.0")
        patcher = mock.patch.multiple(wu, REPO=self.repo, SUBSCRIBED=self.subscribed, ROOT=self.root,
                                      STAGE=self.root / "stage", MOD=self.root / "stage" / "PalWorkPriority",
                                      UPLOADER=self.uploader)
        patcher.start()
        self.addCleanup(patcher.stop)

    def make_repo(self, version):
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        (self.repo / "CHANGELOG.md").write_text(CHANGELOG, encoding="utf-8")
        (self.repo / "Scripts").mkdir()
        (self.repo / "Scripts/main.lua").write_text('local VERSION = "%s"\n' % version, encoding="utf-8")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "release")
        git(self.repo, "tag", "v" + version)
        commit = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"],
                                capture_output=True, text=True, check=True).stdout.strip()
        build = self.repo / ("build/release-%s" % version)
        build.mkdir(parents=True)
        archive = build / ("PalWorkPriority-%s-workshop.zip" % version)
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("Info.json", json.dumps({"Version": version, "PackageName": "PalWorkPriority",
                                                "DebugMode": False, "Thumbnail": "thumbnail.png"}))
            z.writestr("thumbnail.png", b"png")
            z.writestr("Scripts/main.lua", 'local VERSION = "%s"\n' % version)
        json_write(build / ("PalWorkPriority-%s-release.json" % version), {
            "source_commit": commit,
            "archives": {"workshop": {"file": archive.name,
                                      "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}}})

    def set_subscribed(self, version, recorded):
        json_write(self.subscribed / "Info.json", {"Version": version})
        json_write(self.subscribed / ".workshop.json", {"publishedfileid": ITEM, "changenote": "old",
                                                        "last_published_version": recorded})

    @property
    def mod(self):
        return self.root / "stage" / "PalWorkPriority"

    def prepare(self, version="0.5.0"):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            wu.prepare(version)
        return out.getvalue()

    def refused(self, fn, *args):
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as cm:
            fn(*args)
        self.assertIsInstance(cm.exception.code, str, "a refusal exits with a message")
        return cm.exception.code

    def exit_code(self, fn, *args):
        with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit) as cm:
            fn(*args)
        return cm.exception.code, out.getvalue()

    def uploader_publishes(self, version="0.5.0"):
        """What the uploader does after a successful upload: it writes the new
        version into the stage's .workshop.json."""
        meta = json.loads((self.mod / ".workshop.json").read_text(encoding="utf-8"))
        meta["last_published_version"] = version
        (self.mod / ".workshop.json").write_text(json.dumps(meta), encoding="utf-8")

    def steam_downloads_stage(self):
        """Steam's copy after the update: the uploaded files, including the
        .workshop.json as it was uploaded."""
        for p in self.mod.rglob("*"):
            if p.is_file():
                dest = self.subscribed / p.relative_to(self.mod)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(p.read_bytes())


class ClassifyStatus(unittest.TestCase):
    def test_actual_uploader_strings(self):
        for text in PUBLISHED:
            self.assertEqual(wu.classify_status(text), "published", text)
        for text in WARNINGS:
            self.assertEqual(wu.classify_status(text), "warning", text)
        for text in ERRORS:
            self.assertEqual(wu.classify_status(text), "error", text)

    def test_constant_matches_uploader_text(self):
        self.assertEqual(wu.PUBLISHED, "Workshop item submitted successfully.")

    def test_report_exit_codes(self):
        for text, code in [(PUBLISHED[0], 0), (WARNINGS[0], 0), (WARNINGS[1], 0)] + [(t, 1) for t in ERRORS]:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(wu.report_submit(text), code, text)
            if text in WARNINGS:
                self.assertIn("warning", out.getvalue())
                self.assertIn(text, out.getvalue())


class NoAsserts(unittest.TestCase):
    def test_no_assert_statements(self):
        tree = ast.parse((ROOT / "tools/workshop_upload.py").read_text(encoding="utf-8"))
        self.assertEqual([n.lineno for n in ast.walk(tree) if isinstance(n, ast.Assert)], [])


class Prepare(Fixture):
    def test_writes_live_version_not_stale_metadata(self):
        out = self.prepare()
        meta = json.loads((self.mod / ".workshop.json").read_text(encoding="utf-8"))
        # The subscribed .workshop.json says 0.4.0 (one release behind); the
        # live version is the subscribed Info.json's 0.4.1.
        self.assertEqual(meta["last_published_version"], "0.4.1")
        self.assertEqual(meta["publishedfileid"], ITEM)
        state = json.loads((self.root / "stage/stage.json").read_text())
        self.assertEqual(state["live_version"], "0.4.1")
        self.assertEqual(state["files"][".workshop.json"],
                         hashlib.sha256((self.mod / ".workshop.json").read_bytes()).hexdigest())
        self.assertIn("live version: 0.4.1", out)

    def test_refuses_same_version_live(self):
        self.set_subscribed("0.5.0", recorded="0.4.1")
        msg = self.refused(wu.prepare, "0.5.0")
        self.assertIn("not newer than the live version 0.5.0", msg)
        self.assertFalse(self.mod.exists(), "nothing staged after a refusal")

    def test_refuses_downgrade(self):
        self.set_subscribed("0.6.0", recorded="0.5.0")
        self.assertIn("live version 0.6.0", self.refused(wu.prepare, "0.5.0"))

    def test_refuses_after_upload_before_steam_download(self):
        self.prepare()
        self.uploader_publishes("0.5.0")  # Steam's copy still says 0.4.1
        before = sorted(p.name for p in self.root.iterdir())
        msg = self.refused(wu.prepare, "0.5.0")
        self.assertIn("live version 0.5.0", msg)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), before, "the stage was not moved aside")

    def test_refuses_when_an_aside_stage_recorded_it(self):
        aside = self.root / "stage-before-20261028-220000" / "PalWorkPriority"
        json_write(aside / ".workshop.json", {"publishedfileid": ITEM, "last_published_version": "0.5.0"})
        self.assertIn("live version 0.5.0", self.refused(wu.prepare, "0.5.0"))

    def test_restage_after_dry_run_moves_old_stage_aside(self):
        self.prepare()
        self.prepare()  # a dry run changes nothing, so the same version may be staged again
        self.assertEqual(len(list(self.root.glob("stage-before-*/PalWorkPriority"))), 1)
        meta = json.loads((self.mod / ".workshop.json").read_text(encoding="utf-8"))
        self.assertEqual(meta["last_published_version"], "0.4.1")

    def test_version_compare_is_numeric(self):
        self.assertLess(wu.version_key("0.9.0"), wu.version_key("0.10.0"))
        self.assertEqual(wu.version_key("0.5"), wu.version_key("0.5.0"))
        self.assertIn("dotted number", self.refused(wu.version_key, "0.5.0-beta"))

    def test_bad_subscribed_item_refused(self):
        json_write(self.subscribed / ".workshop.json", {"publishedfileid": "1", "last_published_version": "0.4.1"})
        self.assertIn("not %s" % ITEM, self.refused(wu.prepare, "0.5.0"))

    def test_change_note_from_tag_not_working_tree(self):
        (self.repo / "CHANGELOG.md").write_text(CHANGELOG.replace("TAGGED FIX TEXT", "WORKTREE ONLY"),
                                                encoding="utf-8")
        self.prepare()
        note = (self.root / "stage/changenote-0.5.0.txt").read_text(encoding="utf-8")
        self.assertIn("TAGGED FIX TEXT", note)
        self.assertNotIn("WORKTREE ONLY", note)

    def test_missing_tag_refused(self):
        git(self.repo, "tag", "-d", "v0.5.0")
        self.assertIn("tag v0.5.0 does not exist", self.refused(wu.prepare, "0.5.0"))

    def test_guards_survive_python_O(self):
        self.set_subscribed("0.5.0", recorded="0.5.0")
        code = ("import sys; sys.path.insert(0, %r); import workshop_upload as wu; from pathlib import Path; "
                "wu.REPO = Path(%r); wu.SUBSCRIBED = Path(%r); wu.ROOT = Path(%r); "
                "wu.STAGE = wu.ROOT / 'stage'; wu.MOD = wu.STAGE / 'PalWorkPriority'; wu.prepare('0.5.0')"
                % (str(ROOT / "tools"), str(self.repo), str(self.subscribed), str(self.root)))
        r = subprocess.run([sys.executable, "-O", "-c", code], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("not newer than the live version", r.stderr)
        self.assertFalse(self.mod.exists())


class Check(Fixture):
    def setUp(self):
        super().setUp()
        self.prepare()

    def test_pass_defaults_to_staged_version(self):
        self.steam_downloads_stage()
        self.uploader_publishes("0.5.0")
        code, out = self.exit_code(wu.check)
        self.assertEqual(code, 0, out)
        self.assertIn("PASS", out)

    def test_not_yet_while_steam_has_old_copy(self):
        self.uploader_publishes("0.5.0")
        code, out = self.exit_code(wu.check)
        self.assertEqual(code, 1)
        self.assertIn("NOT YET", out)

    def test_not_yet_without_uploader_record(self):
        self.steam_downloads_stage()
        code, out = self.exit_code(wu.check)
        self.assertEqual(code, 1)

    def test_compares_against_hashes_from_prepare(self):
        # Stage and Steam copy changed the same way: still not what was prepared.
        for root in (self.mod,):
            (root / "Scripts/main.lua").write_text("changed\n", encoding="utf-8")
        self.steam_downloads_stage()
        self.uploader_publishes("0.5.0")
        self.assertIn("stage changed since prepare", self.refused(wu.check))

    def test_steam_copy_differs(self):
        self.steam_downloads_stage()
        self.uploader_publishes("0.5.0")
        (self.subscribed / "Scripts/main.lua").write_text("other\n", encoding="utf-8")
        code, out = self.exit_code(wu.check)
        self.assertEqual(code, 1)
        self.assertIn("different (1): Scripts/main.lua", out)

    def test_other_version_refused(self):
        self.assertIn("stage holds 0.5.0", self.refused(wu.check, "0.4.1"))


class Upload(Fixture):
    def setUp(self):
        super().setUp()
        self.prepare()
        self.calls = []

    def fake_run(self, status):
        def run(args, **kw):
            self.calls.append(args)
            if args[0] == "tasklist":
                return subprocess.CompletedProcess(args, 0, stdout="steam.exe  1234 Console\n")
            if args[0] == "powershell.exe" and "-StatusFile" in args and status is not None:
                Path(args[args.index("-StatusFile") + 1]).write_text(status, encoding="utf-8")
            return subprocess.CompletedProcess(args, 0)
        return run

    def upload(self, mode, status):
        with mock.patch.object(wu.subprocess, "run", self.fake_run(status)):
            return self.exit_code(wu.upload, mode)

    def test_submit_success(self):
        code, out = self.upload("Submit", PUBLISHED[0])
        self.assertEqual(code, 0)
        ps = self.calls[-1]
        self.assertEqual(ps[ps.index("-Stage") + 1], str(self.root / "stage"))
        self.assertEqual((self.uploader.parent / "workshop_path.txt").read_text(encoding="utf-8"),
                         str(self.root / "stage"))

    def test_submit_with_warning_is_published(self):
        code, out = self.upload("Submit", WARNINGS[0])
        self.assertEqual(code, 0)
        self.assertIn("Published, with a warning", out)

    def test_submit_error_exits_1(self):
        code, out = self.upload("Submit", "Submission failed: k_EResultLimitExceeded")
        self.assertEqual(code, 1)
        self.assertIn("NOT published", out)

    def test_submit_without_status_file_refused(self):
        with mock.patch.object(wu.subprocess, "run", self.fake_run(None)), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as cm:
            wu.upload("Submit")
        self.assertIn("no final status", cm.exception.code)

    def test_dry_run_passes_no_status_file(self):
        code, _ = self.upload("DryRun", None)
        self.assertEqual(code, 0)
        self.assertNotIn("-StatusFile", self.calls[-1])
        self.assertIn("-DryRun", self.calls[-1])

    def test_refuses_after_a_successful_upload(self):
        self.uploader_publishes("0.5.0")
        with mock.patch.object(wu.subprocess, "run", self.fake_run(PUBLISHED[0])):
            self.assertIn("stage changed since prepare", self.refused(wu.upload, "Submit"))
        self.assertEqual(self.calls, [], "nothing was started")


if __name__ == "__main__":
    unittest.main()
