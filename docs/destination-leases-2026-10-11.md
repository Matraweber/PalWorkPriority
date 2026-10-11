# Writable destination and missing-file reservations — October 11

This is a disposable experiment, not a live migration or an async enablement.
The installed game code, settings, trial launcher/receipt and journals were not
modified. No game was launched. Public/default async remains OFF.

## Implemented

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
Success keeps the startup fence and trial files; it does not activate the
candidate or claim an atomic multi-file commit. There is no automatic resume.

## Review and verification

Independent review found a race between the pristine-state check and a second
snapshot read: a newer edit could become the overwrite baseline. Fixed by
comparing every captured snapshot with the immutable original before intent,
and comparing all held contents again before any payload write. The regression
preserves the newer edit and refuses before intent/fence creation. A negative
control removes both checks in memory and produces the expected test failure;
the repository is not modified by that control.

Sixteen focused tests pass: eleven real Win32 lease tests and five multi-file
integration tests. They cover short/long/empty payloads, partial writes, failed
truncation/flush/readback, identity/hash mismatch, hardlinks/redirects, existing
writers, competing creators, uncertain release, lost receipt writes and abrupt
test-process exits after reservation/first write. Interrupted experiments remain
fenced and refuse blind retry. Real Lua recovery/decoding verifies X, OFF and
unrelated rows in the successful synthetic case.

Actual review-bundle **copy** evidence:
`test-results/destination-leases-20261011-302dbe8ebfd149c4937ed7444963df2f/`.
All eight candidate copies verified; five absent destinations were reserved.
Sixteen direct Win32 access requests returned sharing error 32, and the matching
sixteen Python write/delete attempts were also refused. The real installation's
eight legacy entries, four journal entries and two trial entries matched exact
pre-run snapshots afterward. The copied fence and trial files were retained.
Validation, source hashes and the negative-control output are in the evidence.

The first copy attempt is preserved separately under
`test-results/destination-leases-20261011-67890ea4084c45ffb12a10abc533ddc5/`.
Its checker wrongly required `OSError.winerror == 32` from Python writes, which
reported a permission error without that field. All operations were blocked,
but the checker stopped before payload writes. The corrected fresh-copy run
uses direct Win32 errors alongside actual denied Python operations; the failed
attempt was not silently resumed or counted as a success.

Independent post-run audit passed: all eight candidate bytes, reservation/write
identities and hashes match retained files; all competitor requests were denied;
the copied fence/trial and all fourteen actual source entries remain unchanged.
The reviewer saved separate success and failed-attempt receipts. Both temporary
fixtures remain retained for inspection; neither is a game installation.

## Remaining gate

Follow-up: the staged v2 path now records an object's identity before publication
and explicitly recovers known pre/post-publication states. See
`docs/staged-reservation-recovery-2026-10-11.md`. The limitations below still
describe the original v1 direct-reservation experiment; unknown payloads and
live/native acceptance remain separate gates.

CREATE_NEW reserves a name by creating a file; it is already a mutation. A crash
between creation and durable ownership-receipt publication leaves an ambiguous
reservation. Matching bytes alone must not confer recovery ownership. This
experiment deliberately refuses automatic recovery of that case.

The direct writes are not atomic replacement: the startup fence and preserved
original plan protect the experiment while partial bytes exist. A live adapter
still needs explicit interrupted-transaction recovery and trial-retirement/
final-fence sequencing. Absent names after deletion and unrelated new children
are not universally excluded. Checked FlushFileBuffers is API success, not a
proof of storage-device power-loss durability. Native rollback evidence from
the earlier replacement-based fixture does not automatically validate this new
same-handle write path.

Relevant API semantics:
[CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)
and [FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers).
