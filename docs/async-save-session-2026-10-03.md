---
date: 2026-10-03
tags: [async-save]
status: evidence
---
# Save-session controller — October 3, 2026

Related: [async-save-world-transition-2026-10-04](async-save-world-transition-2026-10-04.md) · [async-enablement-2026-10-04](async-enablement-2026-10-04.md)

Status 2026-10-20: experiment code under `experiments/`, not wired into the
shipping writer. Async stays off; 0.5.0 ships the synchronous writer unless
optional gate G2b closes first ([RELEASE-0.5.0.md](RELEASE-0.5.0.md) G2/G2b).

Status on October 3: implemented in the isolated experiment with regression
coverage. Not installed, not wired into production settings, and not an in-game
acceptance result. Production persistence remains synchronous and unchanged.

This note also holds the two contracts the controller sits on: the
`save_scratch.lua` queue (September 29, merged from async-save-scratch) and the
`save_scope.lua`/`save_transport.lua` native backend contract (October 3, merged
from async-save-transport). The rejected Blueprint routes around them are in
[async-save-history.md](async-save-history.md).

## Why this boundary comes first

The V3 native trial proves completion delivery and bounded synthetic readback,
but the existing production edit handler equates a successful synchronous flush
with durability. Async enqueue cannot replace that return value safely. The
baseline-capture barrier must also continue waiting for confirmed persistence
before automatic permission changes are allowed.

`experiments/save_session.lua` wraps the existing pure queue with an explicit
development gate. No factory or IO runs unless enabled is exactly true. Its
factory must construct, without IO, an adapter/queue bound to a stable storage
owner. That owner must include world/guild/storage-stream identity; an incarnation
token identifies the current connection/role, not a reusable map name.

## Contract

October 3 authority-gate follow-up: enabled controllers now require an injected
`authorize(owner, incarnation)` callback. Missing, throwing or non-true results
deny queue construction and new submissions. This trusted, non-yielding,
non-reentrant callback must freshly establish the exact scope/incarnation,
authority and verified storage readiness; selected-world ID format is not proof.
The native evidence provider is still unimplemented, so this is a fail-closed
integration boundary, not native identity verification.

Authorization is checked before/after construction, on submissions, before/after
polling and before exposing status or committed ranges. Loss retires the active
incarnation permanently: already accepted snapshots drain to their original
owner, but recovery installation and completion replies are suppressed. A return
to hosting requires a new incarnation, even for the same storage owner. Retired
definite-failure retry retains the previous contract; it cannot accept new data.
The [same-process observation](async-save-world-transition-2026-10-04.md)
(the selected local ID survives joining a server) motivated this gate.
Production persistence and installed modules remain unchanged.

- `open(owner, incarnation)` recovers before edits are admitted. Failed or
  unreadable recovery cannot install an empty configuration.
- `submit(incarnation, full_snapshot)` returns a receipt for memory acceptance,
  never a durable acknowledgement. Snapshots are immutable strings up to 64 KiB,
  containing the complete stream state, not deltas. Coalescing may skip an
  intermediate payload while preserving later authoritative state.
- `status(receipt)` distinguishes saving, saved, error, uncertain and stale.
  A validated saved prefix does not clear a newer dirty revision.
- `take_committed(incarnation)` returns newly confirmed revision ranges once.
  Recovery does not emit acknowledgements for another connection's edits.
  Production routing must still check scope/incarnation and retain bounded
  durability evidence independently of request settlement.
- Timeout marks an outstanding operation uncertain without releasing its lock,
  resubmitting it, or claiming failure. A matching late terminal result may
  resolve it. Clock values must be finite and monotonic.
- `close(incarnation)` revokes new submissions and completion replies immediately,
  retaining the old queue until accepted data drains. Explicit retry of a
  definitely completed failure is allowed for that retired owner; uncertain IO
  cannot be retried. A new owner cannot replace unfinished work.
- Controllers targeting the same backend must share one lease. Constructor
  reentry is rejected. This cooperative Lua lease is not sufficient protection
  across module reloads; the native adapter must enforce ownership too.
- Incarnation reuse is refused across controllers sharing the backend lease.
  The development prototype keeps a bounded 256-token history and refuses
  further opens at capacity.

`experiments/save_scratch.lua` gains `timeout()`, preserving its in-flight
operation and latest snapshot while changing the reported state to uncertain.
It also captures each submitted revision before adapter dispatch so a reentrant
submission cannot change the receipt returned for the original snapshot.

## Verification

Authority-gate follow-up: all 92 scripts pass with both transport integration
fixtures explicitly supplying authorization. Tests reject missing, nil, false,
string and throwing callbacks; constructor-time revocation starts no recovery;
role loss suppresses recovery installation and ACKs while old accepted data
drains; regaining authority cannot revive an old incarnation. Independent review
found a test ternary that did not actually exercise missing callbacks; corrected
to an explicit nil assignment and reran the suite. No remaining code finding
under the documented callback contract. Current run:
`test-results/save-transition-20261003/lua-authority-gate.log`.

Lua 5.4 compiles 51 production modules. All 84 regression scripts pass. The new
session suite exercises delayed/coalesced revisions including X, both-slot
recovery, stale receipts, close during flight, changing storage scope, late
completion, ambiguous start, definite failure/retry, recovery failure, deadline
handling, replacement-controller contention, reentrant construction, and
construction failure. Independent review found two reentrancy bugs, now covered:
old-token close/poll cannot release a constructor's reservation, and nested
submissions retain distinct receipts. Five in-memory mutants compile but fail
the suite: premature durable receipts, removed uncertainty timeout, removed
lease check, old-close reservation release, and wrong nested-submission receipt.
Receipts are in `test-results/save-session-20261003/`.

The independent reviewer rechecked both fixes and ran the session, scratch queue
and interruption suites under Lua 5.4. No remaining findings in that bounded
review; this does not validate the unwired native production adapter.

## Remaining integration gates

### Fresh evidence composition (October 3 follow-up)

`experiments/save_authorization.lua` supplies the controller's authorization
callback from three trusted, fresh providers: copied current context, identity
observation and active-storage proof. It rejects missing/throwing providers,
client/undecided roles, unloaded/unknown worlds, wrong incarnation or scope,
unreadable/conflicting candidates and incomplete/foreign proofs. It copies the
initial context before invoking other providers and compares the context again
after verification. Nested authorization is denied; providers must not yield.

The proof contract `PWP-ACTIVE-STORAGE-1` binds active storage to the same
incarnation, epoch, world and guild. It is a trusted integration contract, not a
cryptographic credential or verification merely because fields are populated.
The provider must prove active loaded storage; directory existence or the
selected-ID property alone cannot implement it. **No native provider has been
implemented or installed.** The observed viewport/local-host candidate route is
the only route covered here; dedicated-server identity remains unavailable.

All 93 Lua scripts pass. The new suite covers candidate/readiness failures,
foreign/stale proofs, changes during provider calls, reentry and real controller
plus queue integration: a retained ID on a client initiates zero recovery IO.
Evidence: `test-results/save-transition-20261003/lua-authorization-evidence.log`.
This step changes no production file and needs no game restart.
Independent review found no concrete issue under the trusted, non-yielding
provider contract; authorization/session/transport suites and supplemental
mutation/reentry checks passed. Review does not establish native storage proof.

V6 subsequently demonstrated scoped development slots and operation identity
([history](async-save-history.md), V6 section); it is still
not a production backend. Before any real setting uses it, complete native
singleton ownership, verified identity, positive absence versus unreadable
distinction, safe migration/backups, and realistic serialization beyond the
current 64 KiB prototype limit. Preserve the production baseline fence barrier
and separate priority/limit streams.

Wire network completion to scoped generations rather than request-ID inference;
keep notifications bound to immutable batches (or conservatively invalidate the
whole stream), and never clear newer dirty changes on an older completion.
Exercise host/client/host transitions, native interrupted IO and storage errors,
then matched in-game edit/frame tests. No game restart is useful for this pure
controller yet, and no production installation was attempted.

## Queue contract: `save_scratch.lua` (2026-09-29, merged from async-save-scratch)

The queue is still live experiment code (`experiments/save_scratch.lua`) and is
what the session controller above wraps. It is a pure queue/recovery model,
**not an integrated UE4SS adapter**. Contract:

- Copies strings/numbers, bounds payload/generation, keeps one operation in
  flight, coalesces later values and rotates A/B slots after verified completion.
- Separates stable persisted scope from incarnation tokens. The record field
  named Session holds stable scope; tickets/incarnation identify callbacks.
- Refuses dirty/in-flight reset, preserving unfinished saves. Requires recovery
  before writing and after a clean reset. Ambiguous starts retain the IO lock;
  timeouts never cause overlapping retries. Failed saves remain unsaved.
- Requires explicit missing/valid/invalid/unreadable read outcomes. Nil is not
  absence. Empty initialization requires both slots positively missing. Invalid
  data without a valid alternate generation blocks writes.
- Uses an FNV-1a checksum for accidental-corruption detection, not authentication.

This is a single-owner scratch design, not multi-guild persistence or a complete
role-transition/shutdown implementation. The fixed slots are not independent
storage for multiple concurrent owners (the scoped slot names below fix that).

Local UE 5.1 sources confirm serialization into copied bytes before
SaveGameAsync, default-platform file writing on the task pipe, and completion on
the core ticker/game thread. The pipe explicitly does not guarantee ordering, so
the one-operation-in-flight rule is necessary.

### The V1 editor prototype the queue was first tested against

Built and exercised in UE 5.1.1, reloaded in a fresh editor process, cooked for
Windows and packaged separately. Never installed in Palworld or on the server
(that came with V2, see [history](async-save-history.md)).

- Generator: `unreal/PalWidgetGen/Private/BuildSavePrototypeCommandlet.{h,cpp}`
  makes a SaveGame Blueprint and an Actor Blueprint from stock engine nodes. The
  actor owns ActiveSave and invokes UAsyncActionHandleSaveGame. Busy rejects
  overlapping submissions. Done/Success/CompletedGeneration expose completion on
  the game thread. Engine GameInstance registration owns the pending action.
- Package: `test-results/save-scratch/PalWorkPrioritySaveScratch.pak`, SHA256
  `a0238c366e68b7e37dbc336edc8e831107c42b0f728c05c75d02da1e83fd2c9e`. Exactly
  four files: BP_ScratchRecord and BP_ScratchBridge (.uasset/.uexp). Printable
  cooked /Script imports are Engine and CoreUObject only. No DLL, Lua worker,
  ModActor or production asset.
- Slots: only fixed `PWP_SaveScratch_v1_A` and `_B`, no caller-supplied path.
  Fixtures use tiny synthetic strings containing X, never actual priorities.

| Check | Result |
|---|---|
| Native write/readback | Passed; game-thread completion verified |
| Actual Blueprint event | Passed; overlapping submission rejected |
| Forced GC while pending | Passed; original generation completed |
| Null-record submission | Passed; failure reported and Busy cleared |
| Fresh process | Both native A and Blueprint B payload/generation reload exactly |
| Cook/package | Passed; four scratch files, no production files |
| Lua | 51 production modules compile; all 78 regression scripts pass |

Final repeat: native enqueue **0.082 ms**, completion **36.759 ms**; Blueprint
enqueue **0.092 ms**, completion including forced GC **16.288 ms**. An earlier
Blueprint run measured **11.428 ms** enqueue and **28.280 ms** completion. Do not
claim all enqueues are sub-millisecond. Completion is measured before the
synchronous readback; tiny editor payloads are not server benchmarks.

Null-record failure is engine rejection, **not** disk-full/permission/interrupted
write testing. Queue regressions inject unsuccessful completion, corrupt readback,
read exceptions, nil/error, explicit unreadable, both corrupt slots, stale ticket,
dirty reset, cross-incarnation recovery and failed re-recovery; these do not
replace physical filesystem fault tests. Independent review caught recovery
identity, dirty-reset, re-recovery and ambiguous-read defects; each has a
regression. Editor debugging fixed the wrong SelectString helper class, double
fixture-world initialization, missing core ticker pumping and disabled editor
Actor script execution (dated logs kept under `test-results/save-scratch-*`).

Repeat (the kit must already include PalWidgetGen; compiler 14.38.33130;
`--skip-build` needs an already compiled matching commandlet; the script never
installs the package):

```powershell
python tools/test_lua.py
python tools/build_save_scratch.py --engine 'D:\Program Files (x86)\Epic Games\UE_5.1' --kit 'C:\Users\matra\Desktop\PalworldModdingKit'
```

Open items it named, still true for any real adapter: a fresh-resolution UE4SS
driver with duplicate-load rejection and no wrappers kept across callbacks; a
nonblocking or bounded readback (a synchronous LoadGameFromSlot can stall on
the server); real headless-runtime mounting; slow/failing storage and restart
tests that preserve the prior valid generation; and an engine success callback
is not power-loss durability. Installed client datafile.lua stayed
`E87094DBB64DC7858E91301832DC3DE4B7824ABFE7BC8253AAA40AD4B381FEF1`.

## Native backend contract: `save_scope.lua` / `save_transport.lua` (2026-10-03, merged from async-save-transport)

Status then: isolated Lua scope/transport boundary exercised with the real queue
and session controller against an in-memory reference backend. **No compatible
native backend existed; nothing installed or enabled.**

### Scope: `experiments/save_scope.lua`

Derives deterministic slot names from a verified persistent storage GUID, guild
GUID and the priorities/limits stream. Both GUIDs must have 32 hex digits and be
nonzero. Map names, display names and incomplete identities are refused. Case is
canonicalized. Fixed-width identities are encoded directly, without a
collision-prone shortened hash or caller paths. Slots use the separate
`PWP_AsyncDev_v1_` namespace. Camp-specific records stay inside their
guild/stream snapshot. Obtaining the correct persistent world/server storage
identity is an integration requirement, not something this adapter guesses.

### Transport: `experiments/save_transport.lua`

Translates the scratch queue's logical A/B slots into that namespace. Requests
contain immutable copies and separate incarnation/ticket identity from the
persisted record generation. Completion must match scope, incarnation, ticket,
operation and physical slot. A matching terminal result is copied and retained
locally until the backend acknowledges consumption of its terminal mailbox.
Failed acknowledgement retries only that acknowledgement, never the storage
operation. Reentrant polling is guarded.

Foreign records stop recovery even when the other slot contains a valid older
record. Null/unknown loads are not classified as missing. Exact checksum/payload
validation stays in the queue before its saved generation advances. Accepted
writes still do not imply durability.

The adapter requires explicit development opt-in and the backend contract string
`PWP-SCOPED-DEV-1`; the V2/V3 native bridges do not implement it, and V4/V5 must
not advertise it. Checking a contract string is API compatibility, **not proof
of native safety**.

### Required native contract

- `dispatch(operation)` returns true for accepted, false only for definitely not
  started, or an uncertain outcome. Native admission must bind verified scope,
  owner and lifetime, enforce monotonically increasing operation tickets and
  reject competing/duplicate owners. Uncertainty cannot permit another write.
- `peek(identity)` returns a copied, retained terminal envelope or pending. Its
  `read.status` is explicitly ok/missing/invalid/unreadable; missing needs
  positive platform evidence. Completion includes save and readback, not save
  alone.
- `consume(identity)` acknowledges exactly that terminal result. It is idempotent
  after a lost response and cannot release a newer operation. Pending or
  unmatched mailboxes cannot be overwritten. A missed Lua hook must not lose the
  result.
- Engine-backed ownership must survive Lua reload and cover world teardown.
  **Trap:** a world-owned Actor bridge can disappear with its world while IO is
  still in flight. Actor absence, timer cancellation, or an empty Lua lease is
  not proof that IO stopped. A surviving coordinator or independently verified
  drain is required before opening those slots again (V4 moved to a rooted
  transient UObject for this reason, see
  [history](async-save-history.md), V4 section).

Independent design review confirmed that bind-once identity and a retained
mailbox improve the Actor within one world lifetime, but do not by themselves
solve teardown.

### Verification

Lua 5.4 compiles 51 production modules; all 85 regression scripts pass. The suite
covers world/guild/stream separation, canonical/path-safe identities, X
round-trip, mismatched completions, foreign data in an alternate slot, unreadable
recovery, lost completion notification, failed/lost consume acknowledgement,
reentrant consume, ambiguous dispatch and complete queue/session integration.
The backend in these tests is a contract fixture, not Unreal or the server.

Review found that inline completion could replace a session during dispatch and
retag the old receipt with the new incarnation. Submission now captures the
originating queue/scope/incarnation; recovery, polling and retry revalidate that
origin after callbacks. A regression closes/reopens during submission and checks
that the old receipt stays stale, even after new-session recovery.

Six in-memory mutants are rejected: guild collision, stream collision, ignored
completion identity, foreign data misclassified as missing, early durability
before mailbox release, and inline-completion receipt retagging.
Evidence: `test-results/save-transport-20261003/`.

Still missing for the full adapter: native process-wide uniqueness, verified
persistent storage identity discovery, missing/unreadable classification and
copied completion envelopes, then scoped migration/backups, sizes beyond 64 KiB
and generation-based network durable acknowledgements. Keep the production
baseline-capture barrier until actual persistence is confirmed.
