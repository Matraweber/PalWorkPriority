# Changelog

## 0.5.0 - 2026-10-28

A reliability release. It fixes the problems reported most since 0.4.1, such
as priorities and X lost after a restart, a second or stuck panel, and Pals
that stopped mining and chopping. Most fixes below were tested in the game, in
singleplayer and on a dedicated server. Only the mod's automated tests checked
the cap of 500 limits per guild, the stand on a server without the mod or with
another version, the warnings for a missing pak and a second UE4SS, the config
reset notice, and controller input after the latest fixes.

### Before you update

- **Back up your mod folder first.** It is
  `<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority` (in Steam,
  right-click Palworld > Manage > Browse local files). Your priorities and
  limits carry over on every route.
- **Steam Workshop: write down any changes you made in
  `Scripts\config.lua`** in that folder. A Workshop update deletes that file
  before 0.5.0 can carry it over. Enter the changes again in the new
  `config.lua` in the mod folder. Settings changed on the in-game options page
  are kept. Extracting the manual zip over 0.4.1 keeps your changes. In
  Vortex, install 0.5.0 next to 0.4.1, start the game once, then remove 0.4.1.
  Your `config.lua` edits are kept that way.
- **Old Mining limits now stop only their own rocks.** A Stone limit from
  0.4.1 stops the stone rocks, and your Pals keep mining ore. Set
  `item_limits_on_rocks = false` in `config.lua` to keep the old behaviour,
  where a Mining limit stops all mining.
- **X priorities that 0.4.1 already lost cannot be brought back.** 0.4.1
  dropped every X row whenever it saved (fixed now). If you have an older copy
  of `priorities.txt` that still has them, put it back before starting 0.5.0.
  0.5.0 reads 0.4.1's files unchanged.
- **Server and every player need exactly 0.5.0.** Mixed versions are refused
  and nothing is written. A 0.4.1 player on a 0.5.0 server gets a chat message
  asking them to update, and a 0.5.0 player on an older server sees "Server
  version incompatible" in the panel. Workshop players update on their own, so
  hosts should update the server first or on the same day.
- Your editable settings move to `config.lua` in the mod folder. With a
  manual install the old file is kept as `config.migration.bak`.
- **Pals you never ranked are now left to the game.** A Pal whose jobs all
  have the same number is no longer steered. The game picks its work, and X
  and production limits still apply. `work_priority` in `config.lua` no
  longer ranks these Pals. Give a job a different number to steer that Pal,
  or set `leave_unordered_pals_to_game = false` to steer every Pal as 0.4.1
  did.
- **Use one copy: Workshop or manual, not both.** If the Steam Workshop copy
  is switched on in the game's mod list, the game installs it over a manual
  install on the next start. Switch it off or unsubscribe before installing
  by hand. 0.5.0 says so in the panel when it finds a switched-on Workshop
  copy of another version.

### Fixed

**Settings**
- Priorities, including X, survive restarts in singleplayer and on dedicated
  servers, and Pals follow them right after loading without another edit
  (reports by Two Bob Games and johndujo).
- X is no longer dropped when the file is saved (diagnosed with a working
  patch by like in the Steam discussions).
- Many quick edits are saved once, not once per click.
- A settings file that cannot be read is never replaced with defaults.
- If an upgrade had to reset `config.lua`, the panel tells you, and the notice
  stays until you have opened the panel.
- Old `config.lua` values that 0.4.1 accepted but 0.5.0 does not are moved
  into range with a warning instead of stopping the mod. A BOM in the file is
  fine now.
- The options page (ESC > Darn Mod Options, needs the optional DarnMenu mod)
  uses clearer names. Restart the game after a change there.

**Scheduling**
- Priority 1 work wins over priority 5 work (report by HelpImStupid0).
- "Everything stops" / "only one miner" (report by Okami_sama): Pals mine and
  chop again. The game announces rocks and trees only once at load, so the mod
  now counts them as work while they can be worked. Limits met under the
  "all bases" storage option no longer flicker to "stock unavailable" between
  passes.
- An empty generator and a cooler with food in it pull a Pal with a high
  priority for that work back to it (the game never announces this work).
- Ranches: a Pal with a high Farming priority goes to an empty ranch again
  instead of being kept on other work (report by Rey: "Lamball reports
  insufficient ranch skill"). More Pals can still graze when they have nothing
  higher to do.
- Berry and crop harvests count as Gathering work, not ranch work.
- Fishing ponds: a Pal with a high Handiwork priority is sent to a waiting
  pond (report by poiman). A pond with bait and a lab running Handiwork
  research now count as Handiwork work.
- The staffing limit holds (a maximum of 3 keeps 3 working, not 4).
- Turning the mod off and `!pwp restore` give back the rocks held for Mining
  limits right away.
- Handiwork 1 over Kindling 2 and Grizzbolt on the generator through sleep
  and wake work as set (August reports).

**Production Limits panel and Monitoring Stand**
- Alt+F1 never opens a second panel and the panel never gets stuck in front
  of the pause menu, inventory or map (report by Extramrdo).
- The lists keep their layout at every size, and the amount editor stays on its
  row and above the page buttons.
- Escape cancels an unfinished amount, and a second Escape closes only the panel.
  Photo mode while editing is clean. Dying while editing closes the panel and
  discards the unsaved amount instead of leaving the editor over the death
  screen.
- Clicks and keys on the stand always change the cell they were pressed on,
  even when the list redraws in between.
- Limits are shown in full up to the 9,999,999 maximum. Only storage counts
  above a million are shortened (12.3M).
- Status words are plain and fit their column. The job column shows one line,
  "Mining (rocks)" for a per-item Mining limit, and Mining rows show their own
  item's state first.
- Keys and pad buttons no longer add or remove a limit by accident while you
  type in a box or the list changes.
- A guild can hold at most 500 limits. More used to leave every member of
  that guild stuck connecting.
- Escape with an armed Remove ("Sure?") cancels it instead of closing the
  panel.
- Raising a limit above the highest step (50,000) no longer sets it to 50,000.
  It keeps the typed value and says so.
- A version mismatch with the server is shown in amber with what to do, on
  both screens. Server error codes are replaced by plain sentences.
- Key hints: "ESC / ALT+F1" and, on the host, Alt+F2 "Recheck now" (as bound
  on the options page), plus a mouse line under the limits. Confirmations name the
  item and say "Saved" or "Sent to the server", and warn when storage already
  holds the new limit. A search with no results says so.
- The Monitoring Stand legend says what left and right click do, that 1
  wraps to X, that a Pal with all jobs equal is left to the game, the number
  keys, the marks (* sending, ! not saved, ? unknown) and Alt+F1. It now has
  a dark backing, so it stays readable on grass.
- The item list no longer counts Pal souls, Ancient Civilization Parts, AI
  Core, Carbon Fiber and similar items as Mining or Lumbering products.
- The item search and "Show all" no longer crash the game with item mods
  installed (reports by DarkWyrmReaper and NoMo, tested with Cosmetic Outfits
  and PalSchema): the game is only asked for the names of items it actually has.

**Installation**
- A manual install running next to a switched-on Steam Workshop copy of a
  different version is named in the log and on the Production Limits panel
  ("Steam Workshop copy 0.4.1 also on: use one copy"), because the game may
  replace or delete the manual files when that copy updates.
- The mod warns when its pak is missing and when it finds a second UE4SS.
  Without the pak the stand still shows numbers, but clicks do not change
  them and the legend says the pak is missing.

**Controller**
- The Monitoring Stand and the Production Limits panel work with a
  controller. On the stand: D-pad moves, LB or A toward 1, RB toward X, X
  sets X, View opens Production Limits (Y stays the game's view switch). In
  the panel: D-pad moves, Y opens or raises, LB/RB switch tabs,
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
  another Pal Work Priority version the stand stays read-only until both
  match.

### Limits in 0.5.0

You can add, change and remove limits as in 0.4.1, and the ones you already
have carry over.

- **Adding a limit takes two clicks.** The first click on an item shows what
  the limit will stop and the amount. A second click a moment later adds it,
  so a very fast double click adds nothing. Enter in the search box never
  adds a limit. A second item in the same work type joins that group.
- **Removing asks first.** Delete, the remove button or X on a pad arms it
  and shows "Sure?". Press it again to remove the limit. If you wait too
  long, the limit is kept.
- **Mining limits now work per item.** A reached Stone limit stops only the
  rocks that mainly give stone, and your Pals keep mining ore and crystals. A
  rock counts as what it mainly drops. Mining stops as a whole only when nothing left to mine is still
  wanted. Stone Pits and other mining buildings keep producing
  while other mining goes on. Switch this off with
  `item_limits_on_rocks = false` (or on the options page) to get the old
  behaviour. Nothing is saved into your world: rocks forget it on a reload.
- **Other limits are group limits:** each one switches its whole work type.
  With several limits in one work type, the work stops only once every one of
  them is reached.

### Performance (measured 2026-10-20 on the release candidate, before per-item Mining limits)

Measured with PresentMon on the developer's test base, matched captures with
the profiler off. "Slow frame" = longer than 16.7 ms (below 60 FPS).
- **Normal play:** the mod costs about one slow frame every 10 seconds (its
  scheduling pass, now about 20 ms, was 35 ms). Only while you have limits
  that need stock counts, it adds one frame over 33 ms every 30 seconds (the
  storage count).
- **With the Monitoring Stand open:** about one extra slow frame per second
  while it is open, because the mod redraws the priority numbers once a second.
- 0.5.0 also fixes a hidden cost: on game 1.0.5 a failing name lookup made
  every roster read about ten times slower than needed.

### Not in 0.5.0 (planned for 0.5.x / 0.6)

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
are kept.

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
