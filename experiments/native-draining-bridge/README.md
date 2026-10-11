# Isolated native draining facade (default off)

No installation, Lua session implementation, engine hooks, native game-save paths,
or production wiring. The sole export is `luaopen_pwp_draining_bridge`. The bridge
uses the tested `native/save_core/draining_writer` unchanged. A trusted caller must
validate local authority/context and BOTH recovered typed schemas; this native
facade is not storage authorization or a typed-settings validator.

`python experiments/native-draining-bridge/check_link.py` builds `/MD` release
objects, runs actual-entry tests against the real native backend/filesystem, and
audits exactly the existing ten public LuaMadeSimple imports against pinned
UE4SS `2281fa31`. It writes only this directory's `build/` artifacts. It never
loads UE4SS or installs/loads the built DLL. Runtime ABI remains a live check.

## Wire contract (settled)

Reuse `experiments/save_native_backend.lua`'s `call`, `pack`, and `unpack` unchanged;
do NOT use its settings-backend factory with this different command vocabulary.

Inputs: `(command, handle, ticket, hex_input, hex_length)`.
Results: `(status, packed_data, caller_thread, QPC_start, QPC_end, QPC_frequency)`.
Fields are binary LEu32 length + exact bytes, no field count, maximum 16 fields
and 600000 raw bytes. Input is lowercase hex, exact even length. Empty input is
zero fields/empty string. Payload bound is 262144 bytes. Integers are removed in
descending order `5,3,2,1`; the original hex string stays rooted while its copy
is read and decoded. `set_string(string_view)` copies output including NUL bytes.

Status 0 means this call was definitely refused, 1 means command success, 2
means recovery peek pending. No results / exception / malformed reply means
unknown completion. Status 1 is NEVER itself a durable ACK (even drain can return
status 1 with a blocked phase). Inspect identity and all status fields.

The trusted startup call to command 0 establishes the control thread. The bridge
cannot independently identify a UE game thread. Every later call, including
read-only status and cleanup, must be on that same thread. No `ExecuteAsync` or
Lua callbacks are used for journal work; `DrainingWriter` runs its own native
thread. Returned thread is the caller, NOT worker telemetry. Offline worker
routing evidence does not establish live engine-thread identity.

| Command | Handle/ticket | Fields | Successful data |
|---|---|---|---|
| 0 configure | 0/0 | none | one field root ID `1` |
| 1 owner only | 1/0 | worldGUID,guildGUID,stream,incarnation,epoch | one monotonic handle |
| 2 start recovery | handle/positive | none | empty |
| 3 peek recovery | handle/0 | none | recovery16, or status2 with empty data |
| 4 typed-side approval | handle/positive | `existing` OR `initialize_missing` | empty |
| 5 submit | handle/positive | complete copied payload | one logical revision |
| 6 status | handle/0 | none | status16 |
| 7 close | handle/positive | none | empty |
| 8 drain | handle/positive | none | status16 |
| 9 cleanup | handle/0 | none | empty, idempotent after cleanup |

World/guild are 32 lowercase nonzero hex GUIDs; stream is `priorities` or `limits`.
Incarnation is 1..128 printable nonspace ASCII bytes; epoch is canonical decimal
1..2147483646. Mutating tickets (2/4/5/7/8) strictly increase per handle and are
consumed BEFORE the native action. Handles never reuse: at most 128 total and
eight active/unresolved slots. No raw pointer, userdata or runtime path input.

The fixed root is the EXISTING disposable directory:
`C:/Users/matra/Desktop/palworld-priority-mod/test-results/native-draining-live-20261004/store`.
Namespace: `local-test-profile`. Command 0 pins that configured directory; it
does not create it. Command 1 claims an immutable scope/incarnation/epoch owner
without record IO or worker launch. Command 2 is the separate postcheck/start.

Recovery16 uses the prior bridge format:
`scope, incarnation, epoch, status, certain, generation, covered_revision,
preimages, error, cleanup_error, Astatus, Agen, Apayload, Bstatus, Bgen, Bpayload`.
Nonvalid slot generation is `0`, payload empty. Peek is available only while
awaiting validation. Approval asserts the trusted typed caller inspected both
valid payloads. `initialize_missing` additionally asserts explicit first-write
authorization and is only accepted on positive absence; existing is refused
on missing. Approval itself is not a storage-authority grant.

Status16:
`scope, incarnation, epoch, accepted, committed, phase, error, generation,
cleanup_error, terminal_status, terminal_certain, terminal_error,
last_ticket, last_command, last_revision, last_outcome`.
Phases: `dormant`, `recovering`, `awaiting_validation`, `ready`, `closing`,
`closed`, `blocked`. Errors: `none`, `recovery`, `admission`, `publication`,
`uncertain`, `consume`, `release`, `exception`. Last outcome: `none`, `unknown`,
`accepted`, `refused`. `last_revision` is nonzero only for accepted submit.
Terminal fields are empty before any terminal. Counters are local logical
revisions, distinct from physical journal generation.

## Lost returns and lifetime

Never retry a lost mutating call. Query status with ticket0 and validate the
immutable identity plus last_ticket/command/outcome/revision. An accepted submit
may still fail to commit; only the committed prefix may be acknowledged. If the
last action is unknown, stop admission and retain the handle; do not infer that
no bytes were published. A duplicate ticket returns 0 WITHOUT replaying it; that
does not undo or deny acceptance of the earlier invocation. Lost configure/owner
returns do not have a handle-recovery protocol: stop that trial; the bounded
registry retains any successfully created owner. No automatic reset or retry.

Close fences new submissions and drains accepted work on the original owner.
Drain closes and joins explicitly on the control caller OUTSIDE loader lock.
It has NO wall-time guarantee: filesystem calls may block. Never call it in
DllMain, CRT teardown, or while holding locks needed by filesystem filters.
After drain, cleanup destroys a writer only if it was positively joined AND its
phase is closed. Blocked/unknown coordinators remain retained/pinned. Root pins
remain for process lifetime; there is no reconfiguration command.

The registry is intentionally allocated through a static heap pointer with no
registry destructor registered for CRT/DLL teardown. Module pinning is NOT a
substitute for this: pinning does not prevent process-termination CRT destructors.
Source guards check this boundary, and an actual-entry executable returns from
main with an awaiting-validation worker to test normal CRT teardown without an
implicit join. No DllMain/unload autojoin logic is added.

## Offline evidence and next trial

Actual entry + real native files cover owner-only inactivity, missing recovery,
explicit approval, initialization snapshot preservation, deterministic native
coalescing of revisions 2/3, explicit drain, exact typed generation readback,
binary NUL transport, invalid packets, otherwise-valid wrong-thread commands,
stale/duplicate tickets, lost submit reply, eight-active/128-total bounds, cleanup,
and a real injected after-publication failure with no committed ACK/owner release.
Parser-order and original-string-root mutants must fail at the actual entry.
Only LuaMadeSimple is mocked; native test pause/fault hooks are compiled into
test objects ONLY, never the DLL. Test roots are compile-time overrides beneath
build/, never runtime path arguments. Both recovered typed payloads are checked
with the actual Lua settings codec.

For a future synthetic GUID1/GUID2 trial, submit initialization revision1 then
2/3 quickly; explicit drain while alive must report accepted=committed=3, closed,
error=none. Physical generation may be 2 or 3 depending on scheduling. Cleanup,
reopen/recover, validate BOTH typed slots and exact latest payload3, then drain
without approval and cleanup. This facade does not establish supported shutdown
hooks, all travel modes, normal-game-exit draining, crash/power-loss guarantees,
or production/multiplayer suitability. A separate live caller owns those checks.
