# Decision log

What was decided, why, and what was rejected. Newest first within each
section. One entry per decision; link the dated evidence file rather than
repeating it. If a decision is reversed, keep the old entry and mark it
**Superseded** with a link to the new one. Mistakes go to [LESSONS.md](LESSONS.md).

Format: **Decision** - why. *Rejected:* alternatives and the reason. *Evidence:* link.

## Release and scope

- **2026-10-11 - 0.5.0 ships a defined scope, not the full plan.** The full
  plan was estimated at 2-6 more weeks with open-ended items, while users sit
  on 0.4.1's known P1 bugs. Scope and exit conditions are in
  [RELEASE-0.5.0.md](RELEASE-0.5.0.md). Item-specific production limits move
  to 0.6. *Rejected:* holding every gate in release-gates for 0.5.0.
- **2026-10-11 - Performance is best effort, not a fixed target.** The
  user's call: optimise as far as practical rather than promise a number.
  "Stutter-free" is impossible as a gate because the game itself hitches
  about twice a minute without the mod. To keep the gate from running
  forever, it closes when the remaining costs are each fixed or justified and
  two rounds in a row gain less than 1 slow frame per minute
  ([RELEASE-0.5.0.md](RELEASE-0.5.0.md) G5). *Rejected:* a hard limit of
  2 extra slow frames per minute (proposed, not chosen).
- **2026-10-11 - Async saving does not block 0.5.0.** It stays off by default
  (as it already is) unless its gates in RELEASE-0.5.0.md pass first. The
  synchronous writer with checked saves and backups is the shipping path.
  *Evidence:* [async-enablement-2026-10-04.md](async-enablement-2026-10-04.md).
- **2026-10-11 - Work lives on branch `reliability-0.5` until release.**
  Master stays equal to what the stores serve (0.4.1).
- **2026-10-11 - The GPortal server address stays out of the repo.** The repo
  is public. The working macro on the Desktop keeps it, and the repo copy reads
  `PWP_SERVER`. The Windows user name was NOT scrubbed: it is already in the
  public history and matches the public handle.

## Saving and settings

- **2026-10-04 - Native writer through UE4SS's public Lua module interface,
  not the private Unreal SDK.** The matching SDK dependency was not
  obtainable, and a minimal module compiled against the installed UE4SS
  loaded and passed 1,000 in-game calls. *Rejected:* waiting on SDK access.
  Unreal's async SaveGame was prototyped first (worked, but no reliable save
  destination identity). *Evidence:* [async-save-route-research-2026-10-04.md](async-save-route-research-2026-10-04.md).
- **2026-10-03 - Async saves bind to the GameState save-directory ID, never
  the menu's.** The menu keeps the old local ID after joining a server, so a
  write could land in the wrong world. *Evidence:* [async-save-world-transition-2026-10-04.md](async-save-world-transition-2026-10-04.md).
- **2026-10 - After travel, the writers stay closed and the stand says
  "Restart the game to edit".** Same-process re-arming is not supported.
  *Rejected:* auto re-arm (unproven ownership handover).
- **2026-09-29 - Async save research started** because of 1.2-2.2 s flush
  stalls on the GPortal server. *Rejected then:* PalPriority's approach (save
  once after 3 s idle, still on the game thread) because it lowers stall
  frequency, not duration. In hindsight, see LESSONS "A gate without a done when".
  *Evidence:* [save-flush-2026-09-29.md](save-flush-2026-09-29.md), [reference-persistence-2026-09-29.md](reference-persistence-2026-09-29.md).
- **2026-09-11 - Fresh installs mirror vanilla: checked work = 1, unchecked = X.**
  Existing priorities survive upgrades. The user confirmed "1 is fine".
  *Rejected:* everything at 3, and guessing intent from permissions an older
  version already changed.
- **2026-09-11 - 1 is highest, 5 lowest, X disabled.** Explained in the UI
  rather than reversing saved values. Cycling wraps 1 <-> X (Steam request).
- **2026-09-11 - Unreadable settings are never replaced with defaults.**
  Unknown is not "fresh install". See LESSONS.

## Scheduling and limits

- **2026-09-26 - Resolve the network component only when a pass has changes
  to send.** Learned from PalPriority. Pass dropped 85.6 to 66.2 ms on the
  server. *Rejected from the same comparison:* caching engine objects (our
  crash history). *Evidence:* [palpriority-comparison-2026-09-26.md](palpriority-comparison-2026-09-26.md).
- **2026-09-25 - Unknown assignment means "preserve existing permissions",
  never "grant".** A fallback that granted work on unknown data was removed.
  *Evidence:* [assignment-reader-2026-09-25.md](assignment-reader-2026-09-25.md).
- **2026-09-23 - Limits the game cannot control per item are labelled
  unsupported before the user picks an item.** Legacy limits still switch a
  whole work type (stone stops ore). *Rejected:* letting users create a rule
  that silently does something else.
- **2026-09-11 - Balanced staffing and strict priority stay separate modes**,
  with the difference shown. Manual assignments are respected, not fought.
- **2026-08-23 - Rules are guild scoped; the server files a rule under the
  sender's guild, never a guild the client names.**
  *Evidence:* project history, guild isolation test with a fabricated guild id.

## Performance

- **2026-09-29 - Edit pushes discover transmitters once and take components
  directly.** 110 to 83.5 ms per stand update. *Rejected:* reusing the roster
  across calls (stale data risk) until freshness can be proven.
  *Evidence:* [transmitter-first-2026-09-29.md](transmitter-first-2026-09-29.md), [edit-latency-root-cause-2026-09-29.md](edit-latency-root-cause-2026-09-29.md).
- **2026-09-14 - The Blueprint (CreativeMenu-style) icon loader was tried and
  reverted.** Four recordings, no convincing gain once icons were loaded.
  *Evidence:* [icon-prototype-2026-09-14.md](icon-prototype-2026-09-14.md).
- **2026-09-13 - Widgets are found by targeted queries on the current tree,
  not global object walks.** Stand lookup 10 to 0.6 ms, rules refresh 13.8 to 2 ms.
- **2026-08-28 - Authority comes from a demand pulse newer than the current
  spawn; the owned component from the controller's `Children`.** Both may
  answer yes or nil, never no.
- **2026-08-27 - Rejected with measurements, do not re-propose without new
  numbers:** closure/pcall hoisting, GC tuning, lazy logging, token interning,
  per-item tile keying (tiles are slot-keyed on purpose), dirty-flag refresh
  gating (reintroduces the repaint bug that bit three times), N-pass authority
  caching, net-hook evidence as sole authority proof, scheduler rank memo
  (215 calls, under 1 ms), SFO name memo for the menu.

## UI and input

- **The panel keeps its original position.** The user preferred it over the
  audit's move (Aug 2026, reverted). Layout fixes happen inside it.
- **Queued clicks and keys bind their target cell at press time**, not when
  processed. Rebinding a row or rebuilding the stand discards stale input.
  *Evidence:* [stand-pointer-2026-09-24.md](stand-pointer-2026-09-24.md), [stand-lifecycle-2026-09-24.md](stand-lifecycle-2026-09-24.md).
- **Escape in the amount editor cancels the draft; a second Escape closes
  only Production Limits.** *Evidence:* [editor-escape-2026-09-23.md](editor-escape-2026-09-23.md).
- **Game-and-UI input with pawn suppression, never UI-only.** See LESSONS.

## Testing

- **Testing is automated and self-serve; do not ask the user to click.**
  AHK macros restart into singleplayer or the server and open the stand,
  `tools/remote.py` drives the running game, PresentMon captures frames
  without prompts, and an independent agent cross-checks each live run.
  Lua changes may be staged while the game runs; a restart activates them.
  Full protocol: [testing.md](testing.md).

## Test installation

- **2026-10-11 - The local client was switched from the async trial back to the
  shipping path** so 0.5.0 is tested as it will ship. Codex's planned migration
  machinery was not needed: journals and legacy files held identical rows,
  verified byte for byte against the export bundle. The trial was disarmed by
  moving its launcher and receipt into a verified full backup, not deleted.
  *Rejected:* testing on the trial install (wrong code path, older build) and
  running the multi-step cutover tooling for data that did not differ.
  *Evidence:* [restart-persistence-2026-10-11.md](restart-persistence-2026-10-11.md).
- **2026-10-14 - Generators count as demand when built and not full.** The
  game never announces generator work, so an empty generator could not pull a
  Pal off other work. The scheduler now adds vacancies = generators with
  BuildProcess Completed and StoredEnergyAmount < MaxEnergyStorage, minus Pals
  already on Generating Electricity in that camp. *Rejected:* counting every
  generator work object (parks Pals at full or unbuilt generators, the
  retracted first proposal) and the work's CurrentState alone (Workable for
  blueprints too). Coolers are not included until a reliable signal is found.
  *Evidence:* [g4-scheduling-2026-10-14-stations.md](g4-scheduling-2026-10-14-stations.md).
- **2026-10-16 - Coolers count as demand when built and holding spoilable food.**
  Same gap as generators: Cooling never announces work, so a Cooling-1 Pal
  stayed on Watering 2 for about 2 minutes. The game marks a cooler's work
  Workable only while spoilable food is inside, verified live in both
  directions, so vacancies = coolers with BuildProcess Completed and
  CurrentState Workable, minus Pals already cooling. Both kinds go through one
  list (`stations.KINDS`). *Rejected:* counting every built cooler (would park
  a Pal at an empty one). *Evidence:* [g4-scheduling-2026-10-16-coolers.md](g4-scheduling-2026-10-16-coolers.md).
