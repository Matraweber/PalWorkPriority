# Staged reservation recovery — October 11

The missing-destination ownership gap is closed for the tested disposable v2
transaction: record a scratch object's identity before publishing it into a
legacy recovery filename. No installed game files or settings were modified.
Public/default async remains OFF; the checked local trial remains unchanged.

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
the older replacement-based fixture and must not be reused as proof of this path.

Follow-up: native fenced startup and candidate recovery now pass on the isolated
synthetic server fixture. See `docs/staged-recovery-native-2026-10-11.md`.
Rollback for the new same-handle path remains open.

The real installation adapter also needs final transaction sequencing that
keeps deployment protection and the startup fence intact through data replacement
and trial retirement. Historical membership evidence is not a fresh ownership
or deletion grant.

API basis: [FILE_RENAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info)
and [SetFileInformationByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle).
