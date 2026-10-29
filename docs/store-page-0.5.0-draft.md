---
date: 2026-10-29
tags: [release]
status: current
---
# Store page text for 0.5.0 (draft, not posted)

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [vortex-2026-10-28](vortex-2026-10-28.md) · [g1-workshop-2026-10-20](g1-workshop-2026-10-20.md) · [release-replies-0.5.0-draft](release-replies-0.5.0-draft.md)

Written 2026-10-29 from the README on branch `fix/r3-docs` (round-3 review,
onboarding P2-5). Players read the store page, not the README, so it carries
the install traps. Updating the Steam Workshop and Nexus pages is the user's
action (gate G7, "Store pages updated"). Before posting, check it once more
against the README of the tagged build. Steam and Nexus take BBCode: bold
lines become `[b]...[/b]`, lists `[list][*]...[/list]`.

## Steam Workshop description

**Pal Work Priority 0.5.0**

Work priorities for your base Pals. You set them on the Monitoring Stand: 1 is
the highest priority, 5 the lowest, and X means the Pal never does that job.
Left click a cell to raise it toward 1, right click to lower it toward X. A
left click on 1 wraps around to X. If every job a Pal may do has the same
number, the mod leaves that Pal to the game.

Alt+F1 opens Production Limits. A limit stops work once storage holds enough
of an item. A Mining limit stops only the rocks that mainly give that item.
Every other limit stops its whole job. The mod never starts crafting for you.

**Needs:** [Experimental UE4SS for Palworld](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587).
Subscribe to it and to this mod, switch both on in the game's Mod Management
and restart the game. Steam version on Windows only. The Xbox and PC Game Pass
versions are not supported.

**Use one copy only.** Use this Workshop copy or the manual zip from Nexus,
not both. A switched-on Workshop copy is installed over a manual copy on the
next start.

**Updating from 0.4.1:** your priorities, limits and options page settings
carry over. Changes you made in 0.4.1's `Scripts\config.lua` do not, because
the Workshop update deletes that file first. Write them down before you
update and enter them again in the new `config.lua` in the mod folder. The
panel tells you when default settings are in use. X priorities that 0.4.1
already lost cannot be brought back.

**Settings** live in `config.lua` in the mod folder
(`<Palworld>\Mods\NativeMods\UE4SS\Mods\PalWorkPriority`), or on the options
page with the optional [DarnMenu](https://steamcommunity.com/sharedfiles/filedetails/?id=3769456391)
(ESC > Darn Mod Options). A value saved on the options page wins over
`config.lua`. Restart the game after a change.

**Multiplayer:** the server and every player need exactly 0.5.0. Mixed
versions are refused and nothing is written, so update the server first or
on the same day. Dedicated servers must run Windows and need UE4SS too. Linux
servers cannot run UE4SS Lua mods. The README has the server steps.

**Known limits**
- Limits per item exist only for Mining on natural rocks. Stone Pits and
  other mining buildings cannot be stopped on their own yet.
- Not tested: Steam Deck, a physical controller (a virtual pad was), two real
  players in two guilds at once.
- Before you remove the mod, turn it off first ("Assign Pals to jobs" on the
  options page, or `enabled = false`), load your world and play for a
  moment, then remove it.
  Otherwise Pals can keep work switched off.

Bugs: please attach `priority.log` from the mod folder.

## Nexus description

Same text as the Workshop page, with these changes.

Replace the "Needs" paragraph with:

> **Needs:** Experimental UE4SS for Palworld (Steam Workshop item 3625223587).
> Subscribe to it, switch it on in the game's Mod Management and start the
> game once. Then close the game and extract this zip into your Palworld
> folder (in Steam: right-click Palworld > Manage > Browse local files) and
> let it merge the folders. INSTALL.txt in the zip has the steps. Steam
> version on Windows only. The Xbox and PC Game Pass versions are not
> supported.

Replace the "Updating from 0.4.1" paragraph with:

> **Updating from 0.4.1:** extract the new zip over the old one. Your
> priorities, limits and `config.lua` changes stay.

Add after "Use one copy only":

> **Vortex:** before you install, open Vortex's Settings > Mods and turn off
> "Manage modding requirements (UE4SS, Unreal Pak Tool) automatically".
> Otherwise Vortex adds a second UE4SS. If Palworld is on another drive than
> Vortex, put the staging folder on that drive ("Suggest"). To update from
> 0.4.1, install 0.5.0 next to it, start the game once, then remove 0.4.1.
> Your `config.lua` changes are kept that way. Vortex's Update or Replace
> removes 0.4.1's files first, so your `config.lua` changes are lost that way.
