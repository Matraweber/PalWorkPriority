# Journal export reconciliation and preparation — October 11, 2026

This is a review-only recovery preparation path. It does not switch writers,
replace legacy settings, remove a trial launcher, or enable public async saving.

## Implemented

- `experiments/settings_export_reconcile.lua` combines canonical journal bodies
  with the selected legacy recovery state. It replaces only explicitly claimed
  target Pals and target guild groups; preserves unclaimed/foreign rows and
  wildcard defaults; preserves X/OFF; and applies claimed target deletions.
- Journal Pals outside target claims, conflicting global baseline markers,
  duplicate/foreign claims, invalid runtime aliases, and simultaneous canonical
  and runtime-alias source groups are rejected. The last rejection applies even
  to disjoint items and an empty journal; independent review found that missing
  case and its regression now covers it.
- `tools/settings_export_bundle.py` captures all eight legacy recovery paths,
  four journal paths, and both launcher/receipt paths, including missing markers.
  It writes originals and `.body` candidates into a new, separate directory.
  Sources are rechecked around writes. Partial directories remain and cannot be
  reused. Verification recomputes the entire proposal from captured bytes and
  rejects altered/missing/extra artifacts. It never follows source paths supplied
  by the manifest.
- `settings_migration_backup.game_closed` now fences the entire Palworld and
  PalServer process-name families, including the previously missed dedicated
  Shipping-Cmd executable. Tests run the actual PowerShell predicate over inert
  synthetic names. Errors and unknown results still fail closed.

## Actual offline files

Prepared and verified `test-results/export-review-only-20261011-e5a32f93/bundle`
from the installed local trial's unchanged legacy files and current journals.
The source rechecks passed; launcher, receipt, journals and legacy settings were
not modified. The bundle contains 41 priority rows and two limit rows, selected
from journal generations 8 and 11 respectively. The selected legacy data also
has 41 priority rows and two limit rows. This particular proposal has no outside
rows to retain; the synthetic regressions exercise those preservation cases.

`claims-provenance.json` beside the bundle records that membership claims were
constructed ONLY from journal-listed keys. They are not independently verified
current ownership or historical deletion coverage. All replacement/ownership
flags remain false. A sampled stopped-process check is not a writer exclusion
lock. Byte-consistent verification is not authentication or power-loss proof.

## Validation

- Lua 5.4: 55 production modules compile; all 211 regression scripts pass.
- Full offline Python: 525 tests, 444 passed, 81 native tests explicitly skipped.
- Structural checker passes (existing panel local-count warning remains).
- 12 bundle tests cover round-trip recomputation, preserved source bytes, all
  interrupted write boundaries, disk errors, source/marker/journal changes,
  pending legacy generations, corruption, tampering and unexpected artifacts.
- Three in-memory negative controls fail as expected when alias/baseline guards
  or unrelated-Pal preservation are removed.
- Independent reviews of the frozen Lua reconciliation and Python bundle pass.

Logs: `test-results/export-reconcile-20261011-{lua,python,structural,mutations}.log`.
No game was launched, no native settings writes occurred, and nothing was published.

## Cutover requirements still open

The `.body` candidates must NOT simply be copied over priorities.txt/caps.txt:
existing `.pending`, `.tmp` or `.bak` generations may still win recovery. A real
cutover needs verified world/guild and historical ownership/deletion coverage,
exclusive offline ownership, a recoverable transaction across BOTH complete
legacy recovery sets, and a persistent marker that blocks startup if interrupted.
Only after recovery selects both intended new streams may the launcher/receipt
be retired. Keep journals and original code for recovery; do not delete them.
The bundle has no apply operation. Restoring or modifying player files is outside
what this prepared proposal authorizes. Native restart, interrupted cutover and
rollback acceptance remain separate from these offline tests.
