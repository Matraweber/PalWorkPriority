"""tools/restart-server-stand.ahk without the game: its --self-test (when
AutoHotkey v2 is installed) and the order of its guild gate in the source."""
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
MACRO = ROOT / "tools" / "restart-server-stand.ahk"
AHK = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs/AutoHotkey/v2/AutoHotkey64.exe"


class GuildGate(unittest.TestCase):
    def test_gate_runs_before_any_key_and_names_the_way_out(self):
        text = MACRO.read_text(encoding="utf-8")
        body = text[text.index("try {"):]
        gate = body.index("GuildGate(EXPECTED_GUILD, ANY_GUILD)")
        first_input = min(body.index(call) for call in ("Key(", "Focus()", "Point(", "keybd_event"))
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


if __name__ == "__main__":
    unittest.main()
