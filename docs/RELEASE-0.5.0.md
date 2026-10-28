---
date: 2026-10-27
tags: [release]
status: current
---
# 0.5.0 release scope

Related: [DECISIONS](DECISIONS.md) · [release-gates-2026-10-09](release-gates-2026-10-09.md) · [g5-performance-2026-10-19](g5-performance-2026-10-19.md) · [testing](testing.md)

Decided 2026-10-11 (see [DECISIONS.md](DECISIONS.md)). This file is the ship
list. A gate closes only when its **Done when** line is met on the current
candidate, with the evidence linked next to it. Everything not listed here is
deferred, not forgotten: the full backlog stays in
[release-gates-2026-10-09.md](release-gates-2026-10-09.md).

Rules for every gate: record the loaded build (fingerprint) for each run, use
the automated rig in [testing.md](testing.md), and follow [LESSONS.md](LESSONS.md)
on what counts as evidence. Commit at the end of each session.

Status: `[ ]` open, `[x]` done (link evidence), `[-]` moved out of scope (say why).

## G1. Settings survive (the most reported problem)

- [x] **Restart keeps priorities and applies them.** Singleplayer: saved values PASS twice, and edit then save then restart PASS, on 2026-10-11 ([evidence](restart-persistence-2026-10-11.md)). Dedicated server: client edit, server restart, client reconnect PASS on 2026-10-11. **Done.** Reports: Two Bob Games
  (Steam, Sep 23: "Transport X returns to 1 after restart, ignored until edited
  again"), johndujo (Nexus bug: "Priority list not saving").
  **Done when:** in singleplayer AND on the server, a mix of 1-5 and X on at
  least 3 Pals survives two AHK restarts in a row. The stand, the settings file
  and the first pass after load all agree, and the Pals act on them without any
  edit after the restart.
- [x] **Upgrade from 0.4.1 keeps every row.** Manual route PASS 2026-10-11 ([evidence](upgrade-041-2026-10-11.md)); Workshop route PASS 2026-10-20 through the game's own mod loader, every row identical; edits in 0.4.1's Scripts/config.lua are lost on that route (the loader deletes the file first), the changelog says so ([evidence](g1-workshop-2026-10-20.md)). Steam's download step was simulated; the release upload re-checks it.
  **Done when:** a real 0.4.1 install with priorities and limits is upgraded
  through both the Workshop and manual routes, and a file diff shows every
  saved row intact. (X rows that 0.4.1 already lost cannot be recovered; the
  changelog says so.)
- [x] **Rapid edits save once, not per click.** PASS 2026-10-11 on the server: 20 edits, one save, one pass, final value survived a restart ([evidence](restart-persistence-2026-10-11.md)). Timing belongs to G5.
  **Done when:** 20 rapid edits on the server produce no edit callback above
  the G5 budget, and the final values survive a restart.

## G2. Saving backend decision

- [ ] **0.5.0 ships the synchronous writer; the native async DLL is not in
  the package** (G2b moved to 0.5.x on 2026-10-20). 2026-10-20: the rc1
  archives hold no DLL, and a clean manual install ran the synchronous writer
  with no fence, and so did a clean Workshop install on 2026-10-21 ([evidence](g7-install-2026-10-20.md)). Open: the G1 upgrade
  notes do not say "no fence" explicitly; check that on the final build.
  **Done when:** the release archive contains no DLL, a clean install and a
  0.4.1 upgrade both run the synchronous writer, and no recovery fence or
  "restart to edit" lock appears.
- [-] **G2b (optional) async in 0.5.0, off by default.** MOVED to 0.5.x on
  2026-10-20 (user's decision): 0.5.0 ships the synchronous writer only.
  **Done when:** the remaining async steps pass: rollback test of the staged
  write path, cutover on the real install with a verified backup, dedicated
  server priority edit, save and restart, and clean install, upgrade and
  removal of the DLL. If not done in time, this moves to 0.5.x.

## G3. Frontend reports

- [x] **No second or stuck panel.** PASS 2026-10-17: 10 cycles plus 7 rapid presses, one panel each time, pause/inventory/map fine ([evidence](g3-panel-2026-10-17.md)). Report: Extramrdo (Steam, Sep 28: Alt-F1
  opens a second panel, stuck panel blocks menus).
  **Done when:** 10 open/close cycles including rapid Alt-F1 presses leave
  exactly one panel, and pause, inventory and map all work afterwards.
- [x] **Layout holds at every list size.** PASS 2026-10-17: 0/1/13/14/26/27 entries, picker pages 1-2 of 8, editor on a single row and above the pager ([evidence](g3-layout-2026-10-17.md)).
  **Done when:** screenshots of the rules list at 0/1/13/14/26/27 entries and
  two picker pages show no overlap, and the amount editor sits on its row.
- [x] **Search/Add crash** (Nexus, DarkWyrmReaper, with Cosmetic Outfits mod 5049). PASS 2026-10-20: 5 rounds of Show all, search and Add with the mod and PalSchema 0.6.71 active, no crash; the crash class was reproduced (GetItemName on an id the item table does not have aborts the game) and fixed by naming only catalogue rows ([evidence](g3-search-crash-2026-10-20.md); earlier investigation [search-crash-2026-09-15](search-crash-2026-09-15.md)).
  **Done when:** with that mod installed, Search all and Add run 5 times
  without a crash, or the attempt is recorded as not reproducible and the
  reporter is asked for the crash log.
- [x] **Escape, photo mode, death while editing.** PASS 2026-10-17: Escape and photo mode clean; death (SelfKillPlayer) left the editor over the death screen, fixed by deathwatch.lua and retested with an unsaved 12345 draft (discarded, not saved); one unexplained limit step recorded ([evidence](g3-escape-photo-death-2026-10-17.md)).
  **Done when:** one recorded run each leaves no grey box, no lost input and no
  stale editor. 2026-10-21: photo mode from a Pal bed (Zekrom144, Roin) PASS too.
- [x] **New-user panel texts checked in game** (3b7f4e2, user's pick from
  [ux-review-2026-10-21](ux-review-2026-10-21.md)). PASS 2026-10-22 on the dev
  install; the stand legend went back to one line and the item-to-work mapping
  got a look-alike list (both found in game, fixed, rechecked). Client-only
  texts still need a client.
  **Done when:** on the deployed build the notice row, foot hint, tabs-row key
  hints, status column ("Limit reached", "Reached N/M") and the two-line stand
  legend are screenshotted without overlap or cut text, the raise above
  50,000 keeps the value, and the first Escape disarms an armed Remove.
- [x] **Controller input** ([controller-2026-10-21](controller-2026-10-21.md), [controller-routes-2026-10-22](controller-routes-2026-10-22.md)):
  PASS 2026-10-22 in game with a virtual XInput pad connected before game
  start: stand editing (D-pad, LB/A, RB, X), View opens the panel, panel
  navigation, tabs, Y confirms, B closes only the panel; keyboard and mouse
  rechecked. A in the panel stays the game's own confirm (Y used). Built into
  WorkRules contract 4 / StandInput contract 3 (user's decision to ship it in
  0.5.0). Open: one run with a real controller through Steam Input.
  **Done when:** a controller can open the panel, move, edit priorities on
  the stand and close the panel without closing the stand.
- [x] **Old Pal reports rerun on rc1** (user's pick 2026-10-21): KhanKeal's
  Flambelle/all-1 setups, Samurai9400's research, Rey's Lamball and ranch,
  poiman's fishing pools. **Done when:** each is observed by Current Task and
  output, or recorded as not reproducible. Done 2026-10-27 ([evidence](g4-old-reports-2026-10-27.md)):
  Pupperai PASS; Lamball reproduced (the ranch never counted as work) and
  fixed, observed on the ranch over two game starts; Flambelle covered by a
  planning test (no Flambelle in the world); research and fishing not
  reproducible (no lab or pond in the test world). Found on the way: berry
  harvests were typed as ranch work, fixed. Output (wool) not counted.
  Second round the same day (user's request): lab and pond built and
  measured, Flambelle caught and tested. Pond reproduced and fixed (untyped,
  silent); lab typed correctly by research subject, silent, now counted;
  Flambelle reproduced ranching while the pond was invisible, and with the
  pond counted it stays on the ranch only while the Handiwork seats are
  taken. Untouched Pals are now left to the game (user's decision).

## G4. Scheduling does what the stand shows

Judge by the Pal's Current Task and by output, never by fence log lines alone.

- [x] **Priority 1 beats priority 5.** PASS 2026-10-12 by swap control on one Pal ([evidence](g4-scheduling-2026-10-12.md)); per-Pal output not isolated. Report: HelpImStupid0 (Nexus, Sep 19:
  "Transport 5 still dominates primary work 1").
  **Done when:** a staged base with two competing jobs at 1 and 5 shows the
  Pal on the priority-1 job in at least 8 of 10 observations, and that job's
  output rises.
- [x] **August repro cases still hold:** CLOSED 2026-10-20 (user): all four observed locally (Incineram, Grizzbolt, generators, coolers); the done-when does not require the dedicated server, where stations remain untested. Incineram Handiwork over Kindling PASS 2026-10-14 ([evidence](g4-scheduling-2026-10-12.md)); Grizzbolt sleep/wake PASS 2026-10-14; generators: the game never announces generator work, so an empty generator did not pull an Electricity-1 Pal off other work; FIXED 2026-10-14 by reading build state and stored energy, verified live (back on the generator 16 s after its priority was restored) ([record](g4-scheduling-2026-10-14-stations.md)); coolers had the same gap (Cooling 1 stayed on Watering 2 about 2 min), FIXED 2026-10-16 by counting built coolers with spoilable food, verified live (on the fridge 18 s after the switch, 9 of 10 samples) ([record](g4-scheduling-2026-10-16-coolers.md)). Server RAM runs 30ee360 since 2026-10-19 20:06 (G5 rounds 1-3; backup Scripts-before-30ee360); stations there untested. Incineram Handiwork over Kindling,
  Grizzbolt stays on the generator after being moved, sleep and wake.
  **Done when:** one observed cycle each, same criteria.
- [x] **Staffing limit:** max 3 on a type with 4 eligible Pals keeps 3 working. PASS 2026-10-12: never above 3, reached 3 under demand ([evidence](g4-scheduling-2026-10-12.md)).
- [x] **"Everything stops" / "only one miner"**: reproduced 2026-10-16/17 (mod: 0 miners and lumberjacks in 42 samples; vanilla 1-3 and 2-5). Two causes, both fixed and verified live: met limits under the "all bases" option shown as "stock unavailable" half the time, and rocks/trees never announced after load ([evidence](g4-scheduling-2026-10-17-miners.md)). One reproduction attempt
  with output counts, result recorded either way.
- [-] **Empty dedicated server assignments.** Not applicable, confirmed on rc1 2026-10-11: 0 works with nobody online ([evidence](g4-scheduling-2026-10-12.md)). In August no base work ran with
  zero players online.
  **Done when:** that is re-confirmed on rc1. The gate is then closed as not
  applicable, without adding any assumption to the scheduler.

## G5. Performance target

- 2026-10-19: matched baseline on e073183 (mod present vs physically absent, 3 x 60 s each): UI closed 7-8 frames over 33 ms per minute with the mod vs 0-1 without; stand open 67-68 over 16.7 ms vs 2-5. Rounds 1-3 (nickname property read, one typing pass, type memo by work id) cut the scheduler pass from 34.6 (49.7 in the grown world) to 20.2 ms and frames over 33 ms to 2-3 per minute; frames over 16.7 ms unchanged. Decided 2026-10-19/20: the pass stays at 10 s with its camp FindAllOf (10 ms); the stand refresh (12 ms/s, stand open only) stays, recorded as justified because its "nothing changed" skip is the dirty-flag gating DECISIONS rejected on 2026-08-27. 2026-10-20: an aligned trace showed the 28.7 s chain is the storage refresh and the other ~30 s chain overlaps no mod event; the storage refresh (31-37 ms/30 s, only with limits) stays, recorded as justified. Every recurring cost over 5 ms is now reduced or recorded. Final capture 2026-10-20 (same light, same monitor; the absent session was too fresh for a clean with/without figure, so the changelog states attribution): UI closed, the mod costs about one frame over 16.7 ms every 10 s (scheduler pass) and, only with limits, one over 33 ms every 30 s (storage refresh); stand open, about one extra frame over 16.7 ms per second ([evidence](g5-performance-2026-10-19.md)).
- [x] **Best effort, no fixed number (user's decision 2026-10-11).** CLOSED 2026-10-20: every recurring cost over 5 ms is reduced (rounds 1-3) or recorded as justified by the user's choice (pass 10 s, stand refresh, storage refresh); no candidate round is left, so the two-small-rounds condition is met by stopping, not by measuring two more rounds. Final numbers above go into the changelog (G7). Optimise
  as far as is practical and report the measured result honestly in the
  changelog. Starting point (September, older code): the mod added about 8
  slow frames (over 16.7 ms) per minute over the mod-absent baseline (10-11 vs
  2); the matched baseline of 2026-10-19 above replaces those numbers.
  Every measurement uses matched captures (same save, scene and settings;
  3 windows each; profiling off; UI closed and stand open).
  **Done when:** every recurring mod cost above 5 ms per call has either been
  reduced or recorded in DECISIONS.md with its measured price and why it stays,
  and the last two optimisation rounds each gained less than 1 slow frame per
  minute. The final mod-present vs mod-absent numbers go in the changelog.

## G6. Multiplayer minimum (one machine, own server)

- [x] **Priority edit survives a server restart** PASS 2026-10-11 on RAM ([evidence](restart-persistence-2026-10-11.md)). (limits already passed on
  2026-10-09). **Done when:** client edit, server restart, client reconnect,
  same value in the stand and in the server file.
- [x] **Old client and new server disagree politely.** 2026-10-19: 0.4.1 client on the rc1 server corrupts nothing and, since 28e41ca, gets a system-chat update notice (verified live); rc1 client on a 0.4.1 server is refused and, after a panel fix (it said "Connecting to server..." for good), shows "Server version incompatible" (verified live); server priorities.txt untouched in both directions ([evidence](g6-version-mismatch-2026-10-19.md)).
  **Done when:** a 0.4.1 client joining a 0.5.0 server, and the reverse, shows
  a clear incompatible-version message and corrupts nothing.
- [x] **Guild isolation still holds.** PASS 2026-10-19 on RAM: fabricated-guild Mining/Stone/1 plus real-guild control; the client saw only its own rule ([evidence](g6-guild-isolation-2026-10-19.md)). **Done when:** the August
  fabricated-guild test (rule under a fake guild id plus the real-guild
  control) gives the same result on rc1.

## G7. Package and publish

- [x] **Limits can be added again** (user's decision 2026-10-27). PASS
  2026-10-27 in singleplayer ([evidence](limits-unlock-2026-10-27.md)):
  added from the panel, reached at once switched the work type off, raised
  switched it back on, a second item joined the Mining group and Mining
  resumed, both survived a restart, removed again from the panel. Dedicated
  server PASS 2026-10-28: a client added Mining Stone 1, the server logged
  "set ... by a player" and saved it, the client's list showed it, and the
  client's removal was applied and saved too ([per-item-limits-2026-10-27](per-item-limits-2026-10-27.md)).
- [x] **Mining limits per item on rocks** (user's decision 2026-10-28, into
  0.5.0). Built: `Scripts/item_sources.lua`, scheduler, panel wording
  ("Add item limit", "Its rocks only", "Rocks stopped"), config switch;
  tests pass (228 Lua). PASS 2026-10-28 in game ([evidence](per-item-limits-2026-10-27.md)):
  19 stone rocks held, 0 of 12 samples on stone while ore and crystals were
  mined, released at a raised limit, held again, fresh after a restart and
  after a world change. Dedicated server PASS 2026-10-28 (GPortal "RAM" on
  34fe913): the client's Stone limit held 3 stone rocks for 2 minutes while
  Mining stayed wanted, and its removal released all 3. **Done when:** in game a reached Stone limit holds the stone
  rocks off (log "rock(s) held for limits", no Pal on a stone rock in 12
  samples) while ore and crystal rocks are mined, raising the limit releases
  them, the panel shows "Rocks stopped", and after a reload every rock reads
  Workable again.

- [ ] **One clean build for both stores.** 2026-10-20: clean manual install loads one copy, pak mounted, no fence; the Workshop/manual conflict is warned in the log and on the panel; a Workshop copy switched on but never installed overwrites a manual install unseen, so the changelog says "use one copy" ([evidence](g7-install-2026-10-20.md)). 2026-10-21: the clean Workshop install passes too (one copy, pak mounted, no false warning). Open: the tagged final build (rerun A and C on it with tools/g7_install_matrix.py). **Done when:** `tools/release.py`
  builds the Workshop and Nexus archives from one tagged commit with matching
  hashes. Clean installs from each load exactly one copy (pak mounted), and the
  Workshop/manual conflict is detected and explained.
- [ ] **Changelog and replies.** 2026-10-20: CHANGELOG.md 0.5.0 draft written from the gate evidence (fixed, before-you-update incl. lost X, legacy limits locked, measured performance, deferred list, open items marked [OPEN]); the stale rc1 section was replaced (git keeps it). Open: user review. Replies: not needed (user's decision 2026-10-27); the drafts stay as a record. 2026-10-27: reply drafts rewritten against 252c0e3 from the gate evidence, one per reporter group plus KhanKeal, Samurai9400, Rey, poiman, like and Ceo of Toes; two depend on Vortex and the real-controller run. **Done when:** the changelog lists what is
  fixed, what is deferred (below) and that 0.4.1 X losses cannot be undone, and
  [release-replies-0.5.0-draft.md](release-replies-0.5.0-draft.md) is updated
  against the final build. Posting is the user's action.
- [x] **Vortex:** one install/update/remove run, or the Nexus page says it is
  not supported yet. PASS 2026-10-28 with the Palworld extension 0.5.0
  ([vortex-2026-10-28](vortex-2026-10-28.md)): Vortex's root-mod installer puts our archive into the
  manual layout; 0.4.1 installed and loaded, 0.5.0 installed over it, 0.4.1
  removed, 0.5.0 loaded once with settings intact, removal kept the user's
  files. The Nexus page should say to turn off Vortex's UE4SS management when
  UE4SS comes from the game's mod loader.

## Deferred to 0.5.x / 0.6 (say so in the changelog)

- Item-specific production limits (stone stops while ore continues). 0.5.0
  has group limits as 0.4.1 did: new ones can be created again since
  2026-10-27 (user's decision, [DECISIONS](DECISIONS.md)), each switches its
  whole work type. Next step (user's pick): research per-item control and
  measure the overshoot BIG DADDY reported. First round 2026-10-27/28
  ([per-item-limits-2026-10-27](per-item-limits-2026-10-27.md)): every mining work names its product; marking a work
  NotWorkable keeps Pals off it (0 of 12 samples on blocked stone rocks);
  rocks do not save that state, buildings do (a pit stayed NotWorkable after
  a reload), so per-item control is possible for natural rocks first.
  Overshoot not measured yet (this base mines too slowly).
- Async saving (gate G2b, moved 2026-10-20), on by default later, and async on dedicated servers (open checklist:
  [dedicated-async-next-gates-2026-10-09](dedicated-async-next-gates-2026-10-09.md)).
- Design calls open since the 2026-08-26 audit: marking a capped work column
  on the stand (needs injecting into vanilla header widgets) and un-hiding the
  vanilla checkbox when the mod switched a permission off. The mouse and key
  legend (Extramrdo, Sep 28) ships in 0.5.0 as two lines under the stand
  ([ux-review-2026-10-21](ux-review-2026-10-21.md)); it does not name pad
  buttons.
- Live tests with two real clients and two real guilds (needs a second Steam
  account and machine), unmodded-client edit detection.
- Physical Steam Deck, ultrawide and UI scaling matrix.
- Requests: independent priority/limit mods, high-quality stand restriction,
  Pal-produced materials, deferred scheduling after UI close.

## Suggested order

G1 first (it is what users report most and what the sync-writer decision
rests on), then G3 and G4 in parallel on the AHK rig, G6, G5 captures last on
the final code, then G7. Rough size: 1.5-2 weeks at the September pace.
