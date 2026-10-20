---
date: 2026-10-04
tags: [async-save, research]
status: history
---
# Async save: routes tried and rejected (Blueprint trial, 2026-09-29 to 2026-10-04)

Related: [async-enablement-2026-10-04](async-enablement-2026-10-04.md) · [async-save-route-research-2026-10-04](async-save-route-research-2026-10-04.md) · [async-save-world-transition-2026-10-04](async-save-world-transition-2026-10-04.md)

Status 2026-10-20: history. Async stays off; 0.5.0 ships the synchronous writer
unless optional gate G2b closes first ([RELEASE-0.5.0.md](RELEASE-0.5.0.md)
G2/G2b). This note replaces twelve trial notes (deleted 2026-10-20, git history
keeps them). Each section keeps the numbers, the dead ends with their evidence
and the traps. Newest first.

**Where it ended.** Unreal's async SaveGame worked on the server, but no route
gave a reliable identity for the save destination, and completion times had a
long tail. The research moved to a native writer loaded through UE4SS's public
Lua module interface ([DECISIONS](DECISIONS.md) "Saving and settings",
2026-10-04; [async-save-route-research-2026-10-04.md](async-save-route-research-2026-10-04.md)).
The identity question was answered by the GameState directory field
([async-save-world-transition-2026-10-04.md](async-save-world-transition-2026-10-04.md)).
The pure Lua queue, session controller and scoped transport contract that
survive from this period are in
[async-save-session-2026-10-03.md](async-save-session-2026-10-03.md).

Common to every trial: separate diagnostic mods and paks, synthetic payloads
only, production persistence unchanged, every control left DISABLED, production
writer hash `e87094db...fef1` unchanged where checked. Times are UTC unless
marked local. "Engine completion" figures are frame-quantized elapsed intervals,
not game-thread CPU time or frame durations.

## Save-process map: empty (2026-10-03, async-save-process)

Rejected: reading `SaveGameManager.WorldSaveProcess.ProcessMap`
(`FPalAsyncSaveProcessParallel.ProcessMap`, `TMap<FString,FPalAsyncSaveProcess>`,
entries with `State`, `bPreDelegateSuccess`, `SaveObject`) to find the active
destination.

- Probe `experiments/save_process_probe.lua`, driver
  `experiments/ue4ss-save-process/`. Fresh engine/viewport/world/game
  instance/manager resolution per sample, map size read first, more than 16
  entries refused, never reads `SaveObject`, 1 s polling, stop at 240 s or 240
  samples, a read over 10 ms stops further polling.
- TMap API used as documented: `#map`, `ForEach(key,value)` with `:get()` and
  `true` to stop; matching `LuaTMap.cpp` for UE4SS 2281fa31 saved under
  `test-results/save-process-20261003/`. Trap: the native iterator scans sparse
  indices up to GetMaxIndex, which Lua cannot see, so the entry cap bounds copied
  data, not native scan time.
- **Result:** PID 40888, 19:56:37-20:00:37, **234 samples, all maps empty**,
  including loaded MainWorld5 from 19:57:14, while local `Level.sav` metadata
  advanced (including 19:58:29). The value getter was never exercised in game.
- Conclusion recorded then: do not repeat this polling without new evidence; a
  denser poll or empty map cannot prove anything. The next step was the
  GameState field.

## Destination hooks: never fired (2026-10-03, async-save-destination)

Rejected: observing the game's own save-completion callbacks as destination proof.

- SDK leads (`PalworldModdingKit/Source/Pal/`): `PalSaveGameManager.h` declares
  `OnFinishedWorldAsyncSaveGameInternal(SlotName, UserIndex, bSuccess,
  WorldName, Timestamp)` and `OnFinishedWorldAsyncSaveGamePreInternal` (same
  arguments, Boolean return that must never be overridden). Bodies are stubs.
  `LoadedWorldSaveData` (transient `UPalWorldSaveGame*`) holds world contents
  and a display name but **no directory GUID**; `PalWorldBaseInfoData.DirectoryPath`
  belongs to listed metadata, not the active save.
- Classifier `experiments/save_destination_probe.lua` (copied scalar arguments
  only, expected `<prefix>/<32-hex-ID>/Level[.sav]` shape, path privacy).
- **Single hook** (`experiments/ue4ss-save-destination/`):
  `OnFinishedWorldAsyncSaveGameInternal` registered 19:12:39; `Level.sav` grew
  156,616 → 156,691 bytes (19:12:11 → 19:15:01); `TIMEOUT no callback observed`
  at 19:17:39. **0 callbacks in 5 minutes.**
- **Paired hooks** (`experiments/ue4ss-save-destination-pair/`), process 43784:
  `OnFinishedWorldAsyncSaveGamePreInternal` plus
  `PalStaticLogCollector:OnEndedWorldAutoSave`. Final
  `TIMEOUT destination=0 notification=4` at 19:39:42. **0 destination callbacks
  in the 7-minute trial while `Level.sav` changed.** `OnEndedWorldAutoSave`
  fired about **every 30 s** (19:34:04, 19:34:34, 19:35:04, 19:35:34; buffer
  capped at four) but is success-only and **carries no destination**.
- Traps: hook registration does not prove the UFunction is called through the
  intercepted route; a timeout does not prove no save happened; never call these
  functions or force an autosave to manufacture evidence; a retiring world's
  completion can arrive after a role change, so even a fired callback would need
  session correlation. Evidence: `test-results/save-destination-20261003/`,
  `test-results/save-destination-pair-20261003/`.

## Authority-side identity: AutoSave name empty, selected ID before load (2026-10-03, async-save-authority)

Rejected: `AutoSaveWorldDefaultName` as a corroborating GUID, and the selected
directory field as a load signal. Reused the identity probe (next section).

- Two local host boots, one full restart apart (the macro saw process 14604
  exit and 16044 start):
  `SelectedWorldSaveDirectoryName` = 31141b9948fe8b9a8b4cc399974dddf1,
  `bIsLoadedWorldSaveData=true`, **`AutoSaveWorldDefaultName` empty**. The
  selected ID matched exactly one world directory with `Level.sav`, whose mtime
  advanced (correlation only).
- **The selected ID is visible on Title before load:** 19:21:22 local, Title,
  loaded=false, ID already set; MainWorld5 loaded=true at 19:21:26. A
  format-valid field is not proof that its world has loaded.
- Return to the server (fresh process 42500): both identity properties empty,
  loaded=false. AutoSave name was therefore **empty on host and client**.
- Collector trap caught in review: a startup session-0 `PWP_READY authority` line
  must not count as gameplay authority; only positive-session readiness after
  the fresh boot's MainWorld5 boundary counts. Evidence:
  `test-results/save-identity-authority-20261003/`.
- The same-process follow-up (selected ID survives joining a server) is in
  [async-save-world-transition-2026-10-04.md](async-save-world-transition-2026-10-04.md).

## Client identity probe and read classification (2026-10-03, async-save-identity)

Rejected: the client route as a source of the server's save identity, and any
"missing" classification derived from a failed read.

- `experiments/save_read.lua`: schema-labelled snapshot; unknown schema, failed
  field reads, null loads and foreign scope are **unreadable**; malformed
  same-scope records are invalid; deliberately **no missing** outcome from V6's
  boolean/native-null results. A failed read fed to recovery keeps fresh
  defaults prohibited (zero writes).
- UE 5.1 source trap: GameplayStatics returns false when the save system is
  absent; `FGenericSaveGameSystem` maps negative FileSize to `DoesNotExist`, and
  Windows FileSize collapses failed metadata queries to -1. **A failed FileSize
  therefore reads as -1 / DoesNotExist**, so a failed existence check cannot
  authorize replacement. (Detail: [save-initialization-review-2026-10-04.md](save-initialization-review-2026-10-04.md).)
- `experiments/save_identity_probe.lua` + `experiments/ue4ss-save-identity/`:
  reads SelectedWorldSaveDirectoryName, AutoSaveWorldDefaultName,
  bIsLoadedWorldSaveData fresh per callback, never calls getters (kit bodies are
  stubs). 13:06-13:07 local on the server client: Splash, Login, Title and
  MainWorld5 all gave **both strings empty, loaded=false** (successful reads,
  not failures). Evidence: `test-results/save-identity-20261003/`.

## V6 scoped ownership (2026-10-03, async-save-scoped)

Superseded by the native writer; contract kept in
[async-save-session-2026-10-03.md](async-save-session-2026-10-03.md).

- `BindStorage(world GUID, guild GUID, priorities|limits)`: two nonzero 32-digit
  GUIDs, case canonicalized, same slot names as `experiments/save_scope.lua`,
  never rebindable. `BindOwner(epoch)`: a newer epoch can claim only after
  pending IO and unconsumed results drain; tickets stay monotonic across
  handovers; same owner text in another epoch gets no access to old callbacks.
- Native matrix: all 16 A/B slots (2 worlds × 2 guilds × 2 streams) written
  before any readback; fresh-process readback; one fixture failure came from a
  collected raw class pointer in the oracle (fixed by owning the class through
  GC). Evidence: `test-results/save-scratch-v6/`.
- Live (12:37-12:38 local, `experiments/ue4ss-save-scoped-v6/`,
  `test-results/save-scoped-live-20261003/`): 65,536 bytes exact; undrained
  handover rejected; epoch 2 claimed; stale epoch-1 request/retire/ack rejected;
  read 102 held unconsumed from splash into MainWorld5, then consumed. 88 Lua
  scripts pass.
- Limits: per-object binding is not a process-wide singleton; live travel held
  a completed result, not IO in flight.

## V5 native mailbox (2026-10-03, async-save-mailbox)

- `BindOwner(scope, owner)` is permanent per object; `ReserveRequest` snapshots
  record/ticket/kind/slot and reserves Busy **before returning** (atomic
  reservation came from review); busy IO or an unconsumed terminal result block
  dispatch; `ConsumeResult` needs exact scope/owner/ticket/kind/slot and is
  idempotent for the last consumed identity only. Timeouts never unlock unknown IO.
- Trap: on fresh asset reload, result-node defaults reset; fixed with linked
  `MakeLiteralBool` nodes (failed asset kept under
  `test-results/save-scratch-v5/failed-result-default/`).
- Live 10:05-10:06 (`experiments/ue4ss-save-mailbox-v5/`,
  `test-results/save-mailbox-live-20261003/`): 65,536-byte write/readback,
  guards pass, an unconsumed read survives MainWorld5 travel, old ack leaves it
  intact. Pak SHA256 `54771da7...01e5bb`. 87 Lua scripts pass.
- Limits: immutable owner cannot be retired or transferred; no process-wide
  uniqueness; must not advertise `PWP-SCOPED-DEV-1`.

## V4 rooted lifetime (2026-10-03, async-save-lifetime)

Why it existed: **a world-owned Actor bridge can vanish with its world while IO
is in flight.** V4 moved the bridge to a rooted transient UObject that keeps its
async action through a reflected property (retain, bind, then activate).

- Native fixtures tear down the owning world/game instance while work is
  pending and GC again during readback; weak references prove collection while
  the pending action survives. Two rejected builds: an exposed proxy pin that
  depended on editor metadata (failed fresh reload) and a timing-dependent GC
  checkpoint. Pak SHA256 `a84890b1...cf5e75`, `test-results/save-scratch-v4/`.
- **Trap 1, global `GetEngine` missing:** the first live attempt called a
  nonexistent global `GetEngine`; use `require('UEHelpers').GetEngine()`.
- **Trap 2, one-string `StaticFindObject` rejects package-only names:** the
  second attempt failed on `/Engine/Transient`. The driver now takes the engine's
  outer and requires exactly `Package /Engine/Transient` (UE 5.1
  `LaunchEngineLoop.cpp`, UE4SS `GetOuter`).
- Trap 3: the third attempt "passed" on splash-to-login travel; the check now
  requires `MainWorld_5/PL_MainWorld5`.
- Final live run (process 3464, 09:25-09:26, `experiments/ue4ss-save-lifetime-v4/`,
  `test-results/save-lifetime-live-20261003/`): Lua session/transport suites
  pass inside UE4SS, 65,536-byte write/readback exact, root/record/ticket survive
  into PL_MainWorld5. 86 Lua scripts pass. Clock fields deliberately unmeasured.

## V3 on the populated server: the latency tail (2026-10-02, async-save-events-warm)

The number that ended Unreal's AsyncSaveGameToSlot as a stall fix. Trial
`warm-events-20261002-162701`, 24 records (32/4,096/32,768/65,536 bytes, six
each), V3 pak `00fd37d0...dd61f`.

| Measurement | Result |
|---|---:|
| Engine save/read completion median | **69.574 ms** |
| Maximum | **1,505.007 ms** |
| Operations above 500 ms | **4 of 24** |
| Slow samples | 1 = 999.088, 8 = 1,335.763, 16 = 1,505.007, 19 = 203.230, 24 = 669.597 ms |
| Sample 16 async save stage | 1,471.747 ms |
| Bridge lookups | 553 ms / 24 (about 23 ms each) |
| Enqueue / completion-hook totals | 4 ms / 8 ms |

READWARM after a controlled restart recovered generations 23/24 exactly. Client
PresentMon over 299.979 s: no present or display interval above 50 ms (no
mod-absent control, so no FPS claim). Evidence:
`test-results/save-scratch-events-warm-20261002/` (`check_trial.py` there).

## V3 completion event replaces polling (2026-10-01, async-save-events)

- The generated V3 bridge calls a public zero-argument UFunction
  `ScratchCompleted` after publishing terminal state (success and failure); the
  Lua receiver copies scalar data into an inbox, so waiting callbacks resolve no
  UObject. 83 Lua scripts pass. `experiments/ue4ss-save-scratch-v3/`.
- Live `event-20261001-174304`: three FAILURE boots (32-byte seed, explicit
  null-save failure, seed reread exactly), write/read totals 127.673 / 130.892 /
  139.586 ms. Trap: the armed control **replayed on two later unexplained boots**
  (Oct 2 04:32 and 08:12). READFAIL recovered the seed in 33.797 ms engine time.
- Limits: null input is not a storage fault; stopping observation does not
  cancel native IO or unhook the bridge; timeouts must stay unknown outcomes.
  Evidence: `test-results/save-scratch-v3/`, `test-results/save-scratch-events-20261001/`.

## Idle lookups removed (2026-10-01, async-save-idle)

- Driver decides idle/baseline/spacing in plain Lua before resolving its bridge.
  Trial `idle-20261001-154402`: 49 bridge resolutions (24 requests + 25 polls),
  **1,255 ms** resolution cost (was 7,999 ms), callback work 1,497 ms (was
  8,106 ms). Harness overhead only.
- Engine completion median 71.161 ms, **max 703.270 ms** (sample 5, 32 bytes,
  save stage 669.948 ms): warmup did not remove the tail. READWARM recovered
  generations 23/24. 81 Lua scripts pass; the interruptions suite has 12
  persisted fake-storage scenarios. Evidence: `test-results/save-scratch-idle-20261001/`.

## V2 warm trial: name polling is too expensive (2026-10-01, async-save-warm)

- Trial `ram-20261001-141758`, three baseline/active pairs, 24 write/readbacks
  exact. Harness: `experiments/ue4ss-save-scratch/Scripts/main.lua` WARM mode,
  `metrics.lua`, 33 ms gap observer, 500 ms operation callback.
- **StaticFindObject name-based bridge resolution cost 7,999 ms (about 8 s) per
  trial**; the polling harness cannot be a production design.
- Engine completion median 68.801 ms, range 65.683-204.240 ms; inclusive Lua
  callback mean 23.607 baseline vs 24.790 ms active (includes lookups and
  checksum work, not engine save cost).
- PresentMon (299.965 s): displayed-change p99 16.7275 ms, max 33.3658 ms, none
  above 50 ms; fixed camera, no clock mapping to server events.
- Trap: GPortal's web file manager showed "Directory is empty"
  (`AxiosError: Network Error`) while direct FTP listed every file; FTP data
  connections timed out intermittently, so uncertain uploads were read back
  before retry. Evidence: `test-results/save-scratch-warm-20261001/`.

## V2 on the server (2026-09-29, async-save-ram)

- First run of stock `AsyncSaveGameToSlot` + `AsyncLoadGameFromSlot` on the
  server (GPortal 8684515, UE4SS v3.0.1 Beta ba2efd55, trial `ram-20260929-2058`,
  pak `PalWorkPrioritySaveScratchV2.pak` SHA256 `094c0ed6...b757`, slots
  `PWP_SaveScratch_v1_A/B`). Eight synthetic writes read back exactly; a second
  restart recovered A/B read-only.
- Totals were 66-91 ms except **sample 3: the first 32 KiB (32,768-byte) async
  save took 1,123.722 ms (save 232.613 + read 891.110)**; the same size later
  took 66 ms. Never explained; it set off the later warm trials.
- Lua enqueue printed 0-1 ms at unmeasured `os.clock` resolution: a printed
  zero is not zero cost. Evidence: `test-results/save-scratch-v2/`.
- The V1 editor prototype before it and the queue it tested are in
  [async-save-session-2026-10-03.md](async-save-session-2026-10-03.md).
