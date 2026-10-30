"""tools/workshop_upload.py with temporary directories and fakes only: no
Steam, no uploader, no PowerShell, nothing under D:/ is touched. "origin" is a
bare repository in the temporary directory, never GitHub."""
import ast
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
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


REAL_RUN = subprocess.run


def head(repo):
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"],
                          capture_output=True, text=True, check=True).stdout.strip()


def json_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


class Fixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        self.repo = tmp / "repo"
        self.origin = tmp / "origin.git"
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
        (self.repo / ".gitignore").write_text("build/\n", encoding="utf-8")
        (self.repo / "CHANGELOG.md").write_text(CHANGELOG, encoding="utf-8")
        (self.repo / "Scripts").mkdir()
        (self.repo / "Scripts/main.lua").write_text('local VERSION = "%s"\n' % version, encoding="utf-8")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "release")
        # Annotated, like the real v0.5.0, and pushed to a local bare origin.
        git(self.repo, "tag", "-a", "v" + version, "-m", "Pal Work Priority " + version)
        git(self.origin.parent, "init", "-q", "--bare", self.origin.name)
        git(self.repo, "remote", "add", "origin", str(self.origin))
        git(self.repo, "push", "-q", "origin", "v" + version)
        self.build_release(version, head(self.repo))

    def build_release(self, version, commit, marker=""):
        """What tools/release.py leaves in build/release-<version>: the
        Workshop zip and the release manifest naming its commit and hash."""
        build = self.repo / ("build/release-%s" % version)
        build.mkdir(parents=True, exist_ok=True)
        archive = build / ("PalWorkPriority-%s-workshop.zip" % version)
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("Info.json", json.dumps({"Version": version, "PackageName": "PalWorkPriority",
                                                "DebugMode": False, "Thumbnail": "thumbnail.png"}))
            z.writestr("thumbnail.png", b"png")
            z.writestr("Scripts/main.lua", 'local VERSION = "%s"\n%s' % (version, marker))
        json_write(build / ("PalWorkPriority-%s-release.json" % version), {
            "source_commit": commit,
            "archives": {"workshop": {"file": archive.name,
                                      "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}}})

    def set_subscribed(self, version, recorded):
        json_write(self.subscribed / "Info.json", {"Version": version})
        json_write(self.subscribed / ".workshop.json", {"publishedfileid": ITEM, "changenote": "old",
                                                        "last_published_version": recorded})

    def move_tag(self, version="0.5.0", push=False):
        """A fix after the tag: commit, then git tag -f to the new commit."""
        (self.repo / "fix.txt").write_text("fix\n", encoding="utf-8")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "fix after the tag")
        git(self.repo, "tag", "-f", "-a", "v" + version, "-m", "Pal Work Priority " + version)
        if push:
            git(self.repo, "push", "-q", "--force", "origin", "v" + version)
        return head(self.repo)

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


def long_changelog(parts=12, body=700, name_len=55):
    """A 0.5.0 section with many Fixed groups whose long names make the
    "Not shown here for length" footer far longer than a fixed reserve."""
    out = ["# Changelog", "", "## 0.5.0", "", "Intro.", "", "### Fixed", ""]
    for n in range(parts):
        name = ("Group %02d " % n + "with a very long descriptive name " * 3)[:name_len].strip()
        out += ["**%s**" % name, ""]
        out += ["- fix %02d.%d %s" % (n, k, "x" * (body // 4)) for k in range(4)]
        out.append("")
    out += ["### Performance", "", "- " + "p" * 900, "", "### Vortex", "", "- " + "v" * 900, "", "## 0.4.1", "", "- old"]
    return "\n".join(out) + "\n"


class ChangeNoteBudget(unittest.TestCase):
    def note(self, text):
        with mock.patch.object(wu, "changelog_at_tag", lambda version: text):
            return wu.change_note("0.5.0")

    def test_long_section_list_always_fits_and_footer_is_exact(self):
        for parts, body, name_len in [(12, 700, 55), (20, 380, 60), (14, 600, 60), (30, 240, 60)]:
            with self.subTest(parts=parts, body=body, name_len=name_len):
                text = long_changelog(parts, body, name_len)
                note, left_out, cut = self.note(text)
                size = len(note.encode("utf-8"))
                self.assertLessEqual(size, wu.NOTE_MAX)
                self.assertGreaterEqual(len(left_out), 5, "the case needs a long footer")
                footer = ("Shortened here: %s. " % ", ".join(cut) if cut else "") + \
                    "Not shown here for length: %s. Full changelog" % ", ".join(left_out)
                self.assertIn(footer, note)
                self.assertTrue(any("fix %02d.0" % n in note for n in range(parts)), "something was kept")
                # Priority order: whole groups, then at most one shortened
                # group, then only left-out groups. Never a later group in
                # the place of an earlier one.
                states = []
                for n in range(parts):
                    whole = "fix %02d.3" % n in note
                    short = any(item.startswith("Group %02d " % n) for item in cut)
                    named = any(item.startswith("Group %02d " % n) for item in left_out)
                    self.assertEqual(whole + short + named, 1, "group %d is shown, shortened or left out" % n)
                    if short:
                        self.assertIn("fix %02d.0" % n, note, "a shortened group keeps its first bullet")
                    states.append("whole" if whole else "short" if short else "out")
                self.assertEqual(states, sorted(states, key=["whole", "short", "out"].index), states)
                self.assertLessEqual(states.count("short"), 1)
                # As much as possible: a shortened group could not keep one
                # more bullet in the room left.
                if cut:
                    bullet = len(("[*]fix 00.0 " + "x" * (body // 4) + "\n").encode("utf-8"))
                    self.assertLess(wu.NOTE_MAX - size, bullet)

    def test_footer_longer_than_the_old_fixed_reserve_still_fits(self):
        # 2026-10-29: the old fixed 150-byte reserve gave 8081 bytes once five
        # long names were left out. The budget now measures the footer.
        note, left_out, _ = self.note(long_changelog(20, 380, 60))  # the old code: 8369 bytes, refused
        footer = note[note.index("Not shown here for length"):note.index("Full changelog")]
        self.assertGreater(len(footer.encode("utf-8")), 150)
        self.assertLessEqual(len(note.encode("utf-8")), wu.NOTE_MAX)

    def test_short_changelog_keeps_everything(self):
        note, left_out, cut = self.note(CHANGELOG)
        self.assertEqual((left_out, cut), ([], []))
        self.assertNotIn("Not shown here", note)
        self.assertNotIn("Shortened here", note)

    def test_high_priority_part_is_shortened_not_skipped_for_smaller_ones(self):
        # 2026-10-29 (round 3, release-truth P2-1): the largest Fixed group
        # (the panel fixes) was dropped whole while the smaller, lower
        # Installation group was kept.
        def bullets(tag, n, size):
            return ["- %s %d %s" % (tag, k, "z" * size) for k in range(n)]
        text = "\n".join(
            ["# Changelog", "", "## 0.5.0", "", "Intro.", "", "### Before you update", ""]
            + bullets("before", 4, 600) + ["", "### Fixed", "", "**Settings**", ""]
            + bullets("settings", 3, 400) + ["", "**Production Limits panel and Monitoring Stand**", ""]
            + bullets("panel", 14, 400) + ["", "**Installation**", ""]
            + bullets("install", 2, 150) + ["", "### Vortex", ""] + bullets("vortex", 1, 100)
            + ["", "## 0.4.1", "", "- old", ""])
        note, left_out, cut = self.note(text)
        self.assertLessEqual(len(note.encode("utf-8")), wu.NOTE_MAX)
        self.assertEqual(cut, ["Production Limits panel and Monitoring Stand fixes"])
        self.assertIn("panel 0 ", note)
        self.assertNotIn("panel 13 ", note)
        self.assertIn("[*]More in the full changelog (link below).", note)
        self.assertEqual(left_out, ["Installation fixes", "Vortex"])
        self.assertNotIn("install 0", note, "a smaller, lower part does not take the panel's room")
        self.assertIn("Shortened here: Production Limits panel and Monitoring Stand fixes. "
                      "Not shown here for length: Installation fixes, Vortex. Full changelog", note)

    def test_shortened_versions_cut_whole_bullets(self):
        md = "**Group**\n\n- one\n  more of one\n- two\n- three\n"
        self.assertEqual(list(wu.shortened(md)), [
            "**Group**\n\n- one\n  more of one\n- two\n" + wu.MORE + "\n",
            "**Group**\n\n- one\n  more of one\n" + wu.MORE + "\n"])
        self.assertEqual(list(wu.shortened("- only one\n")), [])

    def test_production_limits_outranks_installation_and_controller(self):
        rank = [k for k in wu.KEEP if k.startswith("Fixed/")]
        self.assertLess(rank.index("Fixed/Production Limits"), rank.index("Fixed/Installation"))
        self.assertLess(rank.index("Fixed/Production Limits"), rank.index("Fixed/Controller"))


# Loads only the NoteProblem function from the driver (no UI Automation, no
# uploader) and prints its answer for the texts in two files.
NOTE_PROBLEM_PS = r"""
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:PWP_PS1, [ref]$null, [ref]$null)
$f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'NoteProblem' }, $true)
if (-not $f) { [Console]::Out.Write('NO FUNCTION'); exit 3 }
. ([scriptblock]::Create($f.Extent.Text))
$r = NoteProblem ([IO.File]::ReadAllText($env:PWP_HELD)) ([IO.File]::ReadAllText($env:PWP_WANT)) ([int]$env:PWP_MAX)
if ($r) { [Console]::Out.Write($r) } else { [Console]::Out.Write('OK') }
"""


@unittest.skipUnless(os.name == "nt" and shutil.which("powershell.exe"), "Windows PowerShell required")
class DriverNoteCheck(unittest.TestCase):
    """tools/workshop-upload.ps1 compares the note the uploader holds with
    the file exactly (CRs included) and counts UTF-8 bytes, as Steam does."""

    def problem(self, held, want, limit=8000):
        with tempfile.TemporaryDirectory() as directory:
            held_file, want_file = Path(directory) / "held.txt", Path(directory) / "want.txt"
            held_file.write_bytes(held.encode("utf-8"))
            want_file.write_bytes(want.encode("utf-8"))
            env = dict(os.environ, PWP_PS1=str(ROOT / "tools/workshop-upload.ps1"), PWP_HELD=str(held_file),
                       PWP_WANT=str(want_file), PWP_MAX=str(limit))
            r = REAL_RUN(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", NOTE_PROBLEM_PS],
                         capture_output=True, text=True, encoding="utf-8", env=env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def test_cases(self):
        note = "[h1]0.5.0[/h1]\n[list]\n[*]Fixed\n[/list]\n"
        self.assertEqual(self.problem(note, note), "OK")
        self.assertIn("changed the line ends", self.problem(note.replace("\n", "\r\n"), note))
        self.assertIn("did not go in completely", self.problem(note[:10], note))
        self.assertIn("did not go in completely", self.problem(note.upper(), note), "case counts")
        # 4001 characters, 8002 bytes: within a character count, over Steam's byte limit.
        wide = "\u00e9" * 4001
        self.assertIn("8002 bytes; Steam allows 8000", self.problem(wide, wide))
        crlf = "x\r\n" * 2667  # 8001 bytes with the CRs, 5334 without
        self.assertIn("8001 bytes", self.problem(crlf, crlf.replace("\r", "")))


# Loads WhileNotesOpen and CloseNotes from the driver with stubs for the
# uploader (buttons, Press, the window list, Stop-Process): a failure while
# the Change Notes window is open must press Cancel or end the uploader.
NOTES_GUARD_PS = r"""
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:PWP_PS1, [ref]$null, [ref]$null)
foreach ($name in 'WhileNotesOpen', 'CloseNotes') {
    $f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $f) { [Console]::Out.Write("NO FUNCTION $name"); exit 3 }
    . ([scriptblock]::Create($f.Extent.Text))
}
$CancelWait = 1
$proc = [pscustomobject]@{ Id = 4242 }
$script:log = @()
$script:open = $true
function Button($window, $name) { if ($name -eq 'Cancel' -and $env:PWP_CANCEL -eq '1') { 'cancel-button' } }
function Press($button) { $script:log += "press $button"; if ($env:PWP_CLOSES -eq '1') { $script:open = $false } }
function IsOpen($procId, $handle) { $script:open }
function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:log += "kill $Id"; $script:open = $false }
$dialog = [pscustomobject]@{ Current = [pscustomobject]@{ NativeWindowHandle = 77 } }
try {
    $r = WhileNotesOpen $dialog {
        if ($env:PWP_FAIL -eq '1') { throw 'The change note did not go in completely (10 of 40 characters).' }
        'ok-button'
    }
    $out = "RETURNED $r"
} catch { $out = "THREW $($_.Exception.Message)" }
[Console]::Out.Write($out + "`n" + ($script:log -join ';'))
"""

# Every use of $dialog in the script body (outside function definitions,
# apart from the assignment that finds it) must sit inside a WhileNotesOpen
# call; Press $ok must not, or a failed OK press would end a running upload.
NOTES_GUARD_AST_PS = r"""
$L = 'System.Management.Automation.Language'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:PWP_PS1, [ref]$null, [ref]$null)
$guards = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'WhileNotesOpen' }, $true))
$functions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
function Within($node, $outer) { foreach ($o in $outer) { if ($node.Extent.StartOffset -ge $o.Extent.StartOffset -and $node.Extent.EndOffset -le $o.Extent.EndOffset) { return $true } }; return $false }
$uses = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq 'dialog' }, $true)
$bad = @()
foreach ($u in $uses) {
    if (Within $u $functions) { continue }
    if ($u.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and $u.Parent.Left -eq $u) { continue }
    if (-not (Within $u $guards)) { $bad += "line $($u.Extent.StartLineNumber)" }
}
$press = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Press' -and $n.Extent.Text -match '\$ok\b' }, $true))
if ($press.Count -ne 1) { $bad += "Press `$ok found $($press.Count) times" }
foreach ($p in $press) { if (Within $p $guards) { $bad += "Press `$ok inside WhileNotesOpen (line $($p.Extent.StartLineNumber))" } }
if ($guards.Count -lt 2) { $bad += "only $($guards.Count) WhileNotesOpen calls" }
[Console]::Out.Write(($bad -join '; '))
"""


@unittest.skipUnless(os.name == "nt" and shutil.which("powershell.exe"), "Windows PowerShell required")
class DriverCancelsOnFailure(unittest.TestCase):
    """2026-10-30 (round 4, tooling P2-1): a failure after the Change Notes
    window opened (a cut note, missing buttons) left the window open with
    the rejected note, one OK away from publishing it."""

    def run_ps(self, script, **env):
        env = dict(os.environ, PWP_PS1=str(ROOT / "tools/workshop-upload.ps1"),
                   **{"PWP_" + k.upper(): v for k, v in env.items()})
        r = REAL_RUN(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                     capture_output=True, text=True, encoding="utf-8", env=env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def guard(self, fail, cancel, closes):
        out = self.run_ps(NOTES_GUARD_PS, fail=fail, cancel=cancel, closes=closes)
        result, _, log = out.partition("\n")
        return result, log

    def test_failure_presses_cancel_and_rethrows(self):
        result, log = self.guard("1", "1", "1")
        self.assertTrue(result.startswith("THREW The change note did not go in completely"), result)
        self.assertIn("Cancel was pressed in the uploader: nothing was sent.", result)
        self.assertEqual(log, "press cancel-button")

    def test_cancel_that_does_not_close_ends_the_uploader(self):
        result, log = self.guard("1", "1", "0")
        self.assertIn("so the uploader was ended", result)
        self.assertEqual(log, "press cancel-button;kill 4242")

    def test_no_cancel_button_ends_the_uploader(self):
        result, log = self.guard("1", "0", "0")
        self.assertTrue(result.startswith("THREW "), result)
        self.assertEqual(log, "kill 4242")

    def test_success_touches_nothing(self):
        self.assertEqual(self.guard("0", "1", "1"), ("RETURNED ok-button", ""))

    def test_every_use_of_the_dialog_is_guarded(self):
        self.assertEqual(self.run_ps(NOTES_GUARD_AST_PS), "")


class NoAsserts(unittest.TestCase):
    def test_no_assert_statements(self):
        for name in ("tools/workshop_upload.py", "tools/g7_install_matrix.py", "tools/g1_workshop_route.py",
                     "tools/mod_absent.py"):
            tree = ast.parse((ROOT / name).read_text(encoding="utf-8"))
            self.assertEqual([n.lineno for n in ast.walk(tree) if isinstance(n, ast.Assert)], [], name)


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

    def test_change_note_size_is_reported_in_bytes(self):
        text = CHANGELOG.replace("TAGGED FIX TEXT", "Fixed f\u00fcr \u00e9t\u00e9")
        with mock.patch.object(wu, "changelog_at_tag", lambda version: text):
            out = self.prepare()
            note = wu.change_note("0.5.0")[0]
        self.assertGreater(len(note.encode("utf-8")), len(note))
        self.assertIn("%d of %d bytes" % (len(note.encode("utf-8")), wu.NOTE_MAX), out)

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

    def test_refuses_when_the_public_tag_is_the_old_commit(self):
        old = head(self.repo)
        new = self.move_tag()  # moved locally, not force-pushed: origin still holds the old tag
        self.build_release("0.5.0", new, marker="-- rebuilt\n")
        msg = self.refused(wu.prepare, "0.5.0")
        self.assertIn("public tag v0.5.0 on origin is %s" % old[:12], msg)
        self.assertIn("git push --force origin v0.5.0", msg)
        self.assertFalse(self.mod.exists(), "nothing staged after a refusal")

    def test_accepts_the_force_pushed_tag(self):
        new = self.move_tag(push=True)
        self.build_release("0.5.0", new, marker="-- rebuilt\n")
        self.prepare()
        self.assertEqual(json.loads((self.root / "stage/stage.json").read_text())["source_commit"], new)

    def test_refuses_a_tag_that_is_not_on_origin(self):
        git(self.repo, "push", "-q", "origin", ":refs/tags/v0.5.0")
        msg = self.refused(wu.prepare, "0.5.0")
        self.assertIn("not on origin", msg)
        self.assertFalse(self.mod.exists())

    def test_lightweight_public_tag_is_read_directly(self):
        git(self.repo, "tag", "-f", "v0.5.0", head(self.repo))
        git(self.repo, "push", "-q", "--force", "origin", "v0.5.0")
        self.assertEqual(wu.public_tag_commit("0.5.0"), head(self.repo))

    def test_unreachable_origin_refused(self):
        git(self.repo, "remote", "set-url", "origin", str(self.origin.parent / "missing.git"))
        self.assertIn("ls-remote origin failed", self.refused(wu.prepare, "0.5.0"))
        self.assertFalse(self.mod.exists())

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

    def test_moved_tag_refused(self):
        self.steam_downloads_stage()
        self.uploader_publishes("0.5.0")
        self.move_tag(push=True)
        self.assertIn("the tag moved", self.refused(wu.check))

    def test_rebuilt_archive_refused(self):
        self.build_release("0.5.0", head(self.repo), marker="-- rebuilt\n")
        self.assertIn("another Workshop archive", self.refused(wu.check))

    def test_newer_live_version_refused(self):
        self.set_subscribed("0.6.0", recorded="0.5.0")
        self.assertIn("newer version 0.6.0 is live", self.refused(wu.check))


class Upload(Fixture):
    def setUp(self):
        super().setUp()
        self.prepare()
        self.calls = []

    def fake_run(self, status):
        def run(args, **kw):
            if args[0] == "git":  # the tag checks read the temporary repository
                return REAL_RUN(args, **kw)
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

    def test_old_workshop_path_is_kept_and_printed(self):
        path = self.uploader.parent / "workshop_path.txt"
        path.write_text("C:\\Program Files (x86)\\Steam\\steamapps\\workshop\\content\\1623730", encoding="utf-8")
        old = path.read_bytes()
        code, out = self.upload("DryRun", None)
        self.assertEqual(code, 0)
        kept = list(self.root.glob("workshop_path-before-*.txt"))
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0].read_bytes(), old)
        self.assertIn(str(kept[0]), out)
        self.assertEqual(path.read_text(encoding="utf-8"), str(self.root / "stage"))
        # A second run finds the stage already there: nothing more to keep.
        self.upload("DryRun", None)
        self.assertEqual(len(list(self.root.glob("workshop_path-before-*.txt"))), 1)

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

    def refused_without_powershell(self):
        with mock.patch.object(wu.subprocess, "run", self.fake_run(PUBLISHED[0])):
            msg = self.refused(wu.upload, "Submit")
        self.assertEqual(self.calls, [], "neither tasklist nor powershell was started")
        self.assertFalse((self.uploader.parent / "workshop_path.txt").exists())
        return msg

    def test_refuses_after_the_tag_moved(self):
        # prepare ran in setUp; then a fix is committed and the tag moved.
        new = self.move_tag()
        msg = self.refused_without_powershell()
        self.assertIn("tag v0.5.0 is now %s" % new[:12], msg)
        self.assertIn("run prepare again", msg)

    def test_refuses_after_the_tag_moved_and_was_rebuilt(self):
        new = self.move_tag(push=True)
        self.build_release("0.5.0", new, marker="-- rebuilt\n")
        self.assertIn("the tag moved", self.refused_without_powershell())

    def test_refuses_when_the_public_tag_moved_after_prepare(self):
        # Local tag unchanged, but origin's tag now names another commit.
        other = self.move_tag()
        git(self.repo, "tag", "-f", "-a", "v0.5.0", "-m", "back", head(self.repo) + "~1")
        git(self.repo, "push", "-q", "--force", "origin", "%s:refs/tags/v0.5.0" % other)
        msg = self.refused_without_powershell()
        self.assertIn("public tag v0.5.0 on origin is %s" % other[:12], msg)

    def test_refuses_when_the_public_tag_was_deleted(self):
        git(self.repo, "push", "-q", "origin", ":refs/tags/v0.5.0")
        self.assertIn("not on origin", self.refused_without_powershell())

    def test_refuses_when_the_manifest_lists_another_archive(self):
        self.build_release("0.5.0", head(self.repo), marker="-- rebuilt\n")
        self.assertIn("another Workshop archive", self.refused_without_powershell())

    def test_refuses_when_the_live_version_caught_up(self):
        self.set_subscribed("0.5.0", recorded="0.4.1")
        self.assertIn("not newer than the live version 0.5.0", self.refused_without_powershell())

    def test_refuses_after_a_successful_upload(self):
        self.uploader_publishes("0.5.0")
        with mock.patch.object(wu.subprocess, "run", self.fake_run(PUBLISHED[0])):
            self.assertIn("stage changed since prepare", self.refused(wu.upload, "Submit"))
        self.assertEqual(self.calls, [], "nothing was started")

    def test_refuses_while_the_uploader_is_open_before_touching_workshop_path(self):
        # 2026-10-30 (round 4, tooling P3-2): workshop_path.txt was rewritten
        # before the driver refused an uploader that was already open.
        path = self.uploader.parent / "workshop_path.txt"
        path.write_text("C:\\elsewhere", encoding="utf-8")

        def run(args, **kw):
            if args[0] == "git":
                return REAL_RUN(args, **kw)
            self.calls.append(args)
            return subprocess.CompletedProcess(
                args, 0, stdout="steam.exe  1234 Console\nPalworldModUploader.exe  5678 Console\n")
        with mock.patch.object(wu.subprocess, "run", run):
            self.assertIn("uploader is already open", self.refused(wu.upload, "Submit"))
        self.assertEqual([c[0] for c in self.calls], ["tasklist"], "powershell was not started")
        self.assertEqual(path.read_text(encoding="utf-8"), "C:\\elsewhere")
        self.assertEqual(list(self.root.glob("workshop_path-before-*.txt")), [])

    def test_failed_tasklist_refused(self):
        def run(args, **kw):
            if args[0] == "git":
                return REAL_RUN(args, **kw)
            self.calls.append(args)
            return subprocess.CompletedProcess(args, 1, stdout="", stderr="broke")
        with mock.patch.object(wu.subprocess, "run", run):
            self.assertIn("tasklist failed", self.refused(wu.upload, "Submit"))
        self.assertFalse((self.uploader.parent / "workshop_path.txt").exists())

    def test_prepare_records_the_change_note_hash(self):
        state = json.loads((self.root / "stage/stage.json").read_text(encoding="utf-8"))
        note = self.root / "stage/changenote-0.5.0.txt"
        self.assertEqual(state["changenote"], note.name)
        self.assertEqual(state["changenote_sha256"], hashlib.sha256(note.read_bytes()).hexdigest())

    def test_refuses_a_changed_change_note(self):
        # 2026-10-30 (round 4, tooling P3-1): upload sent whatever the file held.
        note = self.root / "stage/changenote-0.5.0.txt"
        note.write_text(note.read_text(encoding="utf-8") + "edited by hand\n", encoding="utf-8", newline="\n")
        self.assertIn("not the change note prepare wrote", self.refused_without_powershell())

    def test_refuses_a_stage_without_a_change_note_hash(self):
        path = self.root / "stage/stage.json"
        state = json.loads(path.read_text(encoding="utf-8"))
        del state["changenote_sha256"]
        path.write_text(json.dumps(state), encoding="utf-8")
        self.assertIn("records no change-note hash", self.refused_without_powershell())

    def test_driver_failure_says_not_published(self):
        def run(args, **kw):
            if args[0] == "git":
                return REAL_RUN(args, **kw)
            self.calls.append(args)
            if args[0] == "tasklist":
                return subprocess.CompletedProcess(args, 0, stdout="steam.exe  1234 Console\n")
            return subprocess.CompletedProcess(args, 1)
        for mode in (None, "Submit", "DryRun"):
            with self.subTest(mode=mode), mock.patch.object(wu.subprocess, "run", run):
                code, out = self.exit_code(wu.upload, mode)
            self.assertEqual(code, 1)
            self.assertIn("NOT published, do not press OK", out)

    def test_failure_after_ok_does_not_invite_a_retry(self):
        def run(args, **kw):
            if args[0] == "git":
                return REAL_RUN(args, **kw)
            if args[0] == "tasklist":
                return subprocess.CompletedProcess(args, 0, stdout="steam.exe  1234 Console\n")
            return subprocess.CompletedProcess(args, wu.AFTER_OK)
        with mock.patch.object(wu.subprocess, "run", run):
            msg = self.refused(wu.upload, "Submit")
        self.assertIn("Do not upload again", msg)
        self.assertNotIn("NOT published", msg)

    def test_metadata_warning_is_recorded_and_a_repeat_refused(self):
        # 2026-10-30 (round 4, tooling P3-3): "Submitted, but failed to update
        # metadata" leaves .workshop.json at 0.4.1 and Steam's copy at 0.4.1
        # until it downloads, so a second upload passed every guard.
        code, out = self.upload("Submit", WARNINGS[0])
        self.assertEqual(code, 0, out)
        self.assertIn("a second upload is refused", out)
        state = json.loads((self.root / "stage/stage.json").read_text(encoding="utf-8"))
        self.assertEqual(state["submitted"]["version"], "0.5.0")
        self.assertEqual(state["submitted"]["status"], WARNINGS[0])
        self.calls = []
        with mock.patch.object(wu.subprocess, "run", self.fake_run(PUBLISHED[0])):
            msg = self.refused(wu.upload, "Submit")
        self.assertEqual(self.calls, [], "neither tasklist nor powershell was started")
        self.assertIn("not newer than the live version 0.5.0", msg)
        self.assertIn("(submitted)", msg)
        self.assertIn("live version 0.5.0", self.refused(wu.prepare, "0.5.0"), "a new prepare is refused too")

    def test_record_survives_the_stage_being_moved_aside(self):
        self.upload("Submit", WARNINGS[0])
        aside = self.root / "stage-before-20261030-120000"
        shutil.move(str(self.root / "stage"), str(aside))
        self.assertIn("live version 0.5.0", self.refused(wu.prepare, "0.5.0"))

    def test_error_is_not_recorded(self):
        self.upload("Submit", "Submission failed: k_EResultLimitExceeded")
        state = json.loads((self.root / "stage/stage.json").read_text(encoding="utf-8"))
        self.assertNotIn("submitted", state)

    def test_check_passes_after_a_metadata_warning(self):
        self.upload("Submit", WARNINGS[0])
        self.steam_downloads_stage()  # the stage's .workshop.json still says 0.4.1
        json_write(self.subscribed / "Info.json", {"Version": "0.5.0"})
        (self.subscribed / "Info.json").write_bytes((self.mod / "Info.json").read_bytes())
        code, out = self.exit_code(wu.check)
        self.assertEqual(code, 0, out)
        self.assertIn("recorded the submission", out)


if __name__ == "__main__":
    unittest.main()
