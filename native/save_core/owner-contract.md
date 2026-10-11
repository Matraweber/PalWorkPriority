# Experimental exclusive owner and completion retention

This is an isolated native coordination primitive, not an installed save backend.
An owner is scoped by the exact normalized storage/guild/stream scope. Admission
also captures copied incarnation and epoch; their active-world provenance must
be established by the caller. A scope alone never grants storage permission.

The first creator of `Global\PWP-AsyncOwner-Dev1-<scope>` is admitted. Existing
named objects or access errors deny admission. This uses kernel-object existence,
not thread-affine mutex acquisition: no waiting or ReleaseMutex occurs. The
global name is conservative across duplicate DLLs and processes, including
identical scope IDs in different directories. Cooperating implementations must
use this same protocol. The synchronous writer and unrelated filesystem writers
are not excluded by it.

Reference: https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createmutexw

A bounded native registry retains up to 128 claims even when the caller drops
its reference. Each owner allows one increasing ticket at a time. Completion
is retained until matching consumption; uncertain completion is deliberately
not consumable. Retirement rejects new reservations, but existing IO may finish
against its originally captured destination. Release requires retirement and
no unresolved/unconsumed operation. No timeout releases a claim.

`certain` means every part of operation IO has stopped and its publication
outcome is resolved. It does not mean successful, readback-valid or durable.
Never set it merely because a callback arrived. This version cannot reconcile
an uncertain result or reacquire a dropped claim; process restart is required.

Every operation must retain the EXACT original shared owner object and immutable
binding/ticket/kind/slot/bytes. Do not send old completions to a replacement
"current owner". A fresh claim requires a fresh incarnation from admission;
ticket high-water marks reset at handover. Consumption is idempotent for the
most recently consumed ticket while the owner remains open, not an unlimited
history service. Raw methods do not independently authenticate a caller-created
completion or execute/schedule IO.

Admitted owner code is pinned until process termination with GetModuleHandleEx.
This prevents Lua reload/FreeLibrary from tearing down the registry. Future
worker code must live in the same pinned module or have its own verified
lifetime. Process teardown is not interrupted-write or shutdown-latency proof.

Reference: https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandleexw

`python tools/test_native_owner.py` builds two separately loadable test DLL
copies and runs real kernel arbitration, independent-process exclusion, process
exit/reclaim, pinned FreeLibrary, concurrent reservation, stale ticket/epoch,
pending retirement, dropped caller and uncertain-result tests. Evidence is
fingerprinted in `test-results/native-owner-20261004/`. No game IO is invoked.
