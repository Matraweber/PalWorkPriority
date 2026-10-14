# Continuous stations lose their worker for good (Cosmic Warbear, cooling reports), 2026-10-14

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
