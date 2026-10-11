# Amount editing during rule-list changes — September 25, 2026

The panel retained old editor layout entries across rule-list redraws. When a
rule disappeared or shifted off the current page, its still-active amount box
could stay over the row now belonging to another rule. The stale-value save
guard protected removed/changed values, but an unchanged off-page rule could
still accept a draft while the editor appeared over something else.

Each rule-list draw now owns a fresh layout map. A draft whose work/item is no
longer on the current page, or whose guild changed, is cancelled immediately
inside the game-thread refresh, and a cancellation notice explains why. The
unwrapped cancel adapter avoids waiting behind an already-queued confirmation.
A still-visible target follows its current row and keeps its typed draft.

Regression test_panel_edit_reflow fails before the fix: deleted rule retains its
native-editor binding. Afterward it covers deletion, sorted insertion pushing
the target off-page, movement within the visible page retaining text, queued
confirmation invalidation, and guild changes. All49 modules compile, all69
regression scripts pass, and the structural checker passes (panel194 locals).
Receipt: test-results/edit-reflow-checks-20260925.txt.

These tests execute the real renderer with native boundaries simulated. They
do not establish populated multiplayer delivery, death while editing, or the
cause of the original Escape-crash reports. User rules are not modified to
manufacture the multi-page scenario in the live world.

Independent review found an additional ordering gap: refresh positioned the
editor once before validating the new rule list. Removed that early placement;
the editor is now placed only after drawing the current validated page. A new
regression deletes a just-opened target before first paint and asserts zero
non-nil editor-binding/focus requests. All69 suites pass after this correction.

Final independent ordering review passed. Main checked deployment03:37:26
backed up prior files in `deploy-20260925-033726-44913a25eb3d4cbeac3c32ec20b2d052`;
supported UI reload succeeded03:37:27. Source/installed panel hash matched
`414E8AA0112B2B1829D0FF87164854F434498501956811F3CE930749131C879F`.
Native smoke: opened Stone35000, Backspaced its unsaved draft, Escape restored
35000, next Escape closed only Production Limits. No saved rule was changed;
priorities/caps/config hashes still match the pre-test backup. The normal
editor path works with post-draw placement; native remote reflow remains untested.
