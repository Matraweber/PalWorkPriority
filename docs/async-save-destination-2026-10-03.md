# Active save destination investigation — October 3, 2026

Production persistence is unchanged. The initial investigation made no native
calls; the subsequent checked passive trial is recorded below.

## Local SDK evidence

Kit: `C:/Users/matra/Desktop/PalworldModdingKit/Source/Pal/`.

- `Public/PalSaveGameManager.h`: `LoadedWorldSaveData` is a transient
  `UPalWorldSaveGame*`, separate from the loaded flag and autosave name.
- `Public/PalWorldSaveGame.h` / `PalWorldSaveData.h`: declared loaded data
  contains world contents and a display name, but no persistent directory GUID.
  Display-name agreement cannot distinguish copies or identically named worlds.
- `Public/PalWorldBaseInfoData.h`: `DirectoryPath` belongs to listed world
  metadata. Listing an existing directory does not prove it is the active save.
- `Public/PalSaveGameManager.h` declares
  `OnFinishedWorldAsyncSaveGameInternal(SlotName, UserIndex, bSuccess, WorldName,
  Timestamp)`. This is a candidate passive observation point for the game's own
  completed save destination. `Private/PalSaveGameManager.cpp` is a stub, so it
  proves neither runtime invocation nor argument semantics.

The existing global GameMode authority fallback is not sufficient proof that a
save callback belongs to the current world. A retiring world's completion may
arrive after a role/session transition. Do not call the completion function to
generate evidence and do not force an autosave for this investigation.

## Implemented preparation

`experiments/save_destination_probe.lua` classifies copied scalar completion
arguments only. It makes no native calls, logs no raw path/display name and
returns `verified=false` with no writable storage/key/readiness fields.
It recognizes the hypothesized relative `<prefix>/<32-hex-ID>/Level[.sav]`
shape, rejects traversal/absolute/control/oversized inputs, preserves failed
versus unknown completion, and reports conflicting GUID candidates separately.
This grammar still needs observation against the installed runtime.

All94 Lua regression scripts pass; 51 production modules compile with Lua5.4.
New cases cover failed/unknown completions, malformed paths, conflicting IDs,
privacy-preserving output and objects whose conversion/access would throw.
Evidence: `test-results/save-transition-20261003/lua-destination-observation.log`.
Independent review found no concrete issue; the focused suite and supplemental
boundary/privacy checks pass. Runtime slot grammar and callback behavior remain
unverified. All five installed diagnostic arms remain disabled.

## Next native acceptance

### Live observation

Normal restart created process39992. UE4SS logged native hook registration
(15,16) at19:12:39UTC. MainWorld5 was loaded at19:13:16; the macro reported
world ready and the stand displayed priorities afterward. No callback had
arrived when the local `Level.sav` metadata changed from156616 bytes at
19:12:11UTC to156691 bytes at19:15:01UTC. This establishes a file change during
the observation window, not which internal C++ save path performed it. Hook
registration does not establish that this UFunction is invoked through the
intercepted route. Do not promote this route to a working storage-proof provider.

Final result: at19:17:39UTC the driver reported `TIMEOUT no callback observed
timer_cancelled=true`. Capture verified source/installed hashes, unchanged
production Lua and disabled arm. No destination candidate or verified identity
was obtained. Independent review confirmed the metadata evidence and its limits.
The game remains in singleplayer with the Monitoring Stand open.

Next passive candidates are `OnFinishedWorldAsyncSaveGamePreInternal` (same
declared destination arguments; Boolean return must never be overridden) and
`PalStaticLogCollector:OnEndedWorldAutoSave` (success-only corroboration, not a
destination). Both are declarations backed by stubs; native invocation and
interception remain unproven. Do not treat this timeout as proof that no save
occurred, nor call these functions to manufacture a result.

### Paired follow-up

`experiments/ue4ss-save-destination-pair/Scripts/main.lua` observes those two
callbacks independently. Each has a four-event cap so notification traffic
cannot crowd out a destination event. Registration failure disables only that
callback; both failures stop the trial. The probe logs each source separately,
stops after both have been observed or at420seconds, and never changes the
Boolean return of the PreInternal function. Success-only notifications cannot
be treated as destination evidence. Current timer identity is still not
correlation with the originating save/session. This separate installation
preserves the original single-hook source and captured evidence.

All96 regression scripts pass. Independent review covered separate registration,
nil return values, per-source caps, partial timeout, privacy, sink failures and
events arriving during logging. No blocker found in that bounded review.
Checked installation copied three Lua files into `PWPAsyncSaveDestinationPair`,
verified hashes/unchanged production and armed last; normal singleplayer restart
started. Evidence: `test-results/save-destination-pair-20261003/`.

Live partial result: process43784 reached MainWorld5 at19:33:19UTC. Both hooks
registered. The notification hook emitted successful events at roughly30-second
intervals, while the destination hook had not fired. `Level.sav` changed during
this interval (metadata snapshots retained). This is positive evidence that
autosave notifications are visible through the installed hook mechanism; it is
not destination identity and does not establish which internal C++ path bypasses
the expected destination callback. The notification buffer stops at four events
by design while the destination observation continues until the overall deadline.

Final paired result: successful notifications at19:34:04,19:34:34,19:35:04 and
19:35:34UTC; zero destination callbacks. At19:39:42UTC the driver reported
`TIMEOUT destination=0 notification=4 timer_cancelled=true`. The seven-minute
trial therefore completed by timeout, not by both-source acceptance. Capture
verified unchanged production, source/install hash agreement and disabled arm.
The success-only route is observed on this local host; destination identity,
session correlation and dedicated-server behavior remain unverified. Do not
spend another identical restart repeating either silent destination hook without
new evidence about its invocation path.

Additional SDK lead (not read in-game): `PalSaveGameManager.WorldSaveProcess`
contains `FPalAsyncSaveProcessParallel.ProcessMap`, declared as
`TMap<FString,FPalAsyncSaveProcess>`. Entries expose `State`,
`bPreDelegateSuccess` and `SaveObject`. String-key meaning and entry lifetime
are unknown; no claim that keys are slot paths. A bounded property-only probe
could inspect sanitized keys/state without invoking save methods. The collector
also has `targetLogManager` pointing to a `PalWorldSubsystem`, a possible route
for world correlation that needs independent runtime validation.

Pre-install driver review found shutdown reporting could throw again when its
log sink failed. Terminal reporting is now protected. All95 regression scripts
pass, including open/write/close/console failures, cancellation exceptions,
registration/timer failure, bounded buffering and inert callbacks after stop.
Independent re-review found no remaining blocker in the bounded driver.
Checked local installation copied exactly three Lua files, verified hashes and
unchanged production, then armed the probe and started the normal singleplayer
restart. Evidence is under `test-results/save-destination-20261003/`.

The original `experiments/ue4ss-save-destination/Scripts/main.lua` driver
consumes its arm before registration, observes the declared
callback at entry without overriding return values, and buffers at most four
classified scalar events. No Engine traversal or log IO runs inside that hook.
A game-thread timer samples identity, emits the candidate and stops on an event
or at300seconds. Registered callbacks remain inert after stop; this does not
claim that the engine hook itself has been removed. Hook/timer errors stop the
trial. Current identity sampled afterward is contextual evidence, not proof that
the completion originated in that session.

Before any observation is promoted to storage proof, correlate the originating
current-manager/world and session identity, reject old-session completions and
verify destination semantics. Preserve bounded observation and keep engine
wrappers callback-scoped. Notification success alone cannot identify storage.
Confirm runtime thread/argument behavior before using any result as proof.
If the hook is unavailable or the slot grammar differs, remain unavailable;
never substitute selected-ID or directory existence. Dedicated-server behavior,
multiple saves, copied-world policy and restart persistence remain separate gates.
