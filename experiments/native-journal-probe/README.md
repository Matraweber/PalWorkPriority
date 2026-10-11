# Isolated native journal probe

## Generation/thread contract (version 2)

Both bridge-review findings are addressed in the shared native dispatcher (`dispatch.hpp`) used by `entry.cpp`. The exported function now requires **exactly two integers: command, expected ticket**. The old one-integer driver is incompatible. All phase-changing, backend and IO actions follow native ticket/thread validation; Lua timing/thread checks remain secondary diagnostics.

| Command | Required ticket | Thread and action |
| --- | --- | --- |
| 0 | 0 | Bind the first calling native thread as control thread; subsequent calls must be on that same thread. No backend action. |
| 1 | 1 | Control thread only; initial admission, attempted at most once. |
| 5 | Exact next ticket (2 or 3) | Control thread only; previous ticket must be consumed and no worker running. Each admission is attempted at most once, even after failure/exception. |
| 2 | Exact current admitted ticket | Any non-control thread only; reject before touching backend on wrong thread, wrong ticket, consumed ticket, or duplicate start. Capture the exact operation under the gate, then release the gate and run that captured object. |
| 3 | Exact current ticket | Control thread only; inspect while no worker is running and result has not been consumed. Repeated inspection is allowed. |
| 4 | Exact current ticket | Control thread only; consume only a successful certain result, once. |
| 6 | 3 | Control thread only; ticket 3 must be consumed, no worker running. Retire/release at most once; permanently close dispatcher even when release fails. |

The real entry obtains the caller ID with native `GetCurrentThreadId`; Lua cannot supply or spoof that ID through this export. `(0,0)` is invoked by the scheduled game-thread entry. This **binds that caller**, rather than independently discovering Unreal's game thread; correctness of the initial scheduler route remains a live-runtime assumption. Worker restriction means "different from the bound control thread," not proof of a particular UE4SS worker identity.

Every Lua worker/completion/delayed-admission closure captures its ticket at construction and passes it unchanged. Duplicate delayed admission callbacks also check that captured ticket against the expected next Lua phase. A late phase-1 worker cannot resolve phase 2. Stale/wrong-thread native calls return status 0 without touching the backend. Invalid arity/type/range returns no values. Existing five-integer result layout (status, caller thread, QPC start, QPC end, frequency) is unchanged. Exceptions or missing native replies remain uncertain and stop the driver; no automatic retry, consumption or release follows. A timeout does not cancel already-running IO.

This is still an isolated fixed-root synthetic probe, not a production storage or migration grant. `SaveOperation` retains its own one-shot execution protection as an additional layer. Its owner and copied inputs are kept alive by the captured shared operation.

## Context diagnostic addition

After consuming `PWP_JOURNAL_PROBE <nonce>` and waiting 90 seconds, the delayed game-thread entry now runs exactly one context diagnostic **before loading or admitting native work**:

1. Load the standalone context-pair module.
2. Call `UEHelpers.GetEngine()` at that time and `UEHelpers.GetGameplayStatics(true)` with forced CDO cache invalidation.
3. Call `Pair.read(engine, get_state, get_instance)` with callback-local closures invoking `cdo:GetGameState(ctx)` and `cdo:GetGameInstance(ctx)`.
4. Log a fixed, sorted whitelist of 19 scalar fields. Each string is capped at 512 bytes and control/delimiter characters are sanitized; the joined field text is capped at 8,192 bytes. Every context line explicitly states `diagnostic_only=true storage_grant=false`.

The driver's own code retains no engine/CDO/getter wrappers beyond this synchronous diagnostic call and passes none to a worker. UEHelpers itself implements its own engine cache; calling GetEngine afresh is not an engine-cache invalidation or independent active-engine proof. The inspected helper supports ForceInvalidateCache for GetGameplayStatics.

A returned context disagreement/unavailability is logged and does not veto the synthetic fixed-root journal experiment. It cannot choose or change a destination. Missing/invalid CDO supplies unavailable getters to Pair. Exceptions escaping helper/module/Pair calls, malformed output, non-scalar whitelisted values, or output claiming a grant stop the run before native loading/admission. Engine exceptions contained by Pair become its normal negative diagnostic results, which are logged. No active-provider authorization or actual settings/migration path is connected.

## Files required for later manual installation

Preserve these paths relative to the isolated helper directory containing `main.lua`:

| Destination | Repository source |
| --- | --- |
| `main.lua` | `experiments/native-journal-probe/main.lua` |
| `pwp_journal_probe.dll` | separately checked native build output |
| `experiments/save_context_pair_probe.lua` | `experiments/save_context_pair_probe.lua` |
| `experiments/save_headless_identity_probe.lua` | `experiments/save_headless_identity_probe.lua` |
| `experiments/save_world_identity_probe.lua` | `experiments/save_world_identity_probe.lua` |
| `experiments/save_identity_probe.lua` | `experiments/save_identity_probe.lua` |

`context-dependencies.sha256` fingerprints the five Lua installation files, with destination-relative paths. UEHelpers remains the pinned runtime dependency. No collector is embedded or duplicated in this directory. The version-2 `check_link.py` build receipt records native source, driver, collector and regression-test fingerprints. Do not mix the rebuilt DLL with the old one-argument driver. No helper/runtime loading, game installation or deployment is performed by the build checks.

## Offline checks

`python tools/test_lua.py tests/test_native_journal_driver.lua tests/test_save_context_pair_probe.lua`

The driver test mocks helper/module boundaries, verifies forced CDO invalidation and colon/context forwarding, and asserts no early or worker-thread engine queries, no wrapper retention, sorted/bounded output, malformed/no-arm denial and pre-admission stop on thrown reads. Valid negative Pair results still run all three synthetic phases. Ticket sequences, late phase-1 execution after phase-2 admission, duplicate worker and delayed-admission callbacks, wrong-thread admission/completion, and zero simulated IO on wrong-thread execution are covered. Uncertainty, timeout and invalid-native-result cases remain covered. The standalone Pair suite separately executes all three real collectors against 88 strict engine-mock cases.

`python experiments/native-journal-probe/check_link.py` compiles and links Release `/MD` against the pinned headers/runtime export list, enforces exactly the original six LuaMadeSimple imports, checks the sole intended export and absence of a second/raw Lua dependency, then records hashes. It also builds and **runs only a standalone fake-backend C++ regression executable**, using the exact dispatcher header compiled into the helper. That executable checks zero backend actions on stale/wrong-thread dispatch, 16 concurrent worker duplicates causing one simulated IO, three-generation sequencing, failed/throwing admissions, uncertainty, and release failure. It does not load the helper/UE4SS, claim a real owner, or call the real journal. Journal/owner integration testing is separate. Offline checks do not establish installed-runtime ABI, game-thread bootstrap, actual IO ordering or travel coverage.
