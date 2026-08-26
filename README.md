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
- `PalWorkPriority.pak` in `Pal/Content/Paks/LogicMods`, which carries the panel's widget. It is
  part of the mod rather than an optional extra: without it the panel falls back to a plain
  canvas with no named rows, and the header collapses onto one line. Subscribing installs it;
  see the publishing section if you are building the package yourself. A Lua mod shipping its UI
  in a pak is the ordinary arrangement here - `AutoHatch` does the same, and `CreativeMenu` sits
  in the same folder

## Installing for development

```powershell
.\tools\deploy.ps1
```

This copies `Scripts/` into `<Palworld>/Mods/NativeMods/UE4SS/Mods/PalWorkPriority` and adds the
mod to `mods.txt`, keeping the built-in `Keybinds` entry last as UE4SS requires. Pass
`-GamePath` if Palworld is not at the default Steam location, and `-Remove` to uninstall.

`deploy.ps1` deliberately does not touch the pak. The Lua reloads in place a hundred times an
hour and the pak changes when the widget does, which is rarely, so they are built by different
commands on purpose:

```powershell
python tools\pak_mod.py
```

That cooks nothing by itself - it takes what the editor already cooked under `Saved/Cooked`, and
writes `build/PalWorkPriority.pak` into `<Palworld>/Pal/Content/Paks/LogicMods`. Pass `--stage` to
build without installing. `unreal/shell/README.md` covers producing the cooked assets from stock
UE 5.1.1, with no Palworld SDK and no Wwise.

`build/` is git-ignored: the pak is a build artifact, reproducible from the sources in `unreal/`,
and a binary in the history would be rewritten on every widget change.

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

`min_suitability_rank` stops the mod from DEDICATING a low-rank Pal to a job a specialist should
be doing. It does not stop that Pal doing the work: the gate is applied when the pass pulls a Pal
onto a fence, not when it decides which work a Pal is permitted, so a rank-1 Pal keeps the
permission and the game's own AI may still send it.

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
untouched, and they stay that way until somebody says otherwise. Where every base camp the
server currently has loaded belongs to one guild, the mod says so once and offers `!pwp adopt`,
which makes those limits that guild's and gives every limit an owner.

Adopting is deliberate rather than automatic, and the reason is worth knowing before you run it.
The mod can only read a guild off a base camp that is streamed in, and it cannot list the guilds
a save contains at all. On a server where one guild is online and another is not, only the first
guild's camps are loaded, so "every camp agrees" is true and says nothing about the guild that is
offline. This used to happen by itself on the next pass, which meant a shared limit could become
one guild's, on disk, with the wildcard deleted and no way back, because somebody walked near
their own base. If more than one guild plays on your server, check the others are not relying on
those limits first. Where the loaded camps already span several guilds the offer is not made, and
the panel says so rather than pretending to remove a shared rule. `0` removes a limit rather than
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
spheres in your pockets do not count towards a ceiling. Items dropped on the base ground DO count,
along with every container.
What does count is every container on the base, chests and production stations
alike, and the feed box and loose dropped items with them; `!pwp stock` prints both
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

Every container on the base, chests and stations alike. `uncounted_containers` ships empty, so
nothing is excluded by default, including the feed box.

This started as a list of classes to *include* and that was the wrong way round. Palworld has
far more station types than any hand written list will name, and each one missed is a ceiling
quietly overshooting by whatever that station holds. A Logging Site sitting on 297 wood was the
one that showed it. Counting everything and naming the exceptions means a station type this mod
has never heard of still counts.

The feed box used to be excluded, on the reasoning that food set aside to be eaten is not stock,
so counting it would stop a ranch that is only keeping pace with what the Pals get through. What
that produced was a lie on the screen: a base holding 20,454 Berries in its feed box, against a
3,000 ceiling, reported `0 in storage` and went on planting, because the only berries it had were
in the one container the mod refused to look at. A limit that ignores most of what you own is not
a limit, and "in storage" has to mean in storage.

The ranch case is real, but it is a hysteresis problem rather than a counting one: the box drains
as the Pals eat and the work resumes when it falls back under the ceiling. If you would rather
have the old behaviour, name the classes yourself:

```lua
uncounted_containers = {
    "PalMapObjectPalFoodBoxModel",         -- food set aside for pals to eat
    "PalMapObjectDropItemModel",           -- dropped on the ground
    "PalMapObjectPickupItemOnLevelModel",  -- waiting to be collected
},
```

Dropped and lying-about items are loose world clutter rather than base stock, and one test base
carried 54 of them, so those two are worth excluding if the clutter bothers you.

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

## The Production Limits panel

`Alt+F1` opens it, `Alt+F1` or `Esc` closes it. It is the only part of the mod you can reach
without a chat box, which matters in single player, where there is no chat box at all.

The arrow keys move around it and Enter activates. Those were bound for a long time before they
worked: the panel used to hold a UI-only input mode, and under that route the PlayerController
sees no key presses at all, so the keys were dead exactly when they mattered. It now holds a
Game-and-UI route and suppresses the player pawn instead, which is what a controller needs too.

The name is worth getting right because the mod has two features that sound alike. This panel
sets **production limits**: how much of an item a base stockpiles before the job that makes it
stops. It does not set work priorities. Those live on the Monitoring Stand, described in the next
section, and are a different screen with a different control.

**RULES** lists the limits in force:

| column | what it is |
| --- | --- |
| JOB | the work type the limit suspends |
| ITEM | what is being counted |
| IN STORAGE | how much the base holds now, amber once it is at or over the limit |
| LIMIT | the ceiling, click it to type one or use the arrow keys to step it |
| STATUS | `Working`, `Stopped` when every base is at the ceiling, or `Stopped at 2` meaning two of your bases are at it and the rest are still going. Also `Waiting` when this item is capped but the job runs on for another, `Rule off` when the mod is disabled, and `Testing` in dry run |

`Remove` deletes a rule. `+ Add a rule` opens the other tab.

**ADD** is a picker of everything the base is holding, largest first, with a search box. Click an
item to create a limit for it. Items that already have one are marked `LIMITED` and clicking
them takes you to the rule instead. `Show every item with a job` widens the list from what you
are holding to every item a Pal could produce, which is how you set a limit on something the base
has not made yet.

Changes take effect on the next pass, and the panel triggers one when you make one, so a rule you
set is usually in force before you have closed the window.

On a multiplayer server the rules belong to the guild, and the panel shows and edits only your
own. A client's edits are sent to the server, which decides; the panel says "asked the server to"
rather than claiming a change it cannot confirm.

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

## Settings in game, via DarnMenu

If [DarnMenu](https://www.nexusmods.com/palworld/mods/4245) is installed, **ESC > Darn Mod
Options > Pal Work Priority** edits the settings that otherwise need `config.lua` opened in a text
editor: whether the mod assigns at all, test mode, the pass interval, spread or fill, the per-job
Pal cap, the minimum rank worth dedicating, the storage scope, the log level, **and the hotkeys**.

Priorities and production limits are deliberately absent. Both are already editable in game, on
the Monitoring Stand and in the Alt+F1 panel, so a second place to set them would be a second
thing to keep in step.

Every option is marked as needing a relaunch, which is honest rather than cautious: config is read
once at load and the pass, the grid and the panel each capture what they need from it.

`config.lua` stays the baseline. An option the player never touched is absent from
`Mods/shared/PalWorkPriority_user.lua` and falls through to the shipped value, and deleting that
file restores the defaults exactly. Without DarnMenu the schema this mod writes simply sits unread,
so nothing here can stop the mod working.

**Rebinding a hotkey** replaces the shipped Alt+Fn. A saved key that this UE4SS build has no entry
for falls back to the default with a warning, rather than binding nothing - a hotkey that silently
does not exist is the worst outcome available, and this mod has shipped one of those before. The
discovery and transport-test keys are developer tools and stay on Alt+F5 and Alt+F9. Esc is not
rebindable, because it is Esc.

## Playing with a controller

The panel is fully drivable from a gamepad, including on a Steam Deck.

| control | what it does |
| --- | --- |
| **RB + View** | opens the panel |
| **D-pad up/down** | one press, one row |
| **D-pad left/right** | raises and lowers the selected ceiling |
| **A** | confirm, the same as Enter |
| **X** | Remove the selected rule |
| **B** | closes the panel |
| **LB / RB** | previous and next tab |

Opening needs two buttons held together for a reason worth knowing. While the panel is shut the
game owns its input and the mod cannot take it away, so any single button bound here would open
the panel **and** do whatever the game has that button doing. Two held at once is a gesture
Palworld does not use. `RightShoulder` and `Special_Left` were also checked against every mod
installed alongside this one: FreeCam claims `LeftTrigger` and `Special_Right`,
FullSphereSummon claims `LeftShoulder` and `FaceButton_Left`, and both stick clicks are taken.

Up and down move a whole **row** rather than one control, so reaching the next rule is one press
and not three. That leaves Remove somewhere the selection never lands, which is why **X** acts on
the selected row directly.

The tab bar is deliberately not in the vertical walk. Wrapping from the last row used to step
through both tabs and the close button on the way round; the shoulders and **B** reach them the
way a pad expects to.

### Why it reads the controller the way it does

`RegisterKeyBind` reads the keyboard and nothing else, so a controller press never reaches it.
The pad is polled through the PlayerController instead, with `IsInputKeyDown` and an `FKey` built
as a plain table with a `KeyName` field, which is how FreeCam and FullSphereSummon read theirs on
this build.

Three things had to be true at once, and each was measured rather than assumed:

- **The route cannot be UI-only.** Under `SetInputMode_UIOnly*` the PlayerController sees nothing,
  keyboard or pad, because a UI-only mode routes both into Slate's focus framework instead of the
  input stack. `GameAndUIEx` reads the keyboard; the pad needs the next item as well.
- **The pawn is suppressed, not the input mode.** `SetIgnoreMoveInput`, `DisableInput` and
  `SetDisablePlayerInput` on the pawn stop the character walking while the panel is up, which is
  the whole reason UI-only was chosen originally. FreeCam does the same and that is exactly why it
  can read a pad.
- **The controller is disabled while the panel is open**, or the d-pad opens the build menu
  behind it. That is safe only because the panel closes itself the moment the game opens UI of its
  own: a disabled controller ignores the game's menus too, so the two must never be on screen
  together.

The pad is read on the mod's 16ms loop rather than its 100ms one. `IsInputKeyDown` reports a level
rather than an event, and a deliberate d-pad press is 60 to 100ms, so reading it on the slow beat
dropped short presses and looked like an unreliable controller.

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
| `!pwp sweep <seconds>` | how long the chest-count cache lives. It does not print the sweep; `!pwp stock` does |
| `!pwp trace on\|off` | breadcrumb marks to `trace.txt`, for finding what was in flight when a hard crash killed the process. A file write per risky touch, so it is off by default |
| `!pwp adopt` | take the wildcard rules left by an older version into your own guild |
| `!pwp names` | what the game calls each item id, and how long resolving all of them took |
| `!pwp pad probe\|watch` | whether a controller is readable, and what it is reporting |
| `!pwp panel <verb>` | drive the panel from chat: `input`, `unstick`, `pawn`, `drive`, `ui`, `hover` |
| `!pwp click` / `!pwp clicks` | click a named panel control, and toggle click reporting |

`!pwp restore` is the one to remember. The fences are the game's own saved data, so they outlive
the mod: uninstalling while a base is fenced leaves Pals with most of their work switched off and
no way back but the stand, by hand. Run it before you remove anything. `!pwp off` does it for you.

Keys, for the same actions. Everything is on Alt, and deliberately so: Ctrl is crouch, so a
`Ctrl`+function key rolls your character every time you press it, and Shift is sprint. Palworld
binds Alt to nothing at all, which makes it the only modifier that is free to hold.

| key | does |
| --- | --- |
| `Alt+F1` | open and close the Production Limits panel |
| `Esc` | close the panel, if it is open |
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
`!pwp restore` have no key, and a single player save has no chat box either.

`remote.txt` is the way in. It sits next to `priority.log` in the mod folder, is read once a
second, and every line after the first is an instruction:

    17                   any number, changed each time, so rewriting the same instruction counts
    pwp restore          any chat command, exactly as you would type it
    open                 open the panel, or close
    mode item            which screen the panel shows, item or list
    reload               swap panel, overlay and icons without a restart
    cmd shot showui      run a console command, this one takes a screenshot

The first line is a nonce: the file is acted on when its contents change, so bumping that number
is how you run the same instruction twice. `python tools/remote.py "pwp restore"` writes it for
you and prints whatever the mod said back.

This exists because the panel takes the input mode while it is open, so UE4SS never sees a key
press - which is exactly when you most want to tell the mod something. A file can be written at
any moment from outside the game.

It matters most for dry run: with `dry_run = true` in `config.lua` there is no key and no chat,
so `remote.txt` is the only way back without editing the file and restarting.

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
`14 = Anyone`, so `workdefs.enum_offset` stays 1.

**`config.work_priority.Anyone` is inert.** It is shipped, it is read, and it changes nothing,
whatever you set it to. Nothing ever resolves a work object to suitability 14: it appears in no
entry of `WORKTYPE_TO_SUIT` and in none of the keyword patterns, so demand for it is always zero,
the type is never wanted, and no fence ever covers it. An earlier version of this file claimed
the rank gate was bypassed for it and any Pal would do. That was never true. Making `Anyone` work
needs demand resolution for value 14, not a config change.

## Multiplayer

**Install it on the server as well as on every player who wants the UI.** The
server is where the work actually gets decided, so a client-only install does
nothing: no passes run, the grid stays empty and every edit is sent to a server
that is not listening. Subscribing handles this automatically for a server that
subscribes to Workshop mods; for a manually managed server, see
[Dedicated servers](#dedicated-servers) below.

The server owns both data files and makes every decision. A client owns nothing:
it draws what the server sends and sends back what the player clicks.

**Priorities and production limits are guild-scoped.** Each guild sees and edits
only its own, and the server files an incoming change under whichever guild the
message arrived from - which a client cannot forge, because the guild is never
part of the payload. A player in no guild is refused rather than given
everyone's.

**The Monitoring Stand grid works on a client.** The server sends each pal's
ranks and priorities, the client draws them, and a click goes back up as a
request that the server validates, applies, saves and pushes to everyone. The
number that changes on screen is the server's answer, not a local guess.

**Passes only run on the server.** `run_pass` returns immediately without
authority, so nothing is estimated or decided client-side. `!pwp status` on a
client says so.

**Players without the mod are unaffected.** Everything travels on two RPCs the
vanilla UI already uses, addressed to one connection at a time, and an unmodded
client is never sent anything.

### Dedicated servers

The mod has to be installed on the server itself, under the server's own UE4SS
Mods directory, exactly as on a client:

    PalServer/Mods/NativeMods/UE4SS/Mods/PalWorkPriority/

`Info.json` declares a server install rule, so a server that subscribes through
Workshop gets it without any manual step:

    { "Type": "Lua", "IsServer": true, "Targets": ["./Scripts"] }

The pak is deliberately NOT installed on a server - it carries only the panel's
widget, and a headless server draws no UI.

Two things worth knowing when running one:

- **With nobody connected the server does nothing.** The game runs no base work
  without a player present, and there is no player controller to send changes
  through, so the pass stands down rather than sending into the void. It
  resumes on its own when somebody joins.
- **Your own chat commands work; another player's do not.** A chat message
  carries who sent it, so the mod compares it against the player at this
  machine. Anything that changes something is refused when it came from someone
  else - chat reaches everybody, and some of these cannot be undone. If the
  sender cannot be identified at all, changing commands are refused while
  anyone else is connected. Read-only commands - `help`, `status`, `net` -
  always work, and the server console and `remote.txt` are never restricted.

## Publishing to Steam Workshop

`Info.json` is already in the Workshop package format. Before uploading:

- set `Author` to your Steam name
- set `MinRevision` to the game revision you actually tested on
- confirm the `Dependencies` entry. These are **`PackageName` strings, not Workshop IDs**: every
  installed mod that depends on UE4SS lists `"UE4SSExperimentalPW"`, and PalSchema mods list
  `"PalSchema"`. A numeric ID there makes the Mod Uploader fail to read the file at all, and the
  mod shows up in its list with a blank name
- add a `thumbnail.png`
- **copy `build/PalWorkPriority.pak` into a `LogicMods/` folder in the package**, beside
  `Scripts/`. `Info.json` carries the rule that installs it:

  ```json
  { "Type": "LogicMods", "Targets": ["./LogicMods/"] }
  ```

  Both halves are needed and neither is obvious. The pak in the package does nothing on its own,
  because the uploader deploys what `InstallRule` names; the rule does nothing without the pak.
  This is the step that hides, because the mod runs on the developer machine either way - the pak
  was installed by `pak_mod.py` months ago and is still sitting in `Paks/LogicMods`. A subscriber
  gets only what the package carries, so leaving either half out ships a panel whose header is
  collapsed onto one line, which reads as a layout bug rather than a missing file.

  No `_P` suffix. That belongs to paks delivered through `~WorkshopMods/`, which is a different
  mechanism; everything in `Paks/LogicMods` is named plainly, `AutoHatch.pak` and
  `CreativeMenu.pak` alongside ours. `AutoHatch` is the mod to copy here - a Lua mod that ships a
  widget pak exactly this way.

**Check the pak before packaging.** `build/PalWorkPriority.pak` is an artefact, not a build
step, so it can sit stale while a newer one is installed and working. That happened: a pak six
hours older than the live one shipped, the panel found 7 of its 21 named widgets and fell back to
the blueprint's own defaults, and it read as a broken layout rather than as the wrong file.

```
python tools/pakcheck.py
```

It compares what you are about to ship against the pak the game is running, which is the only one
you have evidence about. It cannot check the CONTENTS - the pak index does not expose so much as
a file name, so the widget names are unreachable without real Unreal tooling.

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
