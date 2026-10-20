# Changelog

## 0.5.0 - DRAFT, not released yet

A reliability release. It fixes the problems reported most since 0.4.1:
priorities and X lost after a restart, a second or stuck panel, and Pals that
stopped mining and chopping. Every fix below was tested in the game
(singleplayer, and on a dedicated server where it concerns multiplayer).

### Before you update

- **Back up your mod folder first** (`priorities.txt`, `caps.txt`,
  `config.lua`). The Workshop updater can replace the old Scripts folder before
  0.5.0 gets to migrate your settings.
- **X priorities that 0.4.1 already lost cannot be brought back.** 0.4.1
  dropped every X row whenever it saved (fixed now). If you have an older copy
  of `priorities.txt` that still has them, put it back before starting 0.5.0;
  0.5.0 reads 0.4.1's files unchanged.
- **Server and every player need 0.5.0.** Mixed versions are refused and
  nothing is written: a 0.4.1 player on a 0.5.0 server gets a chat message
  asking them to update, and a 0.5.0 player on a 0.4.1 server sees "Server
  version incompatible" in the panel.
- Your editable settings move to `config.lua` in the mod folder; the old file
  is kept as `config.migration.bak`.

### Fixed

**Settings**
- Priorities, including X, survive restarts in singleplayer and on dedicated
  servers, and Pals follow them right after loading without another edit
  (reports by Two Bob Games and johndujo).
- X is no longer dropped when the file is saved.
- Many quick edits are saved once, not once per click.
- A settings file that cannot be read is never replaced with defaults.

**Scheduling**
- Priority 1 work wins over priority 5 work (report by HelpImStupid0).
- "Everything stops" / "only one miner" (report by Okami_sama): Pals mine and
  chop again. The game announces rocks and trees only once at load, so the mod
  now counts them as work while they can be worked; and limits met under the
  "all bases" storage option no longer flicker to "stock unavailable" between
  passes.
- An empty generator and a cooler with food in it pull a Pal with a high
  priority for that work back to it (the game never announces this work).
- The staffing limit holds (a maximum of 3 keeps 3 working, not 4).
- Handiwork 1 over Kindling 2 and Grizzbolt on the generator through sleep
  and wake work as set (August reports).

**Production Limits panel and Monitoring Stand**
- Alt+F1 never opens a second panel and the panel never gets stuck in front
  of the pause menu, inventory or map (report by Extramrdo).
- The lists keep their layout at every size; the amount editor stays on its
  row and above the page buttons.
- Escape cancels an unfinished amount; a second Escape closes only the panel.
  Photo mode while editing is clean. Dying while editing closes the panel and
  discards the unsaved amount instead of leaving the editor over the death
  screen.
- Clicks and keys on the stand always change the cell they were pressed on,
  even when the list redraws in between.
- Large limits are shown short: 9,999,999 reads as "10.0M".

**Multiplayer**
- An edit made by a player survives a server restart.
- Rules stay inside their guild: one guild's limits never apply to another's
  bases.

### Limits in 0.5.0

Limits you already have keep working as **legacy group limits**: each one
switches its whole work type (a Stone limit also stops ore mining). **New
limits cannot be created in 0.5.0**; limits per item come in 0.6. If you remove
a legacy limit, it can only be added back through `work_caps` in `config.lua`.

### Performance (measured)

Measured with PresentMon on the developer's test base, matched captures with
the profiler off. "Slow frame" = longer than 16.7 ms (below 60 FPS).
- **Normal play:** the mod costs about one slow frame every 10 seconds (its
  scheduling pass, now about 20 ms, was 35 ms). Only while you have limits
  that need stock counts, it adds one frame over 33 ms every 30 seconds (the
  storage count). All other stutter we measured comes from the game itself.
- **With the Monitoring Stand open:** about one extra slow frame per second
  while it is open, because the mod redraws the priority numbers once a second.
- 0.5.0 also fixes a hidden cost: on game 1.0.5 a failing name lookup made
  every roster read about ten times slower than needed.

### Not in 0.5.0 (planned for 0.5.x / 0.6)

- Limits per item (stop stone while ore continues).
- Faster background saving as the default (built and tested separately; off
  in 0.5.0).
- Marking a capped work column on the stand, showing the game's checkbox
  again when the mod turned a permission off, and a mouse and controller
  button legend.
- Tests with several real players and guilds at once, Steam Deck and
  ultrawide/UI-scale checks.
- Requests: separate priority and limit mods, restricting high-quality stands,
  limits for Pal-produced materials.

### Still being checked before release

- [OPEN] Search/Add crash reported together with the Cosmetic Outfits mod
  (DarkWyrmReaper).
- [OPEN] Updating through the Steam Workshop (the manual Nexus route is
  tested and keeps every saved row).
- [OPEN] Vortex install, update and removal.

Developer notes, decisions and test evidence: [docs/Home.md](docs/Home.md).

## 0.4.1 — published August 28, 2026

Historical implementation summary, with September audit corrections:

- Added cheaper authority evidence and owned-component lookup routes, an early no-camp exit and Monitoring Stand tree traversal.
- Reduced repeated panel property writes and added headless/controller guards.
- Added `!pwp perf` and `!pwp stand` diagnostics.

Earlier release text overstated the outcome. The tests did not establish that all expensive lookups disappeared, all client clicks became cheap or gameplay was stutter-free. Some profiler rows counted calls without timing them and displayed zero milliseconds. Complete pass cost and external frame captures were missing; nested timing totals overlapped. The earlier headless guard also did not establish that all polling recognized a populated server correctly.

Historical long-session object scans were observed around 36–45 ms, but those observations are not a candidate benchmark or a current-runtime guarantee. Continued periodic stutter, settings loss and UI failures are tracked in the September ledger. The rules/picker pager overlap was not resolved by this release.

The saved August UE4SS log names `c838a8ac`; September's dependency advertised `2281fa31`. Compatibility with the newer runtime does not follow from the August tests.

## 0.4.0

- Added authoritative-server scheduling and client grid/rule synchronization. A client-only installation cannot replace the server mod.
- Changed fence widening to retain higher-priority permissions, addressing a cause implicated in generator and Handiwork/Kindling reports.
- Added restoration routes when disabling scheduling.
- Added temporary-file persistence and validation, reduced several icon lookup/logging paths, adjusted panel drawing and feedback.
- Tightened guild authorization and chat mutation routing, isolated the DarnMenu settings environment and bounded incoming client data.
- Made the developer remote channel opt-in at startup.

Corrections to the original release claims:

- Temporary-file writing was **not** crash-proof: ordinary write/close failures and destructive replacement remained. The statement that “a crash costs nothing” was wrong.
- Retaining a priority in a fence did not prove a Pal actually worked that station or produced output. Generator displacement, manual assignments and research still need native evidence.
- Removing specific icon lookup work did not prove the picker or the whole game could no longer stutter.
- The release lacked protocol negotiation; mixed versions and incomplete synchronization were not fully covered.
- Pager overlap, UI lifecycle risks and restart persistence defects remained.

## 0.3.0

Added optional DarnMenu settings/hotkeys, in-game item names and `tools/pakcheck.py` after an earlier asset packaging error. Hash matching can catch a mismatched artifact; it does not verify a native widget contract.

## 0.2.0

Shipped with a stale pak: only 7 of 21 expected named widgets resolved in the historical test. The asset mismatch was addressed in 0.3.0. Clean-package mounting and widget acceptance remain required for every new release.
