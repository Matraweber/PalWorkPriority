# Pal Work Priority

Work priorities for your base Pals in Palworld. You set them on the Monitoring Stand. A separate Production Limits panel stops work once you have enough of an item.

The mod is made for the Steam version of Palworld on Windows. It was only tested there.

## Quick start

1. **Open a Monitoring Stand.** Every job cell shows a number. 1 is the highest priority, 5 the lowest, and X means the Pal never does that job. Left click a cell to raise it toward 1, right click to lower it toward X. A left click on 1 wraps around to X.
2. **Equal numbers are left to the game.** If every job a Pal may do has the same number, the mod does not steer that Pal and the game picks its work. X jobs stay off. A fresh install starts from the game's ticks. A ticked job becomes 1 and an unticked job becomes X. Give one job a different number and the mod steers that Pal.
3. **Press Alt+F1 for Production Limits.** Click an item once and the panel shows what the limit will stop and the amount. Click it again a moment later to add the limit. A Mining limit stops only the rocks that mainly give that item. Every other limit stops its whole job.
4. **Change settings** in ESC > Darn Mod Options (needs the optional [DarnMenu](#settings)) or in `config.lua` in the mod folder. Restart the game after a change.

Updating from 0.4.1? Read "Before you update" in the [changelog](CHANGELOG.md) first.

## Install

Use one copy only, either the Workshop or the manual zip. If the Workshop copy is switched on in the game's mod list, the game installs it over a manual copy on the next start. 0.5.0 says so in the Production Limits panel when it finds a switched-on Workshop copy of another version. Close the game and back up your world and your mod folder before you install or update.

The mod needs [Experimental UE4SS for Palworld](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587) (Workshop item 3625223587). 0.5.0 was tested on game 1.0.5 with that UE4SS.

To find your Palworld folder, open Steam, right-click Palworld, then Manage > Browse local files. Below it is written as `<Palworld>`.

### Steam Workshop

Subscribe to [Pal Work Priority](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856) and to Experimental UE4SS for Palworld. Switch both on in the game's Mod Management and restart the game.

Your priorities and limits carry over when the Workshop copy updates, and so do settings from the options page. Changes you made in 0.4.1's `Scripts\config.lua` do not, because the update deletes that file first. Write them down before you update and enter them again in the new `config.lua`. In Vortex you can keep them, see [Vortex](#vortex).

### Manual zip from Nexus

1. Subscribe to Experimental UE4SS for Palworld, switch it on in the game's Mod Management and start the game once. After that the folder `<Palworld>\Mods\NativeMods\UE4SS` exists.
2. Close the game. Extract the zip into `<Palworld>` and let it merge the folders. The target must be exactly `<Palworld>`. Some tools add the zip's name as an extra folder at the end of the target. Remove that part before you extract. You get `<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\` and `<Palworld>\Pal\Content\Paks\LogicMods\PalWorkPriority.pak`.
3. Check that `<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\Scripts\main.lua` exists. If it does not, the files went into the wrong folder.
4. Start the game and open a Monitoring Stand. It works when the stand shows numbers and a click changes one. No stand yet? Alt+F1 opens the Production Limits panel, which proves the mod loaded.

When you update, extract the new zip over the old one. Your priorities, limits and `config.lua` stay.

### Vortex

Vortex puts the Nexus zip into the same folders as the manual install. Before you install, open Vortex's Settings > Mods and turn off "Manage modding requirements (UE4SS, Unreal Pak Tool) automatically". Otherwise Vortex adds a second UE4SS under `<Palworld>\Pal\Binaries\Win64`. If Palworld is on another drive than Vortex, put the staging folder on that drive (Vortex offers it with "Suggest"). UE4SS itself still comes from the game's Mod Management, as in step 1 above.

Updating from 0.4.1 in Vortex? Install 0.5.0 next to it, start the game once, then remove 0.4.1. Your `config.lua` edits are kept. If you remove 0.4.1 before 0.5.0 has run once, they are lost.

### Dedicated server (Windows)

The server needs UE4SS too. On GPortal you switch it on in the server panel's modding settings, or you upload it yourself. Only Windows servers work. Linux servers cannot run UE4SS Lua mods. If you host co-op from your own game, your game is the server, and the normal install above is all you need.

1. Stop the server. Back up the world and the old `PalWorkPriority` folder if there is one.
2. From the manual zip, take the folder `Mods/NativeMods/UE4SS/Mods/PalWorkPriority`. It goes into the server's UE4SS Mods folder. On hosts like GPortal that is `Pal/Binaries/Win64/ue4ss/Mods/`. The pak is not needed on the server.
3. Upload it. Copy the folder with the host's file manager or FTP. If your host takes zip uploads, upload the `Scripts` folder as a zip into `PalWorkPriority` and unpack it there into a folder named `Scripts`. Some unzip buttons make a folder named after the zip, so name the zip `Scripts.zip`. Afterwards `.../ue4ss/Mods/PalWorkPriority/Scripts/main.lua` must exist.
4. When you update, copy the new files over the old ones. Do not delete the old `Scripts` folder first. The old settings are read from it once.
5. Start the server. The mod writes `priority.log` in the `PalWorkPriority` folder. That log and the server's UE4SS log should show `Pal Work Priority 0.5.0 loaded` and a line starting with `PWP_READY` that contains `role=authority`.

Server settings live in `config.lua` inside that `PalWorkPriority` folder on the server. Restart the server after a change. The in-game options page has no effect on a server.

The server and every player need exactly 0.5.0. Mixed versions are refused and nothing is written. A 0.4.1 player gets a chat message asking them to update, and a 0.5.0 player on an older server sees "Server version incompatible" in the panel. On a server with another Pal Work Priority version the stand stays read-only until both match. Workshop players get updates on their own, so update the server first or on the same day. A player with the mod on a server without it gets the normal Monitoring Stand back after about a minute.

To remove the mod from a server, set `enabled = false` in the server's `config.lua` and restart the server. Check that its `priority.log` says the work permissions were verified, then stop the server and delete the folder.

## Editing priorities

Clicks wrap around at the ends. A left click on 1 gives X, and a right click on X gives 1.

```text
left click:   X → 5 → 4 → 3 → 2 → 1 → X
right click:  1 → 2 → 3 → 4 → 5 → X → 1
```

You can also type a number. Click a cell or move to it with the arrow keys first, then press 1 to 5. The legend under the stand lists the keys and the marks. `*` is still being sent, `!` was not saved and `?` is unknown. It also reminds you that 1 wraps to X and that a Pal with all jobs equal is left to the game.

A dash means the Pal cannot do that job at all. It is not a priority.

On a server, your edits go to the server, which checks and saves them. Many quick edits are saved once, not once per click.

### Balanced and strict staffing

`assignment_mode = "spread"` (the default) gives every waiting job one Pal before it adds a second Pal to any job. A lower priority job can get its first Pal before a higher one gets its second.

`assignment_mode = "fill"` fills the highest priority job first.

`max_pals_per_work_type` is the most Pals the mod puts on one job (default 3). `false` removes the limit. Neither mode creates work. The game still picks the exact task inside what the mod allows.

## Production Limits

Alt+F1 opens and closes the panel. Click an item once to see what its limit stops and the amount. Click again a moment later to add it. A very fast double click does not add it, and Enter in the search box never adds a limit. To remove a limit, select it and press Delete twice, or click the remove button and then "Sure?". If you wait too long, the limit is kept. Escape first cancels an amount you are typing or an armed remove, a second Escape closes the panel.

In the job column a per-item Mining limit says "Mining (rocks)".

Amounts go up to 9,999,999. A guild can hold at most 500 limits.

**Mining limits act per item on natural rocks.** A reached Stone limit stops only the rocks that mainly give stone, and your Pals keep mining ore and crystals. A rock counts as what it mainly drops. Mining stops as a whole only when nothing left to mine is still wanted. Stone Pits and other mining buildings cannot be stopped on their own yet. Nothing is saved into your world. Rocks forget it on a reload. `item_limits_on_rocks = false` brings back the old behaviour, where a Mining limit stops all mining.

**Every other limit stops its whole job.** A Lumbering limit for Wood stops all lumbering once it is reached. With several limits in one job, the job keeps running until every one of them is reached.

Storage is counted per base by default. `storage_scope = "global"` counts every loaded base of your guild. When the storage cannot be counted, the panel says "No count yet". On a server, the panel shows the server's limit status.

The mod does not start crafting for you. A limit only stops work.

## Settings

Settings come from two places.

- **The options page.** With [DarnMenu](https://www.nexusmods.com/palworld/mods/4245) installed (also on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3769456391)), open ESC > Darn Mod Options. DarnMenu is optional. Its values are saved in `<Palworld>\Mods\NativeMods\UE4SS\Mods\shared\PalWorkPriority_user.lua` and win over `config.lua`.
- **`config.lua`** in `<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\`. The mod creates it on the first start. Leave `Scripts\default_config.lua` alone. An update replaces it.

Restart the game after a change. `!pwp reload` also reads `config.lua` again, but a restart is the safe way.

| Setting | Default | What it does |
| --- | --- | --- |
| `enabled` | `true` | `false` gives every Pal its work back and stops the mod |
| `dry_run` | `false` | Test mode. Logs what it would change and changes nothing |
| `assignment_mode` | `"spread"` | `"spread"` or `"fill"`, see above |
| `max_pals_per_work_type` | `3` | Most Pals on one job, `false` for no limit |
| `leave_unordered_pals_to_game` | `true` | `false` steers every Pal, as 0.4.1 did |
| `item_limits_on_rocks` | `true` | `false` makes Mining limits stop all mining |
| `storage_scope` | `"camp"` | `"global"` counts every loaded base of your guild |

If an upgrade had to reset `config.lua`, the panel tells you. The notice stays until you have opened the panel. Values from 0.4.1 that 0.4.1 accepted but 0.5.0 does not, such as a recheck every 3 seconds, are moved into the allowed range and the log warns about it. A `config.lua` saved with a BOM (some editors add one) is read normally. Keep these files when you update or reinstall. They are all in the `PalWorkPriority` folder.

| File | What it holds |
| --- | --- |
| `priorities.txt` | Your priorities, X included |
| `caps.txt` | Your limits |
| `config.lua` | Your settings |
| `config.migration.bak` | The old `Scripts\config.lua` from a manual upgrade (defaults after a Workshop update) |
| `priority.log` | Command replies and warnings |

The `.tmp`, `.pending` and `.bak` files next to them are recovery copies. Do not edit any of these files while the game runs.

## Controls and commands

| Key | Action |
| --- | --- |
| Alt+F1 | Open or close Production Limits |
| Alt+F2 | Recheck now. Runs a pass and counts storage (not on a client) |
| Alt+F3 | Write base storage to `priority.log` |
| Alt+F5 | Write `Discovery.txt` to the mod folder (useful for bug reports) |
| Alt+F10 | Switch between spread and fill until you restart |
| Alt+F11 | Change the most Pals per job until you restart |
| Alt+F12 | Change how storage is counted until you restart |
| Left / right click | Raise toward 1 (1 wraps to X) / lower toward X on the stand |
| Arrows, Enter | Move and press in the panel |
| Delete twice | Remove the selected limit |
| Escape | Cancel an amount or an armed remove, then close the panel |

Only the six Alt keys F1, F2, F3, F10, F11 and F12 can be changed on the options page.

**Controller.** Tested with a virtual XInput pad on the release candidate. No physical controller or Steam Input run was done, and the latest input fixes were checked only by the mod's automated tests. Plug the pad in before you start the game. On the stand, the D-pad moves, LB or A step toward 1, RB toward X, X sets X and View opens Production Limits (Y stays the game's view switch). In the panel, the D-pad moves, Y opens or raises, X twice removes, LB and RB switch tabs, LT and RT turn pages and B closes the panel. A does nothing in the panel.

Commands go into chat. Their replies are written to `priority.log` in the mod folder and may not show up in the chat itself.

| Command | What it does |
| --- | --- |
| `!pwp help` / `!pwp status` | List the commands, show the mod's state |
| `!pwp run` | Ask for a pass now |
| `!pwp dry` / `!pwp live` | Test mode on or off |
| `!pwp on` / `!pwp off` | Turn the mod on, or off and give every Pal its work back |
| `!pwp restore` | Give every Pal its work back before you remove the mod |
| `!pwp reload` | Read `config.lua` again |
| `!pwp mode` / `!pwp cap` | Staffing mode, most Pals per job |
| `!pwp limit` / `!pwp stock` | List limits, list storage |
| `!pwp rocks` | Rocks held back by limits and who mines what (host or server) |
| `!pwp net` | Connection check with the server |
| `!pwp perf [on\|off\|reset]` | Timing report |

## Troubleshooting

1. **Is UE4SS on?** Look for `<Palworld>\Mods\NativeMods\UE4SS\UE4SS.dll`. After a game start `UE4SS.log` is next to it. An empty `UE4SS` folder is not enough. If the files are missing, switch Experimental UE4SS for Palworld on in the game's Mod Management and start the game once.
2. **Is the mod in the right place?** You need `<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\Scripts\main.lua` and `<Palworld>\Pal\Content\Paks\LogicMods\PalWorkPriority.pak`. If they sit in an extra folder named after the zip, extract again with exactly `<Palworld>` as the target.
3. **Did it load?** Open `<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\priority.log`. It should say `Pal Work Priority 0.5.0 loaded`.
4. **No numbers on the stand?** The mod is not running. Go through steps 1 to 3.
5. **Numbers, but a click changes nothing and the legend says the pak is missing?** Copy `PalWorkPriority.pak` back to `<Palworld>\Pal\Content\Paks\LogicMods\` or reinstall.
6. **Two copies?** Use either the Workshop or the manual zip. The mod warns when it finds a switched-on Workshop copy of another version, and when it finds a second UE4SS, for example one Vortex added under `<Palworld>\Pal\Binaries\Win64`. Remove that one.
7. **"Server version incompatible"?** The server and every player need exactly 0.5.0. Until then the stand is read-only.
8. **A Pal ignores its numbers?** If all its jobs have the same number, it is left to the game. Also check the panel does not say "Mod off" or "Test mode".
9. **A setting does nothing?** Restart the game. On a server, change the server's `config.lua`. Settings changed with Alt+F10, Alt+F11 or Alt+F12 last only until you restart.

For a bug report, send `priority.log` and, if you can, the `Discovery.txt` from Alt+F5.

## Removing the mod

The mod changes the game's saved work checkboxes. If you just delete it, Pals can keep work switched off. Turn it off first.

**Singleplayer or hosting** (no chat needed)

1. Turn "Assign Pals to jobs" off on the options page, or set `enabled = false` in `config.lua`.
2. Start the game, load your world and play for a moment. Every Pal gets its work back and `priority.log` says the work permissions were verified. Jobs you set to X stay off.
3. Save, close the game, then unsubscribe or delete the mod folder and the pak.

With chat you can use `!pwp off` instead of step 1. For a server, see [Dedicated server](#dedicated-server-windows).

## Known limits

- Not tested: two real players in two guilds at the same time, players without the mod editing on a modded server, Steam Deck, a physical controller.
- Checked only by the mod's automated tests, not in the game: the cap of 500 limits per guild, the stand on a server without the mod or with another version, the warnings for a missing pak and a second UE4SS, the config reset notice, and controller input after the latest fixes.
- Limits per item for buildings (Stone Pit, Logging Site, furnaces) and for work other than Mining are not there yet.

## For developers

The project notes are an Obsidian vault, start at [docs/Home.md](docs/Home.md). Test steps are in [docs/testing.md](docs/testing.md), the release record in [docs/RELEASE-0.5.0.md](docs/RELEASE-0.5.0.md) and the decisions in [docs/DECISIONS.md](docs/DECISIONS.md). Public reports are tracked in the [comment census](docs/comment-ledger-2026-09-11.md).

Evidence for the claims above:

- Clean installs, the 0.4.1 upgrade and the server: [g7-final-build-2026-10-28](docs/g7-final-build-2026-10-28.md). The install checks are run again on the final archives.
- Workshop update (priorities and limits kept, old `Scripts/config.lua` edits lost): [g1-workshop-2026-10-20](docs/g1-workshop-2026-10-20.md).
- Vortex 1.15.2 and 2.9.1: [vortex-2026-10-28](docs/vortex-2026-10-28.md).
- Server folder and restarts on GPortal (UE4SS 3.0.1): [restart-persistence-2026-10-11](docs/restart-persistence-2026-10-11.md).
- Controller with a virtual pad: [controller-routes-2026-10-22](docs/controller-routes-2026-10-22.md).
- Per-item Mining limits: [per-item-limits-2026-10-27](docs/per-item-limits-2026-10-27.md).
- Frame costs: [g5-performance-2026-10-19](docs/g5-performance-2026-10-19.md).
- Mixed versions: [g6-version-mismatch-2026-10-19](docs/g6-version-mismatch-2026-10-19.md).
- The 0.5.0 audit: [review-2026-10-28](docs/review-2026-10-28.md) and [review-round2-2026-10-29](docs/review-round2-2026-10-29.md). Fixes retested: [retest-2026-10-29](docs/retest-2026-10-29.md).

`tools/release.py` builds both archives from one commit and checks the pak hash. Run the Lua and Python tests from [docs/testing.md](docs/testing.md) before a build.

## Credits and license

Game-side API understanding was informed by AutoAssignResearchLab, BreedingHelper and [PalPriority](https://www.nexusmods.com/palworld/mods/3830). This is an independent implementation. MIT, see [LICENSE](LICENSE).
