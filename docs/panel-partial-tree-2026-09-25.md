# Incomplete panel tree — September 25, 2026

`panel_runtime.snapshot` accepted advertised children that resolved to nil or
had unreadable names: traversal returned early without marking the tree
incomplete. A renderer could therefore interpret an unreadable existing control
as missing. Empty names were also accepted as cache identities.

Missing child/name evidence now refuses the entire snapshot and clears the
partial object map. Existing panel teardown cancels the affected editor and
refuses later confirmation. The next complete tree can be reopened normally.
Unsupported child-count methods on leaf widgets retain their existing behavior;
this change does not add class scans or new native calls.

Evidence:

- The new runtime regression failed before the fix: nil-child accepted as complete.
- Nil children, throwing/nil/empty names now reject partial snapshots and recover
  on the next complete enumeration.
- Real renderer fixture: interrupt a focused draft by making one advertised root
  child unreadable. No replacement controls are constructed, the editor/panel
  closes, subsequent confirmation cannot write, and reopening recovers without
  stale-wrapper access.
- All 49 modules compile; all 67 regression scripts and the structural checker
  pass. Independent review independently passed the runtime and renderer tests.
  Full-suite receipt: test-results/panel-partial-tree-checks-20260925.txt.

Native fault injection is deliberately not used to create unreadable engine
objects. Native smoke testing can validate normal opening/editing/reopening, but
cannot establish that the original reported Escape crash has this cause.

Before restart, the user returned to the original nine-Pal stand. Visible priorities
and all nine rows were present; status reported local authority and saved settings.
This closes post-respawn stand reopening for that tested session, not the missing
ClientRestart-event evidence or death-while-editing gate.

Checked deployment at03:00:29 preserved prior files in installed-mod backup
`deploy-20260925-030029-271642ca8a364da98d73c47be8dd3c2c`. Source and installed
panel_runtime.lua SHA256 both
`A4D152D43161E5CBAAE97A8A57F665512DE6270748D73FFA126BFD1AC4A7C217`.
All three user settings files still match the pre-test backup hashes.

## Native smoke acceptance

The second normal AHK restart replaced PID31424 with PID6628; stand-ready
recorded03:02:15. All nine stand rows returned. At03:02–03:04, opened Production
Limits, clicked Wood30000, Backspaced the draft to3000, and pressed Escape:
the editor closed and30000 returned. A second Escape closed only the panel.
Reopening showed one intact panel with both original rules; then closed it and
left the Monitoring Stand open. Status03:04:01 reports healthy local authority,
saved priorities/limits and no active editor. The last160 log lines contained no
WARN/ERROR, and all three settings hashes still match the pre-test backup.
No deliberate engine-object corruption, death during editing, or native
multiplayer test occurred. This is normal-path compatibility acceptance only.
