---
date: 2026-10-04
tags: [async-save, multiplayer]
status: evidence
---
# World-scoped identity across host/client transition — October 4, 2026

Related: [async-save-session-2026-10-03](async-save-session-2026-10-03.md) · [async-enablement-2026-10-04](async-enablement-2026-10-04.md)

Isolated observation; production persistence unchanged. Async stays off
(status 2026-10-20: [RELEASE-0.5.0.md](RELEASE-0.5.0.md) G2/G2b).

This note is the proof chain behind the [DECISIONS](DECISIONS.md) entry
"2026-10-03 - Async saves bind to the GameState save-directory ID, never the
menu's". Merged into it on 2026-10-20: async-save-transition-2026-10-03,
async-save-world-identity-2026-10-03 and async-save-world-reverse-2026-10-04.
The earlier routes that failed (destination hooks, ProcessMap, AutoSave name)
are in [async-save-history.md](async-save-history.md).

## The chain in short

1. **2026-10-03, same process, host → Title → server:** the menu's
   `SelectedWorldSaveDirectoryName` keeps the local ID after joining a server.
   It cannot identify the current storage.
2. **2026-10-03, GameState field:** `PalGameStateInGame.WorldSaveDirectoryName`
   (world state, replicated) returned the local save's directory on the loaded
   host world and nothing on Splash/Login/Title.
3. **2026-10-04, host → client (this run):** the GameState directory followed
   the active world to the server's ID while the menu selection stayed local.
4. **2026-10-04, client → host:** the reverse; the GameState directory switched
   back to the local ID and differed from the server's.

All observations stay `verified=false`. Two directions, one existing local
save: distinct-local-save discrimination, headless dedicated identity and
storage binding remain separate gates.

## Host → client in one process (2026-10-04)

The October 3 local-host trial read the matching directory from the current
GameState only after gameplay loaded. This follow-up must observe, in one
process: 10 seconds of local authority (role 3, dedicated=false, loaded=true),
Title with loaded=false, then 10 seconds of client (role 1/2, dedicated=true,
loaded=false). Both readers must report the same current world. The two
GameState directory candidates and retained game-instance selection are
compared explicitly.

The driver retains only scalar state, resolves wrappers afresh each callback,
samples once a second, and stops after 600 seconds or 600 samples even if the
transition never completes. Reporting, cancellation and failures are protected.
It neither invokes a game save nor writes production settings. All observations
remain verified=false; matching map names do not prove object incarnation.

A successful observation is not acceptance of asynchronous persistence.
Distinct local-save discrimination, reverse travel, headless-server resolution,
active-session binding and recovery/migration gates remain required.

All 101 Lua regression scripts pass and 51 production modules compile.
Independent review caught a misleading COMPLETE deadline message for unfinished
transitions; it now reports TIMEOUT transition incomplete. Tests cover
incomplete/failed connections, phase order, role/readiness combinations, stable
dwell resets, privacy, clock/sample limits and inert shutdown. Re-review passed.

Checked installation copied three diagnostic Lua files, source/install hashes
matched and production hashes stayed unchanged. Normal local restart established
PID 12772. All subsequent travel used the normal game menus without restarting.

| UTC (October 3; local date October 4) | Observation |
|---|---|
| 22:51:09 | Stable host: directory 31141b9948fe8b9a8b4cc399974dddf1; role 3, dedicated=false, loaded=true |
| 22:52:06 | Title: GameState directory unreadable; selected local ID retained; loaded=false |
| 22:52:54 | Server map appeared but GameState unavailable; no completion accepted |
| 22:52:56 | Client: directory fa6a923a4d58502a1cb830a01bdc8e24; role 1, dedicated=true, loaded=false; selected ID still local |
| 22:53:06 | Ten-second stable client window completed; 155 samples; timer_cancelled=true |

The before/after process receipts both identify PID 12772 and the same start
time. The driver explicitly reports differs_from_host=true and
selected_retains_host=true. The directory followed the active world through
this host→client transition; the menu selection did not. No native getter/save
function was invoked by the diagnostic. The loaded-client status subsequently
confirmed server-owned assignments and synchronization ready.

Evidence: `test-results/save-world-transition-20261004/` contains installation,
regression log, process-before/after, full diagnostic log, production/runtime
logs and acceptance.json. Capture verifies disabled arm, cancellation, matching
source/install hashes and unchanged production. The ordinary client-role warning
is expected; this is not a blanket claim of zero warnings or stutter-free play.

The first status-tool attempt used the tool's obsolete default C: game path and
failed before sending. Re-running with the known D: root supplied in-process
returned client/ready. No tool source or game installation was changed for that.

## Same-process host to client (2026-10-03, merged from async-save-transition)

Separate, read-only experiment (`experiments/ue4ss-save-transition/`). The
preceding two-host-boot experiment ([history](async-save-history.md), authority
section) could not test game-instance state that survives a return to title.
This driver stays active for up to ten minutes, records a ten-second first
MainWorld5 visit, requires an observed Title boundary, and records a ten-second
second MainWorld5 visit before cancelling itself. Only strings/booleans survive
callbacks. The startup arm is consumed first. Host/client roles are established
independently from the same process's production log and server handshake;
repeated map names are insufficient. The probe never binds a save slot.

All 92 Lua regression scripts pass. The fixture exercises Title ordering,
single-visit rejection, both dwell resets, disarm failure, timeout at 600 seconds
and cancellation failure. Review found throwing cancellation could trigger a
second shutdown attempt; shutdown is now idempotent and cancellation protected.

Completed in process 18604 (started 19:41:41 local), identical process identity
before and after. Evidence: `test-results/save-transition-20261003/`.

| UTC | Observation | Selected local ID | Loaded-world flag |
|---|---|---|---|
| 17:42:32 | First stable singleplayer visit | 31141b9948fe8b9a8b4cc399974dddf1 | true |
| 17:43:29 | Title boundary | same ID | false |
| 17:45:11 | Second stable visit, server client | same ID | false |

Production evidence independently establishes positive-session host authority
before Title and client role, ready synchronization and the expected server
guild after joining. Startup arm disabled; production Lua hashes match.

**Finding:** the selected local-save ID survives a same-process join to a remote
server. Format validity and matching an existing local save directory cannot
establish the current storage identity; the async writer must require
current-session authority/readiness evidence. This is an integration hazard for
the experiment, not a demonstrated production persistence regression.
Independent review confirmed it and added the host → Title → client regression
to `tests/test_save_identity_probe.lua` (selected ID constant while loaded goes
true → false → false; no stage may expose verified identity, storage, key or
readiness).

Reverse run (fresh boot into the server, back through Title to the local save,
no restart; process 39980; `test-results/save-transition-reverse-20261003/`):

| UTC | Observation | Selected ID | Loaded-world flag |
|---|---|---|---|
| 18:39:20 | Stable server client | empty | false |
| 18:40:19 | Title after leaving the server | empty | false |
| 18:40:50 | Local save selected, still Title | local 31141... | false |
| 18:41:04 | Stable local gameplay | local 31141... | true |

Production logs show client refusal before leaving and session 3
authority/settings after returning. One existing save only; hash/control checks
were done by the main collector, not repeated by the reviewer.

This finding is what made `experiments/save_session.lua` require fresh
authorization at admission and delivery boundaries (see
[async-save-session-2026-10-03.md](async-save-session-2026-10-03.md)).

## GameState `WorldSaveDirectoryName` (2026-10-03, merged from async-save-world-identity)

The ProcessMap trial returned 234 empty samples while the local save changed,
so identical polling was dropped ([history](async-save-history.md)). Source
review found a stronger candidate: `PalGameStateInGame.WorldSaveDirectoryName`,
a transient FString replicated through `OnRep_WorldSaveDirectoryName`
(DOREPLIFETIME registered in the SDK). The getter and notification bodies in the
kit are stubs; no setter/load semantics follow from them.

UE 5.1 `Engine/Classes/Engine/World.h` declares GameState as a transient
UPROPERTY on UWorld (line 1371 in the installed source). That supports a fresh
property chain engine → viewport → world → GameState without an object-array
search. The field belongs to world state, unlike the retained game-instance
selection. **Trap:** replication means a client legitimately sees the server's
directory ID; it must never be taken as permission to write local settings.

`experiments/save_world_identity_probe.lua` copies only a canonical nonzero GUID,
role 0-3, the dedicated-server Boolean and a bounded world name. Missing,
malformed and throwing reads stay distinguishable. No native getter beyond
validity and name reads; no native references survive the callback. Results are
always verified=false with no storage/key/ready field. The driver
(`experiments/ue4ss-save-world-identity/`) disarms before scheduling, reads once
a second, stops after 10 seconds of stable readable observations or 180
seconds/samples. An unavailable field cannot produce a completed observation.

Offline: all 100 regression scripts pass, 51 production modules compile.
Tests include a retained local selection alongside a different replicated
client directory, fresh wrapper replacement, field/sink/timer errors, world
mismatch, stable-observation reset and inert shutdown.

Live (installed 20:46:04 UTC into the separate PWPAsyncSaveWorldIdentity mod,
three Lua files, hashes checked, older probes disabled): process 43644, armed
20:46:54, completed 20:47:41 UTC with 43 samples and timer cancelled.

- Splash/Login/Title GameState gave no directory.
- 20:47:27: on Title the game-instance selection already held the local ID but
  GameState did not.
- 20:47:31: loaded MainWorld5 GameState returned
  31141b9948fe8b9a8b4cc399974dddf1, matching the selected local save, role 3,
  dedicated=false, loaded-world=true; stable for 10 seconds.
- Role 3 also appeared on Title: **role alone is not readiness**.

Evidence: `test-results/save-world-identity-20261003/`. A speculative
selection-hook prototype was never installed; this property route superseded it.

## Client to host (2026-10-04, merged from async-save-world-reverse)

Property-only follow-up (`experiments/ue4ss-save-world-reverse/`). The observer
requires 10 stable seconds of dedicated client state, a Title boundary with
loaded=false, then 10 stable seconds of local host state. Current directory,
role, dedicated flag, loaded-state readability and matching reader worlds are
all required; the same map name is not enough. It compares the final local
directory to the first server directory and the current menu selection, and
keeps verified=false and no write authorization. Same bounds as the forward
driver (600 seconds or 600 samples, explicit incomplete TIMEOUT).

All 102 Lua regression scripts pass; 51 production modules compile. Three
diagnostic Lua files in a separate local mod; production hashes unchanged.

PID 31528 (started October 4 00:58:01+02:00), before/after receipts match. UTC:

- October 3 22:59:02: stable client directory fa6a923a4d58502a1cb830a01bdc8e24;
  role 1, dedicated=true, loaded=false, local selection empty on this fresh launch.
- 22:59:46: Title boundary, loaded=false.
- 23:00:19: local selection populated on Title, current directory unreadable;
  not host readiness.
- 23:00:23: MainWorld5 directory 31141b9948fe8b9a8b4cc399974dddf1, role 3,
  dedicated=false, loaded=true.
- 23:00:33: stable host; directory differs from the server and matches the
  local selection. TRANSITION_COMPLETE after 142 samples; timer cancelled.

At 01:02:20 local production status reported local authority, two camps, saved
priorities/limits. The stand-open macro did not show a visible grid (a large Pal
blocked the view); stand reopening is not verified by this trial and no cause is
inferred. Evidence: `test-results/save-world-reverse-20261004/acceptance.json`
plus process receipts, logs and `lua-regressions.log`. The archive is accepted
by `tools/accept_save_transition.py` (see
[async-enablement-2026-10-04.md](async-enablement-2026-10-04.md), "Evidence
acceptance").

## Remaining limits

Both directions are observed, each in its own process run (for the selected-ID
probe and again for the GameState probe). Only one existing local
save was listed, so distinct-local-save discrimination is untested. No native
dedicated-server identity is proven here (the read-only October 9 dedicated
observation is in async-enablement). Save-absence classification, migration,
native singleton enforcement and active storage binding remain required before
production async integration. No performance or release-readiness claim follows.
