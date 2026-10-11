# Native save-process map observation — October 3, 2026

Production persistence remains unchanged. This is an isolated diagnostic.

The destination-hook trials produced zero destination callbacks and four
success-only notifications. This follow-up inspects the SDK-declared
`SaveGameManager.WorldSaveProcess.ProcessMap`, rather than repeating silent hooks.
The SDK implementation is a stub; neither key meaning nor entry lifetime is known.

`experiments/save_process_probe.lua` resolves fresh engine, viewport, world,
game instance and manager references within each sample. It reads map size
first and refuses more than 16 entries. Each callback copies only a sanitized
key classification, an optional GUID candidate, State (0–4), and
bPreDelegateSuccess. It never reads SaveObject. Arbitrary key paths/names are
not retained. Missing or failed reads remain unknown. Every result has
verified=false and supplies no storage binding or write authorization.

The intended TMap API is `#map`, `ForEach(key,value)` with `:get()` parameter
access and true to stop iteration, documented in the
[official TMap reference](https://docs.ue4ss.com/dev/lua-api/classes/tmap.html).
The installed log identifies commit2281fa31. Its matching LuaTMap.cpp and
tmap.md are saved under test-results/save-process-20261003. Construction retains
a pointer rather than converting the entire map; length reads Num(); callbacks
receive parameter wrappers and true breaks. The probe checks map:type()==TMap.

The isolated driver disarms before scheduling, samples on the game thread at
one-second intervals, logs changes only, and stops after 240 seconds or 240
samples. Timer cancellation and terminal reporting are protected. No hooks,
save/load calls, forced autosaves or settings edits are involved.

The native iterator scans sparse indices up to GetMaxIndex, which Lua does not
expose. The entry cap bounds copied data and callbacks, not native scan time.
A measured probe read over10ms stops future polling; it cannot preempt that
first read. Oversized, invalid-count and failed reads also stop the driver.

Limitations: one-second polling can miss short-lived states; unchanged entry
counts do not prove an immutable map; selected-world IDs are known to persist
across transitions. A matching process key remains a candidate until its
meaning, originating session, authority and active storage are independently
established. Empty samples cannot establish that a save never occurred.

Offline validation: all98 regression scripts pass;51 production modules compile
under Lua5.4. New tests cover real API-shaped wrapper access, privacy, unknown
properties, map limits, early stop, type validation, one-shot arming, failed
sinks/timers, time/sample limits, slow-read shutdown and inert callbacks after
stop. Independent review found no Lua-level blocker, while explicitly retaining
the native pointer/struct-getter and sparse-scan limitations above.

Checked installation at19:55:57UTC copied exactly three Lua files into the
separate PWPAsyncSaveProcess diagnostic, verified source/install hashes and
unchanged production, and armed last. All seven older diagnostic controls were
disabled. The normal singleplayer restart was then started.
Live result: PID40888, armed19:56:37UTC and completed20:00:37UTC with
234samples and timer_cancelled=true. All sampled maps were empty, including
the loaded MainWorld5 from19:57:14 onward. The stand reopened with its priority
numbers visible; production reported authority/settings available. Local
Level.sav metadata advanced during the window, including19:58:29UTC, while
the observed map remained empty. No native struct values were encountered,
so the value getter remains untested in-game. No destination was established.

Evidence under test-results/save-process-20261003 includes installation hashes,
98-script regression output, exact runtime map source, full diagnostic log,
production/runtime logs, process identity and before/mid/after save metadata.
Capture confirmed identical source/install hashes, unchanged production,
disabled arm and successful timer cancellation. This is not storage-identity
acceptance or a performance verdict.

Do not repeat the same polling experiment without new evidence. Next identity
work needs an observed destination-bearing source, or independently verified
save-selection/load semantics tied to the active authority session. A denser
poll, empty map or success-only notification does not supply that proof.
