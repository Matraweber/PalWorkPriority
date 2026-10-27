---
date: 2026-10-27
tags: [limits, release, testing]
status: evidence
---
# Adding limits again (2026-10-27)

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [DECISIONS](DECISIONS.md) · [comment-ledger-2026-09-11](comment-ledger-2026-09-11.md)

## Why

The user asked to "make sure the stock limits work again". On 2026-10-11, 0.5
had locked new limits. Existing limits kept working, but nothing new could be
added, because a limit switches its whole work type.

I read the 8 public comments about limits (rows 3, 4, 17, 31, 38, 62, 75, 76
in the [ledger](comment-ledger-2026-09-11.md)):

- None of them asked for the lock.
- All of them were written on 0.4.1, where adding limits works.
- The one real demand is per-item control (SolidRhoé: stone stops, ore goes
  on). The lock did not deliver that either.

The user picked two steps:

1. 0.5.0 adds limits again, as group limits, clearly labelled.
2. Then research per-item limits and measure BIG DADDY's overshoot.

## Change

- **`caps.support`:** true for every valid work and item.
- **`caps.apply_set`:** no longer refuses a rule that does not exist yet. It
  is stored and enforced like an old one. `scheduler.cap_state` stops the work
  type once every limit on it is reached.
- **Panel texts:**
  - Empty list: "No limits yet. A limit switches its whole work type off once
    reached."
  - Foot row: "Add a limit (browse items)".
  - Item screen help: "Click an item to add a limit (green ones have one)."
  - Item tiles: "Add group limit". A second item in a limited work type says
    "Joins the Mining limits: Mining stops once every one is reached."
  - Remove no longer says "0.5.0 cannot add it back".
- **Tests:** 9 tests now check acceptance instead of refusal. This covers the
  client-to-server path with real caps (accepted, saved, confirmed) and guild
  isolation of a new rule. 227 Lua tests and 686 Python tests pass (81
  skipped).

## In game (singleplayer, test world)

Build: working tree on ecbdcaf plus this change, deployed with
`tools/deploy.ps1`, full game restart.

Starting state: Wood 30,000 and Stone 35,000 (both reached).

| Step | Seen |
| --- | --- |
| Add Red Berries from the item screen | Row "Planting, Red Berries, 50,000, Limit reached". The seed is the top rung because storage held 126,742. Notice: "Saved. Storage already holds 126,742 Red Berries, so this limit is reached." `caps.txt` got `Seeding\|Berries\|50000`. Next pass: Planting left the wanted list, capped 4 to 5, 5 permission requests. |
| Type 200,000 into it | "Saved: Planting limit 200,000 for Red Berries.", "Below limit". Next passes: Planting wanted again. |
| Add Ore (3,146 in storage) | Seeded 5,000, "Below limit". Stone's row went from "Limit reached" to "Others below". Next passes: Mining 34, 32, 33 wanted (none before). |
| Game restart | Both new rows back in the panel. World load: Mining 35 wanted, 2 capped (Wood). |
| About 5 minutes of play over two sessions | Stone 45,864 to 46,051 and Ore 3,146 to 3,152, with the Stone limit itself already reached. The base mines while the group has an item below its limit. |
| Remove Ore (Sure?, then click) | "Removed the Mining limit for Ore." Stone back to "Limit reached". Mining gone from the wanted list. |
| Remove Red Berries | "Removed the Planting limit for Red Berries." |

## Restore

After the test:

- `caps.txt` rows match `caps-before-unlock.txt` again (only the header
  generation differs).
- `priorities.txt` is byte-identical to its snapshot.
- The launch task is back on `--title`.

## Not covered

- A client adding a limit on the dedicated server. The Lua test covers that
  path with real caps, but it has not been run live.
- Overshoot past a limit (BIG DADDY) has not been measured. That is step 2.
