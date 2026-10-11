# Existing-limit navigation — September 25, 2026

The picker said an existing limit could be edited in Rules but only switched
tabs. It retained the previous Rules page and selected its first row. With
multiple pages the requested rule could be invisible; even on one page the
selected amount could belong to a different item.

The panel now carries only a work/item/guild reveal hint, computes the page from
the next current sorted rule list, selects the matching amount action after
redraw, and consumes the hint. Explicit screen changes, movement and subsequent
actions cancel it. Guild changes discard it; close/reset clears it. No save is
performed by navigation and no new top-level panel locals or native calls were
added.

Regression test_panel_rule_reveal failed before: Stone15 opened the wrong page.
It now passes for targets15/27/1/26 among27 rules, exact amount selection,
removal shifting the target to a different page, superseding screen/movement
actions, guild changes and zero writes. All49 modules compile; all68 regression
scripts pass. Independent review caught the initial navigation-cleanup gap;
the correction and expanded tests passed its final review.

Checked deploy03:15:30 backup:
`deploy-20260925-031530-2d3f2d7342834c998470a001f8ac95ac`.
Supported UI-only reload succeeded03:15:31 in PID6628; no restart needed for
this panel-only change. Native picker showed both existing legacy limits.
Clicking Stone switched to Rules; after redraw its amount action was selected
(03:16:04 diagnostic sel=6; visible caret on Mining/Stone). Stone35000 and
Wood30000 remained unchanged. Escape returned to the stand.

All three user settings hashes remain unchanged. The native fixture has two
rules: multi-page behavior is regression-tested, not a native27-rule acceptance.
No temporary rules were added to the user's world. Full native layout/resolution
matrix and broader release gates remain open. Suite receipt:
test-results/rule-reveal-checks-20260925.txt.
