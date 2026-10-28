# Pal Work Priority

Work priorities for base Pals in Palworld, with an editor on the Monitoring Stand and a separate Production Limits panel.

**0.5.0 is a reliability release.** Saved priorities and X survive restarts, the panel no longer doubles or sticks, Pals mine and chop again, limits can be added again (Mining limits per rock item), and the Monitoring Stand and panel work with a controller. What was tested and how is in the [release plan](docs/RELEASE-0.5.0.md) (the project notes form an Obsidian vault, start at [docs/Home.md](docs/Home.md)); public reports are tracked in the [comment census](docs/comment-ledger-2026-09-11.md).

**Not covered by the 0.5.0 tests:** two real players in two guilds at once, players without the mod editing on a modded server, Steam Deck hardware, item-specific limits for buildings (Stone Pit, logging site, furnaces) and the asynchronous saver (built, off, planned for 0.5.x).

## What the mod controls

Pal Work Priority changes which work types each Pal may perform. Palworld's AI chooses the actual job within those permissions. A permitted job, a displayed priority and a Pal actively producing an item are three different observations.

- **1 is highest priority, 5 is lowest, and X disables that work.** Existing saved values keep their meaning.
- A dash means the Pal cannot perform that work; it is not another priority.
- The candidate's fresh-install policy preserves vanilla selections: checked work starts at equal priority 1 and unchecked work stays X. Import requires evidence that an older mod has not already altered those flags.
- **A Pal with no order is left to the game.** When every job a Pal may do has the same number (a fresh install's "all 1", an all-1 setup, or a Pal nobody edited), the mod does not steer it: the game picks its work, and only X and production limits still apply. Give one job a different number and the mod steers that Pal. `leave_unordered_pals_to_game = false` in `config.lua` steers every Pal, as 0.4.1 did. A Pal nobody edited reads as 1 for every job; the 1-5 ranking in `config.work_priority` no longer applies to it.
- Upgrade migration is designed to preserve existing mod settings when their files are available. Keep pre-update backups: preservation through the actual Workshop updater remains unverified. Previously modified permissions cannot safely reveal the player's original choices. X values lost by older saves cannot be reconstructed without an earlier copy.
- Missing job, authority, storage or synchronization information must remain unavailable; it must not become a confident permission decision or “Working”/“Stopped” status.

These are the candidate's behavior contract. Fresh-install detection, manual assignments and transitions between worlds remain native acceptance tests.

### Balanced and strict staffing

`assignment_mode = "spread"` is **balanced staffing**: distribute workers across waiting work types before adding further workers to one type. A lower-priority type can receive its first worker before a higher-priority type receives another.

`assignment_mode = "fill"` is **strict priority order**: allocate higher-priority demand first, subject to eligibility and the staffing limit. Neither mode creates jobs or directly commands the AI's next action. Existing mode choices survive upgrades.

`max_pals_per_work_type` controls the intended number of eligible workers per type; `false` removes that limit. The candidate must count held workers and prevent fallback permissions from bypassing it. Actual occupancy still needs native verification.

Manual assignments should be respected. Conflicts with explicit X or production limits need to be reported rather than silently fought. Research, cooling, generation, ranching and fixed assignments remain acceptance cases; an enabled permission alone is not a passing test.

## Installation and runtime compatibility

Use one installation route. A Workshop copy plus a manual copy can load duplicate code or panels. Close the game before replacing files, and back up the world and existing mod settings first.

The intended dependency is [Experimental UE4SS for Palworld, Workshop item 3625223587](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587), package name `UE4SSExperimentalPW`. This identifies the distribution; it does not certify every update.

The saved August test log identifies UE4SS `c838a8ac`. The dependency reviewed in September advertises `2281fa31`, updated September 3. **0.5.0 was tested on game 1.0.5 (build 102999) with the Experimental UE4SS for Palworld from the Workshop and on a GPortal dedicated server.** Acceptance must record the actually loaded game revision, UE4SS build/binary hash, Lua version, mod source/package hashes and pak hash. A dependency page or banner alone does not prove what the process loaded.

### Steam Workshop

Subscribe to [Pal Work Priority](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856) and the required UE4SS distribution, enable them through the game's supported mod flow, and fully restart. The package must include both Lua scripts and `LogicMods/PalWorkPriority.pak`. Installation rules determine their destinations; do not copy the staging directory into an unrelated UE4SS layout.

On a dedicated server, authoritative Lua belongs on the server as well as on modded clients. The panel asset is client-side. Matching candidate versions are required until version negotiation passes acceptance.

### Manual archive from Nexus

Follow the archive's `INSTALL.txt`. The intended manual archive is extracted into the **Palworld game root**, producing:

```text
Mods/NativeMods/UE4SS/Mods/PalWorkPriority/
    enabled.txt
    Scripts/main.lua
    Scripts/...
Pal/Content/Paks/LogicMods/PalWorkPriority.pak
```

UE4SS itself must already be installed in that native-mod layout. Other distributions may use different paths; installing this archive into them has not been accepted. After restart, confirm one mod instance and the mounted panel asset. A missing pak is a dependency failure, not a working fallback panel.

**Alt+F1 opens Production Limits. Alt+F2 runs a scheduler pass; it does not open the panel.** Priorities are edited at the Monitoring Stand.

### Vortex

Tested 2026-10-28 with the Palworld Vortex extension 0.5.0: install, update and removal pass (docs/vortex-2026-10-28.md). The extension's root-mod installer copies the archive unchanged into the game root, which is the manual layout above. Turn off "Manage modding requirements (UE4SS, Unreal Pak Tool) automatically" in Settings > Mods when UE4SS comes from the game's mod loader or the Workshop; otherwise Vortex adds a second UE4SS under `Pal\Binaries\Win64`. With the game on another drive, the staging folder must be on that drive ("Suggest").

## Settings and save files

The candidate's editable configuration is **`config.lua` in the mod root**, beside `priority.log`, outside replaceable `Scripts` content. `Scripts/config.lua` is the source template; release archives map it to **`Scripts/default_config.lua`**. This prevents manual extraction from overwriting an older editable `Scripts/config.lua` before migration can preserve it. Existing configuration migrates with **`config.migration.bak`** retained, and an existing root configuration takes precedence. Keep the old copy and migration backup until restarted settings have been verified. **This mapping protects manual merge/extraction only:** a Workshop updater could delete the old Scripts directory before first migration, in which case edited config cannot be recovered from it. Keep a pre-update backup and verify the actual updater route; automatic preservation on every route is not established.

Malformed or nonfinite configuration is validated before migration and before main reload/override application. The candidate rejects the whole invalid configuration and retains the prior accepted settings; valid priority 1–5/X meanings are unchanged.

Preserve these on updates and reinstalls:

| File | Purpose |
| --- | --- |
| `config.lua` | Editable configuration |
| `priorities.txt` and recovery generations | Durable per-Pal priorities, including X |
| `caps.txt` and recovery generations | Durable authority-owned rules |
| Configuration migration backups | Previous configuration |
| `priority.log` | Command output, diagnostics and save failures |

The checked save format validates the live file plus `.tmp`, `.pending` and `.bak` generations. `.pending` protects a recovered temporary generation during a subsequent save attempt. Failed open, write, close or replacement must leave settings dirty and report an error. Recovery validates contents before selecting a generation. This reduces recoverable save failures; it is **not** protection against every crash, disk failure or power loss. Keep an independent backup.

**Save migration is forward to the candidate schema**, including inherited-rule OFF masks. Keep a separate pre-upgrade backup in addition to rotating recovery generations. Downgrading requires restoring compatible pre-upgrade settings with the matching older version; do not give the older release current new-schema files.

Do not hand-edit generated saves while the mod runs. Integrity information can make ad hoc edits invalid; use the interface or a reviewed migration procedure. Temporary roster positions such as `slotN` must not become durable Pal identities.

Remote server snapshots are session data, not local saves. Joining a server then hosting locally must not carry its rules into the local world; this remains a required test.

Optional [DarnMenu](https://www.nexusmods.com/palworld/mods/4245) settings can override configuration. Back up its `Mods/shared/PalWorkPriority_user.lua` file too. Restart after configuration/runtime changes so every module uses the same settings.

## Editing priorities

Open the Monitoring Stand's work-suitability screen. Left click raises a priority toward 1; right click lowers it toward X. Both ends clamp:

```text
left:   X → 5 → 4 → 3 → 2 → 1
right:  1 → 2 → 3 → 4 → 5 → X
```

For the candidate's direct **1–5/X** entry, first click a priority or select one with the arrow keys to give the stand keyboard focus. Number keys then edit the hovered priority, or the focused cell when nothing is hovered. Hovering alone does not take focus from another menu. This requires the matching StandInput asset; broader native focus, controller and multiplayer acceptance remains open.

A client sends edits for server validation. Pending choices must be distinguishable from confirmed values; rapid clicks should accumulate on the pending choice. Rejection, incompatibility and unavailable snapshots must be visible. An optimistic number is not proof the server saved or applied it.

## Production limits

**Alt+F1** opens/closes the panel. Escape should cancel an unfinished amount edit before closing. The preferred panel position is retained; pagination and amount placement are repaired within it.

An amount must be a valid whole number in the supported range, including when entered through the limit command. Fractional input is rejected rather than rounded. Invalid text leaves the previous value intact. Stripping punctuation from `-100` or `1.5` to produce a different number is not valid confirmation.

### Group limits

Every limit controls an entire work suitability, both older rules and ones added in the panel (adding them works again since 2026-10-27, as in 0.4.1). A stone-only Mining limit can stop ore mining too. With several Mining thresholds, the group keeps running until every threshold is reached, so individual outputs can exceed their number while another remains short.

Existing rules retain that behavior under an explicit **legacy group limit** label. They remain reviewable, editable and removable; an upgrade must not silently reinterpret them as item-specific rules. Older wildcard rules retain their scope until deliberately migrated. Do not adopt shared rules merely because only one guild's camps happen to be loaded.

Clearing a guild override previously exposed its inherited shared/configuration ceiling again while reporting success. The candidate persists a **guild-local OFF mask** to keep the cleared inherited rule disabled across save/load. Other guilds keep their rules. A scope/round-trip regression was added; native multiplayer verification remains pending.

### Mining limits per item (natural rocks)

Since 2026-10-28 a reached Mining limit switches off only the natural rocks whose main drop is that item, by marking those rocks' work NotWorkable; other rocks stay in use, and Mining stops as a whole only when no rock or pit still produces something wanted (`item_limits_on_rocks`, on by default). Rocks do not save that state, so nothing outlives the mod. Buildings are never written, because their work state is saved: a Stone Pit keeps producing while other mining goes on. Evidence: docs/per-item-limits-2026-10-27.md.

### Other item-specific limits (not available yet)

Limits that stop one product while another of the same work type continues are planned for buildings and other work types. Until then, adding a limit for the other product too keeps the work type running until both are reached. The output-control adapter contract requires a supported producer to stop admitting capped output while unrelated production of the same suitability continues. It must identify producer/storage scope, preserve already-started work and specify a measured in-flight overshoot allowance.

**No native producer adapter is currently accepted.** New limits are therefore group limits, and the panel says so before and after one is added. An item-name heuristic, suitability toggle or simulated adapter is insufficient. The candidate does not yet provide verified stone-only, synthesizer or other item-specific production control.

Storage scope must be visible: selected base, guild and local versus intended broader scope. Player inventory is not base storage. Shared guild storage must be counted once. Incomplete storage reads must display unavailable data rather than measured zero. Native container coverage and guild-chest accounting remain gates.

The mod does not promise to create crafting queues. A cap is not an automatic recipe selector or minimum-stock order.

## Controls and command output

| Default control | Action |
| --- | --- |
| Alt+F1 | Open/close Production Limits |
| Alt+F2 | Request a scheduler pass |
| Alt+F3 | Print storage diagnostics |
| Alt+F10 | Switch balanced/strict mode |
| Alt+F11 | Change worker cap |
| Alt+F12 | Change storage scope |
| Arrows / Enter | Navigate/activate panel controls |
| Escape | Cancel amount editing; otherwise close |

**Controller** (tested with an XInput pad, 2026-10-22; plug it in before starting the game). On the Monitoring Stand: D-pad moves, LB or A steps toward 1, RB toward X, X sets X, View opens Production Limits (Y stays the game's view switch). In the panel: D-pad moves, Y opens or raises, X removes, LB/RB switch tabs, LT/RT turn pages, B closes the panel. A in the panel is the game's own confirm and does nothing there. Steam Deck hardware has not been tested.

Chat replies go to **`priority.log` in the mod root**, and to UE4SS's log. They do not necessarily appear in game chat. Singleplayer may lack chat; the opt-in developer channel is described in [testing](docs/testing.md).

| Command | Purpose |
| --- | --- |
| `!pwp help` / `!pwp status` | Commands, role and state |
| `!pwp run` | Request a pass; sent is not completed |
| `!pwp dry` / `!pwp live` | Simulate / allow permission changes |
| `!pwp on` / `!pwp off` | Enable / disable and restore permitted work |
| `!pwp restore` | Restore permitted work before removal |
| `!pwp mode` / `!pwp cap` | Staffing mode / worker cap |
| `!pwp limit` / `!pwp stock` | Rules / storage |
| `!pwp rocks` | Mining rocks held by limits and which rock each miner is on (host or server) |
| `!pwp net` | Transport diagnostics and echo test |
| `!pwp perf [on\|off\|reset]` | Profiling controls and bounded report |

Limit command output now distinguishes queued client requests from confirmed changes and reports failed clears as failures. The limit listing explains legacy group semantics and shows current guild/base only from verified status evidence; unknown or unscoped stock is unavailable, not zero. Four real command-handler regressions fail before these fixes and pass afterward with mocked boundaries; native behavior remains unaccepted.

Read the actual result after mutations. An echo is not an end-to-end edit test. Other players' chat is not an administrator channel; sender/guild authorization must remain intact.

## Safe removal

The mod writes the game's saved permission flags. Deleting files can leave restrictions behind.

1. Stop the game/server and back up the world and mod settings.
2. With the mod still installed on the authority, use `!pwp off` or the supported restore path. Read its result and verify affected Pals' permissions.
3. Save normally, stop the game/server and preserve settings/backups before removing through the original installation route.

Restoration allows work consistent with saved explicit X choices and capabilities; it cannot reconstruct unknown pre-mod choices. A local client command alone does not prove server restoration. Deleting the entire mod folder is not a substitute for restoration and backup.

## Development, measurement and release

Follow [docs/testing.md](docs/testing.md). Compile with real Lua 5.4 and run isolated regressions before a checked deployment. The structural checker supplements compilation; it is not a compiler or behavioral test.

Keep automatic mod reload disabled during acceptance; restart for runtime changes and never deploy during a measurement window. The remote channel must exist before startup to be enabled and must never ship. Broad reflection/parameter dumps have caused native crashes. `pcall` cannot catch an access violation; even `IsValid()` on a stale wrapper can crash.

Read-only `tools/fingerprint.py` inventories source/package/install/process identities; `tools/analyze_frames.py` analyzes an existing independent capture. They do not launch the game, record frames, deploy or establish compatibility. Use their `--help` and the [testing protocol](docs/testing.md#read-only-identity-and-frame-analysis-tools); fixture success is not a native measurement.

**Unmeasured does not mean zero milliseconds.** Nested timings are inclusive and must not be summed. Complete scheduler/callback timings and independent frame captures are required before claiming a hitch is eliminated. Cadence, no errors and fence membership do not establish stutter-free gameplay or correct production.

Both archives must come from one clean reviewed source set with matching versions, hashes and panel contract. `tools/release.py` requires a reviewed pak and full SHA-256; it does not cook the asset or prove native compatibility. The reviewed pak's integrity result and full hash are recorded in the reliability ledger. This is integrity evidence, not proof of native mounting, widget behavior or current-runtime compatibility. Hash equality is not widget-tree acceptance. Exclude saves, backups, logs, developer triggers and loose duplicate scripts.

The [release checklist](docs/RELEASE-0.5.0.md) and [reply drafts](docs/release-replies-0.5.0-draft.md) are separate from publication. Do not upload until applicable blockers pass.

## Credits and license

Game-side API understanding was informed by AutoAssignResearchLab, BreedingHelper and [PalPriority](https://www.nexusmods.com/palworld/mods/3830). This is an independent implementation. MIT; see [LICENSE](LICENSE).
