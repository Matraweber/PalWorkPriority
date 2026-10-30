---
date: 2026-10-29
tags: [release]
status: history
---
# Store page text for 0.5.0 (posted 2026-10-30)

**Posted 2026-10-30 (about 17:20):**
- **Steam Workshop:** the description, as BBCode. The required item Experimental UE4SS
  (3625223587) was already set.
- **Nexus mod 5376:** the long description, through the editor's source view. One line
  was added there pointing servers to the optional "Dedicated server files" download.

The 0.4.1 texts of both pages, and the posted BBCode, are kept in
`D:\PalWorkPriority-backups\store-pages-0.4.1-20261030`.

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [vortex-2026-10-28](vortex-2026-10-28.md) · [g1-workshop-2026-10-20](g1-workshop-2026-10-20.md) · [release-replies-0.5.0-draft](release-replies-0.5.0-draft.md) · [review-round4-2026-10-30](review-round4-2026-10-30.md)

Written 2026-10-29 from the README on branch `fix/r3-docs` (round-3 review,
onboarding P2-5). Players read the store page, not the README, so it carries
the install traps. Updating the Steam Workshop and Nexus pages is the user's
action (gate G7, "Store pages updated"). Before posting, check it once more
against the README of the tagged build. Steam and Nexus take BBCode: bold
lines become `[b]...[/b]`, lists `[list][*]...[/list]`.

Updated 2026-10-30 from the round-4 review (onboarding P2-1 to P2-9,
newcomer P2-3 and P2-4): GitHub link, first-minute test with a right click,
NVIDIA line, overshoot line, missing-log case, one copy before extracting,
exact Vortex steps. On the Workshop page, also set
Experimental UE4SS for Palworld (3625223587) as a Required item ("Add/Remove
Required Items"), so Steam offers it on subscribe.

## Steam Workshop description

**Pal Work Priority 0.5.0**

Work priorities for your base Pals. You set them on the Monitoring Stand: 1 is
the highest priority, 5 the lowest, and X means the Pal never does that job.
Left click a cell to raise it toward 1, right click to lower it toward X. A
left click on 1 wraps around to X. If every job a Pal may do has the same
number, the mod leaves that Pal to the game.

**First minute:** right after install every job the game had ticked shows 1
and the game still picks. To test the mod, load your world, open a
Monitoring Stand and right click a 1. It becomes 2, and a moment later the
line under the stand says "Steering 1 of" and your number of Pals. Left
click that cell once to put it back. Nothing on the stand? See
Troubleshooting in the full guide (link below).

Alt+F1 opens Production Limits. A limit stops work once storage holds enough
of an item. A Mining limit stops only the rocks that mainly give that item.
Every other limit stops its whole job. Storage is checked every 10 to 30
seconds and Pals finish what they are doing, so storage can end up above the
limit. The mod never starts crafting for you.

**Alt+F1 takes a screenshot instead?** That is the NVIDIA overlay, which uses
Alt+F1 to Alt+F3 too. Switch off those overlay shortcuts, or change the key on
the options page (needs the optional DarnMenu, see Settings).

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
servers cannot run UE4SS Lua mods. The full guide has the server steps.

**Known limits**
- Limits per item exist only for Mining on natural rocks. Stone Pits and
  other mining buildings cannot be stopped on their own yet.
- Not tested: Steam Deck, a physical controller (a virtual pad was), two real
  players in two guilds at once.
- Before you remove the mod, turn it off first ("Assign Pals to jobs" on the
  options page, or `enabled = false`), load your world and play for a
  moment, then remove it.
  Otherwise Pals can keep work switched off.

**Full guide, server steps, troubleshooting:**
https://github.com/Matraweber/PalWorkPriority#readme

Bugs: please attach `priority.log` from the mod folder. No `priority.log` at
all? UE4SS is not running or the mod files are in the wrong place.

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

Replace the "Use one copy only" paragraph with:

> **Use one copy only.** If the Workshop copy of Pal Work Priority is
> switched on in the game's Mod Management, switch it off or unsubscribe,
> start the game once and close it before you extract this zip. If you
> switch the Workshop copy off later, extract the zip again: the game may
> remove files the two copies share.

Add after it:

> **Vortex:** before you install, open Vortex's Settings > Mods and turn off
> "Manage modding requirements (UE4SS, Unreal Pak Tool) automatically".
> Otherwise Vortex adds a second UE4SS. If Palworld is on another drive than
> Vortex, put the staging folder on that drive ("Suggest"). To update from
> 0.4.1, get the 0.5.0 zip with "Manual download", then in Vortex open Mods,
> click "Install From File" and pick the zip. Vortex installs it next to
> 0.4.1. Check that it is enabled and deployed, start the game once, then
> remove 0.4.1. Your `config.lua` changes are kept that way. Vortex's Update
> or Replace removes 0.4.1's files first, so your `config.lua` changes are
> lost that way.
