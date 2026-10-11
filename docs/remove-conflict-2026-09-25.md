# Removal confirmation — September 25, 2026

The old removal confirmation stored only work/item and survived panel teardown.
A second click could remove a changed value or act after reopening. The new
confirmation includes current guild and amount. Each action checks the current
rule view before clearing; a stale rendered/queued value is refused. Rendering
disarms a confirmation if its value/guild is no longer current. Closing/tree
reset and explicit navigation/non-remove actions cancel confirmation.

test_panel_remove_conflict failed before: stale removal accepted a changed
rule. Tests now cover changed/missing values, close/reopen, tab navigation,
guild changes, valid two-click removal and a queued removal whose value changes
before execution. All49 Lua modules compile and all70 regression scripts pass;
the added queued/missing cases also pass the focused rerun. Structural check
passes, with panel194 top-level locals unchanged.

This compares the client's observed snapshot, not an atomic server-side
compare-and-swap. Unseen concurrent server updates and same-value delete/recreate
identity remain outside this guard. No blanket multiplayer-race claim.

Independent read-only review passed the focused suites and eight additional
in-memory probes (draw invalidation, scope/navigation/tree changes and stable
redraw confirmation). No native game window was present, so live acceptance
was not attempted. Checked deployment20:27:53 preserved prior files in
`deploy-20260925-202753-60a55fcd59d84ed4aef04401fec5a3e7`. Source/installed panel
SHA256 match `D4258D196D72948DD4B4FEB6E64BF8D5A55CB419E6B57EBC4126F7755947F82A`.
Priorities, caps and configuration hashes remain identical to the pre-test backup.
The change takes effect on next launch; live confirmation/cancellation is pending.
