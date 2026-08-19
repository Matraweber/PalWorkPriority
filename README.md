# Pal Work Priority

Numeric work priorities for base Pals in Palworld. You decide that Transporting gets staffed
before Mining, and the mod hands each job to the best-suited Pal that is still free.

Vanilla only lets you tick a work type on or off per Pal. This adds an ordering on top: priority
1 work is filled first from the whole roster, priority 5 gets whatever is left over.

## How it works

The mod does not hand Pals jobs. It decides which work types each Pal is **allowed** to do right
now and switches the rest off, then lets Palworld's own AI choose within that. A Pal whose
top-priority work has something waiting gets everything else switched off, so the AI has nowhere
else to send it.

Each pass, per base camp:

1. count **demand** — how many pending jobs exist of each work type
2. work types whose resource ceiling is met contribute no demand
3. walk priority levels 1 to 5, fencing each Pal to the first level where it can do something that
   still has demand to spare
4. a Pal fenced nowhere is left unfenced, keeping everything it may legally do
5. diff against the game's own permissions and send only the differences

Permissions go through `RequestChangeWorkSuitability_ToServer` — the same flag the vanilla
checkboxes write. No game files are patched.

An earlier version pinned one Pal to one work object with
`RequestFixedAssignWorkInBaseCamp_ToServer` and left the AI otherwise free, so a Pal could still
wander off to a lower-priority job the moment it finished — items sitting waiting to be carried
while a Pal went watering instead. Fencing is the mechanism that makes a priority order actually
govern behaviour.

**This means the mod continuously writes work-permission flags to your save.** Restoring is
stateless: a Pal's permissions are always *capable AND not X AND (fenced-in OR unfenced)*, so
switching the mod off puts back *capable AND not X* without needing a record of what came before.
The cost is that a work type you unchecked by hand in vanilla gets switched back on — **X is how
you say "never" to this mod.**

## Requirements

- Palworld, game revision 82182 or newer
- UE4SS — the [Experimental Palworld build](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587) is what this was developed against

## Installing for development

```powershell
.\tools\deploy.ps1
```

This copies `Scripts/` into `<Palworld>/Mods/NativeMods/UE4SS/Mods/PalWorkPriority` and adds the
mod to `mods.txt`, keeping the built-in `Keybinds` entry last as UE4SS requires. Pass
`-GamePath` if Palworld is not at the default Steam location, and `-Remove` to uninstall.

Palworld's own mod loader rewrites `mods.txt` from its active mod list on launch. If the mod
stops loading after a game update or a Workshop subscription change, re-run the script.

## First run

The mod ships with `dry_run = true`. It works out every assignment and logs it without sending
anything. Do one session like that first:

1. load a save with a staffed base
2. type `!pwp run` in chat
3. read the `[PalWorkPriority]` lines in `UE4SS.log`

If the assignments look right, set `dry_run = false` in `Scripts/config.lua` and `!pwp reload`.

## Configuration

Everything lives in `Scripts/config.lua`. The interesting part:

```lua
work_priority = {
    Transport = 1,
    ProductMedicine = 1,
    Cool = 2,
    Handcraft = 3,
    Mining = 4,
    MonsterFarm = 5,
}
```

`1` is filled first, `5` last, `false` means never assign that work type at all. Per-Pal
overrides go in `pal_overrides`, keyed by nickname first and species second:

```lua
pal_overrides = {
    ["Diggy"]   = { Mining = 1, Transport = false },
    ["Lifmunk"] = { Handcraft = false },
}
```

An override outranks suitability. `["Diggy"] = { Mining = 1 }` puts Diggy on mining even when a
better-suited miner is standing next to them; rank only decides between Pals that share the same
priority. `false` removes the Pal from that work type entirely.

`min_suitability_rank` stops low-rank Pals from occupying jobs a specialist should be doing.

## Spread or fill

Priority alone is not enough. A base with 46 pending transport jobs and priority 1 on
Transporting will hand every carrier in the roster to hauling and leave Mining and Handiwork with
nobody — including three rank-6 Anubis pinned to carrying boxes.

Two dials control that, and they combine:

```lua
assignment_mode = "spread",     -- or "fill"
max_pals_per_work_type = 3,     -- or false for no limit
```

**`spread`** walks the priority list giving each work type one Pal, then walks it again for
seconds, and again for thirds. Everything gets covered before anything gets doubled.
**`fill`** lets a work type take every Pal it can before the next type is considered at all —
the strict reading of priority, if that is what you want.

**`max_pals_per_work_type`** caps either mode. Spread with a cap of 3 means one each, then
seconds, then thirds, and no more.

| Mode | Cap | Behaviour |
| --- | --- | --- |
| `fill` | `false` | Priority 1 absorbs the whole roster |
| `fill` | `2` | Each type takes at most 2, in strict priority order |
| `spread` | `false` | One each, then seconds, until Pals run out |
| `spread` | `3` | One each, then seconds, then thirds, then stop |

Both are togglable in game without a restart: `!pwp mode` and `!pwp cap`, or **Alt+F10** and
**Alt+F11**. Each toggle runs a fresh pass immediately so you can see the result.

## Resource ceilings

A work type can be suspended once the base already holds enough of what it produces. The Pals
that would have worked it are still unclaimed when the next priority comes round, so they drop
down to it rather than standing idle next to a full chest.

```lua
work_caps = {
    Deforest = { Wood = 5000 },
    Mining   = { Stone = 3000, Ore = 2000 },
},
```

With several items listed, the work type is suspended only when *every* one is at or above its
ceiling — mining keeps running while either stone or ore is still short.

The keys are internal item ids, not display names, and a misspelled id produces a ceiling that
silently never fires. Run `!pwp stock` while standing in your base to print exactly what is in
storage, by id, and write the full list to `Stock.txt`.

Storage is read by walking the base's chests. If no chest answers, totals read as zero and work
keeps running — overshooting a ceiling is a far milder failure than suspending a work type
because a container did not reply. Storage is only read at all when at least one ceiling is
configured.

## The Monitoring Stand display

Everything the mod decides is shown on the vanilla work-suitability screen, read-only:

- **A number in each grid cell** — the priority in force for that Pal and work type, replacing
  the vanilla checkbox. Coloured on RimWorld's work-tab scale: **1 green, 2 yellow, 3 orange,
  4 red, 5 grey**. A dim **X** means never assign.

Colour means priority and nothing else, so the same number is always the same colour.

The grid deliberately does not mark which job a Pal is on right now. Three attempts all made it
worse — tinting broke colour consistency, a coloured drop shadow rendered as a duplicate digit
(a shadow *is* a second copy of the glyph), and an enlarged glyph just looked wrong. The game
already answers that in its own info panel. The grid is an editor: it shows what you set.
- **Work a Pal cannot do keeps its vanilla dash.** A number there would claim the Pal will do
  something it is incapable of, so those cells are left alone entirely.
- **A status strip** along the bottom: mode, cap, dry/live, and the last pass summary.

Numbers reflect `pal_overrides` too, resolved nickname-first then species exactly as the
scheduler resolves them — so what the grid shows and what the scheduler does cannot drift apart.

### Clicking to change a priority

**Left click raises** a cell towards priority 1. **Right click lowers** it towards never.

```
1  <-  2  <-  3  <-  4  <-  5  <-  X          left click
1  ->  2  ->  3  ->  4  ->  5  ->  X          right click
```

Both ends clamp rather than wrap. Wrapping means one click too many on a priority-1 cell silently
excludes the Pal from that work, with nothing in the number to show it happened.

Clicks only land on cells the mod owns — a Pal that cannot do a work type keeps its vanilla dash
and ignores clicks there, so an invisible edit can never end up hiding under one.

**Setting X also switches the game's own work permission off for that Pal**, which is the only
thing that actually stops work. The mod declining to assign a Pal means nothing to Palworld's own
AI, which will pick the job up regardless — and in dry run nothing is assigned at all, so an X
that only changed a number on screen changed nothing whatsoever. Setting any number switches the
permission back on. This is also what settles the fight with the vanilla left-click, which toggles
that same flag underneath: whatever it did, the click handler puts it back in agreement with the
number now showing.

Edits are per Pal and per work type, and they outrank everything in `config.lua`. They persist to
`priorities.txt` next to the mod, written a couple of seconds after a burst of clicks settles
rather than once per click.

The resolution order is: **a click you made** → `pal_overrides` → `work_priority`. One function in
`store.lua` decides it, called by both the scheduler and the grid, because when they each had
their own copy the two silently disagreed.

### How it attaches

Pal identity comes from hooking the row's `BindFromSlot`, captured as a hook argument. Two crash
findings from PalPriority's UI mod are load-bearing and worth restating if you extend this:

- `pcall` **cannot** catch the native access violation from calling a method on a stale wrapper.
  Every member call needs an affirmative `IsValid() == true` first.
- **Never read a row's `bindedSlot`** — the property read itself crashes natively, before Lua
  sees anything.

Each number is a `TextBlock` injected as a sibling of the cell's checkbox with its slot geometry
copied, so placement is exact by construction rather than inferred. Rows recycle on scroll rather
than being destroyed, so the injected widgets are cached across rebinds; re-injecting on every
bind would stack duplicate glyphs on each scroll.

## Chat commands

| Command | Effect |
| --- | --- |
| `!pwp status` | current mode, camps loaded, which reads resolved |
| `!pwp run` | run one pass now |
| `!pwp dry` / `!pwp live` | log-only, or actually assign |
| `!pwp on` / `!pwp off` | enable or disable |
| `!pwp reload` | re-read `config.lua` without restarting |
| `!pwp mode` | toggle spread / fill |
| `!pwp cap` | cycle max Pals per work type |
| `!pwp stock` | print base storage by item id, and write `Stock.txt` |
| `!pwp discover` | write `Discovery.txt` with live work probes |

`F10` runs a pass, `F11` writes `Discovery.txt`, `F12` prints base storage, `Alt+F10` toggles
spread/fill and `Alt+F11` cycles the cap — for sessions where chat input is not available.

## How a work's type is determined

A live schema dump settled this: `PalWorkBase` has **no** work-suitability field. The
requirement is not on the work object at all — it lives in an assign-define data row the work
only references by name through `AssignDefineDataId`.

What a work does expose is `OverrideWorkType` plus some text, and the order they are consulted
in matters more than any one of them:

1. **`OverrideWorkType`**, the job's own declaration. This is `EPalWorkType` — a *different* enum
   from `EPalWorkSuitability`, mapped through `WORKTYPE_TO_SUIT` in `Scripts/palapi.lua`.
2. **`GetWorkName`**, the game's display name. For several jobs this string is literally the
   suitability label, and it is right precisely where the class name misleads.
3. **`AssignDefineDataId`**, the station identity, for generic `PalWorkProgress` objects where
   one class covers a furnace and a bench alike.
4. **Class name**, last, because one class serves several work types.

Class name has to come last. The transport class reports `OverrideWorkType` 7, 11, 16 and 17
depending on the job; reading its name first files every pickable-collection job under Transport
and hides it from Pals set to Collection. On one test base that was 26 of 79 works.

Anything that resolves to nothing is reported as unreadable and skipped rather than guessed at —
a mis-classified work puts a Pal on the wrong job silently.

`!pwp discover` lists every unresolved work with its three text sources, which is exactly what a
new `workdefs.KEYWORDS` entry needs to match.

A warning if you extend this: UE4SS returns a live-looking `TrivialObject` for **any** property
name, including ones that do not exist. A non-nil read proves nothing. Probing by property name
is how the first four candidate names all appeared to answer while meaning nothing.

The suitability enum is confirmed: `0 = None`, `1 = EmitFlame` … `13 = MonsterFarm`,
`14 = Anyone`, so `workdefs.enum_offset` stays 1. Work filed under `Anyone` names no skill, so
suitability rank and `min_suitability_rank` are both bypassed for it and any Pal will do.

## Multiplayer

The mod runs client-side and only issues RPCs the vanilla UI already issues, so other players do
not need it installed.

On a pure multiplayer client the camp's work list is not replicated until requested. The mod
asks for it via `RequestReplicateBaseCampWork_ToServer` when a pass finds no readable work, so
the following pass usually succeeds. Hosting or singleplayer needs none of this.

## Publishing to Steam Workshop

`Info.json` is already in the Workshop package format. Before uploading:

- set `Author` to your Steam name
- set `MinRevision` to the game revision you actually tested on
- confirm the `Dependencies` entry: `3625223587` is the UE4SS Experimental Workshop item. If it
  is gone or you targeted a different UE4SS core, point this at the one you tested against
- add a `thumbnail.png`

Then upload with Pocketpair's [PalworldModUploader](https://github.com/pocketpairjp/PalworldModUploader).
Bump `Version` on every update — the loader compares it as a plain string and only reinstalls
when it changes.

## Credits

The game-side symbols were learned by reading mods that already run on this build, not guessed:

- **AutoAssignResearchLab** by Wol4ara896 — the worker director walk, `GetWorkSuitabilityRank`,
  and `RequestFixedAssignWorkInBaseCamp_ToServer`
- **BreedingHelper** — `GetWorkProgressManager`, the `WorkCollection.WorkIds` sweep, the
  reflection walk that `discover.lua` reuses, and the storage chain behind resource ceilings
  (chest model classes, `GetItemContainerModule().TargetContainer.ItemSlotArray`,
  `ItemId.StaticId` and `StackCount`)

- **PalPriority** ([Nexus 3830](https://www.nexusmods.com/palworld/mods/3830)) — for establishing
  that a work's `OverrideWorkType` is `EPalWorkType` rather than `EPalWorkSuitability`, that it
  has to outrank the class name, and for `GetWorkSuitabilityRankWithCharacterRank`

This is an independent implementation and shares no code with PalPriority. The two take different
approaches: PalPriority flips the vanilla per-Pal work toggles through
`RequestChangeWorkSuitability_ToServer`, while this drives fixed assignments through
`RequestFixedAssignWorkInBaseCamp_ToServer`. What was taken from it is factual — which engine
symbol means what — not implementation. `WORKTYPE_TO_SUIT` is built from a `EPalWorkType` dump of
the running build rather than copied.

## License

MIT. See [LICENSE](LICENSE).
