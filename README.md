# Pal Work Priority

Work priorities for your base Pals in Palworld. You set them on the Monitoring Stand. A separate Production Limits panel stops work once you have enough of an item.

The mod is made for the Steam version of Palworld on Windows. It was only tested there.

## Quick start

1. **Open a Monitoring Stand.** Every job cell shows a number. 1 is the highest priority, 5 the lowest, and X means the Pal never does that job. Left click a cell to raise it toward 1, right click to lower it toward X.
2. **Equal numbers are left to the game.** If every job a Pal may do has the same number (a fresh install starts at all 1), the mod does not steer that Pal and the game picks its work. Give one job a different number and the mod steers that Pal.
3. **Press Alt+F1 for Production Limits.** Click an item once and the panel shows what the limit will stop and the amount. Click it again to add the limit. A Mining limit stops only the rocks that mainly give that item. Every other limit stops its whole job.
4. **Change settings** in ESC > Darn Mod Options (needs the optional [DarnMenu](#settings)) or in `config.lua` in the mod folder. Restart the game after a change.

Updating from 0.4.1? Read "Before you update" in the [changelog](CHANGELOG.md) first.

## Install

Use one copy only, either the Workshop or the manual zip. If the Workshop copy is switched on in the game's mod list, the game installs it over a manual copy on the next start. 0.5.0 says so in the Production Limits panel when it finds both. Close the game and back up your world and your mod folder before you install or update.

The mod needs [Experimental UE4SS for Palworld](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587) (Workshop item 3625223587). 0.5.0 was tested on game 1.0.5 with that UE4SS.

To find your Palworld folder, open Steam, right-click Palworld, then Manage > Browse local files. Below it is written as `<Palworld>`.

### Steam Workshop

Subscribe to [Pal Work Priority](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856) and to Experimental UE4SS for Palworld. Switch both on in the game's Mod Management and restart the game.

Your priorities and limits carry over when the Workshop copy updates, and so do settings from the options page. Changes you made in 0.4.1's `Scripts\config.lua` do not, because the update deletes that file first. Write them down before you update and enter them again in the new `config.lua`. The same is true when you remove 0.4.1 in Vortex.

### Manual zip from Nexus

1. Subscribe to Experimental UE4SS for Palworld, switch it on in the game's Mod Management and start the game once. After that the folder `<Palworld>\Mods\NativeMods\UE4SS` exists.
2. Close the game. Extract the zip into `<Palworld>` and let it merge the folders. You get `<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\` and `<Palworld>\Pal\Content\Paks\LogicMods\PalWorkPriority.pak`.
3. Start the game. The stand should show numbers.

When you update, extract the new zip over the old one. Your priorities, limits and `config.lua` stay.

### Vortex

Vortex puts the Nexus zip into the same folders as the manual install. Before you install, open Vortex's Settings > Mods and turn off "Manage modding requirements (UE4SS, Unreal Pak Tool) automatically". Otherwise Vortex adds a second UE4SS under `<Palworld>\Pal\Binaries\Win64`. If Palworld is on another drive than Vortex, put the staging folder on that drive (Vortex offers it with "Suggest"). UE4SS itself still comes from the game's Mod Management, as in step 1 above.

### Dedicated server (Windows)

1. Stop the server. Back up the world and the old `PalWorkPriority` folder if there is one.
2. From the manual zip, copy the folder `Mods/NativeMods/UE4SS/Mods/PalWorkPriority` into the server's UE4SS Mods folder. On hosts like GPortal that is `Pal/Binaries/Win64/ue4ss/Mods/`. The pak is not needed on the server.
3. When you update, copy the new folder over the old one. Do not delete the old `Scripts` folder first. The old settings are read from it once.
4. Start the server. Its log should show `Pal Work Priority 0.5.0 loaded` and a line starting with `PWP_READY` that contains `role=authority`.

Server settings live in `config.lua` inside that `PalWorkPriority` folder on the server. Restart the server after a change. The in-game options page has no effect on a server.

The server and every player need exactly 0.5.0. Mixed versions are refused and nothing is written. A 0.4.1 player gets a chat message asking them to update, and a 0.5.0 player on an older server sees "Server version incompatible" in the panel. Workshop players get updates on their own, so update the server first or on the same day. A player with the mod on a server without it gets the normal Monitoring Stand back.

To remove the mod from a server, set `enabled = false` in the server's `config.lua` and restart the server. Check that its `priority.log` says the work permissions were verified, then stop the server and delete the folder.

## Editing priorities

Clicks wrap around at the ends.

```text
left click:   X → 5 → 4 → 3 → 2 → 1 → X
right click:  1 → 2 → 3 → 4 → 5 → X → 1
```

You can also type a number. Click a cell or move to it with the arrow keys first, then press 1 to 5. The legend under the stand lists the keys and the marks: `*` is still being sent, `!` was not saved, `?` is unknown.

A dash means the Pal cannot do that job at all. It is not a priority.

On a server, your edits go to the server, which checks and saves them. Many quick edits are saved once, not once per click.

### Balanced and strict staffing

`assignment_mode = "spread"` (the default) gives every waiting job one Pal before it adds a second Pal to any job. A lower priority job can get its first Pal before a higher one gets its second.

`assignment_mode = "fill"` fills the highest priority job first.

`max_pals_per_work_type` is the most Pals the mod puts on one job (default 3). `false` removes the limit. Neither mode creates work. The game still picks the exact task inside what the mod allows.

## Production Limits

Alt+F1 opens and closes the panel. Click an item once to see what its limit stops and the amount. Click again to add it. Select a limit and press Delete to remove it, or use the remove button. Escape first cancels an amount you are typing, a second Escape closes the panel.

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

If an upgrade had to reset `config.lua`, the mod tells you once. Keep these files when you update or reinstall. They are all in the `PalWorkPriority` folder.

| File | What it holds |
| --- | --- |
| `priorities.txt` | Your priorities, X included |
| `caps.txt` | Your limits |
| `config.lua` | Your settings |
| `config.migration.bak` | Your settings from before the upgrade |
| `priority.log` | Command replies and warnings |

The `.tmp`, `.pending` and `.bak` files next to them are recovery copies. Do not edit any of these files while the game runs.

## Controls and commands

| Key | Action |
| --- | --- |
| Alt+F1 | Open or close Production Limits |
| Alt+F2 | Recheck now. Runs a pass and counts storage (not on a client) |
| Alt+F3 | Write base storage to `priority.log` |
| Alt+F5 | Write `Discovery.txt` to the mod folder (useful for bug reports) |
| Alt+F10 | Switch between spread and fill |
| Alt+F11 | Change the most Pals per job |
| Alt+F12 | Change how storage is counted |
| Arrows, Enter | Move and press in the panel |
| Delete | Remove the selected limit |
| Escape | Cancel an amount, then close the panel |

The keys can be changed on the options page.

**Controller.** Tested with a virtual XInput pad. No physical controller or Steam Input run was done. Plug the pad in before you start the game. On the stand, the D-pad moves, LB or A step toward 1, RB toward X, X sets X and View opens Production Limits (Y stays the game's view switch). In the panel, the D-pad moves, Y opens or raises, X removes, LB and RB switch tabs, LT and RT turn pages and B closes the panel. A does nothing in the panel.

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

1. **Is UE4SS on?** The folder `<Palworld>\Mods\NativeMods\UE4SS` must exist. If it does not, switch Experimental UE4SS for Palworld on in the game's Mod Management and start the game once.
2. **Is the mod in the right place?** You need `<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\Scripts\main.lua` and `<Palworld>\Pal\Content\Paks\LogicMods\PalWorkPriority.pak`.
3. **Did it load?** Open `<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\priority.log`. It should say `Pal Work Priority 0.5.0 loaded`.
4. **No numbers on the stand?** The pak is probably missing. The mod warns about that. Copy the pak back or reinstall.
5. **Two copies?** Use either the Workshop or the manual zip. The mod also warns when it finds a second UE4SS, for example one Vortex added under `<Palworld>\Pal\Binaries\Win64`. Remove that one.
6. **"Server version incompatible"?** The server and every player need exactly 0.5.0.
7. **A Pal ignores its numbers?** If all its jobs have the same number, it is left to the game. Also check the panel does not say "Mod off" or "Test mode".
8. **A setting does nothing?** Restart the game. On a server, change the server's `config.lua`.

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
- Limits per item for buildings (Stone Pit, Logging Site, furnaces) and for work other than Mining are not there yet.

## For developers

The project notes are an Obsidian vault, start at [docs/Home.md](docs/Home.md). Test steps are in [docs/testing.md](docs/testing.md), the release record in [docs/RELEASE-0.5.0.md](docs/RELEASE-0.5.0.md) and the decisions in [docs/DECISIONS.md](docs/DECISIONS.md). Public reports are tracked in the [comment census](docs/comment-ledger-2026-09-11.md).

Evidence for the claims above:

- Clean installs, the 0.4.1 upgrade and the server on the final build: [g7-final-build-2026-10-28](docs/g7-final-build-2026-10-28.md).
- Workshop update (priorities and limits kept, old `Scripts/config.lua` edits lost): [g1-workshop-2026-10-20](docs/g1-workshop-2026-10-20.md).
- Vortex 1.15.2 and 2.9.1: [vortex-2026-10-28](docs/vortex-2026-10-28.md).
- Server folder and restarts on GPortal (UE4SS 3.0.1): [restart-persistence-2026-10-11](docs/restart-persistence-2026-10-11.md).
- Controller with a virtual pad: [controller-routes-2026-10-22](docs/controller-routes-2026-10-22.md).
- Per-item Mining limits: [per-item-limits-2026-10-27](docs/per-item-limits-2026-10-27.md).
- Frame costs: [g5-performance-2026-10-19](docs/g5-performance-2026-10-19.md).
- Mixed versions: [g6-version-mismatch-2026-10-19](docs/g6-version-mismatch-2026-10-19.md).
- The 0.5.0 audit and its fixes: [review-2026-10-28](docs/review-2026-10-28.md).

`tools/release.py` builds both archives from one commit and checks the pak hash. Run the Lua and Python tests from [docs/testing.md](docs/testing.md) before a build.

## Credits and license

Game-side API understanding was informed by AutoAssignResearchLab, BreedingHelper and [PalPriority](https://www.nexusmods.com/palworld/mods/3830). This is an independent implementation. MIT, see [LICENSE](LICENSE).
