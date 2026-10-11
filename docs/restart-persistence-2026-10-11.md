# G1 restart persistence: code review against the reports, 2026-10-11

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
