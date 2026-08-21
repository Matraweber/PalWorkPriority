# Research: the crash is a known UE4SS class, and the cure ships in our build

21 August 2026, evening. A pure research round, no code changed. Every claim
below was checked against a primary source tonight; local evidence was read
directly from disk.

## 1. The community knows this fault

**[Issue #346](https://github.com/UE4SS-RE/RE-UE4SS/issues/346)** is our exact
error string, `[Lua::Registry::get_function_ref] Ref was not function`, filed
against Palworld. Trigger there: two mods hooking the same function. Open, no
maintainer diagnosis, workarounds only.

**[Issue #1372](https://github.com/UE4SS-RE/RE-UE4SS/issues/1372)** is our
exact crash. A Palworld **dedicated server** under load:
EXCEPTION_ACCESS_VIOLATION reading `0xffffffffffffffff`, callstack a repeating
cycle `94b75e -> 94a960 -> 95642b -> 94a129 -> 94aeb3 -> 94a774 -> 94282c ->
95b121` — byte-for-byte the offsets recorded in [the-crash.md](the-crash.md)
from our own dumps. Their hooks were fully pcall-wrapped, like ours; the crash
is below the Lua layer; it correlates with load, not with any call site. Open,
unassigned. Their partial mitigation: **removing file I/O from hook callbacks**.

**[PR #1010](https://github.com/UE4SS-RE/RE-UE4SS/pull/1010)** (merged
24 Sep 2025) fixed one member of the class: a use-after-free when a hook is
unregistered during callback dispatch; registry indices are no longer deleted
mid-iteration.

**[PR #1128](https://github.com/UE4SS-RE/RE-UE4SS/pull/1128)** (merged
24 Dec 2025) is the decisive one. Author narknon, verbatim:

> "Lua is intended to be single threaded. LoopAsync was never safe even for
> purely Lua operations, let alone game thread."

It deprecates `ExecuteAsync` and `LoopAsync` outright and adds a game-thread
delayed-action system: `ExecuteInGameThreadWithDelay`,
`ExecuteInGameThreadAfterFrames`, `RetriggerableExecuteInGameThreadWithDelay`,
`MakeActionHandle`, `CancelDelayedAction`, pause/unpause/reset/query.

## 2. Our installed build already contains the cure

Installed: **UE4SS Experimental (Palworld), workshop package, version
`experimental-palworld-6`** (Info.json; DLL dated 10 Aug). A binary string
scan of that UE4SS.dll tonight found every PR #1128 function name present
(`ExecuteInGameThreadWithDelay` ×9, `RetriggerableExecuteInGameThreadWithDelay`
×4, `MakeActionHandle` ×3). The build therefore postdates Dec 2025 and carries
both #1128 and #1010. **No UE4SS update is needed; the safe API sits in the
DLL we already run.**

## 3. What actually corrupts, and why our addresses looked like text

`LoopAsync` runs its callback on a background thread. Registering game-thread
work from there (`ExecuteInGameThread` takes a Lua registry ref per call)
mutates the Lua state while the game thread may simultaneously be inside a
`RegisterHook` callback of the same state. Lua has no internal locking. The
registry tears; then either UE4SS notices a ref is no longer a function and
removes the engine-tick hook (our silent stop), or it dereferences garbage
(our crashes). Decisive detail: fault address `0x0000656c676774a5` from the
21:18 crash is the ASCII bytes of **"tggle"** — a fragment of "toggle", a
string this mod logs constantly. A pointer read landing inside Lua string
memory is state corruption, not a bad game object.

This explains tonight's stubborn observation that failures tracked
**activity, not time**: more passes means more cross-thread registry traffic
means more chances to tear.

## 4. How the mods that touch the same data survive

Read from disk tonight, all of them:

| mod | same data as us | scheduling discipline |
|---|---|---|
| **IntegratedStorage v2.3** ("ziyuan", by Sarfflow — the global base storage mod) | chests, via the game's own events: hooks `PalBaseCampModuleItemStorage:OnAvailableConcreteModel_ServerInternal` / `OnNotAvailable...` | **≤ 3 bootstrap scans, then latches forever**; one insurance rescan per ~10 min; a single 10s LoopAsync as driver; verbose logging off in release |
| InfiniteWeightInCamp | camp inventory | comment verbatim: *"Crash-safe: no LoopAsync; the timer chain re-arms only inside ExecuteInGameThread."* — an independent local author already knew |
| AutoAssignResearchLab | `GetCharacterHandleSlots` (the call we replaced) | zero loops; event-driven off `ClientRestart` and `OnRep_CurrentResearchId` |
| BreedingHelper | `TargetContainer` / `ItemSlotArray` (identical read path) | reads only while its window is open; avoids "game-thread callback churn" |
| PalBaseInfoGrid | roster via `WorkerDirector → CharacterContainer → SlotArray` (we adopted this) | reads when its window is open |

Common denominators: **events over polling; latch after bootstrap; work only
while someone is looking; near-zero async-thread activity; no file I/O in hot
callbacks.** PalWorkPriority is the only continuously polling mod in the
install, at 100ms/1s/10s cadences, with file writes inside the pass. The
outlier status is the exposure.

## 5. The fix plan this research supports

1. **Scheduling**: replace both LoopAsync loops and the ExecuteWithDelay
   chains with the delayed-action API already in the DLL
   (`RetriggerableExecuteInGameThreadWithDelay`, or chains re-armed on the
   game thread). Probe `type(ExecuteInGameThreadWithDelay) == "function"` at
   startup; fall back to the InfiniteWeightInCamp pattern if absent.
2. **Chest tracking**: adopt IntegratedStorage's shape — hook
   OnAvailable/OnNotAvailableConcreteModel, bounded bootstrap, latch, rare
   insurance scan. The per-pass sweep disappears; stock becomes an
   event-maintained table.
3. **File I/O out of callbacks** (the #1372 mitigation): trace marks off by
   default; log lines buffered, flushed by a slow game-thread timer.
4. **Keep** tonight's proven wins: roster by property, no stored wrappers,
   one pass in flight, panel-open stock refresh.

## 6. Testing without a human in the loop

- **PalServer is already on disk** with a world and DedicatedServerName
  configured, and it uses the same native mod system
  (`Mods/PalModSettings.ini`) as the client.
- Install = mirror the client: copy `Mods/NativeMods/UE4SS` into
  `PalServer/Mods/NativeMods/`, set `bGlobalEnableMod=True` plus ActiveModList
  entries for UE4SSExperimentalPW and PalWorkPriority only — a 2-mod
  environment against the client's 29. The
  [pwmodding server guide](https://pwmodding.wiki/docs/users/ue4ss/installation-server)
  and the package's own Info.json (`"IsServer": true` install rule) both
  confirm server-side UE4SS.
- The server **boots straight into the world**: no title screen, no clicking,
  no person. Issue #1372 is proof our exact crash class reproduces
  server-side. remote.py / stress.py / watch.py need only a path and
  process-name switch.
- The client is then only needed for panel visuals, which hot-reload.
- Searched for a client skip-title / auto-load mod: none exists on Nexus
  (verified tonight); the server rig makes one unnecessary.

## 7. What this retires from our own theory list

- "LoopAsync fixed it" and "fresh vs named closure": both irrelevant next to
  the real mechanism, and measured so (identical failure thresholds).
- The chest sweep and camp_pals as causes: they were the most frequent
  victims. The stale-wrapper purge (186 vs 25 passes) still stands on its own.
