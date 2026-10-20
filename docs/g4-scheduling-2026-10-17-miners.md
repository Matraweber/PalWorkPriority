---
date: 2026-10-17
tags: [scheduling, limits, storage]
status: evidence
---
# "Everything stops" / "only one miner": reproduced, two causes, 2026-10-16/17

Related: [g4-scheduling-2026-10-14-stations](g4-scheduling-2026-10-14-stations.md) · [storage-scope-2026-09-13](storage-scope-2026-09-13.md) · [g5-performance-2026-10-19](g5-performance-2026-10-19.md)

Singleplayer test world (Palpagos Islands, the user's free-to-change test
world), build 0.5.0-rc1 on `reliability-0.5`. Report: Okami_sama (Steam,
Sep 18): adding tasks in the panel stopped other work across the base; mining
allowed only one Pal. Related: SolidRhoé (a Stone limit stops Rushoar and
Mammorest mining metals). Raw data: [test-results/g4-20261017/](../test-results/g4-20261017/)
(local, not in git).

## Reproduced

The bases have 36 Mining works (rocks, a stone pit) and 48 Lumbering works
(trees, a logging site), all Workable. In three days of the mod running, the
demand line never once contained Mining or Lumbering, and no Pal mined or
chopped.

| | Pals working per sample | miners | lumberjacks |
|---|---|---|---|
| mod on, 42 samples, incl. Mining 1 on four Pals (23:50-00:02) | 3-8 | **0** | **0** |
| `!pwp off` (vanilla), 6 daylight samples (00:03-00:05) | 7-11 | 1-3 | 2-5 |

Mammorest, whose only configured work is Mining, kept Planting.

## Cause 1: the limits were reached, but the display said "stock unavailable"

The in-game options (DarnMenu, `Mods/shared/PalWorkPriority_user.lua`) set
`storage_scope = "global"`, so limits count all bases together: Wood 45103 of
30000 and Stone 43134 of 35000. Both rules were met, so Lumbering and Mining
were correctly withdrawn from every Pal (a legacy rule switches the whole work
type; item-specific limits are deferred to 0.6). `!pwp stations` (extended)
showed `last pass limit Mining: capped in 2 of 2 camp(s)`.

What made it look like a bug: `!pwp limit` said "stock unavailable" in 2 of 5
calls 15 s apart, alternating with the correct "44751 / 35000 threshold met".
The scheduler reuses a stock reading for up to `stock_ttl` (30 s) and passes run
every 10 s, but the reading was published as valid for only 30 s, so between
passes the display rejected a reading the scheduler was still acting on.

**Fix:** the reading is published as valid for `stock_ttl` plus one pass
interval (40 s), capped by the protocol's 60 s. Test
`test_scheduler_storage_cost.lua` (a 35 s old reading in force is verified; one
past the next pass is not); negative control: with the old TTL it fails. Live
12:16-12:18: 6 of 6 calls 12 s apart showed "threshold met" with the numbers.

## Cause 2: rocks and trees are never announced after world load

With the limits lifted (10:45, user-approved test), Pals mined and chopped
(1-4 miners, 12-18 lumbering observations, 7-12 working per sample, like
vanilla). But the demand index counted only 2 Mining and 48 Lumbering
announcements for the whole session, all at world load, and they never grew
while Pals worked for minutes (re-announcements after the 45 s expiry would
count again). So, like generators and coolers, resource nodes are silent, and
with any limit or any Pal whose higher priorities had demand, nothing ever
brought Mining or Lumbering back.

**Fix (stations.lua):** `resources_needing(works, value)` counts Workable
Lumbering/Mining works; one owned by a building (rocks and the stone pit have a
model) only when built. A natural tree's owner model reads as an invalid (null)
wrapper and counts (seen for all 46 trees). Vacancy = count minus Pals already
on that work. Tests: `test_stations.lua` (11 node cases), three scheduler cases
(Workable rocks pull a Mining-1 Pal off Planting 2; none adds nothing; miners
on rocks are subtracted). Negative control: without the Mining entry the reader
test fails. Live 11:18-11:20 (limits lifted, after restart): demand showed
`Mining 8-10`, `Lumbering 1-4`, matching the 12 rocks and 3 trees left; 1-4
miners per sample, lumbering 12 of 8 samples.

## Limits restored

The user's rules (Wood 30000, Stone 35000) were removed for the test. Copying
the old `caps.txt` back was refused by the mod's rollback protection ("recovered
limits from caps.txt.bak", it keeps the newer generation): correct behaviour.
New legacy rules cannot be created in 0.5, so the Wood rule was re-added through
the supported path: a temporary `work_caps = { Deforest = { Wood = 30000 } }` in
`config.lua` makes it a legacy rule, `!pwp limit Lumbering Wood 30000` stores it
as the guild rule, then `config.lua` was restored byte for byte. Rules and
priorities diff equal to the snapshots.

## For the changelog / replies

- A met limit stops the whole work type (Stone limit stops ore too), and with
  the "all bases" option the stock of every base is added up. The panel now
  shows the met threshold reliably instead of "stock unavailable".
- Deleting a legacy limit cannot be undone in 0.5 (new limits are locked until
  0.6); the config.lua route above works.
- Mining and Lumbering now pull Pals back on their own, like generators and
  coolers.

## Side notes (test rig)

- The restart macro's in-world step (Esc, Return to Title) failed every time
  today: the macro's clicks arrive, its keys do not, while computer use's keys
  do. Its menu clicks then landed in the world and fired the rifle (19 to 3
  ammo, harmless). The title-screen part (`--title`) works. See LESSONS.
- Alt+F1 sent through computer use opened a full-screen overlay (Game Bar /
  NVIDIA) instead of the mod panel; the game kept running behind it.

## Dedicated server updated (12:23-12:27)

GPortal "RAM" through the browser panel, 0 players online: `Scripts` renamed to
`Scripts-before-34c95ad` (backup of eb54d28), `pwp-server-scripts-34c95ad.zip`
(git archive of 34c95ad, 57 Lua files, sha256 699f0267...) uploaded (401.34 KiB)
and unzipped in place. The new `Scripts` holds 57 files; stations.lua,
scheduler.lua, station_probe.lua and storage_probe.lua match the commit's
sizes. After a panel restart (12:26:55) the server's UE4SS log shows PWP_READY
at 12:27:09 (0.5.0-rc1, authority, settings available) and no PalWorkPriority
error or warning. Behaviour on the server's own base is untested.
