---
date: 2026-10-28
tags: [limits, research, testing]
status: evidence
---
# Per-item limits: first research round (2026-10-27/28)

Related: [limits-unlock-2026-10-27](limits-unlock-2026-10-27.md) · [DECISIONS](DECISIONS.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md)

This is step 2 of the user's choice. The goal is a limit that stops one
product while others of the same work type continue (SolidRhoé: stone stops,
ore continues). Today a limit can only switch Pals' permission for a whole
work type. This round looked for a control at the level of single work
objects.

The probe and sampler are in `tools/research/`. Raw rows (local, not in git)
are in `test-results/per-item-20261027/`.

## Every work object names its product

Headers: [PalworldModdingKit](https://github.com/localcc/PalworldModdingKit),
`Source/Pal/Public`. The probe (`tools/research/product_probe.lua`, run
through the temporary probe file) read this on game 1.0.5:

| Work | Class / owner model | Product read from | Example |
| --- | --- | --- | --- |
| Natural rock | `PalWorkCollectResource` / `PalMapObjectItemDropOnDamagModel` | model `DropItemInfos` (item, count) | `DamagableRock0002` drops CopperOre 40 (an ore node). `0009`, `0010` and `0012` drop Stone 50, Pal_crystal_S 5 and CopperOre 2. `0017` drops Pal_crystal_S 5. |
| Stone pit, logging site | `PalWorkProgress` / `PalMapObjectProductItemModel` | `GetProductItemId()` | Stonepit gives Stone. StationDeforest2 gives Wood. |
| Furnace, workbench, factory | `PalWorkProgress` / `PalMapObjectConvertItemModel` | `GetCurrentRecipeId()` | CampFire Baked_Berries, Factory_Hard_01 Cloth, SphereFactory PalSphere_Giga, None when idle |
| Trees | `PalWorkDeforestFoliage` | (no owner model) | not read yet |

So for every mining work the mod can tell what it yields. Natural rocks yield
several items (stone rocks also drop 2 ore). A per-item rule has to decide
which of those items counts.

Assignability by default: rocks and trees `AssignableFixedType` 1
(FreeOnly), buildings 0 (Both). `CurrentState` is 1 (Workable) everywhere.

## Lever 1: `AssignableFixedType` = Cannot does not work

At 23:54 `AssignableFixedType` was set to 3 (Cannot) on every stone rock and
both stone pits. The probe read the value back as 3, and it stayed 3.

In 12 samples over 4 minutes (`mine_sample.py`, the native assignment of every
Pal on Mining, matched to the work's id), Pals stayed on stone rocks and also
newly took them (Baphomet, BOSS_GrassMammoth and Plesiosaur on `0009` and
`0010`). The automatic assignment does not read this property, so it is
**rejected**. Restored to 1 for rocks and 0 for pits.

## Lever 2: `CurrentState` = NotWorkable works

The game uses this state itself, for example a fishing pond without bait is 2.
At 23:59 it was set to 2 on the same stone rocks and pits.

| Window (20 s samples) | Pals on stone works | On other Mining works |
| --- | --- | --- |
| Before, 8 samples | 1 sample (Baphomet and GrassMammoth on `0009`) | 6 samples on the ore node `0002`, 1 empty |
| Cannot, 12 samples | 12 of 12 | 3 samples crystal rock |
| NotWorkable, 12 samples | **0 of 12** | crystal rocks (`0017`) 3, ore node 1, one new rock id, 7 nobody on Mining |

The game kept state 2 for the whole window and did not set it back.

A rock that was mined out and grew back came back as a new work with state 1.
A real control has to reapply its state on every pass, which the scheduler
pass does anyway.

## Is the state saved? Rocks no, buildings yes

After a save and reload (return to title, quit, start):

- **Rocks:** all back to state 1. The state is not saved, so a crash or an
  uninstall cannot leave a rock blocked.
- **Stone pits:** still state 2 after the reload, while their own model said
  `bIsWorkable=true`. **The state of a building's work is saved.** If the mod
  set a pit NotWorkable and was then removed, the pit would stay idle.
  Restored to 1 by hand at 00:08. After that both pits read 1. A second
  reload to confirm 1 was not done, because the restart script stopped (the
  game did not exit and another session was using the PC).

## What this means for a design

1. **Natural rocks:** per-item control is possible. Mark rocks whose drop
   list contains the limited item NotWorkable while the limit is reached,
   reapply every pass, and leave the rest alone. Nothing is saved.
   - Open: which drops count. A stone rock also drops 2 ore. Most likely
     answer: count the main drop, the first entry with the largest count.
2. **Buildings (pits, logging sites, converters):** the same lever works but
   writes into the save. Before using it there:
   - Find a lever that is not saved, or
   - Restore the state before every save and on shutdown. Research needed,
     and it does not cover a crash.
   - Until then, buildings stay with the group limit.
3. **Trees:** the owner model is missing, so the product is not known yet.
   Trees give Wood, and only one product would matter here.
4. **Converters:** a per-item limit there means "pause this recipe", which
   could use the same lever (also saved) or the recipe request itself.
   Not tried.

## Overshoot (BIG DADDY)

Not measured this round. This base mines too slowly:

- 5 minutes of mining with the group open gave Stone +5 and +16 and Ore +0 in
  the two camps (`stock_baseline.txt`).
- Most Pals haul, and dropped stone waits for transport.

An explanation that needs no measurement: with a group of Stone and Ore
limits, mining continues while one of them is short. So the other item keeps
rising past its number. That fits "ore at about twice its limit while mining
continues". The README states it. Per-item control on rocks would remove this
case. A measurement needs a base with dedicated miners. It is still open.

## Restore

The test world was checked after the run:

- All rocks read `AssignableFixedType` 1 and `CurrentState` 1. Both pits read 0
  and 1.
- The temporary Ore limit (5,000, so that Mining would run) was removed again
  with the limit command. `caps.txt` rows and `priorities.txt` match the
  snapshots.
- The probe file matches the original.
- The launch task is back on `--title`.
