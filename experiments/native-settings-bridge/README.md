# Native settings bridge — uninstalled development experiment

Export: `luaopen_pwp_settings_bridge` in `build/pwp_settings_bridge.dll`.
No production wiring, game automation, migration, UObject access, or install.
Native save-core files and the Lua adapter are owned separately; this experiment
uses their current APIs without editing them.

The shipping experiment configuration is compiled in:

* Root: `C:/Users/matra/Desktop/palworld-priority-mod/test-results/native-settings-live-20261004/store`
* Profile namespace: `local-test-profile`
* Root capability ID: 1, separate from the binding-handle ID space.

Root must already exist. Command 0 pins it; commands 0/1 may open native handles
but perform no settings writes. There is no runtime path argument, root creation,
automatic retirement on world events, or reconfiguration. Root pinning and owner
binding happen on the control thread and are included in the reported QPC time.
The first valid command 0 caller defines control; the bridge cannot independently
identify Unreal's game thread. The trusted Lua caller must establish that route.

## Wire contract

Exactly five arguments, with actual Lua types integer/integer/integer/string/integer:

```text
command, handle, ticket, lowercase_hex_input, hex_character_length
```

Decoded packets contain zero or more `[unsigned LE u32 byte length][field bytes]`
fields, with no count/header/terminator. Empty packet is `""`, not one empty field.
Maximum raw input/output is 600000 bytes; hex input is at most 1200000 characters.
Input has strict per-command field counts. Numeric fields are canonical decimal
ASCII (no leading zeros except `"0"`). GUIDs are lowercase, nonzero, 32 hex digits.
Payloads are binary, maximum 262144 bytes; preimage tokens are 1–256 bytes.
Incarnation is 1–256 printable ASCII bytes. Tickets/epochs/revisions are positive
and <=2147483646; physical generation is positive and <=4294967295 (the backend
can reject additional semantic limits). Handles are 1–128 and never reused.

Normal reply is exactly six Lua values:

```text
status, packed_binary_data, thread_id, QPC_start, QPC_end, QPC_frequency
```

Status 0 is definite refusal, with empty data; 1 is success/terminal; 2 is pending,
with empty data. Malformed transport, caught exceptions, failed worker delivery,
or ambiguous release produce zero values: unknown outcome, never implicit retry.
Peek remains possible after a worker's false delivery if native retained a
terminal. Native throws during mutating operations can permanently fence that
binding. QPC measures dispatch/backend work, after transport decoding; it does not
measure the input hex conversion or Lua reply copy.

The pinned getter removes its stack entry and exposes a NUL-terminated view.
The entry reads integer indices 5,3,2,1, duplicates the remaining input string,
removes only that duplicate through `get_string`, and copies/decodes while the
original remains rooted. Length is checked against the exposed hex view, and all
view bytes must be lowercase hex. Because the public getter does not expose the
original Lua byte length, it cannot detect an embedded NUL suffix hidden beyond
a correctly claimed prefix. The trusted adapter must produce hex itself (as
`save_native_backend.lua` does); this API is not a hostile-Lua sandbox. No binary
payload is passed directly to that getter. Binary output uses the pinned
`set_string(std::string_view)` → `lua_pushlstring(data,length)` copy.

## Commands

| Command | Handle/ticket | Input fields | Success data |
| --- | --- | --- | --- |
| 0 configure | 0 / 0 | none | one field `"1"` (rootcap); one attempt only |
| 1 bind | rootcap 1 / 0 | worldGUID, guildGUID, stream, incarnation, epoch | one decimal binding ID |
| 2 recover | binding / ticket | none | empty; retains exact admitted job |
| 3 update | binding / ticket | preimageToken, payload, physicalGen, coveredRevision, initialize (`"0"`/`"1"`) | empty; retains exact admitted job |
| 4 run | binding / exact ticket | none | empty; only non-control thread, once |
| 5 peek | binding / exact ticket | none | pending empty, or terminal 16 fields below |
| 6 consume | binding / exact ticket | none | empty; exact last-consumed ticket is idempotent, including while a newer job is pending |
| 7 retire | binding / 0 | none | empty; explicitly after all Lua-accepted work drains and no native job remains |
| 8 release | retired binding / 0 | none | empty; closes binding, never recycles ID |

Every command except 4 requires control-thread identity before backend actions;
command 4 rejects control-thread execution before journal IO. Mutex-protected
preflight captures the exact retained job, then unlocks for worker IO. Stale
tickets/handles and duplicate closures cannot look up/run a replacement job.
Failed native binding attempts burn an ID; lifetime maximum is 128 attempts.
Consumed ticket tracking is per binding and only the most recently consumed
ticket is replayable; it cannot consume another outstanding operation.

Terminal fields, exactly 16:

```text
scope, incarnation, epoch,
status, certain(0/1), generation, covered_revision, preimages, error, cleanup_error,
Astatus, Agen, Apayload, Bstatus, Bgen, Bpayload
```

The first three fields come from the retained native binding, not peek arguments.
Lua must validate them against its expected owner before accepting/consuming.
Recovery `status="recovered"` exposes both slot classifications. Valid slots carry
their actual generation/payload; all nonvalid slots carry generation `"0"` and
empty payload. All other terminal statuses, including update and cancellation,
carry six empty fields in positions 11–16. Typed schema checks and fresh mutation
authorization remain upstream. A successful run reply means terminal delivery,
not durable settings success; inspect status/certainty/errors and validate payloads.

Accepted tail work deliberately retains its old root/binding. World events must
not automatically retire it before that accepted work drains. This bridge does
not implement fresh session authorization; it assumes the injected caller has
established it before accepting mutations.

## Build and verification

Run `python experiments/native-settings-bridge/check_link.py`. Release `/MD`,
pinned public headers and runtime-export audit; exactly the nine handoff imports
plus `set_string(std::string_view)`. No raw Lua imports or second Lua runtime.

The build executes the actual entry with stack-popping Lua and in-memory native
mocks, including binary NUL payloads, strict packet shapes, rooted input, threads,
stale/duplicate jobs, identity prefixes, capacity, uncertainties, and lost-return
consume replay. Generated old-order and unrooted-input mutants must fail at the
entry boundary. Terminal normalization uses the actual shared serializer.

It also links a standalone executable with the actual entry/facade and real
JournalBackend/RootCapability/SaveOwner/record reader/journal, mocking only Lua.
A newly created `test-results/nsb-offline-<nonce>/store` is embedded at compile
time into that executable only; there is no runtime path override. It exercises
recovery, two typed updates, release/rebind, recovered A/B bytes, and lost consume
replies. Payload fixtures are generated and recovered bytes revalidated using the
actual Lua settings codec. Artifacts are retained, never deleted automatically.
The production bridge DLL retains only the fixed DEV root above.

`build/receipt.json` records test flags, source hashes, generated fixture hashes,
runtime/import audit and DLL fingerprint, and fails if tracked sources change
during build. It does not claim installed-runtime ABI execution, game-thread
discovery, lifecycle coverage, or live authorization. No deployment occurs.
