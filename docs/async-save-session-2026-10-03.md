# Save-session controller — October 3, 2026

Status: implemented in the isolated experiment with regression coverage.
Not installed, not wired into production settings, and not an in-game acceptance
result. Production persistence remains synchronous and unchanged.

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

October3 authority-gate follow-up: enabled controllers now require an injected
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
The [same-process observation](async-save-transition-2026-10-03.md) motivated
this gate. Production persistence and installed modules remain unchanged.

- `open(owner, incarnation)` recovers before edits are admitted. Failed or
  unreadable recovery cannot install an empty configuration.
- `submit(incarnation, full_snapshot)` returns a receipt for memory acceptance,
  never a durable acknowledgement. Snapshots are immutable strings up to64KiB,
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
- Incarnation reuse is refused across controllers sharing the backend lease. The development prototype
  keeps a bounded256-token history and refuses further opens at capacity.

`experiments/save_scratch.lua` gains `timeout()`, preserving its in-flight
operation and latest snapshot while changing the reported state to uncertain.
It also captures each submitted revision before adapter dispatch so a reentrant
submission cannot change the receipt returned for the original snapshot.

## Verification

Authority-gate follow-up: all92 scripts pass with both transport integration
fixtures explicitly supplying authorization. Tests reject missing, nil, false,
string and throwing callbacks; constructor-time revocation starts no recovery;
role loss suppresses recovery installation and ACKs while old accepted data
drains; regaining authority cannot revive an old incarnation. Independent review
found a test ternary that did not actually exercise missing callbacks; corrected
to an explicit nil assignment and reran the suite. No remaining code finding
under the documented callback contract. Current run:
`test-results/save-transition-20261003/lua-authority-gate.log`.

Lua5.4 compiles51 production modules. All84 regression scripts pass. The new
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
and interruption suites under Lua5.4. No remaining findings in that bounded
review; this does not validate the unwired native production adapter.

## Remaining integration gates

### Fresh evidence composition (October3 follow-up)

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

All93 Lua scripts pass. The new suite covers candidate/readiness failures,
foreign/stale proofs, changes during provider calls, reentry and real controller
plus queue integration: a retained ID on a client initiates zero recovery IO.
Evidence: `test-results/save-transition-20261003/lua-authorization-evidence.log`.
This step changes no production file and needs no game restart.
Independent review found no concrete issue under the trusted, non-yielding
provider contract; authorization/session/transport suites and supplemental
mutation/reentry checks passed. Review does not establish native storage proof.

V6 subsequently demonstrated scoped development slots and operation identity;
it is still not a production backend. Before any real setting uses it, complete
native singleton ownership, verified identity, positive absence versus unreadable
distinction, safe migration/backups, and
realistic serialization beyond the current64KiB prototype limit. Preserve the
production baseline fence barrier and separate priority/limit streams.

Wire network completion to scoped generations rather than request-ID inference;
keep notifications bound to immutable batches (or conservatively invalidate the
whole stream), and never clear newer dirty changes on an older completion.
Exercise host/client/host transitions, native interrupted IO and storage errors,
then matched in-game edit/frame tests. No game restart is useful for this pure
controller yet, and no production installation was attempted.
