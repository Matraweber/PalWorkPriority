# Scoped async-save transport â€” October 3, 2026

Status: isolated Lua scope/transport boundary implemented and exercised with the
real queue and session controller against an in-memory reference backend.
**No compatible native backend exists yet. Not installed or enabled for real
settings; no production saving, package or server state changed.**

## Implemented boundary

`experiments/save_scope.lua` derives deterministic slot names from a verified
persistent storage GUID, guild GUID and priorities/limits stream. Both GUIDs
must have 32 hex digits and be nonzero. Map names, display names and incomplete
identities are refused. Case is canonicalized. Fixed-width identities are
encoded directly, without a collision-prone shortened hash or caller paths.
Slots use the separate `PWP_AsyncDev_v1_` namespace. Camp-specific records stay
inside their guild/stream snapshot; this is not a change to storage accounting.
Obtaining the correct persistent world/server storage identity remains an
integration requirement, not something this adapter guesses.

`experiments/save_transport.lua` translates the scratch queue's logical A/B
slots into that namespace. Requests contain immutable copies and separate
incarnation/ticket identity from the persisted record generation. Completion
must match scope, incarnation, ticket, operation and physical slot. A matching
terminal result is copied and retained locally until the backend acknowledges
consumption of its terminal mailbox. Failed acknowledgement retries only that
acknowledgement, never the storage operation. Reentrant polling is guarded.

Foreign records stop recovery even when the other slot contains a valid older
record. Null/unknown loads are not classified as missing. Existing exact
checksum/payload validation remains in the queue before its saved generation
advances. Accepted writes still do not imply durability.

The adapter requires explicit development opt-in and the new backend contract
`PWP-SCOPED-DEV-1`; the V2/V3 native bridges do not implement it. Checking a
contract string is API compatibility, **not proof of native safety**.

## Required native contract

- `dispatch(operation)` returns true for accepted, false only for definitely not
  started, or an uncertain outcome. Native admission must bind verified scope,
  owner and lifetime, enforce monotonically increasing operation tickets and
  reject competing/duplicate owners. Uncertainty cannot permit another write.
- `peek(identity)` returns a copied, retained terminal envelope or pending. Its
  `read.status` is explicitly ok/missing/invalid/unreadable; missing needs positive
  platform evidence. Completion includes save and readback, not save alone.
- `consume(identity)` acknowledges exactly that terminal result. It is idempotent
  after a lost response and cannot release a newer operation. Pending or unmatched
  mailboxes cannot be overwritten. A missed Lua hook must not lose the result.
- Engine-backed ownership must survive Lua reload and cover world teardown.
  The current Actor bridge can disappear with its world while IO may remain in
  flight. Actor absence, timer cancellation, or an empty Lua lease is not proof
  that IO stopped. A surviving coordinator or independently verified drain is
  required before opening those slots again.

Independent design review confirmed that bind-once identity and a retained
mailbox would improve the existing Actor within one world lifetime, but would
not by themselves solve teardown. No V3 identity is reassigned or adopted here.

## Verification

Lua 5.4 compiles 51 production modules; all 85 regression scripts pass. The new
suite covers world/guild/stream separation, canonical/path-safe identities, X
round-trip, mismatched completions, foreign data in an alternate slot, unreadable
recovery, lost completion notification, failed/lost consume acknowledgement,
reentrant consume, ambiguous dispatch and complete queue/session integration.
The backend in these tests is a contract fixture, not Unreal or the RAM server.

The implementation review found that inline completion could replace a session
during dispatch and retag the old receipt with the new incarnation. Submission
now captures the originating queue/scope/incarnation. Recovery, polling and retry
also revalidate that origin before touching controller state after callbacks.
An integrated regression closes/reopens during submission and verifies that the
old receipt stays stale, even after new-session recovery.

Independent re-review found no remaining issues within the inspected boundary
and separately passed four focused Lua 5.4 suites. Native lifetime/ownership
guarantees remain outside that evidence.

Six in-memory mutants are rejected: guild collision, stream collision, ignored
completion identity, foreign data misclassified as missing, early durability
before mailbox release, and inline-completion receipt retagging.
Evidence: `test-results/save-transport-20261003/`.

## Next implementation gate

[V6 scoped ownership](async-save-scoped-2026-10-03.md) now implements immutable
native world/guild/stream slot binding and drained owner handover with explicit
monotonic epochs. The native scope matrix, asset reload and fresh-process
readback pass. V4/V5 lifetime, reservation and retained-mailbox work remains the
foundation; their earlier missing-feature lists are historical.

The full adapter still needs native process-wide uniqueness, verified persistent
storage identity discovery, missing/unreadable result classification and copied
completion envelopes. Follow with scoped migration/backups, sizes beyond 64 KiB
and generation-based network durable acknowledgements. Keep the production
baseline-capture barrier until actual persistence is confirmed. The isolated V6
trial does not authorize routing real settings into this experimental backend.
