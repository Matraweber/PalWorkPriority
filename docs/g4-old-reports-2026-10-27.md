---
date: 2026-10-27
tags: [scheduling, reports, testing]
status: evidence
---
# Old Pal reports rerun on rc1, 2026-10-27

Related: [g4-scheduling-2026-10-14-stations](g4-scheduling-2026-10-14-stations.md) · [g4-scheduling-2026-10-16-coolers](g4-scheduling-2026-10-16-coolers.md) · [comment-ledger-2026-09-11](comment-ledger-2026-09-11.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md)

Singleplayer, Palpagos Islands test world, build 0.5.0-rc1 plus the fixes
below, on `reliability-0.5`. The rerun the user picked on 2026-10-21: KhanKeal's
Pupperai, Flambelle and all-1 setups, Samurai9400's research, Rey's Lamball and
ranch, poiman's fishing pools. Raw data:
[test-results/g4-20261027/](../test-results/g4-20261027/) (local, not in git).
The assignment census (`pwp assignments`) was sampled every 20 s by
`sample_pal.py`, next to the scheduler's fence and "wanted" lines.

## Results

| Report | Setup here | Result |
| --- | --- | --- |
| KhanKeal: Pupperai ignores Lumbering 1 | Verdash, Lumbering 1, Gathering 2, Transporting 3, Planting X | **PASS.** 9 samples over 3 min: occupied on Lumbering (7) every time, fence Lumbering. |
| Rey: Lamball "insufficient ranch skill" | Lamball swapped into the base (Anubis out), camp 1 has a ranch | **Reproduced, fixed.** Before: the ranch never counted as work, Lamball was fenced to Transporting only, the ranch stood empty. After: with Farming 1 Lamball moved to the ranch within 25 s and stayed (17 samples over two game starts). |
| KhanKeal: Flambelle (Handiwork 1, Kindling 2, Transporting 3, Ranching 4) stays ranching | Round 1: none in the world. Round 2: caught one (Creative Menu), swapped in for Braloha | **Reproduced, explained, partly fixed.** Round 1 planning test (`tests/test_plan_flambelle_ranch.lua`). Round 2: grazing in 9 of 9 samples while the pond waited untyped. After the pond fix she still grazes while the Handiwork seats are taken (Incineram, Anubis or Grizzbolt on Handiwork); "Handiwork 1" appeared and was filled by another Pal within a pass. |
| KhanKeal: all-1 setup, "random" priorities | not rerun separately | Part of it explained: berry harvests were counted as ranch work (below), so the "farm" demand the scheduler acted on was wrong. Changed by the user's decision: an all-1 Pal is now left to the game. |
| Samurai9400: research greyed out | Round 2: lab built, Handiwork research started | **Not reproduced.** Typed correctly by subject (`Lab_Handcraft_1` -> Handiwork); Incineram, fenced to Handiwork, was on Handiwork (suitability 5) while the research ran; its job id was not matched to the lab. The lab is silent; now counted. |
| poiman: fishing pools ignored with Handiwork 1 | Round 2: pond built, bait and target set; Anubis Handiwork 1, Mining 2, Transporting 3 | **Reproduced, fixed.** The pond's work was untyped (never work). Before: Anubis on Handiwork in 2 of 9 samples. After typing it: 6 of 9. Pond is silent; now counted. |

## Found on the way: berry harvests counted as ranch work

The 2026-10-17 census listed a plantation's crop job with no declared type
(`OverrideWorkType` 0), the display name "Harvest" and the station id
`FarmBlockV2_Berries_*`. "Harvest" is not a suitability label, so typing fell
through to the station id, and the "farm" keyword made it ranch work. Ranch
Pals were sent toward berries, and Gathering demand was undercounted.
`workdefs.BY_LABEL["harvest"] = "Collection"` fixes it.

Discovery after the fix (11:11): every berry harvest resolves as Gathering. The
only MonsterFarm work left is the real ranch (`MonsterFarm_0`, "Grazing",
class `PalWorkMonsterFarm`). The single unresolved work is an "Idle" placeholder
(`None | Idle | PalWorkProgress`), which is correct to skip.

## The ranch: a silent station

The ranch work is Workable (`CurrentState` 1) the whole time and was announced
0 times in the session, the same as generators, coolers, trees and rocks
([g4-scheduling-2026-10-14-stations](g4-scheduling-2026-10-14-stations.md)).
Its model is `PalMapObjectMonsterFarmModel`. Neither the work nor the model has
a capacity field, so the fix counts **one seat per built, Workable ranch**, the
rule the other stations use. Guides disagree on the real capacity (most say
four Pals graze at once, one says five), and unknown must not become demand.

Lamball before the fix, default priorities (Transporting 1, Farming 5):

    fenced: ... SheepBall -> Transporting; ...
    wanted: Transporting 53, Lumbering 9, Gathering 3, Cooling 1

After `stations.ranches_needing` (game restarted 11:25):

    wanted: Transporting 180, Gathering 52, Lumbering 11, Watering 3, Cooling 1, Farming 1

With default priorities Lamball still hauls, because spread mode serves each
Pal's priority 1 before its priority 5 and there is hauling to do. That is the
rule as written; vanilla would let it graze. Open question for the user, not
changed. With Farming 1 (Rey's intent) the fence became Farming + Transporting
and the native assignment went to suitability 13 (Farming) within 25 s.

Second gap: a ranch worker's current suitability reads unavailable (the same
was seen on the server on 2026-09-25), so a manned ranch was never subtracted
and "Farming 1" stayed wanted. The scheduler now also counts a Pal whose
assignment record is occupied on that type. Restart at 11:31: Lamball occupied
on Farming in all 8 samples and Farming gone from "wanted".

Output was not checked (no wool count); the evidence is the native assignment.

## Test world restored

Verdash's priorities and the Wood limit (30000) match the snapshots taken
before the test (`priorities-before.txt`, `caps-before.txt`); Lamball's
Farming back to 5; Anubis back in the base, Lamball back in the party. The
temporary probe file was restored and checked with `cmp` after each use.

## Round 2: lab, pond and Flambelle (same day, user's request)

How the world got there, all in the test world:

- Tech: Pal Labor Research Lab (level 19), Cement, Cryogenic Coolant,
  Production Assembly Line and Fishing Pond (level 31) unlocked with
  technology points. The character needed level 31; experience was given with
  `PalUtility.GiveExpToAroundPlayerCharacter` and overshot to **level 64**
  (cannot be undone, see LESSONS).
- The cheat manager (UE4SS enablers switched on for the session, switched off
  again after) turned out to be stubbed: `AddPlayerExp`, `SpawnMonster` and the
  debug add-item calls did nothing. The installed Creative Menu mod (F1) gave
  60 Cement, 5 Cryogenic Coolant, 20 Wooden Board and 50 Simple Bait, and
  placed a level 1 Flambelle, caught with a sphere.
- Built in camp 1: the lab, a High-Quality Workbench, a fishing pond.
  Movement by `K2_TeleportTo` and `SetControlRotation` through the temporary
  probe file (restored and checked with `cmp` after each use).

### Measured

| Work | AssignDefineDataId / GetWorkName / class | Declared type | State |
| --- | --- | --- | --- |
| Fishing pond | `FishingPond1_0` / "Fishing" / `PalWorkFishPond` | 0 | 2 while it has no bait and fish target, 1 with them |
| Research | `Lab_Handcraft_1` / "Research" / `PalWorkLabResearch` | 0 | 1 while a research runs; no work at all otherwise |
| Construction | `BuildWork_0` / "Construction" / `PalWorkProgress` | 0 | 1 while a blueprint stands (untyped, not changed) |

The pond's build tooltip: "Requires Pals that can work with their hands",
Handiwork icon. The first research must be the subject's root node; the
other nodes' Begin button does nothing until it is done. Discovery after the
pond typing: Handiwork wanted 2 at world load (pond and lab), never again in
the next three minutes while the pond's Pal came and went: silent, like the
ranch. `GetWorkAssignInfo` and `GetAssignedCharacters` return arrays that
UE4SS cannot read, so per-work occupancy is not available.

### Fixes

- `workdefs.BY_LABEL["fishing"] = "Handcraft"`.
- `stations.ponds_and_labs_needing`: one seat per built, Workable pond or
  Handiwork research lab, picked by class.
- Untouched Pals left to the game (user's decision, see DECISIONS). After the
  restart: "8 left to the game" in the tick line.

### Samples (20 s, 9 each)

| Run | Anubis (Handiwork 1, Mining 2, Transporting 3) | Flambelle (Handiwork 1, Kindling 2, Transporting 3, Ranching 4) |
| --- | --- | --- |
| Before (pond untyped) | Handiwork 2/9, Transporting 5/9, unavailable 2/9 | Grazing 9/9 |
| Pond typed | Handiwork 6/9, unavailable 3/9 | Grazing 9/9; Handiwork wanted only at load |
| Pond counted, Anubis Handiwork X | (not sampled) | Grazing 9/9; Grizzbolt (untouched, left to the game) was on Handiwork with the research finished, so at the pond or a workbench; Handiwork wanted 1 once, filled within a pass |

Flambelle's case is therefore not "the mod sends her to the ranch": the mod
allows Farming only while it is her held job and nothing at Handiwork,
Kindling or Transporting has a free seat for her in that spread lap. When the
pond stood invisible, that was always the case; now it is the case only while
another Pal holds the Handiwork seat. The pass that would withdraw Farming is covered by the
planning test; it was not caught live because untouched Pals take the Handiwork seat
first.

### Round 2 restore

Anubis back to Handiwork 3, Mining 4, Transporting 2 and Flambelle's rows
cleared: `priorities.txt` and `caps.txt` match the morning snapshots. Braloha
back in the base, Flambelle kept in the party (not released). UE4SS
`mods.txt`/`mods.json` restored from the copies taken before (cheat and
console enablers off again). The lab, workbench and pond stay built; the
unlocked technologies, level 64 and the given items stay.
