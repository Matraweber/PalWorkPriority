---
date: 2026-10-11
tags: [async-save, native, testing]
status: evidence
---
# Native staged-reservation recovery acceptance — October 11

Related: [staged-reservation-recovery-2026-10-11](staged-reservation-recovery-2026-10-11.md) · [async-enablement-2026-10-04](async-enablement-2026-10-04.md)

The new staged-reservation path passed two isolated dedicated-server boots:
interrupted startup remained fenced, and explicit recovery loaded the exported
candidate settings. This is candidate recovery acceptance, not rollback of this
new write path, live migration, an active async-writer crash or power-loss proof.
Public/default and dedicated async remain OFF; the checked local trial is unchanged.

## Fixture and interruption

Runner: `tools/run_staged_recovery_native.py`.
Evidence: `test-results/staged-recovery-native-20261011/`.
Server backup: `PalServer/PWPTestBackups/staged-recovery-native-20261011/`.
Retained settings fixture: `pwp-cutover-fixture-w1ds5icu` under the Windows temp root.

The fixture uses independently encoded synthetic data, absent trial launchers,
the pinned UE4SS runtime, current production Lua, and an archived disposable
server world. Scheduling and world-load passes are disabled. No async writer DLL
is installed. No real client settings are installation targets.

A separate Python child exits with code 73 immediately after publishing the
empty `priorities.txt.tmp` reservation, before its generic progress receipt.
The prior staged receipt identifies that same object. The remaining files still
contain original values or are absent, and the startup fence remains present.
The interruption is a real test-process exit, not game termination.

## Native evidence

| Boot | Result |
|---|---|
| Fenced, nonce `68b6c5e3a0454332bc77e209bc76f87c` | Restart required; both stores unavailable; zero settings opens and zero trial opens; empty canonical snapshots. |
| Recovered, nonce `4f8d458e65844149bc35561ed0d56cdf` | Ready/saved; eight settings opens and two missing-trial checks; exact candidate snapshots. |

Each observation is bound to the installed wrapper nonce, actual server process
identity and its loopback REST listener. Both processes shut down normally; all
tracked fixture settings remained byte-for-byte unchanged through each shutdown.
An already-stopped or different process cannot certify normal shutdown.

Between boots, `settings_destination_recovery.resume` verified all eight
candidate files while retaining the fence. A separate fixture-only final step
then held the candidate files and plan against writes/deletion, rechecked the
absence of game processes, and removed the exact validated marker object through
its retained handle. The recovery report distinguishes its retained-fence state
from the later fixture state; the recovery module itself still never unfences.

The loaded candidates contain `mine|1|X`, preserve `unrelated|2|X`, set this
synthetic guild's Stone limit to `OFF`, and retain the wildcard Wood limit of 200.
This differs deliberately from the original priority 3 and Stone limit 100.
Four controls against the actual recovered log reject those old values, a stale
nonce, and a failed mod entry. A generic successful startup cannot pass this test.

## Review and regression evidence

Twelve focused Python runner tests pass, reported by Newton in 10.510 seconds
(no raw unittest log saved). Eight acceptance-parser tests pass separately.
The Lua observer regression passes and all 55 production modules compile under
Lua 5.4. Counts and source hashes are in `validation.json`; native boots and
negative controls are separate evidence, not extra unittest cases.

Prelaunch review found and closed misleading final-state reporting, missing
launch-time fixture/writer checks, same-bytes marker replacement, an insufficient
shutdown snapshot chain, and a missing final process check. Corresponding
regressions exercise the refusal paths. The final independently reviewed runner
SHA256 is `bfbbb6390e692df8e5b6b604b75e4e74cd86128ef2e01a99aff6df382663ddb5`.

## Restoration and limits

The original server paths were restored with matching recorded hashes. Main's
before/after comparison found all fourteen actual client legacy, journal and
trial entries unchanged; both game and server are stopped. Client evidence:
`test-results/staged-native-client-audit-a259f9099a0347209cc8356b9502ee6b/`.

Independent final audit passed: both native records and normal-shutdown snapshot
chains, all four negative controls, the retained eight-file candidate fixture,
all five restored server targets, and all fourteen real client entries were
rechecked. Its receipt is `independent-review.json` in the native evidence folder.

Process-absence checks are observations, not universal process-start exclusion.
Absent trial paths are checked, not atomically reserved. The synthetic fixture
does not retire or execute a real trial launcher. Unknown partial payloads still
refuse recovery without overwriting them. Directory-metadata durability after
power loss is unproven.

Still open: rollback acceptance for this new same-handle path, final live
installation sequencing with writer/deployment protection and trial retirement,
and fresh ownership/session evidence. The earlier replacement-based native
rollback result remains separate and must not be relabeled as staged rollback.
