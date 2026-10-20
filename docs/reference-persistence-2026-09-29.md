---
date: 2026-09-29
tags: [saving, research]
status: evidence
---
# Other mods: persistence comparison — September 29

Related: [palpriority-comparison-2026-09-26](palpriority-comparison-2026-09-26.md) · [save-flush-2026-09-29](save-flush-2026-09-29.md) · [async-save-route-research-2026-10-04](async-save-route-research-2026-10-04.md)

Read-only inspection. No reference mod executed, installed or changed; our runtime
and the running game were not modified. Local package versions are evidence for
these copies, not claims about the latest online releases or their performance.

## Findings

### PalPriority Core / UI (downloaded July 26 archives)

Inspection root: `.tmp/assignment-census/reference/`. Core main.lua:

- Line 160: SAVE_DEBOUNCE_SECONDS = 3.
- Lines 392–420: serialize, open sibling temporary file, write, close, remove
  primary and rename; direct rewrite fallback. Writes remain synchronous.
- Lines 424–436: mark dirty on each edit; wait three seconds since the last edit;
  clear dirty state before calling writeConfig, ignoring its returned failure.
- Lines 1631–1642: change the priority, mark dirty and push the Pal update now.
- Line 1250: flushConfig(false) at the start of tickBody.
- Lines 1735–1740: LoopAsync queues ExecuteInGameThread(tickBody). This does NOT
  make the file save asynchronous: tickBody, including its flush, is on the game thread.
- Lines 1535–1536: an explicit deletion path also forces a save immediately.

Useful: coalesce a rapid burst into one generation; separate applied values from
durable values. Limits: three seconds is an inactivity debounce, not a maximum
dirty age; uninterrupted edits can postpone saving. Dirty reset before success,
unchecked write/close results, deletion-before-replacement and direct truncation
are not suitable to copy. No verified save receipt accompanies the immediate UI
push in the inspected cycle path. We cannot attribute apparent smoothness solely
to batching or compare its failure behavior from screenshots.

### CreativeMenu 1.2.4

Local Workshop item 3625287786 contains cooked packages, no Lua writer. The current
CreativeMenu_P.pak and our prior inspection copy both hash to
`b1507a64cd4b1d97730a17c7e61ffc02575239cd46d586e0f322a081eb4b16f9`.
Reused extracted inspection assets without repacking or touching the originals.

`BP_OptionsManager.uasset` references CreateSaveGameObject, LoadGameFromSlot,
SaveGameToSlot, Save_Internal, ForceSave, bHasOptionChanged and CreativeOptionsSaveData.
`BP_PermissionManager.uasset` references CreateSaveGameObject, LoadGameFromSlot,
SaveGameToSlot and CreativePermissionSaveData. Neither inspected manager references
AsyncSaveGameToSlot. Evidence saved at
`.tmp/assignment-census/reference-save-symbols.json` with asset hashes.

This establishes an engine-save integration, not its complete call graph or timing.
The changed flag suggests a dirty-state design; symbol names alone do not prove
how often it saves. Do not claim CreativeMenu saves asynchronously or that engine
SaveGameToSlot automatically avoids blocking. Its linked public GitHub repository
was empty when checked: https://github.com/Okaetsu/CreativeMenu .

### Other local Workshop writers

Paths below are relative to `D:/Steam/steamapps/workshop/content/1623730/`.

| Mod/version | Inspected source | Actual behavior / useful lesson |
|---|---|---|
| DarnMenu 1.8.11 | 3769456391/Scripts/writers.lua:273–305,315 onward,450–458 | Checked temporary write/flush/close, unique sidecars, compare-before-commit, preserved backup and rollback; writeText skips identical bytes. No nonblocking writer here. Retain our recovery protections; no-op suppression is useful for repeated identical assignments. |
| Pal Base Info HUD Grid 0.4.17 | 3767452459/Scripts/menu_config.lua:616–692 | Registration writer uses unique temporary names and checked write/flush/close with conflict checks and backup parking. This is registration persistence, not proof of cheap per-click saving. |
| Base Radius Improved 1.2.2 | 3765017449/Scripts/config.lua:479–508 | Migration writes temporary content, checks write and close, then swaps. Boot/migration frequency differs from priority edits. |
| Auto Hatch 0.9.9.6 | 3633175440/Scripts/utils.lua:161–190; main.lua:83–87,138 | Chat on/off writes JSON synchronously and directly; unchecked write/close. ExecuteAsync in main initializes hooks, not a background save worker. |
| Shiny Pals 1.2.9 | 3773773754/Scripts/shiny/settings.lua:264 onward | Temporary write then readback verification and rename; still synchronous, with weaker result/backup guarantees than ours. Not a stall solution. |

No benchmarks of these mods on RAM were performed. Their lack of a visible hitch
in unrelated use is not evidence that their writes avoid the server filesystem stall.

## What is worth using

1. **No-op suppression:** avoid marking an already-identical, durably saved value
   dirty. Our store.apply_set currently always marks it dirty. Still authenticate
   sender/guild, preserve existing dirty/error retries, and send a fresh response.
   This will not help the measured alternating 1/2 edits, which genuinely changed.
2. **Bounded coalescing:** PalPriority's useful idea, with a maximum dirty age and
   one in-flight generation. Preserve “applied, saving” until durable completion;
   never report saved just because a value was broadcast. This changes the
   immediate-quit durability contract and reduces write frequency, not worst
   individual write latency. It should not be sold as the stall fix.
3. **Engine-owned asynchronous saving:** strongest candidate for removing file-I/O
   blocking. Epic documents serialization on the game thread, platform write on
   a worker, and completion back on the game thread. Blueprint exposes a Completed
   pin with success/failure. This is an alternative suggested by engine support,
   NOT a technique proven from CreativeMenu's cooked symbols.

Sources:
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/Kismet/UGameplayStatics/AsyncSaveGameToSlot?application_version=5.5
- https://dev.epicgames.com/documentation/unreal-engine/BlueprintAPI/SaveGame/AsyncSaveGametoSlot

The versioned 5.1 web pages were unavailable to the browser tool. Public 5.5/current
documentation is not proof of this Palworld build's reflected signatures, platform
implementation or server package mounting. Validate against our modding kit and
actual runtime before adopting it.

## Recommended next experiment

Build a separate scratch SaveGame/Blueprint bridge, leaving production priorities
on the current checked writer. Own the async action and copied immutable payload
inside the engine; do not share Lua state with a background callback. Poll bounded
completion state on the game thread or use a verified game-thread completion hook.
Measure enqueue/serialization, full completion time and frame times on RAM.

Prototype acceptance: overlapping edits serialize in order; stale session/guild
completions cannot acknowledge a new session; failure retains dirty data; shutdown
and reconnect cannot silently lose an acknowledged generation; two alternating
validated generations preserve recovery. Keep existing text saves as migration
backups. Never overwrite Palworld's own save slots. Do not assume SaveGameToSlot
provides our checksum/backup/atomic replacement guarantees. Multi-slot recovery
and a server-mounted helper asset are explicit design work, not a one-line swap.

If this engine bridge is unsupported on the actual runtime, a native worker owning
bytes and serialized filesystem transactions is the fallback architecture. A
host-side I/O trace is still needed to name the cause below buffered flush; neither
approach guarantees that the underlying storage delay itself disappears.
