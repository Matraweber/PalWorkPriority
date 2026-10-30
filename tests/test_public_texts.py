"""Public claims in README.md, CHANGELOG.md and the store page draft that a
review found wrong once (round 4, 2026-10-30), and the Workshop change note
built from this CHANGELOG. Plain file reads; nothing is uploaded."""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import workshop_upload as wu


def read(name):
    return (ROOT / name).read_text(encoding="utf-8").replace("\r\n", "\n")


def flat(text):
    """Markdown with its line wrapping undone."""
    return re.sub(r"\s+", " ", text)


class PublicTexts(unittest.TestCase):
    def setUp(self):
        self.readme = flat(read("README.md"))
        self.changelog = flat(read("CHANGELOG.md"))
        self.store = flat(read("docs/store-page-0.5.0-draft.md"))

    def test_stone_pits_are_never_said_to_keep_producing(self):
        # A stone-only base stops its pit once no Mining is wanted (scheduler).
        for text in (self.readme, self.changelog, self.store):
            self.assertNotIn("keep producing", text)
        self.assertIn("Stone Pits and other mining buildings stop only when nothing that base mines is "
                      "still wanted.", self.changelog)

    def test_automated_only_lists_name_the_other_players_panels(self):
        for text in (self.readme, self.changelog):
            self.assertIn("other players' panels after one player's limit edit", text)

    def test_performance_and_routes_say_what_was_measured(self):
        self.assertNotIn("checked again on the final build", self.changelog)
        self.assertNotIn("carry over on every route.", self.changelog)
        self.assertIn("carried over on every route we tested", self.changelog)
        self.assertNotIn("per-item rock limits now work too", self.changelog)
        self.assertIn("Pals working them there was not observed", self.changelog)

    def test_store_page_has_the_guide_link_and_first_minute_lines(self):
        self.assertIn("https://github.com/Matraweber/PalWorkPriority#readme", self.store)
        self.assertIn("right click a 1", self.store)
        self.assertIn("NVIDIA overlay", self.store)
        self.assertIn("can end up above the limit", self.store)
        self.assertIn("can end up above the limit", self.readme)

    def test_readme_evidence_links_exist_in_docs(self):
        for name in ("g7-final-build-2026-10-30", "perf-final-2026-10-29", "review-round3-2026-10-29",
                     "retest-r3-2026-10-29", "review-round4-2026-10-30"):
            self.assertIn("(docs/%s.md)" % name, self.readme)
            self.assertTrue((ROOT / "docs" / (name + ".md")).is_file(), name)
        self.assertNotIn("will be rerun", self.readme)

    def test_change_note_keeps_every_fixed_part(self):
        text = read("CHANGELOG.md")
        original = wu.changelog_at_tag
        wu.changelog_at_tag = lambda version: text
        try:
            note, left_out, shortened = wu.change_note("0.5.0")
        finally:
            wu.changelog_at_tag = original
        self.assertLessEqual(len(note.encode("utf-8")), wu.NOTE_MAX)
        self.assertEqual(shortened, [])
        self.assertIn("[h3]Production Limits panel and Monitoring Stand[/h3]", note)
        self.assertFalse([name for name in left_out if name.endswith(" fixes")], left_out)


if __name__ == "__main__":
    unittest.main()
