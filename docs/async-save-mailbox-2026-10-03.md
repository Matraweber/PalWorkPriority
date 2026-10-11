# Native save ownership and retained results — October 3, 2026

V5 adds native admission and completion acknowledgement to the rooted V4 lifetime
experiment. It uses only `PWP_SaveMailbox_v5_A/B` and the fixed synthetic scope
`PWP-MAILBOX-DEV-1`. This is **not** the dynamic scoped production backend.

## Implemented boundary

- `BindOwner(scope, owner)` rejects unknown scope and empty/oversized owners.
  The first valid owner is permanent for this object. Repeating the same bind
  succeeds without resetting counters; another owner cannot replace it.
- `ReserveRequest` checks binding, positive increasing ticket below INT_MAX,
  operation kind and idle state. It reserves Busy and snapshots record, ticket,
  kind and slot **before returning**. The event wrapper reads no request-input
  temporaries after this call, including after a reentrant post-hook.
- Busy IO and an unconsumed terminal result both block subsequent dispatch.
  Completion retains the result and its identity; losing a Lua notification
  does not release admission or discard that result.
- `ConsumeResult` requires exact scope, owner, ticket, kind and slot. It clears
  only a matching terminal result. Retrying the last consumed identity succeeds
  without modifying a newer pending/terminal operation. The tombstone stores one
  identity; older acknowledgements after a later consumption are rejected.
- Unknown or interrupted IO is never unlocked merely by timeout, object lookup
  failure or a new Lua table. No cancellation/owner-transfer mechanism is added.

V5 uses the same explicit retain/bind/activate async graph ordering as V4. These
are ordinary cooked Blueprint nodes; no new runtime native DLL is required.

## Verification and defects caught

The native fixture covers unbound/invalid admission, immutable binding, busy
rejection, terminal retention through GC, wrong identity fields, duplicate
consume, ticket replay after rebind, old acknowledgements during newer IO and
newer synchronous failure, and read acknowledgements. The V4 pending-teardown,
readback-GC and cleared-inline-action checks also run against V5.

A separate **unsaved, editor-only graph extension** consumes write ticket 2 and
starts read ticket 3 inside `ScratchCompleted`, then returns through the old
completion stack. It checks the newer pending state, exact unique record,
completion count and first write success. A unique GUID payload prevents stale
slot B data from making a failed write pass. The fixture then checks restoration
of the standard record used by the independent restart test. The extension and
its probe fields are not serialized into the cooked diagnostic.

Fresh-process verification initially caught result-node defaults resetting on
asset reload. Linked `MakeLiteralBool` nodes plus the entry's function reference
replace those defaults. Initial failed logs/asset are preserved under
`test-results/save-scratch-v5/failed-result-default/`. The precise original
serialization mechanism was not independently established; corrected fresh
reload behavior is directly tested.

Independent review also prompted the atomic reservation change and stronger
reentry/driver assertions. The Lua driver test deliberately clears Busy or the
pending proxy during an old acknowledgement; both corruptions must fail the
trial. Mock driver tests do not substitute for native execution.

Native build evidence: `test-results/save-scratch-v5/`. Live installation and
acceptance evidence: `test-results/save-mailbox-live-20261003/`.

## Completed live trial

The checked V5 package and separate one-shot Lua diagnostic were installed only
on the local client. All copied files matched their source hashes; every
production Lua hash remained unchanged. The existing V4 control was disabled.
The authorized server macro exited process 3464 normally, started process 6892,
joined RAM and reopened the Monitoring Stand.

| UTC time | Result |
| --- | --- |
| 10:05:20 | One-shot arm consumed |
| 10:05:22 | Real UE4SS Lua session/transport suites pass; exact 65,536-byte native write/readback passes |
| 10:05:22 | Native bind, retained-result, wrong-identity, idempotent-ack and replay guards pass |
| 10:05:23 | Separate read completes; its result deliberately remains unconsumed |
| 10:06:05 | MainWorld5 travel retains that result; old ack leaves it intact; exact consume and retry succeed; timer cancelled |
| 10:06:34 | Server macro confirms expected guild handshake and reopens stand |

Both V4/V5 controls read `DISABLED`. The stand was visually checked after join
with priority numbers visible. All 87 Lua regression scripts pass; 51 production
modules compile. Native build/verify/fresh reload/restart/cook/package checks pass.
Final pak SHA256:
`54771da70baa3e7e2d23c9186653dbd844e45d9e706c3478df89657ba301e5bb`.
Native pending-teardown/reentry tests and live completed-IO travel are separate
pieces of evidence; the live run did not inject actual filesystem failures.
The production log includes the expected dedicated-client authority warning.
This is not a claim that all UE4SS boot diagnostics are warning-free.
Final independent evidence review agreed with the bounded pass and separately
verified all eight installed entries, all 51 production Lua hashes and both
disabled controls. No mismatch was found.

## Remaining integration gates

This proves per-object ownership and result retention on fixed synthetic slots.
It does not enforce a process-wide singleton across arbitrarily constructed
coordinators. The local driver refuses another V5 object before constructing its
single rooted instance; a production factory still needs native uniqueness.
The immutable owner intentionally refuses turnover until process exit; safe
retirement/transfer is not implemented.

Persistent world/guild/stream identity discovery and slot binding, missing versus
unreadable IO, migration and backups, larger records, copied terminal envelopes,
and generation-based network acknowledgements remain required. V5 must not
advertise `PWP-SCOPED-DEV-1` to `save_transport.lua`. It does not change the existing
production save writer, and these checks establish no frame-time improvement.
