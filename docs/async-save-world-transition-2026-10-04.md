# World-scoped identity across host/client transition — October 4, 2026

Isolated observation; production persistence unchanged.

The October3 local-host trial read the matching directory from the current
GameState only after gameplay loaded. This follow-up must observe, in one
process:10seconds of local authority (role3,dedicated=false,loaded=true), Title
with loaded=false, then10seconds of client (role1/2,dedicated=true,loaded=false).
Both readers must report the same current world. The two GameState directory
candidates and retained game-instance selection are compared explicitly.

The driver retains only scalar state, resolves wrappers afresh each callback,
samples once a second, and stops after600seconds or600samples even if the
transition never completes. Reporting, cancellation and failures are protected.
It neither invokes a game save nor writes production settings. All observations
remain verified=false; matching map names do not prove object incarnation.

A successful observation is not acceptance of asynchronous persistence.
Distinct local-save discrimination, reverse travel, headless-server resolution,
active-session binding and recovery/migration gates remain required.

All101 Lua regression scripts pass and51 production modules compile. Independent
review caught a misleading COMPLETE deadline message for unfinished transitions;
it now reports TIMEOUT transition incomplete. Tests cover incomplete/failed
connections, phase order, role/readiness combinations, stable dwell resets,
privacy, clock/sample limits and inert shutdown. Re-review passed.

Checked installation copied three diagnostic Lua files, source/install hashes
matched and production hashes stayed unchanged. Normal local restart established
PID12772. All subsequent travel used the normal game menus without restarting.

| UTC (October3; local date October4) | Observation |
|---|---|
| 22:51:09 | Stable host: directory31141b9948fe8b9a8b4cc399974dddf1; role3, dedicated=false, loaded=true |
| 22:52:06 | Title: GameState directory unreadable; selected local ID retained; loaded=false |
| 22:52:54 | Server map appeared but GameState unavailable; no completion accepted |
| 22:52:56 | Client: directoryfa6a923a4d58502a1cb830a01bdc8e24; role1, dedicated=true, loaded=false; selected ID still local |
| 22:53:06 | Ten-second stable client window completed;155samples; timer_cancelled=true |

The before/after process receipts both identify PID12772 and the same start
time. The driver explicitly reports differs_from_host=true and
selected_retains_host=true. The directory followed the active world through
this host→client transition; the menu selection did not. No native getter/save
function was invoked by the diagnostic. The loaded-client status subsequently
confirmed server-owned assignments and synchronization ready.

Evidence: test-results/save-world-transition-20261004 contains installation,
regression log, process-before/after, full diagnostic log, production/runtime
logs and acceptance.json. Capture verifies disabled arm, cancellation, matching
source/install hashes and unchanged production. The ordinary client-role warning
is expected; this is not a blanket claim of zero warnings or stutter-free play.

The first status-tool attempt used the tool's obsolete default C: game path and
failed before sending. Re-running with the known D: root supplied in-process
returned client/ready. No tool source or game installation was changed for that.

Remaining: reverse client→host, distinct local saves, headless identity and
binding to fresh session ownership. This evidence still does not automatically
authorize storage or enable the experimental persistence backend.
