# Pal Work Priority

Numeric work priorities for base Pals in Palworld. You decide that Transporting gets staffed
before Mining, and the mod hands each job to the best-suited Pal that is still free.

Vanilla only lets you tick a work type on or off per Pal. This adds an ordering on top: priority
1 work is filled first from the whole roster, priority 5 gets whatever is left over.

## How it works

Assignments go out through `RequestFixedAssignWorkInBaseCamp_ToServer` — the same server RPC the
vanilla "assign to this workstation" UI uses. Nothing is written to your save, no game files are
patched, and unmodded players in the same session are unaffected.

Each pass, per base camp:

1. every pending work is bucketed by the suitability it needs
2. buckets whose resource ceiling is already met are dropped
3. surviving buckets are visited in your configured priority order
4. inside a bucket, each work takes the highest-ranked Pal not already claimed this pass

A Pal is claimed at most once per pass. That single rule is what makes priority mean something:
priority 1 picks from everyone, priority 5 picks from the leftovers.

Assignments are remembered between passes, so a Pal already doing the right job is left alone
rather than being re-assigned every cycle and made to re-path.

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

## Chat commands

| Command | Effect |
| --- | --- |
| `!pwp status` | current mode, camps loaded, which reads resolved |
| `!pwp run` | run one pass now |
| `!pwp dry` / `!pwp live` | log-only, or actually assign |
| `!pwp on` / `!pwp off` | enable or disable |
| `!pwp reload` | re-read `config.lua` without restarting |
| `!pwp stock` | print base storage by item id, and write `Stock.txt` |
| `!pwp discover` | write `Discovery.txt` (see below) |

`F10` runs a pass and `F11` writes `Discovery.txt`, for sessions where chat input is not available.

## Two things this build has not confirmed

Both are isolated so they can be fixed without touching the rest of the mod. Run
`!pwp discover` in a loaded world and read `Discovery.txt` next to the mod.

**Which read gives a work's required suitability.** No published mod reads this, so
`SUITABILITY_PROBES` in `Scripts/palapi.lua` is a candidate list tried in order at runtime. The
first one that answers is cached and logged. `Discovery.txt` reports which candidates responded
on live work objects, and dumps the real `PalWorkBase` schema — once confirmed, collapse the list
to the single correct entry. If none answer, the mod logs a warning once and assigns nothing.

**Whether `EPalWorkSuitability` starts at 0 or 1.** `workdefs.enum_offset` assumes 1, which is
what `AutoAssignResearchLab` ships and what works on revision 82182. `Discovery.txt` sweeps the
rank function across a wider range and prints both interpretations side by side; find a Pal whose
suitabilities you know and see which column lines up. If it is wrong, every Pal gets assigned to
the wrong job, so check this before going live.

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

This is an independent implementation. It shares no code with PalPriority and takes a different
approach: PalPriority flips the vanilla per-Pal work toggles, this drives fixed assignments.

## License

MIT. See [LICENSE](LICENSE).
