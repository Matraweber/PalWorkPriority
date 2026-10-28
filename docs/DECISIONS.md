---
date: 2026-10-27
tags: [records, release]
status: current
---
# Decision log

Related: [LESSONS](LESSONS.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md) · [testing](testing.md) · [Home](Home.md)

What was decided, why, and what was rejected. Newest first within each
section. One entry per decision; link the dated evidence file rather than
repeating it. If a decision is reversed, keep the old entry and mark it
**Superseded** with a link to the new one. Mistakes go to [LESSONS.md](LESSONS.md).

Format: **Decision** - why. *Rejected:* alternatives and the reason. *Evidence:* link.

## Release and scope

- **2026-10-29 - Round-2 findings: every P1 and P2 goes in before the upload
  (user's pick).** The left click keeps wrapping 1 to X, and the stand legend
  now says so. A clamp at 1 was rejected because it would change 0.4.1 behaviour.
  The unpublished v0.5.0 tag moves to the final commit and that one tag is
  force-pushed. Nobody downloaded 0.5.0, and the change-note links must reach the
  fixed CHANGELOG.
  *Rejected:* shipping the P1s only, and keeping the old tag and shipping as
  0.5.1.
  *Evidence:* [review-round2-2026-10-29](review-round2-2026-10-29.md).

- **2026-10-28 - Every bundle of the twelve-reviewer audit goes into 0.5.0
  before the upload (user's pick: A to H).** The audit rated every area at 4-6
  out of 10. The fixes cover:
  - code P1s and per-item Mining robustness;
  - panel input safety, including adding a limit in two clicks;
  - per-item wording;
  - all doc fixes;
  - one camp-works read per pass;
  - the upload tools;
  - accessibility;
  - the larger items.

  The protocol moves to schema 5 now so clients get the server's limit verdict
  and its `item_limits_on_rocks`. 0.5.0 is not published yet, so no 0.5.0 client
  exists that the bump would lock out. Afterwards: in-game retest, then a retag
  and rebuild of v0.5.0 (unpublished, so moving the tag breaks nobody).
  *Rejected:* the minimum path (code P1s and docs only). It leaves the
  keyboard and pad paths that create or delete limits by accident.
  *Evidence:* [review-2026-10-28](review-2026-10-28.md).
- **2026-10-28 - No real-controller run before 0.5.0 (user's decision).** The
  virtual XInput pad passed every stand and panel step in game on 2026-10-22,
  and the input routes were checked against other mods (PalPriority is mouse
  only; DarnMenu gets controller input through the game's own CommonUI
  buttons). *Rejected:* holding the release for a Steam Input run with the
  user's pad. *Evidence:* [controller-routes-2026-10-22](controller-routes-2026-10-22.md).
- **2026-10-28 - 0.5.0 is the version string of the release build** (was
  0.5.0-rc1). Server and every player need exactly the same version, so the
  server gets the same build.

- **2026-10-20 - A Workshop copy switched on next to a manual install is
  reported in the log and on the Production Limits panel.** At load
  `install_check.lua` reads PalModSettings.ini and the loader's Info.json; when
  the Workshop copy is switched on and the loader manages a different version
  than the one running, the log gets the full explanation and the panel's sub
  line ends with "Steam Workshop copy X also on: use one copy." Plain file
  reads, silent when anything is unreadable or outside the official layout.
  The case where the loader installs 0.4.1 over a manual 0.5.0 cannot be
  detected by 0.5.0 (it never runs), so the changelog and Nexus page say to
  switch the Workshop copy off before installing by hand. *Rejected:* a system
  chat line (accepted by the engine, never shown to the local singleplayer
  player in three tries; the G6 server-to-client line does show), and editing
  PalModSettings.ini or ManagedMods ourselves (the game's files, the user's
  choice). *Evidence:* [g7-install-2026-10-20.md](g7-install-2026-10-20.md).
- **2026-10-20 - Async saving moves to 0.5.x; 0.5.0 ships the synchronous
  writer only (user's decision).** Gate G2b (staged-write rollback, real
  cutover, server save and restart, DLL install/upgrade/removal) is not done
  and would hold the release back. **Supersedes** the 2026-10-11 "unless its
  gates pass first" clause below. *Evidence:* [RELEASE-0.5.0.md](RELEASE-0.5.0.md) G2,
  [async-enablement-2026-10-04.md](async-enablement-2026-10-04.md).
- **2026-10-19 - Mixed versions are refused, and both sides say so in game.**
  An rc1 server answers a 0.4.1 client with `PWP_Incompatible` and also sends
  that player one system chat line per session through the game's own
  `SendSystemToPlayerChat`, because 0.4.1 cannot read the new reply. An rc1
  client on a 0.4.1 server shows "Server version incompatible" in the panel.
  Neither side writes the other's data. *Rejected:* a compatibility layer for
  0.4.1's wire format (it would carry 0.4.1's X-dropping saves along) and
  silence for old clients (the first run of the test).
  *Evidence:* [g6-version-mismatch-2026-10-19.md](g6-version-mismatch-2026-10-19.md).
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
- **2026-10-11 - Async saving does not block 0.5.0.** (Superseded 2026-10-20:
  moved to 0.5.x, entry above.) It stays off by default
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

- **2026-10-11 - An interrupted settings cutover fences startup; the marker is
  only checked for presence.** `Scripts/main.lua` opens `.settings-cutover` in
  the mod folder before it loads priorities.txt/caps.txt or looks at
  `async-trial/launch.lua`. If the marker exists, or the open fails for any
  reason other than "not found", it acquires `settings_gate`, requires a restart
  and logs "settings cutover marker exists or is unreadable". It never reads,
  runs or removes the marker; only the cutover tooling that created it removes
  it, last. `tools/deploy.ps1` also refuses to deploy while the marker or the
  trial launcher/receipt exists. It ships in 0.5.0 and stays inert there,
  because nothing in a release creates the marker. Same rule as 2026-09-11:
  unknown is not "fresh". *Evidence:* [async-enablement-2026-10-04.md](async-enablement-2026-10-04.md)
  "Parked cutover tooling"; `tests/test_main_integration.lua` "cutover fence
  precedes settings recovery and launcher inspection".
- **2026-10-04 - Native writer through UE4SS's public Lua module interface,
  not the private Unreal SDK.** The matching SDK dependency was not
  obtainable, and a minimal module compiled against the installed UE4SS
  loaded and passed 1,000 in-game calls. *Rejected:* waiting on SDK access.
  Unreal's async SaveGame was prototyped first (worked, but no reliable save
  destination identity, and a long tail: median 69.6 ms but 4 of 24 saves over
  500 ms, worst 1.5 s, on the server ([async-save-history.md](async-save-history.md))). *Evidence:* [async-save-route-research-2026-10-04.md](async-save-route-research-2026-10-04.md).
- **2026-10-03 - Async saves bind to the GameState save-directory ID, never
  the menu's.** The menu keeps the old local ID after joining a server, so a
  write could land in the wrong world. *Evidence:* [async-save-world-transition-2026-10-04.md](async-save-world-transition-2026-10-04.md) (with the 10-03 proofs merged in).
- **2026-10-03 - Rejected as save-destination proof, do not re-propose without
  new evidence:** the game's save-completion hooks
  (OnFinishedWorldAsyncSaveGameInternal 0 callbacks in 5 min, PreInternal 0 in
  7 min, while Level.sav changed), OnEndedWorldAutoSave (fires about every 30 s,
  carries no destination), WorldSaveProcess.ProcessMap (empty in 234 samples),
  AutoSaveWorldDefaultName (empty on host and client) and the menu's
  SelectedWorldSaveDirectoryName (set on Title before load, survives joining a
  server). *Evidence:* [async-save-history.md](async-save-history.md).
- **2026-10 - (Async trial only) After travel, the writers stay closed and the
  stand says "Restart the game to edit".** Same-process re-arming is not
  supported. Does not apply to the shipping synchronous writer, which must
  never show this lock (RELEASE G2).
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

- **2026-10-28 - Per-item Mining is decided per base, and the mod gives back
  what it switched off.** These came out of the audit, see
  [review-2026-10-28](review-2026-10-28.md).
  - **Per base:** with per-item on, readable works and numeric Mining limits,
    a base's own rocks and pits decide whether Mining is capped there. A
    stone-only base with a Stone Pit stops while Ore is short elsewhere.
  - **Fallback:** the guild-wide group rule stays for every other work type,
    and decides Mining when a works read failed and no earlier decision
    exists for that base.
  - **Release:** off, `pwp restore` and test mode release held rocks. Test
    mode still switches none off, so it writes only to undo the mod's own
    writes.
  - **What gets written:** only rocks whose owner model is
    `PalMapObjectItemDropOnDamagModel` are written.
  - **Read failures:** a failed works read keeps held rocks. A failed product
    read is not cached.
  - **Empty bases:** a base with no Pals counts in the verdict by the group
    rule.
  - **Cap:** a guild holds at most 500 limits (`too_many_limits`). Loading a
    file with more is not refused, because refusing would make every limit
    unavailable.

- **2026-10-28 - Per-item Mining limits on natural rocks go into 0.5.0
  (user's decision); a rock counts as its main drop (user's decision).**
  `item_sources.lua` marks a rock NotWorkable while the stock of its main
  drop is at its limit and releases only rocks it marked; Mining stops as a
  whole only when no rock or pit still produces something unlimited or
  below its limit. Buildings are read (their product decides whether Mining
  is still wanted) but never written. Unknown stock switches nothing; dry run
  writes nothing. `item_limits_on_rocks = false` restores group limits.
  *Rejected:* every drop counts (an Ore limit would stop stone rocks for 2
  ore each), waiting for 0.5.x (user wanted it in 0.5.0). *Evidence:* [per-item-limits-2026-10-27](per-item-limits-2026-10-27.md).
- **2026-10-28 - Per-item limits: work-level CurrentState is the lever to
  build on, starting with natural rocks; AssignableFixedType is rejected.**
  Setting a stone rock's work to NotWorkable kept every Pal off it (0 of 12
  samples) while ore and crystal rocks stayed in use; the state is not saved
  for rocks. *Rejected:* AssignableFixedType = Cannot (value stayed, Pals were
  still assigned, 12 of 12 samples), and for now the same lever on buildings
  (pits, logging sites, converters): their work state is written into the
  save, so an uninstall or crash could leave a building idle. Not built yet;
  design open (which drops count for a rock, trees, buildings).
  *Evidence:* [per-item-limits-2026-10-27](per-item-limits-2026-10-27.md).
- **2026-10-27 - A Pal with no order is left to the game (user's decision).**
  When every job a Pal may do has the same number, the planner gives it every
  allowed job (X and capped jobs are already out) and no seat; the game
  picks. A Pal nobody edited reads 1 for every managed job instead of the
  `config.work_priority` ranking, so untouched Pals are vanilla too.
  `leave_unordered_pals_to_game = false` restores steering for everyone; the
  older test suites set it to keep exercising steering on all-1 Pals.
  *Rejected:* "only Pals never edited" (a fresh install's captured all-1
  baseline looks like an edit, so it needed a new marker), keeping the
  config ranking (it sent a Lamball hauling past an empty ranch). Untouched
  Pals ignore `max_pals_per_work_type`, as vanilla has no such limit.
  *Evidence:* [g4-old-reports-2026-10-27](g4-old-reports-2026-10-27.md).
- **2026-10-27 - "Fishing" is Handiwork; built, Workable ponds and Handiwork
  research labs count as one seat each.** The pond's work has no declared type
  and the label "Fishing"; the game's tooltip names Handiwork. Pond and lab
  were wanted only at world load (silent). Picked by class
  (`PalWorkFishPond`, `PalWorkLabResearch`), because workbenches are
  Handiwork too and do announce. Pals already on Handiwork are subtracted,
  which can hide a pond vacancy while someone crafts; per-work occupancy
  (`GetWorkAssignInfo` out-arrays) was unreadable through UE4SS. *Rejected:*
  counting every Workable Handiwork work (six workbenches would become six
  seats). Other research subjects are typed (keyword test) but not counted.
  *Evidence:* [g4-old-reports-2026-10-27](g4-old-reports-2026-10-27.md).
- **2026-10-27 - Ranches count as demand: one seat per built, Workable ranch.**
  The ranch never announces its work (0 times in a session), so Farming never
  reached "wanted" and a Lamball was fenced to Transporting while the ranch
  stood empty (Rey's report). Same rule as coolers: BuildProcess Completed and
  CurrentState Workable, minus Pals already on it. A Pal counts as on the
  station when its current suitability matches, or, when that reads
  unavailable (ranch workers), when its assignment record is occupied on that
  type. *Rejected:* four seats per ranch (what most guides say; nothing in the
  work or model reads a capacity, and unknown must not become demand); leaving
  the ranch to pulses (none arrive). Default priorities still rank Farming 5,
  so a Lamball hauls while there is hauling; whether the default should change
  is the user's call. *Evidence:* [g4-old-reports-2026-10-27](g4-old-reports-2026-10-27.md).
- **2026-10-27 - A work named "Harvest" is Gathering.** Plantation crop jobs
  have no declared type and the station id `FarmBlockV2_Berries_*`, so typing
  reached the "farm" keyword and counted them as ranch work. *Rejected:*
  dropping the "farm" keyword (it still types real farm stations by id).
  *Evidence:* [g4-old-reports-2026-10-27](g4-old-reports-2026-10-27.md).
- **2026-10-17 - A published stock reading stays valid for the reuse window
  plus one pass interval** (max 60 s), because the scheduler acts on it until
  the next pass. *Rejected:* the bare reuse window (the display said "stock
  unavailable" between passes while Mining stayed stopped on that reading).
  *Evidence:* same file.
- **2026-10-17 - Rocks and trees count as demand while Workable.** The game
  announces them only once at world load, so Mining and Lumbering never came
  back once a Pal left them. Vacancies = Workable Mining/Lumbering works (built,
  when a building owns them; a natural tree's owner reads as a null wrapper)
  minus Pals already on them. *Rejected:* relying on pulses (2 rock
  announcements in a whole session while Pals mined for minutes).
  *Evidence:* [g4-scheduling-2026-10-17-miners.md](g4-scheduling-2026-10-17-miners.md).
- **2026-10-16 - Coolers count as demand when built and holding spoilable food.**
  Same gap as generators: Cooling never announces work, so a Cooling-1 Pal
  stayed on Watering 2 for about 2 minutes. The game marks a cooler's work
  Workable only while spoilable food is inside, verified live in both
  directions, so vacancies = coolers with BuildProcess Completed and
  CurrentState Workable, minus Pals already cooling. Both kinds go through one
  list (`stations.KINDS`). *Rejected:* counting every built cooler (would park
  a Pal at an empty one). *Evidence:* [g4-scheduling-2026-10-16-coolers.md](g4-scheduling-2026-10-16-coolers.md).
- **2026-10-14 - Generators count as demand when built and not full.** The
  game never announces generator work, so an empty generator could not pull a
  Pal off other work. The scheduler now adds vacancies = generators with
  BuildProcess Completed and StoredEnergyAmount < MaxEnergyStorage, minus Pals
  already on Generating Electricity in that camp. *Rejected:* counting every
  generator work object (parks Pals at full or unbuilt generators, the
  retracted first proposal) and the work's CurrentState alone (Workable for
  blueprints too). Coolers followed on 2026-10-16 (entry above).
  *Evidence:* [g4-scheduling-2026-10-14-stations.md](g4-scheduling-2026-10-14-stations.md).
- **2026-10-27 - New limits can be created again, as group limits (user's
  decision).** Any valid work and item can get a limit from the panel or the
  command; it is stored and enforced like an existing one (the whole work type
  stops once every limit on it is reached). The panel says so on the empty
  list, on the item tiles ("Add group limit", "Joins the Mining limits") and
  in the rule rows ("Whole work type"). Why: none of the 8 limit comments
  asked for the lock, all of them were written on 0.4.1 where adding works, so
  the lock would have taken a working feature from every user; the one real
  demand (SolidRhoé: stone without ore) is per-item control, which the lock did
  not deliver either. Second step, also the user's pick: research per-item
  limits for 0.5.x/0.6 and measure BIG DADDY's overshoot. *Rejected:* keeping
  the lock (a regression against 0.4.1), per-item limits before 0.5.0 (no
  producer control known; would hold the release). Supersedes the 2026-10-11
  entry below. *Evidence:* [limits-unlock-2026-10-27](limits-unlock-2026-10-27.md).
- **2026-10-11 - New legacy group limits are locked in 0.5.** **Superseded
  2026-10-27** (entry above). Only a limit
  that already exists (in caps.txt or config.lua `work_caps`) counts as legacy
  and stays editable; it switches its whole work type. Any new limit is an
  item limit, refused with "Item-specific limits await a verified producer
  adapter and scope" until 0.6 (`caps.rule_kind`, `caps.support`). Re-adding a
  lost legacy limit for tests: temporary `work_caps` entry plus `!pwp limit`
  (LESSONS). *Rejected:* letting new rules silently switch a whole work type.
  *Evidence:* Scripts/caps.lua, [RELEASE-0.5.0.md](RELEASE-0.5.0.md) Deferred.
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

- **2026-10-20 - The storage refresh stays at 30 s, recorded as justified
  (user's choice).** 31-37 ms every ~29 s, the one mod cost left that crosses
  33 ms (about 2 frames a minute in the test world), and only while limits that
  need stock exist (the refresh lease follows the scheduler's interest). An
  aligned trace showed it is the 28.7 s chain; the other ~30 s chain overlaps
  no mod event. *Not chosen:* 60 s (half the spikes, but Pals overshoot a limit
  up to ~30 s longer, and the 60 s validity cap in the protocol would have to
  rise with it or the 2026-10-17 "stock unavailable" flicker returns); splitting
  it in two callbacks (a fresh FindAllOf per part: ~4 frames over 16.7 ms
  instead of 2 over 33, more CPU). *Evidence:* [g5-performance-2026-10-19.md](g5-performance-2026-10-19.md).
- **2026-10-20 - The stand refresh stays at once a second, recorded as
  justified (user's choice).** 12.2 ms (worst 15) once a second, only while the
  stand is open: about 60 frames over 16.67 ms per minute in that scene,
  nothing with the stand closed. Input repaints its cells at once; only the
  full refresh repaints rows the game redraws itself (scrolling, rebuilt rows,
  new Pals, server pushes). *Rejected:* a "nothing changed" skip (proposed
  2026-10-19 without reading this list; it is the dirty-flag refresh gating
  rejected 2026-08-27, which reintroduced the repaint bug three times). *Not
  chosen:* a slower cadence (stale numbers longer after such a redraw).
  *Evidence:* [g5-performance-2026-10-19.md](g5-performance-2026-10-19.md).
- **2026-10-19 - The scheduler pass stays at 10 s and keeps its camp
  FindAllOf (user's choice).** After rounds 1-3 the pass is 20 ms (worst 23):
  one frame over 16.7 ms every 10 s, none over 33 ms. Half of it is
  FindAllOf(PalBaseCampModel), the only proven way to find live camps (the
  BaseCampManager probe crashed, see palapi.base_camps). *Rejected:* 15 s
  (4 instead of 6 slow frames a minute, but Pals react up to 15 s late; 30 s
  missed whole jobs in August). *Evidence:* [g5-performance-2026-10-19.md](g5-performance-2026-10-19.md).
- **2026-10-19 - Nicknames are read as the SaveParameter.NickName property,
  not with GetNickname.** On game 1.0.5 GetNickname wants an out parameter;
  the call raised every time inside a pcall (names silently fell back to the
  species) and the raise cost about 0.5 ms per Pal, 93% of every roster read.
  *Rejected:* passing a Lua out-table (that native boundary is unproven, see
  camp_pals). *Evidence:* [g5-performance-2026-10-19.md](g5-performance-2026-10-19.md).
- **2026-10-19 - Station counters share one typing of the camp's works, and a
  work's type is remembered by work id.** Four counters each typed every
  work (7.7 ms each with a large stock); now typing happens once per camp and
  only for new works (0.09 ms). Only the id string and the type number are
  kept, never the work; untyped works are asked again, the memo is rebuilt
  every pass and cleared on world change. *Evidence:* same file.
- **2026-09-29 - Edit pushes discover transmitters once and take components
  directly.** 110 to 83.5 ms per stand update. *Rejected:* reusing the roster
  across calls (stale data risk) until freshness can be proven.
  *Evidence:* [transmitter-first-2026-09-29.md](transmitter-first-2026-09-29.md), [edit-latency-root-cause-2026-09-29.md](edit-latency-root-cause-2026-09-29.md).
- **2026-09-14 - The Blueprint (CreativeMenu-style) icon loader was tried and
  reverted.** Four recordings, no convincing gain once icons were loaded.
  *Evidence:* [icon-prototype-2026-09-14.md](icon-prototype-2026-09-14.md).
- **2026-09-13 - Widgets are found by targeted queries on the current tree,
  not global object walks.** Stand lookup 10 to 0.6 ms, rules refresh 13.8 to 2 ms.
  *Evidence:* [viewport-and-icon-retest-2026-09-13.md](viewport-and-icon-retest-2026-09-13.md).
- **2026-09-12..15 - Rejected with measurements (game 1.0.4/1.0.5), do not
  re-propose without new numbers:** bulk stand traversal through
  `GetAllChildren` (`pwp standbulk`, 09-15; four ABBA PresentMon clips showed
  no frame benefit, refresh 11.5 ms indexed vs 11.6-11.9 bulk, and review found
  a duplicate-child hole: a batch `{a,a}` could hide a target); plain
  `GetWidgetFromName` for row ownership (unreflected C++); `FindFirstOf`,
  stored wrappers or name-only freshness for the stand menu (can pick a hidden
  or wrong menu); name-only write caches for cell text (writes cost 0.34 ms per
  grid; risk blank or recycled cells); collapsing rapid saturating clicks into
  a net direction (left then right at 1 must give 2); a mouse debounce (the
  runtime sends down edges, it would drop real rapid clicks); re-adding the
  150 ms draw-age click guard (it discarded real clicks; a regression fails if
  it returns); a speculative log-buffering rewrite (file 7 ms + console 2 ms
  per 170 s); excluding no-base loot before storage module discovery (hides
  module failures). *Evidence:* [g5-performance-2026-10-19.md](g5-performance-2026-10-19.md) "History".
- **2026-08-28 - Authority comes from a demand pulse newer than the current
  spawn; the owned component from the controller's `Children`.** Both may
  answer yes or nil, never no.
- **2026-08-27 - Rejected with measurements, do not re-propose without new
  numbers:** closure/pcall hoisting, GC tuning, lazy logging, token interning,
  per-item tile keying (tiles are slot-keyed on purpose), dirty-flag refresh
  gating (reintroduces the repaint bug that bit three times), N-pass authority
  caching, net-hook evidence as sole authority proof, scheduler rank memo
  (215 calls, under 1 ms), SFO name memo for the menu.

## Multiplayer and network

- **2026-10-28 - Protocol schema 5 carries the server's limit state.** A
  storage reply now also carries:
  - the per-work-type verdict for the client's guild and scope;
  - the items whose rocks are held;
  - the server's `item_limits_on_rocks`.

  Clients show that instead of a permanent "No count yet", and word Mining
  by the server's setting. Every earlier 0.5.0 build, server included, is
  now refused as incompatible, so the server needs this build too. Nothing
  public had 0.5.0 yet.
  *Rejected:* working the verdict out on the client from storage totals. It
  cannot see the server's per-base decisions or its pits.
- **2026-10-28 - A client on a server without the mod, or with another
  version, gets the base game's stand.** This covers the incompatible,
  unavailable and handshake-timeout states.
  - The checkboxes come back and no "?" is drawn.
  - The legend says why.

  It used to keep "?" and hidden checkboxes for the whole session, which
  locked every subscriber out of the stand on unmodded servers.

- **2026-09-23 - An edit timeout invalidates its stream and waits for that
  stream's own full snapshot**; an unrelated snapshot or a late ack cannot
  restore readiness. *Evidence:* tests/test_net_commit_errors.lua.
- **2026-08-26 - Chat commands obey only this machine's player:**
  SenderPlayerUId (guid_key) is compared with PlayerState.PlayerUId; unknown
  means refuse while anyone else is connected. Verified live (`!pwp mode` from
  chat on the dedicated server). *Evidence:* Scripts/main.lua OnReceivedChat
  hook, commit fcb3fc3.
- **2026-08-26 - Refuted audit claim R1 (server double-push per edit).** The
  server log shows exactly one stand push per edit, because store.on_change
  does not fire on the authority. The explicit `push_stand(nil, only_key)` in
  the network edit handler (Scripts/main.lua) must stay; removing it once
  pushed nothing.
- **2026-08-23 - Rejected: rules keyed by base-camp id** (old multiplayer plan,
  phase 4); guild scope from the server-side sender replaced it (Scheduling and
  limits, 2026-08-23). The reason was not recorded.
- **2026-08-19 - Rejected: PalPriority's two-mod server/UI split.** One mod
  works out its role (authority? screen?); a listen host edits by function
  call. (Its "no version skew" argument proved wrong: see 2026-10-19 mixed
  versions under Release and scope.)

## UI and input

- **2026-10-28 - Adding a limit takes two clicks, and keyboard or pad
  selection follows what it points at.**
  - **First click:** says what the limit stops and the amount.
  - **Second click:** creates it.
  - **Seed:** above 50,000 in storage the seed is the next 10,000 above it.
    No limit is created while storage is not counted.
  - **Selection:** the keyboard and pad selection is found again by
    rule, tile or control after every draw.
  - **Typing:** bound keys are ignored while a text box has focus.
  - **Remove:** shares one 8 s timer with its notice and names the item.
    Delete arms it from the keyboard.
- **2026-10-28 - Readability from measured screenshots.**
  - The stand legend sits on a dark box at 14 pt.
  - Sub-labels are 12 pt.
  - The selected row is darker, with a cyan rail.
  - A selected tile keeps both rails.
  - Controller hints name pad buttons.

  The RB+View chord is removed from the code (rejected 2026-10-22).
- **2026-10-28 - An options-menu value that the config check refuses is
  skipped with a warning.** The value from config.lua is kept. It used to
  stop the mod from starting on every launch: the menu allowed an interval
  of 2, validation needs 5.

- **2026-10-22 - Controller support ships in 0.5.0, all parts (user's
  decision).** Open the panel through a DarnMenu tile and a chord the game does
  not use, navigate the panel, and edit priorities on the stand, by handing
  controller keys from our own widgets' key handlers to Lua
  ([controller-routes-2026-10-22](controller-routes-2026-10-22.md)). The
  release waits for it. *Rejected:* shipping 0.5.0 with "use mouse and
  keyboard" and building it in 0.5.x (offered, not chosen); polling the player
  controller in menus (measured: the game's menus take the buttons first).
  Supersedes the 2026-10-22 "deferred" closing of the RELEASE controller item.
  Built the same day: our own widgets hand the buttons to Lua (StandInput
  OnKeyDown, WorkRules OnPreviewKeyDown); View on the stand opens the panel
  because the game keeps Y (view switch); Y confirms in the panel because the
  game's UI confirm takes A; the panel closes on B's release so the release
  cannot close the stand. *Rejected on measurement:* a new chord (RB + View
  opens the map), a `Jump` binding for A (never fires), `UIINputGuardCancel`
  and a CommonUI back handler for the stand closing (no difference).
- **2026-10-21 - The limits panel gets the new-user fixes in 0.5.0 (user's
  pick: P1, the requested key hints and stand legend, and P2 except Enter).**
  From [ux-review-2026-10-21](ux-review-2026-10-21.md): say up front that 0.5.0
  cannot create limits, warn that Remove cannot be undone, fix "raise" setting
  a large limit to 50,000, plain status words that fit the column, show what a
  legacy limit switches, a visible version-mismatch message, mouse and key
  hints, and the P2 friction items. *Rejected for now:* Enter opening the type
  box instead of raising one step (behaviour change, P2-11) and the P3 polish
  list. Moves the "mouse-button and pad legend" out of the deferred list.
- **2026-10-20 - Only rows of the item table are ever named by the game.**
  GetItemName aborts the game (pcall cannot catch it) for an id the item table
  does not have, so `items.real_name` checks the captured catalogue's row names
  first; unknown ids get the readable fallback, an unreadable catalogue names
  nothing. *Rejected:* an id blacklist (cannot know other mods' ids) and
  trusting the picker's job filter alone (it matches id substrings, so a
  modded id containing "ore" or "egg" would pass it). *Evidence:*
  [g3-search-crash-2026-10-20.md](g3-search-crash-2026-10-20.md).
- **2026-10-17 - Production Limits closes itself when the local player dies**,
  dropping any unsaved draft. Detected by polling HP (property reads, every
  0.25 s, only while the panel is open) because ClientRestart only fires at
  respawn. *Rejected:* waiting for ClientRestart (the editor sat on the death
  screen until then) and hooking an unknown death function by guessed name.
  *Evidence:* [g3-escape-photo-death-2026-10-17.md](g3-escape-photo-death-2026-10-17.md).
- **2026-09-25 - ClientRestart resets the session only on positive local-owner
  identification** (two nonempty string names, equal within the callback).
  Foreign, throwing or unreadable contexts keep session, writers and queued
  work; the old code reset on a throwing context. *Evidence:*
  tests/test_main_integration.lua.
- **2026-09-24/25 - Drafts and confirmations bind to the value and guild they
  were made against.** Each rule-list draw builds a fresh layout map; a draft
  whose work/item leaves the current page or whose guild changes is cancelled
  at once with a notice, a still-visible target follows its row and keeps its
  text, and the editor is placed only after the validated page is drawn.
  Confirm compares the draft's original value with the current effective rule
  and refuses a mismatch; Remove binds guild and amount and refuses a stale
  queued removal; an existing-limit jump is a work/item/guild hint consumed
  after redraw, cancelled by navigation or a guild change, and never saves.
  Client-side only ([release-gates](release-gates-2026-10-09.md) section 3).
  *Evidence:* tests/test_panel_edit_reflow.lua, test_panel_rule_reveal.lua,
  test_panel_remove_conflict.lua, test_panel_edit_conflict.lua.
- **2026-09-24 - A notice never moves controls.** One help/notice row stays
  present on Rules and Items; row containers are reserved before pagination.
  *Evidence:* tests/test_picker_notice_layout.lua, test_panel_host_order.lua.
- **2026-09-23 - NoCapture is set and read back before activation; a refused
  or unknown write aborts the open.** Palworld's widget default
  CapturePermanently hid the cursor (bShowMouseCursor=false) and automated
  clicks hit nothing. *Evidence:* [panel-cursor-2026-09-23.md](panel-cursor-2026-09-23.md).
- **2026-09-23 - Rejected for queued stand clicks: a cached-hover sample.** It
  cannot prove event-time intent for an unsampled A to B to A move or
  foreground ownership, and an expiry fixes neither. Debounce and netting
  opposite clicks are rejected too (Performance, 2026-09-12..15). Press-time
  binding replaced it (entry below).
- **2026-09-16 - Rejected: an OnPreviewKeyDown handler on the panel (input
  contract 1).** Natively, Escape still closed the stand underneath. Replaced
  by the Blueprint-owned consuming RadialMenuCancel binding (contracts 2/3,
  [widget-spec](widget-spec.md)).
- **2026-09-15 - Controller Cancel beats Confirm, Remove and navigation in the
  same pad sample**, and cancels an edit before closing the panel. Buttons
  observed down at cancel need proof of release (only boolean readings count;
  unknown keeps the barrier; it survives a UI reset). *Evidence:* tests/test_pad.lua.
- **The panel keeps its original position.** The user preferred it over the
  audit's move (Aug 2026, reverted). Layout fixes happen inside it.
- **Queued clicks and keys bind their target cell at press time**, not when
  processed. Rebinding a row or rebuilding the stand discards stale input.
  *Evidence:* [stand-pointer-2026-09-24.md](stand-pointer-2026-09-24.md), [stand-lifecycle-2026-09-24.md](stand-lifecycle-2026-09-24.md), [stand-close-events-2026-09-24.md](stand-close-events-2026-09-24.md).
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
