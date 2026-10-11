# Interrupted settings cutover — October 11, 2026

## Production startup protection

`Scripts/main.lua` checks `.settings-cutover` before loading either legacy
settings recovery set or inspecting the async trial launcher. Presence or unknown
access acquires the shared settings fence and presents restart-required state.
The marker contents are never read or executed. Startup never removes the marker.
Positive absence keeps normal startup and the existing orphan-receipt check.

Main-composition tests cover presence, open denial/exception, close
failure/exception and injected read failure (contents must not be read), and verify no settings recovery reads,
launcher inspection, successful legacy flush or scheduler call. Root configuration
validation still runs. Bypassing the check in memory fails the new test.
This code is tested offline; it has not been installed in the live client/server.

## Disposable filesystem transaction

`tools/settings_cutover_fixture.py` accepts only a verified review bundle. It
creates its own fresh directory under the system temporary directory; there is
no game-root/live-apply argument. Original source paths in the bundle are not
followed. All changed settings and launcher files are copies.

The persisted fixed-path plan retains original bytes and intended replacements.
The transaction stages and verifies a marker before touching active copies,
replaces all four recovery paths for each of the two streams with checked new
generations, verifies both complete streams, retires the two copied trial marker
files, and removes `.settings-cutover` LAST. Resume accepts only original or
intended exact bytes, rejecting competing changes or an absent marker with mixed
settings. It has no remembered progress counter. Staging scratch never participates
in legacy recovery. The original plan and journal bundle remain available.

The real Lua datafile reader selects the intended priorities and limits after
completion, including X/OFF and unrelated rows. Repeating completed recovery is
idempotent. `live_cutover_allowed` remains false.

## Review fixes and limits

Independent review found an automatic TemporaryDirectory finalizer could bypass
explicit cleanup refusal if the root was replaced. The fixture now uses mkdtemp
and only explicit path/identity-checked recursive cleanup. A garbage-collection
regression ensures a replacement root survives refused cleanup. Failed setup can
leave a disposable evidence directory rather than silently deleting it.

The retirement check now re-verifies all eight intended files after its fault
hook. Three fresh Python subprocesses recover from persisted state at different
interruption points, receiving the parent test's trusted root identity and plan
hash. Those are supplied fixture evidence, not a live ownership/authentication
mechanism.

Tests cover 42 before/after operation boundaries, partial staging writes,
uncertain replacement errors on both sides of the actual rename, lost markers,
unknown competing settings, final-boundary changes, foreign marker/plan data,
and guarded cleanup. File flushes are requested, but this is exception/restart
simulation, not native power-loss testing or NTFS durability certification.

A disposable copy of the actual review bundle also completed: all eight recovery
files checked, both copied trial markers retired, marker removed last. Evidence:
`test-results/cutover-real-bundle-copy-20261011.json`. No game installation,
launcher, receipt, journal or live settings were modified.

## Still required before real cutover

Verify target installation and guard version, current world/guild and historical
Pal ownership/deletion coverage; establish stopped-writer ownership; retain the
complete settings/journal/code backup; bind the transaction to that verified
installation. Then test controlled native restart/interruption and recovery of
both streams before retiring any actual launcher or receipt. This fixture does
not grant those prerequisites and is not a live cutover tool. Public/default and
dedicated async enablement remain unchanged.


## Final verification

Frozen final source passes all 211 Lua regression scripts and compilation of 55
production modules. Structural checks pass (existing panel local-count warning).
Full Python suite: 535 tests, 454 passed and 81 native tests explicitly skipped.
The 10 focused cutover tests pass, including 42 interruption boundaries and three
fresh-process recoveries. Both independent reviews pass after the cleanup fix;
a negative control bypassing the startup marker fails the composition regression.

Evidence: `test-results/cutover-recovery-20261011-lua.log`,
`cutover-recovery-20261011-structural.log`,
`cutover-recovery-20261011-focused.log`, and
`cutover-recovery-20261011-final-python.log`.
The earlier `cutover-recovery-20261011-python.log` is the pre-review-fix baseline,
not final acceptance. This distinction preserves the cleanup defect's history.


## Explicit rollback recovery — October 11

The disposable fixture now has a separate rollback direction. Admission requires
an exact completed forward cutover with no active fence. It persists a plan-bound
rollback intent before restoring anything; that intent remains after completion
so a stale forward driver cannot reapply the exported candidates. Partial intent
staging does not count as committed intent.

Restoration keeps the startup fence present, restores all eight original legacy
recovery entries first (including deleting files that were originally absent),
then restores the two original trial entries. It rechecks the complete original
state before removing the fence last. Unknown/newer bytes, missing or foreign
fences, changed plans and changed root identities refuse further mutation. This
is refusal with byte preservation, not automatic merging of newer saves.

A disposable copy of the actual review bundle was interrupted after restoring
caps.txt. A fresh Python process refused stale forward recovery, resumed the
persisted rollback, and restored all ten original entries exactly, including
five originally missing files. Evidence:
`test-results/cutover-rollback-20261011/actual-bundle-copy.json`.
The owned temporary copy was removed after verification; live files were not
written. This demonstrates exception/process recovery on copied data, not a
native game restart or power-loss durability.

Exclusive use of the fixture directory is a prerequisite. Byte rechecks are not
an OS lock, and process absence sampled before a transaction cannot establish
exclusive writer ownership. Live installation binding, writer exclusion and
native coordinated rollback acceptance still precede any real cutover.

Main final focused run also passed: 22 tests, zero failures (359.033s).
Combined with the disjoint Python complement: 587 tests, 506 passed, 81 native
skips, zero failures. Source hashes and counts: `test-results/cutover-rollback-20261011/validation.json`.
