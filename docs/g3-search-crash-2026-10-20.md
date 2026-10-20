---
date: 2026-10-20
tags: [crash, panel, reports]
status: evidence
---
# G3: Search/Add crash with Cosmetic Outfits, 2026-10-20

Related: [search-crash-2026-09-15](search-crash-2026-09-15.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md) · [comment-ledger-2026-09-11](comment-ledger-2026-09-11.md) · [DECISIONS](DECISIONS.md)

Gate (RELEASE G3): with Cosmetic Outfits (Nexus 5049) installed, Search all and
Add run 5 times without a crash, or the attempt is recorded as not
reproducible. Report: DarkWyrmReaper (Nexus, Sep 14), "Add item / search all
aborts to desktop after adding Cosmetic Outfits".

## Setup

- Cosmetic Outfits v10.1 (Nexus manual download, 54,232,240 bytes, sha256
  74ff545c...) and its requirement PalSchema 0.6.71 (author's GitHub release,
  829,883 bytes, sha256 15fd72cc...). Both inspected before installing: JSON
  item definitions, a pak and icons; PalSchema is `dlls/main.dll`. The user
  allowed the downloads.
- PalSchema was present only as a folder with four data mods (its DLL was
  missing, so it was not loading). `tools/g3_cosmetic_setup.py` backed up the
  saves, moved those four aside (they would have gone live with the loader,
  SuperStacksNoLag included), added PalSchema and Cosmetic Outfits, and
  removed them afterwards (107 files; the four data mods restored with equal
  hashes). Backup: `D:\PalWorkPriority-backups\g3-cosmetic-20261020-184742`.
- Build: 6d34f09 for the five rounds, then the fix below.
- PalSchema log: DT_ItemDataTable_Common 58 rows added; mesh table 69 added, 2
  errors ("ABPAssetMap must be a string": the mod is older than game 1.0.5).

## The gate test: PASS

Five rounds in the panel by real clicks (Alt+F1, ITEMS), each with "Show all
craftable items" (off/on, paging to pages 2-5 of 8), a typed search
("outfit", "believer", "cloth", "ore", "seed", "ingot") and selecting a
result (the panel answers "Unavailable: this item cannot have a separate
production limit", as designed for 0.5). No crash, no warning or error in
priority.log, rules and priorities unchanged. A sixth round on the fixed
build also passed. Side note: the "Show all" header once read 194 instead of
195 items while names were loading (the flicker seen in September).

The cosmetic items never appear in the picker: they have no Pal job, and the
picker drops non-job ids before any name lookup (the September 15 change).

## Cause of the crash: a name lookup for an id the game does not have

Probes (temporary `stand_lifecycle_probe.lua`, restored with cmp each time):

- Our catalogue (`DT_ItemDataTable`, a CompositeDataTable over
  `DT_ItemDataTable_Common`) holds 2,537 rows, 71 of them `COSM_`; 13 of those
  (COSM_Nomad02..05 variants) sit in the composite only.
- `items.real_name` for Wood, COSM_Believer, COSM_Doctor returned names; for
  **COSM_Ninja01 the game aborted** ("Abort signal received", crash context
  UECC-Windows-C6EC2106..., stack through UE4SS into the game) at 18:53:32.
- COSM_Ninja01 is **not a row** of the item table (the mod defines COSM_Ninja).
  GetItemName does not return a placeholder for an unknown id: it aborts, and
  pcall cannot catch that. Rows the game cannot name (88 vanilla debug ids)
  return "en Text" instead and are harmless.

Whether 0.4.1 crashed for exactly this reason on the reporter's machine is not
proven (its search localized every catalogue row, and rows are named fine);
the same abort class is the likeliest match for "aborts to desktop".

## Fix: only rows of the item table reach GetItemName

`items.real_name` now checks the id against the row names of the captured
catalogue before the native call; unknown ids return nil (the readable
fallback name is drawn) and are counted in `items.refused_unknown`. An
unreadable catalogue is unknown: no native call and nothing memoized. This
closes the paths that could reach an unknown id in 0.5.0: a legacy limit on
an item a removed mod or a game update took away (the Rules list names every
rule), rules a server with more mods sends a client, and typed commands.

Test `tests/test_items_catalogue.lua`: an unknown id makes no native call, a
known row is named once, `display_name` keeps the readable fallback, an
unreadable catalogue neither names nor memoizes. Negative control with the old
items.lua fails ("unknown id reached GetItemName"). 219 scripts pass.

Live on the fixed build (19:03): COSM_Ninja01 and PWP_DoesNotExist return no
name and the game keeps running; Wood, COSM_Believer and COSM_Nomad02 are
named.
