# Isolated async-save prototype — September 29, 2026

## Result and boundary

Historical V1 editor-only result below. The subsequent
[V2 async readback and RAM trial](async-save-ram-2026-09-29.md) passed eight
synthetic write/readbacks and two read-only recoveries across a server restart.
That separate test is disabled; production persistence remains unchanged.

Built and exercised in UE 5.1.1, reloaded in a fresh editor process, cooked for
Windows and packaged separately. **Not installed in Palworld or RAM. Production
persistence, acknowledgements and player data are unchanged. This is feasibility
evidence, not a measured fix for the server stall.**

Package: `test-results/save-scratch/PalWorkPrioritySaveScratch.pak`.
SHA256: `a0238c366e68b7e37dbc336edc8e831107c42b0f728c05c75d02da1e83fd2c9e`.
Exactly four files: BP_ScratchRecord and BP_ScratchBridge (.uasset/.uexp).
Printable cooked /Script imports contain Engine and CoreUObject only; this is
not proof that the actual headless server mounts the package. No custom runtime
DLL, Lua worker, ModActor or production asset is included.

## Implementation

`unreal/PalWidgetGen/Private/BuildSavePrototypeCommandlet.{h,cpp}` generates a
SaveGame Blueprint and Actor Blueprint using stock engine nodes. The actor owns
ActiveSave and invokes UAsyncActionHandleSaveGame. Busy rejects overlapping
submissions. Done/Success/CompletedGeneration expose completion on the game
thread. Engine GameInstance registration owns the pending action.

Only fixed `PWP_SaveScratch_v1_A` and `_B` slots are writable; no caller-supplied
path. They currently exist only under the editor kit's Saved/SaveGames. Fixtures
use tiny synthetic strings containing X, never actual priorities.

`experiments/save_scratch.lua` is outside deployed Scripts. It is a pure
queue/recovery model, **not an integrated UE4SS adapter**. It:

- Copies strings/numbers, bounds payload/generation, keeps one operation in
  flight, coalesces later values and rotates slots after verified completion.
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
storage for multiple concurrent owners.

Local UE5.1 sources confirm serialization into copied bytes before SaveGameAsync,
default-platform file writing on the task pipe, and completion on the core
ticker/game thread. The pipe explicitly does not guarantee ordering, so our
one-operation rule remains necessary. Server implementation still needs proof.

## Evidence

Final reproducible receipts: `test-results/save-scratch/`.

| Check | Result |
|---|---|
| Native write/readback | Passed; game-thread completion verified |
| Actual Blueprint event | Passed; overlapping submission rejected |
| Forced GC while pending | Passed; original generation completed |
| Null-record submission | Passed; failure reported and Busy cleared |
| Fresh process | Both native A and Blueprint B payload/generation reload exactly |
| Cook/package | Passed; four scratch files, no production files |
| Lua | 51 production modules compile; all 78 regression scripts pass |

Final repeat: native enqueue **0.082ms**, completion **36.759ms**; Blueprint enqueue
**0.092ms**, completion including forced GC **16.288ms**. An earlier successful
Blueprint run measured **11.428ms** enqueue and **28.280ms** completion including
GC. Do not hide the first-run spike or claim all enqueues are sub-millisecond.
Completion is measured before synchronous readback. Tiny-payload editor samples
are not representative server benchmarks or independent frame measurements.

Null-record failure is engine rejection, **not** disk-full/permission/interrupted
write testing. Queue regressions inject unsuccessful completion, corrupt readback,
read exceptions, nil/error, explicit unreadable, both corrupt slots, stale ticket,
dirty reset, cross-incarnation recovery and failed re-recovery. These simulations
do not replace physical filesystem fault tests.

Final editor runs: 0 errors, 46 kit startup warnings. Earlier debugging fixed the
wrong SelectString helper class, double fixture-world initialization, missing core
ticker pumping and editor Actor script execution being disabled. Failed runs are
retained in dated logs. The custom editor-node warning was removed by using the
stock async node. None of these failures happened in Palworld.

Independent review caught recovery identity, dirty-reset, re-recovery and
ambiguous-read defects. Each now has a regression; final bounded review cleared
the corrected scratch logic. It did not approve production adoption.

## Repeat

```powershell
python tools/test_lua.py
python tools/build_save_scratch.py --engine 'D:\Program Files (x86)\Epic Games\UE_5.1' --kit 'C:\Users\matra\Desktop\PalworldModdingKit'
```

The kit must already include PalWidgetGen. Compiler family 14.38.33130 matches the
existing workflow. Existing assets are verified, not silently regenerated;
generator changes need an explicitly backed-up rebuild. `--skip-build` requires
an already compiled matching commandlet. The script never installs the package.

## Remaining acceptance

1. Add a dev-only UE4SS driver: fresh object resolution, validated world and
   GameInstance, one owned bridge, duplicate-load rejection, game-thread polling.
   No collectable wrappers retained across callbacks.
2. Implement nonblocking readback or separately measure/bound it. The fixture's
   synchronous LoadGameFromSlot could itself stall on RAM. Moving writes alone
   does not prove total persistence cost is removed.
3. Verify mounting and APIs on the actual headless runtime, then run scratch
   trials with representative/max-size payloads, matched frame captures and aged
   sessions. Verify runtime/package fingerprints independently.
4. Test slow/failing storage and interruption/restart boundaries. Preserve the
   prior valid generation and never acknowledge unfinished saves as durable.
   An engine success callback does not establish physical power-loss durability.
5. Design actual scope ownership, migration/backups, bounded retries, ACK states,
   role transitions and forced-quit handling before replacing store/caps writers.

Installed client datafile.lua remains
`E87094DBB64DC7858E91301832DC3DE4B7824ABFE7BC8253AAA40AD4B381FEF1`, matching the
pre-experiment checked writer. No game commands, restart or server upload occurred
during this prototype build.
