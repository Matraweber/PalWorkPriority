---
date: 2026-10-30
tags: [release, testing]
status: evidence
---
# Final 0.5.0 build: archives, clean installs, 0.4.1 upgrade, Workshop dry run (2026-10-30)

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [g7-final-build-2026-10-28](g7-final-build-2026-10-28.md) · [perf-final-2026-10-29](perf-final-2026-10-29.md) · [retest-r3-2026-10-29](retest-r3-2026-10-29.md) · [workshop-upload-2026-10-28](workshop-upload-2026-10-28.md)

## Build

- **Tag:** v0.5.0 moved to **1e945db** (CHANGELOG dated 2026-10-30) and force-pushed;
  `git ls-remote` shows the same commit. Only this tag was moved (approved by the user).
- **Tests before the tag:** 250 Lua scripts and luacheck pass; 781 Python tests pass,
  81 skipped.
- **Archives:** `tools/release.py --pak LogicMods/PalWorkPriority.pak --pak-sha256
  73a312d4...` into `build/release-0.5.0/` (the 35366bf build was moved to
  `build/release-0.5.0-35366bf`). The tool packages the commit's blobs, not the disk.

| Archive | sha256 |
| --- | --- |
| `PalWorkPriority-0.5.0-manual.zip` (Nexus) | `bdb10fcb5e1086898ed2fd6d81e08927940c0e324935ebbfb33836eba5f46e8f` |
| `PalWorkPriority-0.5.0-workshop.zip` | `c39cdd89a29e1e75a8ffb9da9c394e781186036d39aaf561d02303773ba33e87` |

- A second build into another folder gave the same two hashes.
- Both carry 60 Lua files, no DLL, `VERSION = "0.5.0"`. The manual archive has 69
  files including `enabled.txt`; the Workshop archive has 67 (the game's loader
  installs it).

## Installs on the final build

Rig: `tools/g7_install_matrix.py`, state `D:\PalWorkPriority-backups\g7-install-20261030-112343`.
The game was closed through the menus and checked with tasklist before every step.
Every archive passed the new check: its hash matches its `release.json`, and the
manifest's `source_commit` is the commit tag v0.5.0 points at.

**A. Clean manual install: PASS.** 69 files extracted.
- 11:24:29 "Pal Work Priority 0.5.0 loaded" (once in the UE4SS log), `PWP_READY`
  settings available, world load at 11:25:22 with "14 left to the game" (fresh install,
  every Pal equal).
- No warning, so no missing-pak warning. `config.lua` and `priorities.txt` were created.

**C. Clean Workshop install: PASS.** The Workshop item was filled with the Workshop
archive and switched on.
- The game's loader installed it: `ManagedMods\PalWorkPriority` reports 0.5.0, and the
  pak in `LogicMods` matches the asset contract (73a312d4...).
- 11:26:30 "0.5.0 loaded" (once), `PWP_READY`, no warning, so no false "two copies"
  notice.

**G2. Upgrade from a real 0.4.1: PASS.**
- The original 0.4.1 Nexus package (29 files, sha256 35300098...) was installed and run
  once. Its `Scripts/config.lua` got the marker `interval_seconds = 11`.
- Settings: the files 0.4.1 itself wrote on 2026-10-11 (39 priority rows, 2 limits; no
  0.5 envelope), the same set as on 2026-10-28.
- The final manual archive was extracted over it (69 files).
- 11:37:13 "0.5.0 loaded" (once), `PWP_READY`, world ready, 0 warnings.
- `priorities.txt` and `caps.txt` are byte-identical to the 0.4.1-written files.
- The new root `config.lua` carries `interval_seconds = 11`; `config.migration.bak`
  is kept.
- The 0.4.1 Stone limit acts per item: "17 rock(s) held for limits".

**Restore:** "restored; dev install, pak, Workshop item and ManagedMods identical: True".
The manual archive's `INSTALL.txt` was moved from the game root into the state folder.

Logs: `test-results/g7-final-20261030/` (local).

## Workshop staging and dry run

- `tools/workshop_upload.py prepare`: staged 67 files of the Workshop archive in
  `D:\PalWorkPriority-workshop\stage\PalWorkPriority` (older stage moved to
  `stage-before-20261030-113914`). Live version 0.4.1, item 3786408856.
- Change note from CHANGELOG.md at v0.5.0: 7,958 of 8,000 bytes. Left out (linked
  instead): Performance, Not in 0.5.0, Vortex. The panel section is in.
- `upload --dry-run`: the uploader opened the stage, selected "PalWorkPriority 0.5.0",
  filled in the 7,958-byte note and cancelled. Nothing was sent.

## Server

GPortal "RAM" runs 99a2e26. The tag differs from it only in `panel.lua` (the client-side
hover fix) and docs. A 0.5.0 client joined on 2026-10-29 with "sync: ready" in 5 s.

## Left for the user

`python tools/workshop_upload.py upload`, then press OK in the uploader, then
`python tools/workshop_upload.py check`. Nexus upload of the manual archive by hand.
