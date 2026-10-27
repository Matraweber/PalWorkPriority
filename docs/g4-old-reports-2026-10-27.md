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
| KhanKeal: Flambelle (Handiwork 1, Kindling 2, Transporting 3, Ranching 4) stays ranching | No Flambelle in this world | **Planning test**, `tests/test_plan_flambelle_ranch.lua`: on the ranch, Handiwork or Kindling work pulls it off; it keeps the ranch only when nothing above Ranching is wanted. |
| KhanKeal: all-1 setup, "random" priorities | not rerun separately | Part of it explained: berry harvests were counted as ranch work (below), so the "farm" demand the scheduler acted on was wrong. |
| Samurai9400: research greyed out | No research lab in either camp | **Not reproducible here.** LabResearch maps to Handiwork. Whether the lab announces its work (or is a silent station like the ranch) is unmeasured. |
| poiman: fishing pools ignored with Handiwork 1 | No fishing pond in either camp | **Not reproducible here.** The game has no fishing suitability (the enum ends at Farming); FishPond (work type 41) stays unmapped until a pond can be measured. |

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
