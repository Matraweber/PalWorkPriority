---
date: 2026-10-11
tags: [async-save, native]
status: evidence
---
# Staged reservation recovery — October 11

Related: [staged-recovery-native-2026-10-11](staged-recovery-native-2026-10-11.md) · [async-enablement-2026-10-04](async-enablement-2026-10-04.md)

Status 2026-10-20: disposable-fixture tooling for the parked async cutover.
Async stays off; 0.5.0 ships the synchronous writer unless optional gate G2b
closes first ([RELEASE-0.5.0.md](RELEASE-0.5.0.md) G2/G2b). G2b's "rollback
test of the staged write path" refers to the v2 path described here.

The missing-destination ownership gap is closed for the tested disposable v2
transaction: record a scratch object's identity before publishing it into a
legacy recovery filename. No installed game files or settings were modified.
Public/default async remains OFF; the checked local trial remains unchanged.
The v1 direct-reservation experiment it replaces is kept below (merged from
destination-leases-2026-10-11 on 2026-10-20).

## Change

`settings_staged_reservation.py` creates an empty scratch file in the owned
temporary transaction root and retains its read/write/delete handle. It flushes
and verifies a receipt binding the plan, root identity, destination, nonce,
scratch name and file identity before performing a no-replace rename through
that same handle. A competing destination creator causes refusal, not replacement.
The receipt and startup marker stay pinned. Payload writes continue through the
retained handle; ordinary pathname reads are not assumed compatible with a
handle that requests DELETE access.

`RecoveredReservation` can reopen a complete receipt's exact empty scratch,
with strict scope/name/identity checks, and publish it without replacement. It
does not infer ownership from matching bytes. Partial receipts, substituted
objects, changed scratch contents and occupied destinations are refused.

`settings_destination_fixture.run(..., staged=True)` records a v2 intent and
uses this route for absent destinations. The original v1 experiment remains
available for its regressions and does not silently gain recovery authority.

`settings_destination_recovery.resume` is an explicit disposable-only operation.
It pins and validates the plan, intent, marker, publication receipts and present
trial files, checks every destination before mutations, then holds every
destination before payload writes. Accepted data states are exact original
bytes, empty identity-bound reservations, or complete planned candidate bytes.
Unknown/partial payloads and newer edits are preserved and refused. An orphan
scratch created before its receipt is not adopted: when the real destination
and receipt remain absent, recovery creates a fresh recorded reservation and
leaves the orphan alone.

Success verifies all eight candidate copies but retains the startup fence and
trial files. It does not activate anything or claim atomic multi-file commit.
Uncertain handle release prevents successful return. Originally absent trial
paths are rechecked before each write and final verification; those checks do
not create a universal namespace exclusion guarantee.

## Verification

Twenty-nine focused tests pass: fourteen Win32 staged-reservation tests and
fifteen recovery/previous-fixture tests. Fresh Python processes deliberately exit
before receipt creation, immediately before publication, immediately after
publication (before the generic progress receipt), and after a completed payload
write. Subsequent processes recover recognized states while preserving the fence.

Negative tests cover competing creators, rename success followed by an exception,
same-bytes replacement objects, partial/unknown data, tampered and duplicate
receipt fields, changed scratch files, later edits during admission, changed
plans, and newly appearing trial files. Review identified the last two admission
gaps; both were corrected with regressions. A negative control removing the
published identity check in memory makes the replacement regression fail as
expected; repository sources are unchanged by the control.

Evidence:
`test-results/staged-recovery-20261011-f36683d29456407aaef569fc5f77f882/`.
Two fresh copies of the actual review bundle were interrupted immediately before
and after publishing `priorities.txt.tmp`. The generic progress receipt was absent
in both cases. Separate recovery processes completed all eight candidates with
the exact recorded reservation identity. Copied fences and trial files remain.
All fourteen real legacy/journal/trial entries matched their pre-run snapshots.
No game process was launched. Per-phase identities, child outputs, final bytes,
source hashes, test provenance and negative-control log are saved in the evidence.

Independent post-run audit passed for both phases: receipt/object identities,
all eight candidate copies, retained fences/trials and unchanged fourteen real
source entries agree. The review receipt is saved alongside the run evidence.

## Remaining acceptance

This establishes process-interruption recovery of known staged states, not
power-loss durability, arbitrary partial-payload restoration, live cutover or
trial retirement. Damaged/incomplete receipts and unknown contents still stop
without deleting or overwriting them. The new write/recovery path needs its own
native startup/rollback acceptance; the earlier native rollback evidence covers
the older replacement-based fixture and must not be reused as proof of this path
(see [async-enablement-2026-10-04.md](async-enablement-2026-10-04.md), "Parked
cutover tooling").

Follow-up: native fenced startup and candidate recovery now pass on the isolated
synthetic server fixture. See
[staged-recovery-native-2026-10-11.md](staged-recovery-native-2026-10-11.md).
Rollback for the new same-handle path remains open.

The real installation adapter also needs final transaction sequencing that
keeps deployment protection and the startup fence intact through data replacement
and trial retirement. Historical membership evidence is not a fresh ownership
or deletion grant.

API basis: [FILE_RENAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info)
and [SetFileInformationByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle).

## v1 direct reservation (2026-10-11, merged from destination-leases)

Replaced by the staged v2 path above; still in the code for its regressions.
A disposable experiment: installed game code, settings, trial launcher/receipt
and journals were not modified, no game was launched.

### What it did

`tools/settings_destination_lease.py` is restricted to explicitly identified
`pwp-cutover-fixture-*` temporary roots and an exact destination allowlist. It
opens existing files without truncation and validates their opened identity,
size and hash. Missing destinations use exclusive CREATE_NEW; a competing
creator wins rather than having its file replaced. The handle is retained with
read/write access and read sharing only, denying competing writes, deletion and
replacement. Parent directories and the exact startup marker are also pinned.

Overwrites use that same handle: rewind, bounded write loop, truncate at the new
length, checked flush, rewind/readback and identity verification. Short writes
are handled; write/truncate/flush/readback failures prevent another overwrite on
that lease. Uncertain close retains handles until process exit. Reservation or
write failures never automatically delete or restore a file.

`tools/settings_destination_fixture.py` protects the immutable plan/trial files,
records intent before creating the fence or reservations, records each acquired
identity, and acquires all eight legacy recovery destinations before the first
payload overwrite. It verifies all held contents against immutable originals.
Success keeps the startup fence and trial files; no activation, no atomic
multi-file commit claim, and no automatic resume.

### Why v1 was replaced (still true, and the reason v2 exists)

- **A CREATE_NEW reservation is already a mutation.** It reserves a name by
  creating a file.
- **A crash before the ownership receipt leaves an ambiguous file.** Between
  creation and durable receipt publication, nobody can tell whose empty file it
  is. v1 deliberately refuses automatic recovery of that case.
- **Matching bytes must not grant recovery ownership.** An identical file can be
  someone else's object (v2 records the object identity before publication).
- **FlushFileBuffers success is not power-loss durability.** A checked flush is
  API success, not proof that the storage device persisted the bytes.
- The direct writes are not atomic replacement; the startup fence and preserved
  original plan protect the experiment while partial bytes exist. Absent names
  after deletion and unrelated new children are not universally excluded.
- Native rollback evidence from the earlier replacement-based fixture does not
  validate this same-handle write path either.

### v1 evidence

Independent review found a race between the pristine-state check and a second
snapshot read: a newer edit could become the overwrite baseline. Fixed by
comparing every captured snapshot with the immutable original before intent,
and all held contents again before any payload write; the regression preserves
the newer edit and refuses before intent/fence creation. A negative control
removing both checks in memory fails as expected.

Sixteen focused tests pass: eleven real Win32 lease tests and five multi-file
integration tests (short/long/empty payloads, partial writes, failed
truncation/flush/readback, identity/hash mismatch, hardlinks/redirects, existing
writers, competing creators, uncertain release, lost receipt writes, abrupt exits
after reservation/first write). Interrupted experiments remain fenced and refuse
blind retry. Real Lua recovery/decoding verifies X, OFF and unrelated rows.

Review-bundle **copy** run:
`test-results/destination-leases-20261011-302dbe8ebfd149c4937ed7444963df2f/`.
All eight candidate copies verified; five absent destinations were reserved.
Sixteen direct Win32 access requests returned sharing error 32, and the matching
sixteen Python write/delete attempts were refused. The real installation's eight
legacy entries, four journal entries and two trial entries matched exact pre-run
snapshots afterward. Independent post-run audit passed.

The first copy attempt is kept separately under
`test-results/destination-leases-20261011-67890ea4084c45ffb12a10abc533ddc5/`.
Its checker wrongly required `OSError.winerror == 32` from Python writes, which
report a permission error without that field. All operations were blocked, but
the checker stopped before payload writes; it was not resumed or counted.

API semantics:
[CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)
and [FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers).
