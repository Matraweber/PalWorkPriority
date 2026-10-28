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
  Restored to 1 by hand at 00:08. After that both pits read 1. The game was
  closed overnight; on the next start (2026-10-28 14:07) both pits and every
  rock loaded with state 1 and their default assignability, so the test
  world carries nothing from this round.

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

## Built and run in game (2026-10-28)

The user decided to put this into 0.5.0 and to count a rock as its main drop.
Built as `Scripts/item_sources.lua` plus the scheduler and panel changes (see
DECISIONS). Run on the test world, whose Stone limit is 35,000 and is reached
(46,623 in storage).

| Check | Seen |
| --- | --- |
| First pass after loading | "19 rock(s) held for limits", which is every stone rock (`0009`, `0010`, `0012`) in both camps (11 + 8). Probe: all of them state 2. Ore node, crystal rocks and both pits state 1. Mining wanted 16 to 18, only Lumbering capped. |
| Who mines what, 12 samples at 20 s (`mine_itemlimit.txt`) | **0 of 12 on a stone rock.** Miners on the copper ore node `0002` and crystal rocks `0017`; 3 samples nobody on Mining. |
| Panel | Stone row "Rocks stopped", sub line "Its rocks only". Help line "Mining stops by item, other limits stop their whole job." Ore and Paldium Fragment tiles "Add item limit", others "Add group limit". |
| Stone limit raised to 100,000 | "19 rock(s) released", every stone rock state 1, Mining wanted 29. |
| Back to 35,000 | "19 rock(s) held for limits (+19/-0)" in the same pass. |
| Full game restart | First pass blocked 19 again from Workable. With an empty held list this means the rocks loaded Workable, so the state was not saved. |
| Return to title and load the world again (world change, same process) | Same again: 19 held from scratch. |

Two fixes came out of the run and are tested:

- Turning `item_limits_on_rocks` off now releases rocks that are still held,
  instead of leaving them off until a reload.
- A world change clears the held list.

The help line was added after the first look at the panel.

## Restore (2026-10-28)

- `caps.txt` rows are back to the snapshot: the Stone limit was raised to
  test the release and set back to 35,000.
- `priorities.txt` and the probe file match.
- The launch task is back on `--title`.
- The stone rocks stay held, because the world's own Stone limit is reached.
  That is the new behaviour, and it resets on every load.

## Dedicated server (2026-10-28, GPortal "RAM")

Install, through the GPortal web panel with 0 players online:

- The live `Scripts` (30ee360, from 10-19) was renamed to
  `Scripts-before-34fe913`.
- `pwp-server-scripts-34fe913.zip` was uploaded (git archive of 34fe913, 60
  Lua files, 420.6 KiB, sha256 starts b8eb1bdf) and unzipped in place. The
  panel asks for confirmation; the first try missed that dialog and unzipped
  nothing.
- The listing showed 60 files. `item_sources.lua`, `scheduler.lua`,
  `panel.lua`, `main.lua`, `picker_presentation.lua`, `config.lua` and
  `stations.lua` match the commit's sizes.
- Panel restart. UE4SS log: `PWP_READY` 15:12:51 (authority, settings
  available), no PalWorkPriority warning or error. The base has 1 camp and 9
  Pals, all left to the game. Mining wanted 5.

Test, from the local client joined as a player (`role: client`):

| Time | Seen (server UE4SS log in the panel) |
| --- | --- |
| 15:18:48 | Client `pwp limit Mining Stone 1`, which is "queued; awaiting server confirmation". |
| 15:18:49 | Server: "Mining set Stone to 1 by a player". Rule-change pass: **"3 rock(s) held for limits (+3/-0)"**. Mining wanted dropped from 5 to 2, so Mining was not capped. |
| 15:18:59 | Client `pwp limit`: the row shows "Mining Stone unavailable / 1". The client does not get the server's stock. |
| 15:19:00 to 15:20:45 | 10 passes, each "3 rock(s) held for limits". Mining wanted 1 to 2. |
| 15:20:55 | Client `pwp limit Mining Stone off`. Server: "Mining Stone cleared by a player", then **"3 rock(s) released"**. Mining wanted back to 5. |

This also closes "a client adding a limit on the dedicated server". The
server wrote `caps.txt` at 15:18 and again at 15:20. Now it holds only the
header, and `caps.txt.bak` holds the Stone row.

Not seen in this first round: which Pals mined which rock. The client sees no
work objects of the server base. The second round below closes this.

Found on the way: the `pwp limit` listing still said "legacy group limits".
Reworded after the test; it now names Mining's per-item rule. That change is
in the client install only. The server stays on 34fe913 until the next
upload.

The server log page in the panel froze the browser tab twice (very long
log). Reading it with a single short script right after loading works.

## Dedicated server, second round: who mines what (2026-10-28)

The user asked for the newest code on the server, and for a way to see the
miners there.

**Making Pal Mining visible on the server.**

- Admin rights were not needed. In Palworld you become admin by typing the
  server's admin password in chat (the user would have to do that, Claude
  does not enter passwords), and admin rights do not show which rock a Pal is
  on.
- Instead: new command `pwp rocks` (42f1ead). Per base it prints how many
  rocks and buildings give each Mining item, how many are workable, how many
  a limit holds, and which rock or building each miner's assignment is on.
- It is run on the server through the mod's existing remote channel. The
  server's `remote.txt` (next to the log) was edited in the GPortal file
  editor: a new first line (a nonce) plus `pwp rocks`, then Save.
- The output appears in the panel's UE4SS log page.

**Install.**

- The 34fe913 `Scripts` folder was renamed to `Scripts-before-0fac26c`.
- `pwp-server-scripts-0fac26c.zip` (420.68 KiB) was uploaded and unzipped.
  This needed JS clicks; screenshots of the tab timed out at the 2560 px
  window.
- Then `main.lua` of 42f1ead (138.6 KiB, the only file changed since 0fac26c)
  was uploaded over the old one ("Overwrite").
- Restart. `PWP_READY` at 15:32:37, no warning or error.
- With nobody online the base had 0 work, as before, so the client joined
  for the test.

**Test.**

| Time | Seen in the server log |
| --- | --- |
| 15:38:13 | Client limit Mining Stone 1. "2 rock(s) held for limits (+2/-0)". Mining wanted 4 → 2. One stone rock fewer than in round one, mined out since. |
| 15:39:07 | `rocks: base 1: CopperOre rock 1 workable, 0 held; Stone building 1 workable, 0 held; Stone rock 0 workable, 2 held` / `miners: BOSS_CaptainPenguin -> CopperOre rock [occupied]` |
| 15:40:08 | Same counts / `Plesiosaur -> CopperOre rock [ready]` |
| 15:40:56 | Same counts / `Plesiosaur -> CopperOre rock [occupied]; GrassMammoth -> CopperOre rock [occupied]` |
| 15:41:17 | Client removed the limit: "Mining Stone cleared by a player", "2 rock(s) released". |
| 15:41:45 | `Stone rock 2 workable, 0 held` / `miners: none on a rock or pit right now` |

With the limit on, the server's miners were on the copper ore rock in all 3
samples and never on a stone rock. The Stone Pit (a building) stayed
workable, as designed.

**Left on the server.**

- `remote.txt` holds `rocks-20261028-1543` / `pwp rocks`, which is read-only.
  The previous content was `save-flush-end-200156` / `pwp perf` /
  `pwp perf off` / `pwp status`.
- `caps.txt` has no limits again.
- The server runs 42f1ead.

