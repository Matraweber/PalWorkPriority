# 0.5.0 release scope

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
- [ ] **Upgrade from 0.4.1 keeps every row.** Manual route PASS 2026-10-11 ([evidence](upgrade-041-2026-10-11.md)); offline 0.4.1-writer test in place. Open: the Workshop route (needs an upload by the user, ideally an unlisted test item).
  **Done when:** a real 0.4.1 install with priorities and limits is upgraded
  through both the Workshop and manual routes, and a file diff shows every
  saved row intact. (X rows that 0.4.1 already lost cannot be recovered; the
  changelog says so.)
- [x] **Rapid edits save once, not per click.** PASS 2026-10-11 on the server: 20 edits, one save, one pass, final value survived a restart ([evidence](restart-persistence-2026-10-11.md)). Timing belongs to G5.
  **Done when:** 20 rapid edits on the server produce no edit callback above
  the G5 budget, and the final values survive a restart.

## G2. Saving backend decision

- [ ] **0.5.0 ships the synchronous writer; the native async DLL is not in
  the package** unless gate G2b closes before G1, G3-G7 do.
  **Done when:** the release archive contains no DLL, a clean install and a
  0.4.1 upgrade both run the synchronous writer, and no recovery fence or
  "restart to edit" lock appears.
- [ ] **G2b (optional) async in 0.5.0, off by default.**
  **Done when:** the remaining async steps pass: rollback test of the staged
  write path, cutover on the real install with a verified backup, dedicated
  server priority edit, save and restart, and clean install, upgrade and
  removal of the DLL. If not done in time, this moves to 0.5.x.

## G3. Frontend reports

- [ ] **No second or stuck panel.** Report: Extramrdo (Steam, Sep 28: Alt-F1
  opens a second panel, stuck panel blocks menus).
  **Done when:** 10 open/close cycles including rapid Alt-F1 presses leave
  exactly one panel, and pause, inventory and map all work afterwards.
- [ ] **Layout holds at every list size.**
  **Done when:** screenshots of the rules list at 0/1/13/14/26/27 entries and
  two picker pages show no overlap, and the amount editor sits on its row.
- [ ] **Search/Add crash** (Nexus, DarkWyrmReaper, with Cosmetic Outfits mod 5049).
  **Done when:** with that mod installed, Search all and Add run 5 times
  without a crash, or the attempt is recorded as not reproducible and the
  reporter is asked for the crash log.
- [ ] **Escape, photo mode, death while editing.**
  **Done when:** one recorded run each leaves no grey box, no lost input and no
  stale editor.

## G4. Scheduling does what the stand shows

Judge by the Pal's Current Task and by output, never by fence log lines alone.

- [x] **Priority 1 beats priority 5.** PASS 2026-10-12 by swap control on one Pal ([evidence](g4-scheduling-2026-10-12.md)); per-Pal output not isolated. Report: HelpImStupid0 (Nexus, Sep 19:
  "Transport 5 still dominates primary work 1").
  **Done when:** a staged base with two competing jobs at 1 and 5 shows the
  Pal on the priority-1 job in at least 8 of 10 observations, and that job's
  output rises.
- [ ] **August repro cases still hold:** Incineram Handiwork over Kindling PASS 2026-10-14 ([evidence](g4-scheduling-2026-10-12.md)); Grizzbolt sleep/wake PASS 2026-10-14; generators: the game never announces generator work, so an empty generator did not pull an Electricity-1 Pal off other work; FIXED 2026-10-14 by reading build state and stored energy, verified live (back on the generator 16 s after its priority was restored) ([record](g4-scheduling-2026-10-14-stations.md)); coolers had the same gap (Cooling 1 stayed on Watering 2 about 2 min), FIXED 2026-10-16 by counting built coolers with spoilable food, verified live (on the fridge 18 s after the switch, 9 of 10 samples) ([record](g4-scheduling-2026-10-16-coolers.md)). Server RAM runs eb54d28 since 2026-10-16; stations there untested. Incineram Handiwork over Kindling,
  Grizzbolt stays on the generator after being moved, sleep and wake.
  **Done when:** one observed cycle each, same criteria.
- [x] **Staffing limit:** max 3 on a type with 4 eligible Pals keeps 3 working. PASS 2026-10-12: never above 3, reached 3 under demand ([evidence](g4-scheduling-2026-10-12.md)).
- [ ] **"Everything stops" / "only one miner"**: one reproduction attempt
  with output counts, result recorded either way.
- [-] **Empty dedicated server assignments.** Not applicable, confirmed on rc1 2026-10-11: 0 works with nobody online ([evidence](g4-scheduling-2026-10-12.md)). In August no base work ran with
  zero players online.
  **Done when:** that is re-confirmed on rc1. The gate is then closed as not
  applicable, without adding any assumption to the scheduler.

## G5. Performance target

- [ ] **Best effort, no fixed number (user's decision 2026-10-11).** Optimise
  as far as is practical and report the measured result honestly in the
  changelog. Starting point: the mod adds about 8 slow frames (over 33 ms) per
  minute over the mod-absent baseline (10-11 vs 2); scheduler pass about
  20 ms, stand refresh about 11 ms.
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
- [ ] **Old client and new server disagree politely.**
  **Done when:** a 0.4.1 client joining a 0.5.0 server, and the reverse, shows
  a clear incompatible-version message and corrupts nothing.
- [ ] **Guild isolation still holds.** **Done when:** the August
  fabricated-guild test (rule under a fake guild id plus the real-guild
  control) gives the same result on rc1.

## G7. Package and publish

- [ ] **One clean build for both stores.** **Done when:** `tools/release.py`
  builds the Workshop and Nexus archives from one tagged commit with matching
  hashes. Clean installs from each load exactly one copy (pak mounted), and the
  Workshop/manual conflict is detected and explained.
- [ ] **Changelog and replies.** **Done when:** the changelog lists what is
  fixed, what is deferred (below) and that 0.4.1 X losses cannot be undone, and
  [release-replies-0.5.0-draft.md](release-replies-0.5.0-draft.md) is updated
  against the final build. Posting is the user's action.
- [ ] **Vortex:** one install/update/remove run, or the Nexus page says it is
  not supported yet.

## Deferred to 0.5.x / 0.6 (say so in the changelog)

- Item-specific production limits (stone stops while ore continues). Today a
  limit switches a whole work type; the UI says so before item selection.
- Async saving on by default, and async on dedicated servers.
- Live tests with two real clients and two real guilds (needs a second Steam
  account and machine), unmodded-client edit detection.
- Physical Steam Deck, ultrawide and UI scaling matrix.
- Requests: independent priority/limit mods, high-quality stand restriction,
  Pal-produced materials, deferred scheduling after UI close.

## Suggested order

G1 first (it is what users report most and what the sync-writer decision
rests on), then G3 and G4 in parallel on the AHK rig, G6, G5 captures last on
the final code, then G7. Rough size: 1.5-2 weeks at the September pace.
