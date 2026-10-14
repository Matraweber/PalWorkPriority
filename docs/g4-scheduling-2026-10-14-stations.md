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
