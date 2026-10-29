# Changelog

## 0.5.0 - TBD-at-retag

A reliability release. It fixes the problems reported most since 0.4.1, such
as priorities and X lost after a restart, a second or stuck panel, and Pals
that stopped mining and chopping. Most fixes were tested in the game, in
singleplayer and on a dedicated server. Only automated tests checked the cap
of 500 limits per guild, the stand on a server without the mod or with another
version, the warnings for a missing pak and a second UE4SS, the config reset
notice, old 0.4.1 config values and a BOM in config.lua, rocks after a
respawn, and controller input after the latest fixes.

### Before you update

- **Back up your mod folder first:**
  `<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority`. Your priorities
  and limits carry over on every route.
- **Steam Workshop: write down your changes in `Scripts\config.lua`.** The
  update deletes that file before 0.5.0 can carry it over. Enter them again
  in the new `config.lua` in the mod folder. Options page settings are kept.
- **Old Mining limits now stop only their own rocks.** A Stone limit stops
  the stone rocks and your Pals keep mining ore. Set
  `item_limits_on_rocks = false` for the old behaviour.
- **X priorities that 0.4.1 already lost cannot be brought back.** If an
  older `priorities.txt` still has them, put it back before starting 0.5.0.
- **Server and every player need exactly 0.5.0.** Mixed versions are refused
  and nothing is written. Workshop players update on their own, so update the
  server first or on the same day.
- Your settings move to `config.lua` in the mod folder.
- **Pals you never ranked are now left to the game.** If all of a Pal's jobs
  have the same number, the game picks its work. X and limits still apply,
  and `work_priority` in `config.lua` no longer ranks it. Give a job a
  different number to steer that Pal, or set
  `leave_unordered_pals_to_game = false`.
- **Use one copy: Workshop or manual, not both.** A switched-on Workshop copy
  is installed over a manual install on the next start. Switch it off
  before installing by hand.

### Fixed

**Settings**
- Priorities, including X, survive restarts in singleplayer and on dedicated
  servers, and Pals follow them right after loading without another edit
  (reports by Two Bob Games and johndujo).
- X is no longer dropped when the file is saved (diagnosed with a working
  patch by like in the Steam discussions).
- Many quick edits are saved once, not once per click.
- A settings file that cannot be read is never replaced with defaults.
- If an upgrade had to reset `config.lua`, the panel says so until you have
  opened it.
- Old 0.4.1 values out of 0.5.0's range are moved into range with a warning
  instead of stopping the mod, while you leave that value as it was. A BOM
  in `config.lua` is fine now.
- A wrong value in `config.lua` no longer makes the mod vanish: Alt+F1 says
  which value, and the mod is paused until you fix it.
- A `caps.txt` or `priorities.txt` edited by hand or saved by 0.4.1 is used,
  not an older backup.
- The options page (ESC > Darn Mod Options, needs the optional DarnMenu)
  uses clearer names. Restart the game after a change there.

**Scheduling**
- Priority 1 work wins over priority 5 work (report by HelpImStupid0).
- "Everything stops" / "only one miner" (report by Okami_sama): Pals mine and
  chop again. Rocks and trees now count as work while they can be worked.
  Limits under the "all bases" option no longer flicker to "stock
  unavailable".
- An empty generator and a cooler with food in it pull a Pal with a high
  priority for that work back to it.
- Ranches: a Pal with a high Farming priority goes to an empty ranch again
  (report by Rey).
- Berry and crop harvests count as Gathering work, not ranch work.
- Fishing ponds and labs: a pond with bait and Handiwork research count as
  Handiwork work, so a Pal with a high Handiwork priority goes there (report
  by poiman).
- The staffing limit holds (a maximum of 3 keeps 3 working, not 4).
- Turning the mod off and `!pwp restore` give back the rocks held for Mining
  limits right away.
- Handiwork 1 over Kindling 2 and Grizzbolt on the generator through sleep
  and wake work as set (August reports).

**Production Limits panel and Monitoring Stand**
- Alt+F1 never opens a second panel, and the panel never gets stuck in front
  of the pause menu, inventory or map (report by Extramrdo).
- The lists keep their layout at every size.
- Escape cancels an amount first, then closes only the panel. Dying while
  editing closes the panel.
- The item search and "Show all" no longer crash the game with item mods
  installed (reports by DarkWyrmReaper and NoMo).
- A guild can hold at most 500 limits. More left its players stuck
  connecting.
- The stand legend says what the numbers mean (1 first, X never), what
  clicks, Enter and keys do, that all jobs start equal, and how many Pals
  the mod steers.
- With several bases the panel says which base it counts, and a new limit
  starts above your fullest base.

**Installation**
- A manual install running next to a switched-on Steam Workshop copy of a
  different version is named in the log and on the Production Limits panel
  ("Steam Workshop copy 0.4.1 also on: use one copy"), because the game may
  replace or delete the manual files when that copy updates.
- The mod warns when its pak is missing, and when it finds a `dwmapi.dll` in
  `Pal\Binaries\Win64`, which is usually a second UE4SS. Without the pak the stand still shows numbers, but it cannot be edited and
  the legend says the pak is missing.

**Controller**
- The Monitoring Stand and the Production Limits panel work with a
  controller. On the stand: D-pad moves, LB or A toward 1, RB toward X, X
  sets X, View opens Production Limits (Y stays the game's view switch). In
  the panel: up/down move, Y or right raises a limit a step, left
  lowers it, Y also presses buttons and picks items, LB/RB switch tabs,
  LT/RT turn pages, B closes only the panel. X twice removes a limit. The
  hints on screen switch to the controller version while you play with one.
  A in the panel is taken by the game itself, so use Y there. Tested with a
  virtual XInput pad on the release candidate.

**Multiplayer**
- An edit made by a player survives a server restart.
- Rules stay inside their guild: one guild's limits never apply to another's
  bases.
- Players now see the server's limit status in the panel instead of "No count
  yet". This is why the server and every player need exactly 0.5.0.
- A player with the mod on a server without it gets the normal Monitoring
  Stand back after about a minute, instead of a grid of "?". On a server with
  another version, or with its settings locked, the stand stays read-only
  and says who has to update.
- A join or reconnect is no longer refused as "too many at once", and one
  player's limit edit no longer resets the other players' panels.

### Limits in 0.5.0

Your limits carry over, and you can add, change and remove them as in 0.4.1.

- **Adding a limit takes two clicks.** The first click on an item shows what
  the limit will stop. A second click a moment later adds it. Enter in the
  search box never adds a limit.
- **Removing asks first.** Delete, the remove button or X on a pad shows
  "Sure?". Press it again to remove the limit.
- **Mining limits now work per item.** A reached Stone limit stops only the
  rocks that mainly give stone, and your Pals keep mining ore and crystals.
  Stone Pits and other mining buildings keep producing. Rocks forget it on a
  reload, nothing is saved into your world.
- **Other limits stop their whole job,** once every limit in that job is
  reached.

### Performance

Measured 2026-10-20 on the release candidate, before per-item Mining limits,
with PresentMon on the developer's test base, matched captures with the
profiler off. "Slow frame" = longer than 16.7 ms (below 60 FPS).
- **Normal play:** the mod costs about one slow frame every 10 seconds (its
  scheduling pass, now about 20 ms, was 35 ms). Only while you have limits
  that need stock counts, it adds one frame over 33 ms every 30 seconds (the
  storage count).
- **With the Monitoring Stand open:** about one extra slow frame per second
  while it is open, because the mod redraws the priority numbers once a second.
- 0.5.0 also fixes a hidden cost: on game 1.0.5 a failing name lookup made
  every roster read about ten times slower than needed.

### Not in 0.5.0

Planned for 0.5.x or 0.6:

- Limits per item for buildings (Stone Pit, logging site, furnaces) and for
  work other than Mining. 0.5.0 has them for natural rocks only.
- Faster background saving (built and tested separately, planned for 0.5.x).
- Marking a capped work column on the stand and showing the game's checkbox
  again when the mod turned a permission off.
- Tests with several real players and guilds at once, a physical controller
  and Steam Input, Steam Deck and ultrawide/UI-scale checks.
- Requests: separate priority and limit mods, restricting high-quality stands,
  limits for Pal-produced materials.

### Vortex

Tested with the release candidate and the Palworld extension 0.5.0 on Vortex
1.15.2 (install over 0.4.1 and removal, settings kept) and Vortex 2.9.1
(install and removal). Nexus's own update button was not tested yet. If your
UE4SS comes from the game's mod loader or the Steam Workshop, turn off
"Manage modding requirements (UE4SS, Unreal Pak Tool) automatically" in
Vortex's Settings > Mods, or Vortex installs a second UE4SS. If the game is on another drive than Vortex, use "Suggest" for
the staging folder in the same place. To update from 0.4.1, install 0.5.0
next to it, start the game once, then remove 0.4.1. Your `config.lua` edits
are kept. Vortex's Update or Replace removes 0.4.1's files first, so your
`config.lua` edits are lost that way.

Developer notes, decisions and test evidence are on GitHub, not in the mod
download: [docs/Home.md](docs/Home.md).

## 0.4.1 - 2026-08-28

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
