---
date: 2026-09-29
tags: [network, multiplayer]
status: evidence
---
# Broadcast lifetime safety — September 29

Related: [transmitter-first-2026-09-29](transmitter-first-2026-09-29.md) · [edit-latency-root-cause-2026-09-29](edit-latency-root-cause-2026-09-29.md)

Removing the second roster build was deferred: a plain row can become stale
through membership/capability or effective-priority changes during native
callbacks. A command token alone does not prove those fields remained current.
No roster reuse or performance improvement is claimed by this change.

The prerequisite review exposed an existing defect: a synchronous callback
could replace the session during guild discovery and the outer broadcast still
sent/committed an old snapshot. The new regression failed before the fix with
`guild: stale batch reported success`.

net.lua now captures plain peer identities/scopes before native discovery,
checks epoch/server nonce/authority after native calls, and stops native object
access after observed invalidation. Recipient wrappers remain synchronous-call
local. A monotonic push serial invalidates an outer broadcast when a nested
push starts, including another stream. It is never restored after nesting.
Guards run before/after snapshot sends, inside send preparation after FName,
and before committing revision state. Already-sent packets cannot be recalled;
an interrupted batch is left incomplete for protocol recovery.

The lifetime regression covers148 combinations: direct/broadcast, P/R streams,
session/nonce/peer replacement/scope/authority/nested cancellation at discovery,
name/guild/row reads, FName preparation and sending, plus successful nested
broadcasts that must retain newer revisions. Explicit stale-native-access counts
prevent pcall from hiding an invalid dereference in the fixture. All76 regression
scripts pass and51 modules compile with Lua5.4; structural checks pass. Independent
review cleared the guard design. This is mocked invalidation evidence; native
session-change timing is not forced in the player's world.

Source/client/server readback net.lua SHA256:
385e7efba1c61cdabe1705811043f6fdeb8a34b2c2bcae1f8f258aae7d4f140c.
Client previous file: mod-root backups/push-lifetime-20260929-185922.
Only net.lua changed in the deployment; user data and pak remain intact.

## Native smoke

Normal native Quit/Yes followed by the documented --launch macro established
new clientPID21736 and verified RAM/guild, opening the stand19:03:15. Nine rows
returned. Vixy Gathering1→2→1 confirmed visually and by server receipts19:03:56
and19:04:10. Original1 settled green; final server status says priorities saved
and authority yes. Profiling off confirmed19:04:20.

43second window19:03:37–19:04:20, active daytime camp, one client/guild:
two edit callbacks300/306ms; stand deltas107/113ms (110ms mean); push roster
58.5ms mean; component and transmitter discovery each25.5ms mean. Saves4/5ms.
These are inclusive runtime timings (observed1ms clock step), not frame times.
The110ms delta is consistent with the previous111ms sample; two edits in a
different workload do not establish a performance improvement or lack of every
possible regression. This safety fix does not remove the duplicate roster cost.

The server executed permission requests on both edits. That is not independent
proof of completed Pal work. No WARN/ERROR in the measurement window; both log
sinks report zero failures. Native multi-peer reentry and host/client transitions
remain broader acceptance gates; synthetic tests establish the invalidation
contract without deliberately disrupting this live world.

Evidence under .tmp/assignment-census/: server-push-lifetime.log,
client-push-lifetime.log, net-push-lifetime-server.lua, push-lifetime-tests.txt,
push-lifetime-checker.txt and push-lifetime-server-running.png.
