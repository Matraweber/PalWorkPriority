---
date: 2026-10-28
tags: [install, release, testing]
status: evidence
---
# Final 0.5.0 build: archives, clean installs, 0.4.1 upgrade, server (2026-10-28)

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [g7-install-2026-10-20](g7-install-2026-10-20.md) · [upgrade-041-2026-10-11](upgrade-041-2026-10-11.md) · [vortex-2026-10-28](vortex-2026-10-28.md)

## Build

The version moved from 0.5.0-rc1 to 0.5.0 (`main.lua`, `Info.json`) and the
changelog was dated. Commit 35366bf was tagged **v0.5.0**, and the commit and
tag were pushed. Before the tag: 228 Lua tests, luacheck and 686 Python tests
(81 skipped) passed.

`tools/release.py --pak LogicMods/PalWorkPriority.pak --pak-sha256 73a312d4…`
output (`build/release-0.5.0/`, not in git):

| Archive | sha256 |
| --- | --- |
| `PalWorkPriority-0.5.0-manual.zip` (Nexus) | `1d7d059ad2986c8778a7a6f8dbb39b7081adc04fb5dfe19f77b4ca6f19c41501` |
| `PalWorkPriority-0.5.0-workshop.zip` | `37be0c843fe0fd85d6e302ee64f1404fdb26ac5f01ed01e320c228ce21beb056` |

- A second build gave the same two hashes, so the build is reproducible.
- Both archives carry the same 60 Lua files byte for byte (the release maps
  `Scripts/config.lua` to `Scripts/default_config.lua` in both) and the same
  pak (`73a312d4…`).
- Neither contains a DLL. `main.lua` reads `VERSION = "0.5.0"`.

## Installs on the final build

Rig: `tools/g7_install_matrix.py` with state
`D:\PalWorkPriority-backups\g7-install-20261028-210039`. The game was closed
through the menus and checked with tasklist before every step. Logs are in
`test-results/g7-final-20261028/` (local).

**A. Clean manual install: PASS.** Nothing installed, no data. Extracted 69
files.

- 21:01:31 "Pal Work Priority 0.5.0 loaded" (one Lua start), `PWP_READY`
  settings available, world load at 21:02:25.
- The world load reported "14 left to the game": a fresh install starts every
  Pal at an equal number.
- No lock and no warning. The pak is mounted: the stand shows priority numbers.
- `priorities.txt` (baseline) and `config.lua` were created.

**C. Clean Workshop install: PASS.** The Workshop item was filled with the
final Workshop archive and switched on.

- The game's loader installed it: `ManagedMods\PalWorkPriority` reports
  version 0.5.0 and the pak is in place.
- 21:03:35 "0.5.0 loaded" (once), `PWP_READY`, no warning, so no false "two
  copies" notice.
- The stand shows priority numbers.

**G2. Upgrade from a real 0.4.1: PASS.**

- 0.4.1 was the original Nexus package (29 files including its own pak). Its
  settings were the files 0.4.1 itself wrote on 2026-10-11 (39 priority rows,
  2 limits). A marker went into its `Scripts/config.lua`:
  `interval_seconds = 11`.
- The final manual archive was extracted over it (69 files).
- 21:09:32 "0.5.0 loaded" (once), `PWP_READY` settings available, world ready.
  0 warnings, no lock, no "restart to edit".
- `priorities.txt` and `caps.txt` are byte-identical to the 0.4.1-written
  files; they were not rewritten.
- The new root `config.lua` carries `interval_seconds = 11`;
  `config.migration.bak` is kept.
- The stand shows the upgraded numbers.
- The 0.4.1 Stone limit acts per item now: "20 rock(s) held for limits".

**Restore.** "restored; dev install, pak and Workshop item identical: True".
The dev install then got the final code with `tools/deploy.ps1`
(`VERSION = "0.5.0"`). The test world's `priorities.txt` and `caps.txt` rows
match the snapshots.

## Dedicated server (GPortal "RAM")

The server ran 42f1ead. The only difference to v0.5.0 in `Scripts` is the
version line of `main.lua`.

- `main.lua` from the tag was uploaded over it (138.59 KiB, "Overwrite") with
  0 players online, then the server was restarted.
- 21:12:35 "Pal Work Priority 0.5.0 loaded", `PWP_READY version=0.5.0`
  authority, settings available. No warning.
- A 0.5.0 client joined: `sync: ready`, protocol schema 4, the server guild
  was recognised, and `pwp limit` showed the server's (empty) list with the
  new wording. The client then left.
