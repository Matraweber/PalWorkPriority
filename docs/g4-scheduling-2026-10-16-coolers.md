---
date: 2026-10-16
tags: [scheduling]
status: evidence
---
# Coolers: same silent-station gap as generators, fixed, 2026-10-16

Related: [g4-scheduling-2026-10-14-stations](g4-scheduling-2026-10-14-stations.md) · [g4-scheduling-2026-10-17-miners](g4-scheduling-2026-10-17-miners.md)

Singleplayer, Palpagos Islands, build 0.5.0-rc1 on `reliability-0.5`. The user
built a Cooler Box in camp 1 for this test. Raw data:
[test-results/g4-20261016/](../test-results/g4-20261016/) (local, not in git).

## What the game offers

From the modding kit headers: a cooler is `UPalMapObjectItemChest_AffectCorruption`
with a `WorkAffection` of `UPalMapObjectFunctionAffectItemCorruptionByWorkStatus`,
whose `bWorkableOnlyExistsCorruptibleItem` makes the Cooling work workable only
while spoilable food is inside. There is no energy store. Web sources agree
that a Cooling Pal has to stay beside the cooler, and the usual failure is the
Pal leaving (sleep, food) and not coming back.

## Signal, checked live (`!pwp stations`)

| Time | Fridge | Probe |
|---|---|---|
| 20:31:55 | under construction | Cool `state=2 (NotWorkable)`, `build=Building` |
| 20:33:41 | built, 1656 berries inside | `state=1 (Workable)`, `build=Completed` |
| 20:51:04 | user emptied it shortly before | still `Workable` |
| 20:51:17 | empty | `state=2 (NotWorkable)` |
| 20:51:43 | food back in | `state=1 (Workable)` |

Both flips happened within one or two 13 s probe intervals. So for a cooler,
build Completed plus `CurrentState == 1` means "needs a worker". (For
generators CurrentState alone was not enough: blueprints read Workable, see
[g4-scheduling-2026-10-14-stations.md](g4-scheduling-2026-10-14-stations.md).)
Cooling produced no `OnRequiredAssignWork` demand in the census before the fix,
like generators.

## Before the fix (control, old build 70720d1)

Penking (`CaptainPenguin`, Watering 1 / Cooling 2 in the user's settings) was
watering. At 20:58:58 his values were switched to Cooling 1 / Watering 2
(`!pwp setprio`, remote test command). Census every ~18 s:

- 20:59:16 to 21:00:45, 6 samples: **Watering**, while Watering demand lasted
- 21:01:03 to 21:01:57, 4 samples: Cooling, after the Watering demand ran out

So Cooling 1 did not pull him off a lower job; he reached the fridge only
after about 2 minutes, when the other work dried up. (Note: the sampler appends
to its output file, so `ab_before.txt` repeats earlier lines inside each
block; the last line of each `obs` block is that sample. Fixed in the script
before the second run.) Earlier, at night start, he took Cooling directly
because he had no current job, which is why the control needs him busy first.

## Fix

`stations.lua` gains `coolers_needing(works)`: Cooling works whose
`CurrentState` is Workable and whose owning model's `BuildProcess.State` is
Completed (the same `FindModel` read as generators). `stations.KINDS` lists
both kinds, and the scheduler hook loops over it, reading `camp_works` once
per camp. Vacancy per kind = stations needing a worker minus Pals already on
that work type in the camp. Unknown reads count as nothing.

Tests: `tests/test_stations.lua` adds 11 cooler cases (food and built, empty,
unbuilt, under construction, Init, unreadable state, model not found, no build
process, throwing outer, no model, a generator is not a cooler) and checks
KINDS. `tests/test_scheduler.lua` adds four cases: a cooler with food pulls a
Cooling-1 Pal off Watering 2; an empty or unbuilt cooler adds nothing; a Pal
already cooling is not counted twice; generator and cooler vacancies add up.
217 scripts, 0 failures. Negative control: with the state check removed,
`test_stations.lua` fails ("expected 1 cooler needing a worker, got 4").

## After the fix (same protocol, new build)

Deployed (hashes checked), game restarted, world loaded 21:52:52. Probe: Cool
Workable/Completed, generator full (250000/250000, so no generator demand).
Penking watering at 21:53:23; switched to Cooling 1 / Watering 2 at 21:53:26.

- 21:53:44, the first sample, 18 s later: **Cooling**, while Watering 3 was
  still wanted
- 10 samples to 21:56:26: Cooling 9, no task 1 (21:54:20, walking; that
  pass's demand line shows `Cooling 1`, the new vacancy)
- Final fence: `CaptainPenguin -> Cooling`

0 ERROR, 0 WARN since the restart. User settings restored to the 2026-10-12
snapshot (priorities and caps both diffed equal).

## Not covered

- An empty cooler not pulling anyone live (covered by the probe flip plus unit
  tests, not by a census run).
- Refrigerator (same class family, not built here) and coolers on the
  dedicated server (same code path, untested there).

## Side note: launch failure

After the user returned to title, `restart-stand.ahk --title` quit the game but
the new window never appeared, also with `--launch` and with
`steam://rungameid`. No Palworld process started at all and UE4SS wrote
nothing. The user started it from Steam by hand, which worked. Cause unknown
(the Steam window is masked for computer use). See LESSONS.

## Dedicated server updated (23:00-23:04)

GPortal "RAM" through the browser panel, same recipe as 2026-10-14, with 0 players
online: the live `Scripts` was renamed to `Scripts-before-eb54d28` (backup of
3893aa6), `pwp-server-scripts-eb54d28.zip` (git archive of eb54d28, 57 Lua
files, sha256 e93af257...) was uploaded (399.5 KiB) and unzipped in place. The new
`Scripts` holds 57 files; stations.lua (4334 B), scheduler.lua, station_probe.lua
and main.lua match the commit's sizes. After a panel restart the server's UE4SS
log shows PWP_READY at 23:03:47 (0.5.0-rc1, authority, settings available) and
no PalWorkPriority error or warning. Station behaviour on the server is still
untested (no check of its base's generators or coolers).
