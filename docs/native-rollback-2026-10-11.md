# Transaction exclusion and native rollback acceptance — October 11

The disposable cutover driver now holds a real Windows transaction lock for
forward migration, rollback and rollback recovery. Independent review and the
isolated native rollback trial passed. This does not enable public/default or
dedicated async saving, and does not authorize migration of the live client.

## Writer exclusion

`tools/settings_cutover_lock.py` opens a persistent lock file with share mode
zero and keeps its non-inheritable handle for the transaction. There is no PID
guessing, stale-lock deletion or automatic stealing. Directory-list/read handles
pin the owned root and its ancestors against ordinary rename/replacement.
Metadata-only directory access was caught in review and corrected before the
native trial. Uncertain handle release poisons further use in that process;
remaining handles are retained until process exit.

The three public fixture operations each acquire once and use internal helpers
for nested work. The permanent rollback intent still prevents stale forward
recovery. The OS lock excludes cooperating migration processes; it is not a
mandatory lock on every settings file and cannot prevent an unrelated editor
from writing another file. Known game startup is separately fenced by
`.settings-cutover`. Live stopped-writer orchestration and installation binding
are still prerequisites outside this disposable driver.

Eight real Windows tests exercise competing processes, all three operation
wrappers, non-inheritance, root/parent rename denial, hardlink/reparse refusal,
reentrant calls, handle-release uncertainty, and abrupt test-process exit during
both forward and rollback work. Process exit releases the lock while leaving
the persistent recovery markers intact. These tests do not simulate power loss.

## Native protocol and results

Evidence: `test-results/rollback-native-20261011/`.
Server backup: `PalServer/PWPTestBackups/rollback-native-20261011/`.

The fixture uses synthetic priorities and limits with absent original trial
launcher/receipt. It copies current production Lua into an owned temporary
settings root, disables scheduling and world-load passes, and uses the existing
pinned UE4SS runtime in an isolated copy of the archived server world. No async
writer DLL is installed. Real client settings and journals are never targets.

After completing forward cutover, the driver begins rollback and raises a
controlled interruption immediately after replacing `caps.txt`. The startup
marker remains and the recovery files deliberately contain mixed generations.
The first native boot, nonce `2e1e0ca5acf7481fb35b3fefce43c7b9`, reports
restart-required/unavailable, zero settings opens and zero trial opens. Its
empty canonical snapshots pass the strict parser. All tracked bytes remain
unchanged through startup and normal shutdown.

A fresh Python process then resumes the persisted rollback. All eight original
legacy paths and both original trial paths match exactly, including absence.
The marker is removed last. The second native boot, nonce
`ee15c0502b7146f5afb7fc28035d9672`, reports ready/saved, eight settings opens and
two missing-trial checks. Its canonical snapshots match the original priority
3/X and Stone=100 settings, rather than the exported X/OFF candidates.

The native runner verifies the exact loopback listener configuration and the
actual PID-owned 127.0.0.1 REST listener. Shutdown is bound to the accepted
phase/nonce and nonempty PID/path/start identities. An already-stopped server
cannot satisfy this test. Both normal exits are followed by exact settings
readback; recovery requires the matching stopped-phase receipt. These checks
were added after review before either launch.

Both server exits were normal. All original server paths were restored and
independently rehashed against the activation receipt. The retained temporary
fixture also independently matches all 11 tracked states, including the absent
startup marker. Live client readback still matches all eight legacy paths,
four journals and two trial files. Client and server processes are stopped.

## Scope and remaining gates

This verifies native startup after an interrupted *offline coordinator* rollback
and correct original legacy loading. It is not a crash of an active native save
writer, power-loss durability, restoration/execution of a real async launcher,
live installation cutover, historical Pal-deletion coverage or performance proof.
Present trial restoration and newer-edit refusal are covered by the offline
rollback regressions; this native trial deliberately keeps original trial files
absent. Existing public/default/dedicated async settings remain OFF.

The next migration work must bind these protections to the actual installation,
fresh source and session evidence, including fencing known game writers across
startup races. Do not infer universal writer exclusion from the cooperative OS
transaction lock, or remove a startup marker to bypass recovery.

Final disjoint regression totals: 600 tests, 519 passed, 81 native-dependent
skips, zero failures. This includes 570 complementary Python tests, 22
forward/rollback tests and eight real Windows lock tests; the complementary
run explicitly excludes the other three modules. Native boots are separate
evidence, not counted as additional unittest cases. Five native-orchestration
gate tests are included in the complementary run. Counts/provenance are in
`test-results/rollback-native-20261011/validation.json`.
