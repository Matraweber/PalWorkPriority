"""tools/restart-server-stand.ahk without the game: its --self-test (when
AutoHotkey v2 is installed) and, in the source, the order of its guild gate,
the checked game menu and the logged argument refusals."""
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
MACRO = ROOT / "tools" / "restart-server-stand.ahk"
STAND_MACRO = ROOT / "tools" / "restart-stand.ahk"
AHK = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs/AutoHotkey/v2/AutoHotkey64.exe"


def function(text, name):
    """The body of an AutoHotkey function definition (to its closing brace at
    column 0)."""
    return re.search(r"^%s\([^)]*\) \{\n.*?^\}" % re.escape(name), text, re.S | re.M).group(0)


class GuildGate(unittest.TestCase):
    def test_gate_runs_before_any_key_and_names_the_way_out(self):
        text = MACRO.read_text(encoding="utf-8")
        body = text[text.index("try {"):]
        gate = body.index("GuildGate(EXPECTED_GUILD, ANY_GUILD)")
        first_input = min(body.index(call) for call in ("Key(", "Focus()", "Point(", "keybd_event", "OpenMenu("))
        self.assertLess(gate, first_input, "the gate is checked before any input is sent")
        self.assertIn("--any-guild", re.search(r"GuildGate\(expected, anyGuild\) \{.*?\n\}", text, re.S).group(0))

    def test_comment_does_not_claim_the_id_is_absent_from_the_repo(self):
        # The id is still in docs/g6-guild-isolation-2026-10-19.md and older commits.
        text = MACRO.read_text(encoding="utf-8")
        self.assertNotIn("not from the repo", text)
        self.assertIn("docs/g6-guild-isolation-2026-10-19.md", text)

    @unittest.skipUnless(os.name == "nt" and AHK.is_file(), "AutoHotkey v2 required")
    def test_self_test(self):
        r = subprocess.run([str(AHK), "/ErrorStdOut", str(MACRO), "--self-test"],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PASS 13 server readiness cases", r.stdout)
        self.assertIn("PASS 3 guild gate cases", r.stdout)
        self.assertIn("PASS 7 argument cases", r.stdout)
        self.assertIn("PASS 5 menu colour cases", r.stdout)


class MenuBeforeReturnToTitle(unittest.TestCase):
    """2026-10-30 (round 4, tooling P2-2): the server macro still pressed
    Escape blindly before clicking Return to Title, so a swallowed Escape
    sent that click into the world on the shared server."""

    def test_every_escape_before_return_to_title_goes_through_open_menu(self):
        text = MACRO.read_text(encoding="utf-8")
        body = text[text.index("try {"):text.index("} catch as err {")]
        click = body.index("Point(306, 573)")
        before = body[:click]
        self.assertNotIn("Key('Escape')", before, "no blind Escape before the Return to Title click")
        self.assertIn("OpenMenu()", before[before.rindex("if MODE != '--title' {"):])
        open_menu = function(text, "OpenMenu")
        self.assertIn("Key('Escape')", open_menu)
        self.assertIn("if MenuOpen()\n            return", open_menu, "OpenMenu stops once the menu reads open")
        self.assertIn("throw Error(", open_menu)
        self.assertIn("PixelGetColor", function(text, "MenuOpen"))
        self.assertIn("CoordMode 'Pixel', 'Client'", text, "pixels are read window-relative like the clicks")

    def test_menu_points_match_restart_stand(self):
        points = re.compile(r"for pt in \[\[1041, 40\], \[1080, 45\]\]")
        self.assertRegex(function(MACRO.read_text(encoding="utf-8"), "MenuOpen"), points)
        self.assertRegex(function(STAND_MACRO.read_text(encoding="utf-8"), "MenuOpen"), points)


class ArgumentRefusals(unittest.TestCase):
    """2026-10-30 (round 4, tooling P3-4): "--any-guild --world" exited 2
    with no log line and no message."""

    def test_refused_arguments_are_logged_before_the_exit(self):
        text = MACRO.read_text(encoding="utf-8")
        top = text[:text.index("try {")]
        refusal = top[top.index("PARSED := ParseArgs(A_Args)"):]
        refusal = refusal[:refusal.index("ExitApp 2") + len("ExitApp 2")]
        self.assertIn("Note('STOPPED: ' PARSED[3])", refusal)
        self.assertNotIn("for arg in A_Args", top, "arguments are parsed only by ParseArgs")
        # The only other exit 2 is --check's answer.
        self.assertEqual(top.count("ExitApp 2"), 1)
        self.assertEqual(len(re.findall(r"ExitApp .*\? 0 : 2", top)), 1)

    def test_parse_args_names_every_mode_the_macro_runs(self):
        text = MACRO.read_text(encoding="utf-8")
        modes = re.search(r"\^--\(([a-z|-]+)\)\$", function(text, "ParseArgs")).group(1).split("|")
        for mode in modes:
            self.assertIn("'--%s'" % mode, text.replace("MODE = '--", "'--"), mode)
        self.assertEqual(sorted(modes), sorted(["stand", "world", "title", "launch", "open-only", "check", "self-test"]))


class StandMacroSample(unittest.TestCase):
    """restart-stand.ahk --sample (round 4, tooling P3-10): records the title
    and world-select colours a pixel check needs, without any input."""

    def test_sample_sends_no_input(self):
        text = STAND_MACRO.read_text(encoding="utf-8")
        block = text[text.index("if MODE = '--sample' {"):]
        block = block[:block.index("    ExitApp 0\n}")]
        for call in ("Point(", "Key(", "Click", "keybd_event", "MouseMove", "Send"):
            self.assertNotIn(call, block)
        self.assertIn("PixelGetColor", block)
        for point in ("[639, 412]", "[599, 170]", "[971, 654]"):
            self.assertIn(point, block, "the title and world-select click points are sampled")
        self.assertLess(text.index("CoordMode 'Pixel', 'Client'"), text.index("if MODE = '--sample' {"))

    @unittest.skipUnless(os.name == "nt" and AHK.is_file(), "AutoHotkey v2 required")
    def test_both_macros_load(self):
        for macro in (MACRO, STAND_MACRO):
            r = subprocess.run([str(AHK), "/ErrorStdOut", "/Validate", str(macro)],
                               capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, macro.name + r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
