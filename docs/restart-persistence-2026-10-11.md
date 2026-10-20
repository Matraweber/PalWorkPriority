---
date: 2026-10-11
tags: [saving, release, testing]
status: evidence
---
# G1 restart persistence: code review against the reports, 2026-10-11

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [upgrade-041-2026-10-11](upgrade-041-2026-10-11.md)

Gate: [RELEASE-0.5.0.md](RELEASE-0.5.0.md) G1. Reports: Two Bob Games (Steam,
Sep 23: "Transport X returns to 1 after restart; priorities appear ignored until
edited again") and johndujo (Nexus bug "Priority list not saving").
Offline review only. **Live acceptance is still open.**

## Cause 1: 0.4.1 dropped X on every save (fixed in rc1)

0.4.1 `Scripts/store.lua` serialized with

    local p = (prio == false) and false or math.tointeger(prio)

For X (`false`) the `and` yields false, so `or` evaluates
`math.tointeger(false)`, which is nil, and the row is skipped. After a restart
the Pal has no row and shows the config default, usually 1. That is exactly the
first half of the Two Bob Games report. rc1 writes
`prio == false and 'X' or tostring(math.tointeger(prio))` (`'X'` is truthy), and
`tests/test_x_roundtrip.lua` covers it. X values already lost under 0.4.1
cannot be recovered; the changelog must say so.

## Cause 2: 0.4.1 skipped idle camps (fixed in rc1)

0.4.1 `scheduler.lua` returned before applying anything when a camp had no
demand and no ceilings (`stats.idle_skipped`). Right after loading, or at
night, demand is often empty, so a saved X was not applied until some later
demand or an edit triggered a pass. That matches "ignored until edited again".
rc1 runs idle camps as reconciliation passes (`stats.idle_reconciled`).

## Cause 3 (upgrade only): temporary slot keys

When a Pal's GUID was unreadable, 0.4.1 saved its row under `slot<N>`. A slot
index is not a stable identity, so such a row could land on a different Pal
after a restart. rc1 refuses these rows on load and logs
`ignored N temporary slot identifiers`. Those Pals therefore lose their custom
priorities on upgrade. The user's own file (41 rows, 2 X) has no slot rows, so
how often this happened to others is unknown. Ask reporters to look for that
log line.

## Open risk for the live test

rc1 deliberately keeps existing permissions when a Pal's assignment is unknown
([DECISIONS.md](DECISIONS.md), 2026-09-25). If assignments read as unknown in
the first passes after a restart, an X could still wait before taking effect,
which would look like the old "ignored until edited" symptom. The live run
must check the first passes' toggle log for the X Pals, not only the stand.

## Offline state at review

Branch `reliability-0.5` at 070ef05: 55 Lua modules compile, 214 Lua
regressions pass, luacheck clean, 686 Python tests OK (81 native skipped by
design).

## Live run still required (G1 done-when)

Singleplayer and server: set 1-5 and X on at least 3 Pals, restart twice via
the AHK macros, then compare the stand, `priorities.txt` and the first passes'
fence and toggle lines. Watch the Pals' Current Task for the X job.

## Live run, singleplayer, 2026-10-11 20:15-20:25

**Install switched to the shipping path first.** The client had been running a
hand-patched older rc1 with the async trial armed (see DECISIONS.md, same date).
Steps: game and server closed; whole mod folder backed up with a SHA-256
manifest (4,154 files, verified identical) to
`D:\PalWorkPriority-backups\pre-ship-path-20261011-201543`, journal store copied
beside it. Journals matched today's export bundle byte for byte and the legacy
files held the same 41 priority and 2 limit rows, so nothing needed migrating.
`async-trial/launch.lua` and `receipt.lua` were MOVED into that backup's
`disarmed-trial/` (re-arm by moving them back, game closed). Then
`tools/deploy.ps1` installed the branch: 55/55 Lua files match `reliability-0.5`
at e1bdd63, pak unchanged and matching, auto reload 0, Workshop copy not in
ActiveModList.

**Launch method.** The AHK macro was started through a one-off Interactive
scheduled task so the game runs in the user's real session, not as a child of
the agent's shell. (Writes to D: and to the repo on the Desktop were confirmed
visible to the real session with a scheduled-task probe.)

**Test data.** The existing file: 15 Pals, values 1-5 and two X:
Grizzbolt (`BOSS_ElecPanda`, key 679D42C8...) Transporting = X, the Two Bob
Games case; GrassRabbitMan (key 7B48FA63...) Handiwork = X.

**Discriminating readback.** Fence lines and fenced off-lists cannot tell X from
fencing, because a fenced Pal has every other type off anyway. So after each
restart `!pwp restore` (unfence, verified readback) was followed in the same
remote write by `!pwp worksuit`, which reads the game's own
OffWorkSuitabilityList. With fencing gone, only X and caps can be off.

| | Restart 1 (`--launch`, 20:20) | Restart 2 (`--stand`, 20:23) |
|---|---|---|
| world ready / first pass | 20:21:19 / 20:21:32 | 20:24:19 / 20:24:32 |
| Grizzbolt off-list | `[Transport]` | `[Transport]` |
| GrassRabbitMan off-list | `[Anyone Handcraft]` | `[Anyone Handcraft]` |
| restore line | "X choices remain disabled", 25 requests | same, 26 requests |
| priorities.txt / caps.txt | unchanged (6a06f03d / b2de8be4) | unchanged |
| WARN/ERROR in priority.log | 0 | 0 |

(`Anyone` appears on two Pals with no matching mod rule; it is untouched vanilla
state, not an X.)

**Verdict for the "restart keeps priorities and applies them" item, singleplayer:
PASS for saved values.** Both X choices were in force in the game's own state
within a minute of loading, twice, with no edit. Only the first tick after load
reported unverified assignments; they cleared by the next tick.

**Still open in G1:** an in-game edit then save then restart (this run reused
saved rows, it did not exercise the save path), the same check on the server,
the 0.4.1 upgrade route, and rapid edits.

## Save path: edit, restart, readback (2026-10-11 20:37-20:42)

Computer use was declined for the game, so the edit was made with a new
developer command, `setprio <palkey> <work> <1-5|X>`, that makes the same call
a stand cell ends in (`store.set`, then flagging the post-edit pass). It only
runs from remote.txt or the console; any chat line, the host's included, is
refused. A regression test covers both paths, and a negative control (chat
refusal removed) made it fail as intended. The click-to-cell mapping above
`store.set` is not exercised here; Codex accepted it natively on 2026-09-24.

| Step | Result |
|---|---|
| `setprio` Grizzbolt Handiwork 3 -> X | accepted, state `saved` immediately (host flushes per edit) |
| file | `...679D42C8...|5|X` written |
| off-list after restore | `[Handcraft Transport]` (was `[Transport]`) |
| full restart (`--stand`, 20:39:30) | file still `|5|X`; off-list after restore `[Handcraft Transport]`; 0 WARN/ERROR |
| restore original 3 | all 41 rows identical to the pre-test backup; only the header's save generation moved 184 -> 186 |

**Verdict: the singleplayer save path passes** (edit, immediate durable save,
restart, value in force). Remaining G1 items: the server run, the 0.4.1 upgrade
route and rapid edits.

## Dedicated server (GPortal "RAM"), 2026-10-11 21:20-21:54

**Install.** The server still ran the old schema-3 build. The browser panel's
file actions were blocked by the agent's permission check, and the agent may
not log in with the user's FTP password, so the user logged in once to
`tools/ftp_session.py` and the agent drove it from its queue. Server mod path:
`/Pal/Binaries/Win64/ue4ss/Mods/PalWorkPriority`. Old `Scripts` (53 files) kept
as `Scripts-before-0.5-20261011`; new `Scripts` = the 55 files of b793e32, every
one downloaded back and SHA-256 identical. (A dropped connection during the
first readback made the helper re-run the install; fixed in 442be46, see
LESSONS.) The panel's Restart button then worked from the browser.

**Identity.** Server log 21:40:00 "0.5.0-rc1 loaded", 21:40:06 PWP_READY
authority. The client (schema 4) joined, resolved the server guild and the echo
round trip worked; an old schema-3 server could not have synchronised it.

| Step | Evidence |
|---|---|
| client `setprio` Pal 050BF1CE... Transporting 1 -> X | server log 21:46:06 "priority Transport set to X by a player"; server file generation 94 -> 95, row `|12|X`; priority-change pass ran |
| server restart (panel, 21:47) | reloaded 21:47:22 on 0.5.0-rc1; file still `|12|X`, payload checksum unchanged (5accec05; load rewrite moved generation 95 -> 96) |
| client rejoin (server macro `--title`) | stand screenshot: exactly one X on the whole grid, Flambelle's Transporting cell; every other server value is 1 |
| restore 1 from the client | server payload checksum back to 7e4eefdc, all 34 rows identical to the pre-test copy |

Artifacts: `test-results/server-g1-20261011/` (stand screenshot, server file
before / after restart / restored).

**Verdict: G1 "restart keeps priorities" PASSES on the dedicated server.**
Known tool quirk: the server macro reports "STOPPED: Game did not receive
focus" at its last step even when the stand did open (the user's windows were
in front; game is windowed). Treat its report as advisory and check the screen.

**G1 still open:** 0.4.1 upgrade route, rapid edits.

## Rapid edits on the dedicated server (2026-10-11 21:59-22:03)

Twenty edits to one cell (Pal 050BF1CE..., Transporting) were sent from the
client in a single remote write, so they ran back to back in one tick:
`2 3 4 5 X 1 2 3 4 5 X 1 2 3 4 5 X 1 2 4`. The client accepted all 20 in order.

| Check | Result |
|---|---|
| server log | ONE line, 21:59:37 "priority Transport set to 4 by a player" |
| server file | `|12|4`, generation 97 -> 98 (one save), one priority-change pass |
| server restart (panel, 22:00) | reloaded 22:00:17; file still `|12|4`, checksum dcb05d51 unchanged |
| client after rejoin | stand shows 4 in Flambelle's Transporting cell (screenshot `stand-after-rapid-edits.jpg`) |
| restore 1 | server checksum back to 7e4eefdc, rows identical to the pre-test copy |

**Verdict: PASS.** The client's per-cell pending edit merged the burst into one
request carrying the last value, so the server saved once and ran one pass for
twenty clicks. Limits of this run: the burst arrived within one tick; clicks
spread over seconds may produce a few requests rather than one, each still a
single save. Server-side callback time was not measured (server profiling off);
G5 covers timing.
