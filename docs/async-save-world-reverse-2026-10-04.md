# World-scoped identity: client to host — October 4, 2026

Isolated property-only follow-up to the successful host→client observation.
Production persistence is unchanged.

The observer requires10stable seconds of dedicated client state, a Title
boundary with loaded=false, then10stable seconds of local host state. The same
gameplay map name is not sufficient: current directory, role, dedicated flag,
loaded-state readability and matching reader worlds are required. It compares
the final local directory to the first server directory and the current menu
selection, but always retains verified=false and no write authorization.

Like the forward driver, it disarms before scheduling, logs changed scalar
observations, never retains wrappers, and stops after600seconds or600samples
with an explicit incomplete TIMEOUT. Sink/timer failures are contained. No
native save/load calls or production edits occur in the diagnostic.

## Validation and live evidence

All 102 Lua regression scripts pass; 51 production modules compile with Lua
5.4. Independent review covered both client roles, phase ordering, dwell resets,
role/load mismatches, time/sample bounds and inert shutdown. No blocker found.
The checked installation copied only three diagnostic Lua files to a separate
local mod. Source/install hashes match and production Lua hashes are unchanged.

The native reverse transition completed in PID31528, started October4 at
00:58:01+02:00. Before/after process receipts match exactly. Times below are UTC
(the local test date was October4):

- October3 22:59:02: stable client directory fa6a923a4d58502a1cb830a01bdc8e24;
  role1, dedicated=true, loaded=false, local selection empty on this fresh launch.
- 22:59:46: Title boundary, loaded=false.
- 23:00:19: local selection populated on Title, but current directory unreadable;
  this did not satisfy host readiness.
- 23:00:23: MainWorld5 directory 31141b9948fe8b9a8b4cc399974dddf1,
  role3, dedicated=false, loaded=true.
- 23:00:33: stable host observed; directory differs from the server and matches
  the local selection. TRANSITION_COMPLETE after142 samples; timer cancelled.

At01:02:20 local, production status independently reported local authority,
two camps, saved priorities/limits, and synchronization not required. The
stand-open macro did not produce a visible grid; a large Pal obstructed the
view, and opening/closing pause did not resolve it. Stand reopening is therefore
not verified by this reverse trial; no cause is inferred from that observation.

Evidence: `test-results/save-world-reverse-20261004/acceptance.json`, process
receipts, final diagnostic/production/UE4SS logs and `lua-regressions.log`.
The arm is DISABLED. Production persistence remains synchronous and unchanged.

## Remaining limits

This proves observed identity/role transitions, not storage write authorization:
verified remains false throughout. Only one existing local save was listed, so
distinct-local-save discrimination remains untested. Headless dedicated identity,
active storage binding, recovery semantics and production async integration
remain separate gates. No performance or release-readiness claim follows.
