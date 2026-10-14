# Continuous stations: a suspected defect, RETRACTED, 2026-10-14

**Retracted the same evening.** The "reproduction" below was confounded. The
user had replaced the base's generators: during 20:37-20:45 both were unbuilt
blueprints, so no Pal could work them, and from 20:54 they filled up, so they
offered no work. Grizzbolt's return at 20:54 was the first generator finishing.
There is no evidence of a mod defect. The proposed "standing demand" fix would
have been harmful: it would have counted a full generator as a vacant seat and
parked Pals at it. Not implemented. Kept below as the record of how the wrong
conclusion formed.

## Reproduced live

Grizzbolt (`BOSS_ElecPanda`) normally sits on a generator. During the Incineram
test its priorities were temporarily Generating Electricity 4 / Handiwork 1, so
the mod fenced it to Handiwork and it left the generator. At 20:30 the values
were restored (Electricity 1, Handiwork 3). From 20:37 to 20:45 the census shows
Grizzbolt on **Handiwork in every sample**, nobody on Electricity, and the mod
never fenced Grizzbolt. Generator work objects went from states `1x1 3x1` (one
manned) to `3x2` when it left, but Generating Electricity produced **0 demand
announcements** (`OnRequiredAssignWork`) all session.

## Why

Demand comes only from the game's "this work needs a worker" announcements
(demand.lua). Queue stations (workbench, campfire) announce. Continuous
stations (generator; by the same design the cooler/freezer) do not, empty or
not. Retention keeps a Pal that is already on its station, and a verified
fixed assignment outranks everything (scheduler_plan.lua), so the generator
stays manned while nothing disturbs it. But once the Pal leaves (picked up,
which clears a fixed assignment; or fenced away by an edit; or wandering
during night or hunger), no signal ever brings it back. Priority 1 on
Generating Electricity then does nothing.

PalPriority (reference mod, v1.2.0) uses the same announcement hook and the same
keep-current-job rule, and has no handling for these stations either.

## Matching reports

Cosmic Warbear (electric Pals stop, cannot be forced back despite priority 1);
GammaEuviex (Transporting disrupts Vanwyrm cooling); srvtsonn (hauling over
cooling); poiman (Icelyn ignores cooling 1 for priority-5 work); DSFddaaaa
(generation interrupted). See the comment ledgers.

## Proposed fix (not implemented yet)

Standing demand for continuous station types: per camp, if work objects of
type V exist (camp work list) and the assignment census shows no Pal of that
camp on a V job, count V as having one vacant seat. Limited to types that are
continuous stations (Generating Electricity, Cooling) so that ordinary work
types, whose object counts overstate demand (78 "gathering works" for a few
bushes, see demand.lua), are not affected. Unknown census data adds no demand
(unknown is not "empty"). Regression tests: empty generator gives demand 1;
manned generator gives 0; unreadable census gives 0; trees never get standing
demand. Live acceptance: Grizzbolt returns to the generator within a few passes
after leaving it, with Electricity 1 above its other jobs.

## Long watch, 20:47-21:11 (user building two generators; nightfall and dawn)

Census every ~15 s (`test-results/g4-20261012/generator-watch.txt`; the first
block was reconstructed from the census lines in priority.log after the
background sampler died silently with its output sent to /dev/null).

| Time | Grizzbolt | Notes |
|---|---|---|
| 20:47-20:53:43 | Handiwork (3) | nobody on Electricity, no generator demand announced |
| 20:54:01 | Electricity | game moved it; most likely the workbench queue ran out |
| 20:53:44 on | fenced `-> Generating Electricity` | first fence came AFTER the move: retention, not the mod's doing |
| ~21:01 | not working | nightfall, almost all Pals stop |
| 21:06:54 | Electricity | dawn: back on the generator by itself, stayed through 21:11 |

Generator work objects stayed at 2 the whole time (the two new generators had
not finished or not registered by 21:11). Generating Electricity was announced
0 times all session.

**Reading:** sleep and wake are fine (the game returns the Pal to its station
at dawn and the mod then holds it there). The gap is specific: when a Pal is
pulled off its station onto another job, the mod never sends it back; the game
only does so once that other job ends. The proposed standing-demand fix still
applies, and the live test should be "Grizzbolt pulled onto a long workbench
queue returns to the generator within a few passes after its priorities are
set back", not just "after a night".


## Retraction (21:15)

The user reported that the base has only two generators, the ones being built
from ~20:46, and that they are now full. A clean re-run (Grizzbolt fenced onto
Transporting, then set back to Electricity 1) was started and stopped, since a
full generator offers no work and cannot show anything. Settings restored to
the 2026-10-12 snapshot. The cooling reports (GammaEuviex, srvtsonn, poiman)
stay open but unexplained: this base has no cooler. A valid test needs a station
that is built, not full, and has a consumer draining it.

## Clean observation with a valid empty generator (21:21-21:30)

The user rebuilt the base's two generators and stood in front of them, so the
station state could be read off the screen (Power Capacity) while the census ran.

| Time | Grizzbolt | Generators |
|---|---|---|
| 21:21-21:27:43 | Handiwork 3 (construction) | generator 1 finished ~21:23:40, **0 % and unmanned** for about 4 min |
| 21:27:43 | idle | generator 2 finished |
| 21:27:58 | Electricity 1 | mod fence `-> Generating Electricity` from 21:27:47, holding it there |
| 21:29-21:31 | Electricity | one generator charging (36 %), the other at 0 % |

Generating Electricity was announced 0 times throughout.

**What is real:** a short priority inversion. While another job exists, an
empty generator does not pull a Pal whose top priority is Generating
Electricity, because the game never announces generator work and the mod has
no other signal. It ends when the competing job ends. This is a milder form of
Cosmic Warbear's report; whether the cooling reports are the same cannot be
checked without a cooler.

**Why not fix it now:** a fix needs a trustworthy "this station needs a worker"
read (for a generator, stored energy below full). Counting stations without it
would park Pals at full generators, the mistake retracted above. Reading the
energy value means a new, narrow engine probe (LESSONS: no class dumps; probe
one named property on a copied save). Recommended for 0.5.x, not 0.5.0, unless
the user decides otherwise.

## The signal, and the fix (21:55-22:20)

**Signal found in the modding kit headers and verified live.** A read-only probe
(`!pwp stations`, `Scripts/station_probe.lua`) printed per generator work:
`CurrentState`, the station model's `StoredEnergyAmount` / `MaxEnergyStorage`
(via the work's `CachedOwnerMapObjectConcreteModel` property) and the build
state (`manager:FindModel(work.OwnerMapObjectModelId).BuildProcess.State`; the
model's outer is the map object manager, its own outer path does not lead to
the build process). Checked against the in-game Power Capacity readout:

| Time | Generator A | Generator B | Grizzbolt |
|---|---|---|---|
| 22:00:41 | Building | Building | building |
| 22:00:56 | Completed, 0 | Building | Handiwork (building B) |
| 22:04:47 | Completed, 11,731 | Completed, 0 | Electricity |
| 22:08:13 | Completed, 106,595 / 250,000 | Completed, 0 | Electricity |

`CurrentState` reads Workable for blueprints too, so it is not sufficient;
build Completed AND stored < max is.

**Fix** (`Scripts/stations.lua`, hook in `scheduler.lua` before planning): in
pulse mode, if Generating Electricity is configured and not capped, count the
camp's generators that are Completed and not full, subtract the Pals whose
current job is already Generating Electricity there, and add the remainder as
demand. Any failed or odd read counts as "not needed" (unknown never becomes
demand). `cfg.station_demand = false` switches it off. Tests:
`tests/test_stations.lua` (12 cases incl. full, within margin, unbuilt, model
not found, throwing outer, unreadable values, trees) and three scheduler cases
(empty generator pulls an Electricity-1 Pal off Handiwork 3; none needing adds
nothing; a manned generator is not counted twice). Negative control: with the
hook disabled the first scheduler case fails.

**Live acceptance (22:14-22:20):** after restart the demand line showed
"Generating Electricity 1" (B empty, A manned). Grizzbolt was moved onto
Transporting (Transport 1 / Electricity 4); then set back to Electricity 1 /
Transporting 3 at 22:18:08. The very next pass (22:18:07, the edit pass) fenced
it `-> Generating Electricity` with demand 2, and it was on a generator at
22:18:24, 16 s later, staying there (one short gap while switching). 0 ERROR.
User settings restored to the 2026-10-12 snapshot.

Not covered: coolers (no cooler in this base; no equivalent energy reading is
known for them yet), and the dedicated server (same code path, untested there).

## Dedicated server updated (22:28-22:33)

GPortal "RAM" got the fix through the browser panel this time (the earlier
permission block did not recur): the live `Scripts` was renamed to
`Scripts-before-3893aa6` (backup), `pwp-server-scripts-3893aa6.zip` (git archive
of 3893aa6, 57 Lua files, sha256 ce29f14f...) was uploaded and unzipped in
place. The new `Scripts` holds 57 files; stations.lua, station_probe.lua,
scheduler.lua and main.lua match the commit's sizes byte for byte. Restart from
the panel; the server's UE4SS log shows PWP_READY at 22:32:52 (authority,
settings available) and no PalWorkPriority ERROR. The server base was not
checked for generators; generator behaviour on the server is untested.
