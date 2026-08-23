# Pal Work Priority

Numeric work priorities for base Pals in Palworld. You decide that Transporting gets staffed
before Mining, and the mod makes that stick by allowing each Pal only the work it should be on
right now, leaving the game's own AI to choose within what is left.

Vanilla only lets you tick a work type on or off per Pal. This adds an ordering on top. Priority
1 work is filled first from the whole roster, priority 5 gets whatever is left over.

## How it works

The mod does not hand Pals jobs. It decides which work types each Pal is **allowed** to do right
now and switches the rest off, then lets Palworld's own AI choose within that. A Pal whose
top-priority work has something waiting gets everything else switched off, so the AI has nowhere
else to send it.

Each pass, per base camp:

1. count **demand** from the game's own pulses, `PalBaseCampWorkerDirector` fires
   `OnRequiredAssignWork_ServerInternal` every few seconds for each work still wanting a
   worker, and a job that stops pulsing is finished
2. work types whose resource ceiling is met contribute no demand
3. walk priority levels 1 to 5, fencing each Pal to the first level where it can do something that
   still has demand to spare
4. a Pal already doing a work type keeps it while any work of that type remains, for up to 90
   seconds without fresh demand
5. a Pal fenced nowhere is left unfenced, keeping everything it may legally do
6. diff against the game's own permissions and send only the differences

Step 4 is an asymmetry worth understanding. To **pull** a Pal to a work type takes a real pulse,
so nobody is sent to a cold station. To **keep** a Pal where it already is takes only that work of
that type still exists. Without it, a fence is released the instant a job is assigned, an
assigned job stops asking for anyone, so by demand alone it looks finished the moment it truly
starts. The Pal gets its other work types switched back on mid-swing and wanders off to a lower
priority the moment the tree falls, with the whole logging site still standing.

The hold is time-bounded because it only has to outlast a job, not persist forever. A workbench
keeps its work object permanently and a Pal that has *finished* crafting still reports Handiwork
as its current work, so an unbounded hold pins it at the bench with everything else switched off
and nothing to do. Genuine demand resets the clock, so a Pal that keeps getting real work of that
type is never aged out, only one that has run dry.

Permissions go through `RequestChangeWorkSuitability_ToServer`, the same flag the vanilla
checkboxes write. No game files are patched.

An earlier version pinned one Pal to one work object with
`RequestFixedAssignWorkInBaseCamp_ToServer` and left the AI otherwise free, so a Pal could still
wander off to a lower-priority job the moment it finished, items sitting waiting to be carried
while a Pal went watering instead. Fencing is the mechanism that makes a priority order actually
govern behaviour.

Two simpler sources of demand were tried against this build and both failed, which is worth
knowing before changing it. Counting every work object in a camp overstates demand enormously. A
station keeps its work object for as long as it stands, so a base with a handful of ripe bushes
reported 78 gathering works. Reading `WorkerDirector.RequiredAssignWorks` reads an *empty* array
almost every time, because a work sits in that list only for the instant it is asking; polling it
looks exactly like an idle base and stops the mod governing anything.

If the pulse hook ever fails to **register**, the mod falls back to counting every work object and
says `demand ESTIMATED` rather than quietly doing nothing. That test is deliberately about
registration and not about whether any pulse has arrived: a base whose Pals are all asleep
produces no pulses at all, and treating that as a broken hook would fence the whole roster onto
night work that does not exist. `!pwp status` reports both.

**This means the mod continuously writes work-permission flags to your save.** Restoring is
stateless: a Pal's permissions are always *capable AND not X AND (fenced-in OR unfenced)*, so
switching the mod off puts back *capable AND not X* without needing a record of what came before.
The cost is that a work type you unchecked by hand in vanilla gets switched back on, **X is how
you say "never" to this mod.**

## Requirements

- Palworld, game revision 82182 or newer
- UE4SS, the [Experimental Palworld build](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587) is what this was developed against

## Installing for development

```powershell
.\tools\deploy.ps1
```

This copies `Scripts/` into `<Palworld>/Mods/NativeMods/UE4SS/Mods/PalWorkPriority` and adds the
mod to `mods.txt`, keeping the built-in `Keybinds` entry last as UE4SS requires. Pass
`-GamePath` if Palworld is not at the default Steam location, and `-Remove` to uninstall.

A mod installed this way does **not** appear under **Options > Mod Management**. That list comes
from Palworld's own manager, which only knows mods it deployed from a Steam subscription. Writing
a `Mods/ManagedMods` record and an `ActiveModList` line by hand was tried and does not work: the
game deletes both on the next launch, because it reconciles that list against real subscriptions
and drops anything it cannot match.

To get the in-game toggle, upload the mod to the Steam Workshop and subscribe to it. The Workshop
item can be set to **private** visibility, so only you can see it, which gives full integration
without publishing anything publicly.

Files are written as UTF-8 without a byte-order mark, matching how UE4SS writes `mods.txt`
itself. Windows PowerShell adds one by default.

Palworld's own mod loader rewrites `mods.txt` from its active mod list on launch. If the mod
stops loading after a game update or a Workshop subscription change, re-run the script.

## First run

`config.lua` currently has `dry_run = false`, so the mod writes work permissions for real. Set it
to `true` for a session first if you would rather watch before letting it touch a base:

1. load a save with a staffed base
2. press **Alt+F2**, or type `!pwp run` in chat
3. read the `[PalWorkPriority]` lines in `UE4SS.log`

In dry run every pass logs what it *would* toggle and sends nothing. The summary line names the
work types wanting a worker and which Pal was fenced where, which is the fastest way to see
whether the priorities are doing what you meant.

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
nobody, including three rank-6 Anubis pinned to carrying boxes.

Two dials control that, and they combine:

```lua
assignment_mode = "spread",     -- or "fill"
max_pals_per_work_type = 3,     -- or false for no limit
```

**`spread`** walks the priority list giving each work type one Pal, then walks it again for
seconds, and again for thirds. Everything gets covered before anything gets doubled.
**`fill`** lets a work type take every Pal it can before the next type is considered at all.
That is the strict reading of priority, if it is the one you want.

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

Set one from chat, no restart:

```
!pwp limit Lumbering Wood 5000     set it
!pwp limit Lumbering Wood 0        remove it, "off" also works
!pwp limit                         list every limit against what the base holds
```

Ceilings set this way live in `caps.txt` next to the mod and outrank `config.lua`, the same way
a priority clicked on the stand outranks the configured one.

Each line is `Guild|WorkType|ItemId|Ceiling`, and a limit belongs to the guild that set it. On a
shared server one guild's ceiling never touches another guild's bases: the scheduler resolves
each camp's owning guild and applies only that guild's limits, the panel shows and edits only
your own, and the server files an incoming rule under the guild it actually arrived from rather
than one the client names.

A guild of `*` is a limit written before guild rules existed. Those still apply, to any guild
that has not set its own for the same job and item, so an existing `caps.txt` keeps working
untouched. Where every base camp on the server belongs to one guild the ambiguity is not real
and they are adopted into it on the next pass, after which every limit has an owner. Where camps
span several guilds they stay shared, and the panel will say so rather than pretend to remove
one. `0` removes a limit rather than
being read literally: taken at face value it would mean "you already have at least none of
these" and suspend the work type for good, which is what priority `X` on the stand is for.

### Keeping a stock topped up

A limit is a ceiling: it stops a job when storage is full enough. The obvious
companion is a floor - "always keep 100 Pal Spheres" - and that is worth saying
plainly: **the mod cannot queue a craft.** Nothing in this build lets a mod set
what a workbench produces. `PalMapObjectProductItemModel` exposes
`GetProductItemId`, `GetItemContainer` and `CalcRequiredAmount` and no setter at
all; its whole inheritance is `PalMapObjectConcreteModelBase` and then `Object`,
neither of which adds one; and no queue count is exposed anywhere, so there is
nothing to write even if there were somewhere to write it. `!pwp panel craft`
reprints that finding against your own game if you want to check it.

What does work is the other half of the same idea. Queue a large standing order
at the bench once, by hand, then put a ceiling on what it makes:

```
!pwp limit Handiwork PalSphere 100
```

Pals work the bench until storage reaches 100, stop, and start again when it
falls. The standing order is what the mod cannot create; the topping up is
exactly what a ceiling already does.

Two things to know before relying on it. **Your own inventory is not storage** -
spheres in your pockets, or lying on the ground, do not count towards a ceiling.
What does count is every container on the base, chests and production stations
alike, minus the feed box and loose dropped items; `!pwp stock` prints both
lists so you can see which side a pile is on. And a ceiling
gates the whole work type, so if your Pals do other Handiwork it stops too -
unless you list those items as well, because a job only stops once *every*
item listed for it has reached its ceiling.

The equivalent in `config.lua`, for anyone who would rather keep it in a file:

```lua
work_caps = {
    Deforest = { Wood = 5000 },
    Mining   = { Stone = 3000, Ore = 2000 },
},
```

With several items listed, the work type is suspended only when *every* one is at or above its
ceiling, mining keeps running while either stone or ore is still short.

The keys are internal item ids, not display names. `!pwp limit` matches what you type against
what the base is holding and stores the id as the game spells it, so case does not matter, and
it warns when nothing on the base matches at all. Editing `config.lua` by hand has no such
guard and a misspelled id there produces a ceiling that silently never fires. Run `!pwp stock`
to print what is in storage, by id, and write the full list to `Stock.txt`.

### What counts toward a ceiling

Every container on the base, chests and stations alike, minus the exceptions in
`uncounted_containers`:

    PalMapObjectPalFoodBoxModel         food set aside for pals to eat
    PalMapObjectDropItemModel           dropped on the ground
    PalMapObjectPickupItemOnLevelModel  lying about waiting to be collected

This started as a list of classes to *include* and that was the wrong way round. Palworld has
far more station types than any hand written list will name, and each one missed is a ceiling
quietly overshooting by whatever that station holds. A Logging Site sitting on 297 wood was the
one that showed it. Counting everything and naming the exceptions means a station type this mod
has never heard of still counts.

The feed box is the deliberate exception. That food exists to be eaten, so counting it would
stop a ranch that is only keeping pace with what the Pals get through. Dropped and lying-about
items are loose world clutter rather than base stock, and one test base carried 54 of them.

To go the other way and count only certain classes, set `counted_containers` to a list. That
overrides `uncounted_containers` entirely:

```lua
counted_containers = {
    "PalMapObjectItemChestModel",
    "PalMapObjectGuildChestModel",
},
```

Whatever is not in the list is still printed by `Alt+F3`, under `holding stock but NOT counted by
ceilings`, along with what it holds. If a ceiling is not firing when you think it should, look
there first: the resource may be sitting somewhere the count does not reach.

If no container answers at all, totals read as zero and work keeps running. Overshooting a ceiling
is a far milder failure than suspending a work type because a container did not reply. Storage
is only read when at least one ceiling exists, in `caps.txt` or in `config.lua`.

## The Monitoring Stand display

Everything the mod decides is shown on the vanilla work-suitability screen, read-only:

- **A number in each grid cell**, the priority in force for that Pal and work type, replacing
  the vanilla checkbox. Coloured on RimWorld's work-tab scale: **1 green, 2 yellow, 3 orange,
  4 red, 5 grey**. A dim **X** means never assign.

Colour means priority and nothing else, so the same number is always the same colour.

The grid deliberately does not mark which job a Pal is on right now. Three attempts all made it
worse, tinting broke colour consistency, a coloured drop shadow rendered as a duplicate digit
(a shadow *is* a second copy of the glyph), and an enlarged glyph just looked wrong. The game
already answers that in its own info panel. The grid is an editor: it shows what you set.
- **Work a Pal cannot do keeps its vanilla dash.** A number there would claim the Pal will do
  something it is incapable of, so those cells are left alone entirely.

Numbers reflect `pal_overrides` too, resolved nickname-first then species exactly as the
scheduler resolves them, so what the grid shows and what the scheduler does cannot drift apart.

### Clicking to change a priority

**Left click raises** a cell towards priority 1. **Right click lowers** it towards never.

```
1  <-  2  <-  3  <-  4  <-  5  <-  X          left click
1  ->  2  ->  3  ->  4  ->  5  ->  X          right click
```

Both ends clamp rather than wrap. Wrapping means one click too many on a priority-1 cell silently
excludes the Pal from that work, with nothing in the number to show it happened.

Clicks only land on cells the mod owns, a Pal that cannot do a work type keeps its vanilla dash
and ignores clicks there, so an invisible edit can never end up hiding under one.

A click changes **policy only**, it never writes the game's permission flags itself. The fence is
the sole writer of those, and a click schedules a pass so the change lands within a second.

That matters because the vanilla left-click still fires underneath and toggles the same flag. An
earlier version had the click handler re-assert the flag too. That gave one click three
authorities: vanilla toggling it, the handler re-asserting it, and the next pass overriding both.
It showed up as the checkbox flicking between tick and cross beneath the number. Now the vanilla
toggle is simply left for the next pass to correct, which it does by diffing against the game's
real state.

Edits are per Pal and per work type, and they outrank everything in `config.lua`. They persist to
`priorities.txt` next to the mod, written a couple of seconds after a burst of clicks settles
rather than once per click.

The resolution order is: **a click you made** then `pal_overrides` then `work_priority`. One function in
`store.lua` decides it, called by both the scheduler and the grid, because when they each had
their own copy the two silently disagreed.

### How it attaches

Pal identity comes from hooking the row's `BindFromSlot`, captured as a hook argument. Two crash
findings from PalPriority's UI mod are load-bearing and worth restating if you extend this:

- `pcall` **cannot** catch the native access violation from calling a method on a stale wrapper.
  Every member call needs an affirmative `IsValid() == true` first.
- **Never read a row's `bindedSlot`**, the property read itself crashes natively, before Lua
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
| `!pwp limit` | set, clear or list resource ceilings |
| `!pwp scope` | measure ceilings per base, or across loaded bases |
| `!pwp discover` | write `Discovery.txt` with live work probes |
| `!pwp guilds` | write `Guilds.txt`: which guild owns each camp and which you are in |
| `!pwp worksuit` | write `WorkSuit.txt`: what the work suitability read and write sides hold |
| `!pwp net` | report the transport: hooks, role, counters, and which component a send uses |
| `!pwp restore` | give every Pal back every work it can do, and unfence the base |
| `!pwp panel` | drive the rules panel from chat, for scripting and for testing |
| `!pwp help` | list the commands |
| `!pwp icons` | probe the overlay icons, and report what they resolved to |
| `!pwp sweep` / `!pwp trace` | diagnostics: what the storage sweep sees, and what a pass decided |

`!pwp restore` is the one to remember. The fences are the game's own saved data, so they outlive
the mod: uninstalling while a base is fenced leaves Pals with most of their work switched off and
no way back but the stand, by hand. Run it before you remove anything. `!pwp off` does it for you.

Keys, for the same actions. Everything is on Alt, and deliberately so: Ctrl is crouch, so a
`Ctrl`+function key rolls your character every time you press it, and Shift is sprint. Palworld
binds Alt to nothing at all, which makes it the only modifier that is free to hold.

| key | does |
| --- | --- |
| `Alt+F1` | open and close the work rules panel |
| arrows, `Enter` | move around the panel and confirm, while it is open |
| `Alt+F2` | run a pass now |
| `Alt+F3` | print base storage |
| `Alt+F5` | write `Discovery.txt` |
| `Alt+F9` | run the transport test |
| `Alt+F10` | toggle spread/fill |
| `Alt+F11` | cycle the cap |
| `Alt+F12` | switch storage scope between one base and all loaded bases |

The gaps are other people's. `Alt+F4` is Windows, `Alt+F6` and `Alt+F7` belong to EffigyBeacons
and PalBaseInfoGrid, and `Alt+F8` is FreeCam's. All of that was checked with
`tools/keybind_audit.py` against the mods actually installed, not by eye, because two of those
collisions do not survive a grep.

Not everything has one. `!pwp dry`, `!pwp live`, `!pwp on`, `!pwp off`, `!pwp reload` and
`!pwp restore` are chat only, and a single player save has no chat box, so on one they cannot be
reached at all. That matters most for dry run: if you set `dry_run = true` in `config.lua` there
is no way back from inside the game, so edit the file again and restart.

`!pwp discover` *calls* into live Pals, which only the machine running the world can do safely -
on a client those are replicated proxies and `GetWorkSuitabilityRank` on one takes the game down
outright, past any error handling. It detects that and skips those probes, writing a line saying
so. `!pwp guilds` touches nothing but classes and replicated ids and is safe anywhere.
`!pwp worksuit` sits between the two: it reads each base Pal's saved work suitability, which is a
property read rather than a call, and it has been run start to finish on a dedicated server
client. If any probe ever does take the game down, the file it was writing is unbuffered and its
last `[step]` line names where.

## How a work's type is determined

A live schema dump settled this: `PalWorkBase` has **no** work-suitability field. The
requirement is not on the work object at all, it lives in an assign-define data row the work
only references by name through `AssignDefineDataId`.

What a work does expose is `OverrideWorkType` plus some text, and the order they are consulted
in matters more than any one of them:

1. **`OverrideWorkType`**, the job's own declaration. This is `EPalWorkType`, a *different* enum
   from `EPalWorkSuitability`, mapped through `WORKTYPE_TO_SUIT` in `Scripts/palapi.lua`.
2. **`GetWorkName`**, the game's display name. For several jobs this string is literally the
   suitability label, and it is right precisely where the class name misleads.
3. **`AssignDefineDataId`**, the station identity, for generic `PalWorkProgress` objects where
   one class covers a furnace and a bench alike.
4. **Class name**, last, because one class serves several work types.

Class name has to come last. The transport class reports `OverrideWorkType` 7, 11, 16 and 17
depending on the job; reading its name first files every pickable-collection job under Transport
and hides it from Pals set to Collection. On one test base that was 26 of 79 works.

Anything that resolves to nothing is reported as unreadable and skipped rather than guessed at,
a mis-classified work puts a Pal on the wrong job silently.

`!pwp discover` lists every unresolved work with its three text sources, which is exactly what a
new `workdefs.KEYWORDS` entry needs to match.

A warning if you extend this: UE4SS returns a live-looking `TrivialObject` for **any** property
name, including ones that do not exist. A non-nil read proves nothing. Probing by property name
is how the first four candidate names all appeared to answer while meaning nothing.

The suitability enum is confirmed: `0 = None`, `1 = EmitFlame` ... `13 = MonsterFarm`,
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
- confirm the `Dependencies` entry. These are **`PackageName` strings, not Workshop IDs**: every
  installed mod that depends on UE4SS lists `"UE4SSExperimentalPW"`, and PalSchema mods list
  `"PalSchema"`. A numeric ID there makes the Mod Uploader fail to read the file at all, and the
  mod shows up in its list with a blank name
- add a `thumbnail.png`

Then upload with Pocketpair's [PalworldModUploader](https://github.com/pocketpairjp/PalworldModUploader).
Bump `Version` on every update, the loader compares it as a plain string and only reinstalls
when it changes.

## Credits

The game-side symbols were learned by reading mods that already run on this build, not guessed:

- **AutoAssignResearchLab** by Wol4ara896, the worker director walk, `GetWorkSuitabilityRank`,
  and `RequestFixedAssignWorkInBaseCamp_ToServer`
- **BreedingHelper**, `GetWorkProgressManager`, the `WorkCollection.WorkIds` sweep, the
  reflection walk that `discover.lua` reuses, and the storage chain behind resource ceilings
  (chest model classes, `GetItemContainerModule().TargetContainer.ItemSlotArray`,
  `ItemId.StaticId` and `StackCount`)

- **PalPriority** ([Nexus 3830](https://www.nexusmods.com/palworld/mods/3830)), for establishing
  that a work's `OverrideWorkType` is `EPalWorkType` rather than `EPalWorkSuitability`, that it
  has to outrank the class name, and for `GetWorkSuitabilityRankWithCharacterRank`

This is an independent implementation and shares no code with PalPriority. What was taken from it
is factual, which engine symbol means what, not implementation. This mod works by fencing: it
writes the same per-Pal permissions the vanilla checkboxes write, through
`RequestChangeWorkSuitability_ToServer`, and lets the game's AI choose within them. An earlier
version drove `RequestFixedAssignWorkInBaseCamp_ToServer` instead and was replaced, for the
reason given under How it works. `WORKTYPE_TO_SUIT` is built from a `EPalWorkType` dump of
the running build rather than copied.

## License

MIT. See [LICENSE](LICENSE).
