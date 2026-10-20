---
date: 2026-10-20
tags: [performance, testing]
status: current
---
# G5: performance, 2026-10-19

Related: [frame-capture-procedure-2026-10-09](frame-capture-procedure-2026-10-09.md) · [frame-correlation-2026-09-13](frame-correlation-2026-09-13.md) · [storage-prefetch-2026-09-13](storage-prefetch-2026-09-13.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md)

Gate (RELEASE-0.5.0.md G5): every recurring mod cost above 5 ms per call is
reduced or recorded with its price, and the last two optimisation rounds each
gain less than 1 slow frame per minute. The final mod-present vs mod-absent
numbers go in the changelog.

Build: e073183 (rc1) on the local singleplayer test world "Palpagos Islands",
2 camps, 14 Pals, game 1.0.5.102999, UE4SS as installed. Captures:
`tools/capture_frames.py` (PresentMon 2.5.1, pinned hash), 60 s each, 5 s lead,
profiling off, no input or commands during a window. Raw receipts:
`test-results/g5-baseline-20261019/` (private, not in the repo).

"Slow frame" means a present interval above 16.67 ms, as in the September
comparison (2 per minute without the mod, 10-11 with it). Intervals above
33.33 ms are reported too.

## Per-call costs on e073183 (profiler on, 188 s, stand open)

| Region | Mean / worst | Calls |
|---|---|---|
| scheduler: complete (one pass) | 34.6 / 38 ms | every ~10 s |
| api: camp enumeration (FindAllOf PalBaseCampModel) | 10.3 / 12 ms | once per pass |
| scheduler: camp roster | 6.6 / 11 ms | once per camp per pass |
| scheduler: station read | 1.4 / 4 ms | 4 per pass |
| clock: deferred: storage refresh | 20.3 / 24 ms | every ~30 s |
| storage: model enumeration / container traversal | 10.7 / 9.3 ms | inside it |
| stand: complete refresh | 13.2 / 16 ms | every second while the stand is open |
| stand: roster lookup | 7.4 / 11 ms | inside it |

Durations are inclusive; nested rows overlap and must not be added.

## Baseline frames, e073183

Two processes, same save and standing position in front of the Monitoring
Stand, windowed, same settings. The mod was physically absent for the second:
the PalWorkPriority folder and `LogicMods/PalWorkPriority.pak` moved to
`D:\PalWorkPriority-backups\g5-absent-20261019-191625` with a SHA-256 manifest,
`mods.txt` entry set to 0 (byte-exact otherwise), UE4SS log without any
PalWorkPriority line. Before removal `pwp off` gave back every allowed work
permission (verified after 21 requests; X choices stay off), and the world was
saved through Return to Title. The 20 experimental `PWP*` probe mods in the
UE4SS Mods folder have enabled.txt but stop at load without a run.txt trigger,
so they are idle in both conditions. Restored afterwards: all 5,162 mod files,
the pak and mods.txt match the manifest.

| Window | Mean ms | p99 ms | >16.67 ms | >33.33 ms | Max ms |
|---|---|---|---|---|---|
| present, stand open 1 | 7.48 | 11.30 | 67 | 8 | 43.2 |
| present, stand open 2 | 7.50 | 10.00 | 67 | 8 | 46.2 |
| present, stand open 3 | 7.70 | 10.76 | 68 | 7 | 50.0 |
| present, closed 1 (night) | 4.90 | 6.08 | 11 | 8 | 42.3 |
| present, closed 2 (night) | 4.91 | 6.31 | 10 | 8 | 41.9 |
| present, closed 3 (night) | 4.83 | 5.89 | 10 | 7 | 40.3 |
| absent, stand open 1 | 7.30 | 9.61 | 2 | 0 | 27.9 |
| absent, stand open 2 | 8.58 | 11.41 | 2 | 0 | 28.6 |
| absent, stand open 3 | 9.34 | 12.03 | 5 | 0 | 29.4 |
| absent, closed 1 (day) | 7.61 | 11.05 | 11 | 0 | 27.5 |
| absent, closed 2 (day) | 6.31 | 8.17 | 5 | 0 | 30.0 |
| absent, closed 3 (day) | 6.63 | 8.79 | 4 | 1 | 42.2 |

Confound: the present runs were at night, the absent runs from dusk into day
(the absent stand-open mean rose 7.3 to 9.3 ms across its three windows and
the first closed window was the heaviest). The >33.33 ms column is not
affected by that: 7-8 per minute with the mod, 0-1 without. The >16.67 ms
closed comparison needs a same-light rerun.

Reading: with the stand open the mod adds about 64 slow frames per minute,
one per stand refresh (13 ms on top of 7.5 ms frames). With the UI closed the
7-8 frames over 33 ms per minute line up with the scheduler pass (34.6 ms,
every 10 s, so 6 per minute) plus the storage refresh (20 ms, every 30 s, 2 per
minute). In September the pass was 20-23 ms and this column was 0-1; the
October station reads (generators, coolers, rocks, trees) and roster growth
moved it over 33 ms.

## Round 1: the nickname read (2026-10-19)

A probe (temporary `stand_lifecycle_probe.lua`, restored with cmp) timed the
roster read in pieces, 20 iterations per camp:

| Camp | Pals | camp_pals | of which GetNickname |
|---|---|---|---|
| 1 | 9 | 5.10 ms | 4.75 ms |
| 2 | 5 | 2.95 ms | 2.60 ms |

On game 1.0.5 `GetNickname` wants an out parameter. Called without one it
raises "UFunction expected 1 parameters, received 0", the pcall hides it, every
name falls back to the species, and building the error costs about 0.5 ms per
Pal. The stand refresh calls the same `pal_name` for each of its 9 rows every
second. The nickname is also a property, `SaveParameter.NickName`: reading it
took less than the clock's resolution and returned "" for every Pal (none are
named in this world), so names stay the species here and real nicknames show
where they exist.

Change: `palapi.nickname` reads the property; `pal_name` and `camp_pals` use it.
Test `test_roster_read_reuse.lua` now stubs a raising GetNickname and asserts
it is never called and that empty and set nicknames behave; negative control
with the old palapi.lua fails. 219 scripts pass.

## Rounds 2 and 3: station typing (2026-10-19)

After the absent run the camps held far more work objects and items (the
first pass after loading saw 1454 works, 1390 of them Transporting), and the
profiler (same build plus round 1, 182 s, settled) showed why that hurts:
each of the four station counters (generator, cooler, trees, rocks) walked
every work in the camp and typed it again with `api.work_suitability`, which
can take two native string calls (GetWorkName, GetFullName). Station read
7.7 ms x 4 per pass, scheduler pass 49.7 ms, in that grown world.

Round 2: the works are typed once per camp per pass and each counter gets only
its own kind. A throw while typing drops every station count for that pass,
as a throw inside a counter did for its kind. Result in the same world:
typing 6.7 ms per camp, reads 0.04 ms, pass 32.5 ms.

Round 3: a work's type never changes, so the type is remembered by work id (a
plain string from `camp_works`' new third return; the work object is never
kept) and only new works are typed. The memo is rebuilt by every pass, so
vanished works drop out; an untyped work is not remembered and is asked
again; `scheduler.forget()` (world change) clears it. Result: typing 0.09 ms,
camp works read 2.5 ms per camp, pass 20.2 ms (worst 23).

Tests: `test_scheduler.lua` checks that six works are typed six times on the
first pass, once (only the untypable one) on the next, that a new work is
typed once, a vanished one no longer counts, `forget()` starts over, every
counter gets exactly its own kind, and a typing throw reaches no counter.
Negative controls: the old scheduler fails the typed-once check; without
storing the memo the second-pass check fails. 219 scripts pass.

## Per-call costs after round 3 (182 s, settled, stand open)

| Region | Mean / worst | Calls |
|---|---|---|
| scheduler: complete | 20.2 / 23 ms | every ~10 s |
| api: camp enumeration (FindAllOf) | 10.2 / 11 ms | once per pass |
| scheduler: camp works | 2.5 / 7 ms | per camp per pass |
| scheduler: camp roster | 0.35 / 3 ms | per camp per pass |
| scheduler: station typing / read | 0.09 / 0.03 ms | per camp per pass |
| clock: deferred: storage refresh | 31.5 / 33 ms | every ~30 s |
| storage: model enumeration (FindAllOf) / traversal | 11.0 / 20.3 ms | inside it |
| stand: complete refresh | 12.2 / 15 ms | every second, stand open |

The storage traversal grew from 9.3 ms (baseline world) to 20-25 ms with the
larger stock after the absent run; it reads every slot of every container.

## Round 3 frames (same save, process 38040, profiling off)

| Window | Mean ms | p99 ms | >16.67 ms | >33.33 ms | Max ms |
|---|---|---|---|---|---|
| present, stand open 1 | 6.15 | 8.94 | 66 | 2 | 40.3 |
| present, stand open 2 | 6.11 | 8.86 | 67 | 2 | 38.2 |
| present, stand open 3 | 6.08 | 8.87 | 67 | 3 | 39.4 |
| present, closed 1 (evening) | 5.51 | 7.19 | 9 | 2 | 37.9 |
| present, closed 2 (evening) | 5.35 | 6.41 | 10 | 3 | 35.8 |
| present, closed 3 (evening) | 5.33 | 6.34 | 10 | 3 | 37.6 |

Against the baseline: frames over 33 ms per minute fell from 7-8 to 2-3 in
both scenes (the scheduler pass no longer crosses 33 ms; the remaining ones
match the storage refresh at 31-33 ms every 30 s). Frames over 16.67 ms are
unchanged: with the stand open the once-a-second stand refresh (12 ms on 6-7
ms frames) makes about 60 a minute, and with the UI closed the 20 ms pass every
10 s still makes one each time.

## Remaining costs and their decisions

The three remaining costs after round 3 (status updated 2026-10-20):

1. Stand refresh, 12 ms once a second while the stand is open (about 60 slow
   frames a minute in that scene). Input already repaints its cells at once;
   the full refresh catches what the game redraws itself (scrolling, rows
   rebuilt, new Pals, server pushes). Less often means stale numbers for
   longer after such a redraw. **Decided 2026-10-20: justified with that
   price** (see Decisions taken).
2. Camp enumeration, 10 ms per pass (FindAllOf, the only proven way to find
   live camps). It keeps the pass at 20 ms: a slow frame every 10 s, no frame
   over 33 ms. **Decided 2026-10-19: kept** (DECISIONS.md).
3. Storage refresh, 31 ms every 30 s with this stock (FindAllOf 11 ms plus
   reading every slot). It cannot be sliced without a fresh FindAllOf per
   slice, because no engine object may be kept across callbacks. **Decided
   2026-10-20: kept at 30 s, justified** (aligned trace below; DECISIONS.md).

Still open for G5:

- ~~Identify the second ~30 s event~~: done 2026-10-20, it overlaps no mod
  event (aligned trace below).
- The final capture for the changelog: mod present and absent back to back in
  the same light; the >16.67 ms closed comparison above is confounded by night
  versus day.

## Independent cross-check (agent, read-only, 2026-10-19)

Recomputed from frames.csv: every count and mean above matches exactly; all
18 windows validated; sha256 of raw.csv, frames.csv, attempt.json, stdout and
stderr match the receipts; one PID, creation time and swapchain per condition
(17504 baseline present, 22372 absent, 38040 round 3); every window 59.96 to
59.99 s, recorder exit 0.

Spacing in the closed windows: a clean 10.3 s chain in both sessions (the
scheduler pass), 35-42 ms on the baseline and 24-30 ms after round 3, which is
the robust result. Two chains about 30 s apart (28.8-28.9 s and 30.0 s
spacing) remain at 34-38 ms after round 3: one is the storage refresh, the
second is not identified yet. The mod-absent session has its own 10.0 s chain
at 17-18 ms, so not every periodic spike is the mod's.

Caveats it raised: each condition is a different session and round 3 has no
new absent control (closed means went 4.9 to 5.4 ms while stand means went 7.6
to 6.1 ms, a session difference); with three windows per condition a
difference of 1-2 frames over 33 ms is within noise; Dropped presents vary
(one round-3 stand window has 1645); these are present intervals, not display
latency.

## Decisions taken (user, 2026-10-19 evening)

- Stand refresh: investigate a cheap "nothing changed" test that can skip the
  full refresh; keep 1 s whenever something changed. **Dropped 2026-10-20**,
  see below.
- Scheduler pass: keep 10 s and the camp FindAllOf, recorded in DECISIONS.md.
- 30 s events: identify the second one before deciding on the storage refresh.
- Server RAM updated to 30ee360 (backup `Scripts-before-30ee360`, 58 files,
  palapi.lua 74.27 KiB and scheduler.lua 75.84 KiB match the commit), restart,
  `PWP_READY version=0.5.0-rc1` at 20:06:42, no error or warning.

### 2026-10-20: stand refresh justified, "nothing changed" skip dropped (user)

The skip chosen for investigation on 2026-10-19 is the "dirty-flag refresh
gating" that DECISIONS.md (2026-08-27) already rejects with measurements: it
reintroduced the repaint bug three times. It was proposed without reading that
rejected list first. The user dropped it on 2026-10-20.

The stand refresh is recorded as justified with its price: 12.2 ms (worst
15 ms) once a second, only while the stand is open, about 60 frames over
16.67 ms per minute in that scene (66-67 in the round-3 stand windows against
9-10 with the UI closed). With the stand closed it costs nothing. It stays
because the game redraws rows itself (scrolling, rebuilt rows, new Pals,
server pushes) and only the full refresh repaints those.

## Which events cause the frames over 33 ms (2026-10-20, aligned trace)

Recorder `tools/g5_trace_record.py`, analysis `tools/g5_trace_analyse.py`
(after the 2026-10-09 correlation tooling): profiling and the Lua frame-event
trace (events of 4 ms or more) on, two nonce anchors before and two after a
120 s PresentMon capture with raw QPC time; the four anchor brackets agree on a
fixed-rate Lua-to-QPC offset to within 5.2 ms. Build 30ee360 (plus a comment
change), UI closed, daytime, settled 60 s after load. Raw:
`test-results/g5-trace-20261020/closed-1/` (private).

| Frame over 33 ms (capture time) | Overlapping mod event |
|---|---|
| 14.6 s (37 ms), 43.4 s (36 ms), 72.1 s (38 ms), 100.4 s (50 ms) | storage refresh, 31-37 ms each, every 28.3-28.8 s |
| 97.2 s (36 ms) | scheduler pass 23 ms |
| 23.5 s (34 ms), 59.1 s (901 ms), 83.9 s (35 ms), 84.0 s (35 ms) | none of 4 ms or more |

- The ~28.7 s chain the cross-check found is the storage refresh: every one of
  them made a frame over 33 ms.
- The second ~30 s chain is not the mod's: no mod event of 4 ms or more
  overlaps those frames, and they are not evenly spaced (23.5, 59.1, 83.9 s).
  Most likely the game itself (its world autosave also runs about every
  30 s, see [async-save-history](async-save-history.md)); not proven. The
  901 ms stall belongs to it too.
- Over 16.67 ms the closed scene is mostly the game: 59 of 75 such frames
  overlap no mod event. The mod's share is the scheduler pass (19-26 ms every
  10.3 s) and the storage refresh.
- Profiling was on for attribution, so durations include profiler overhead;
  the frame numbers of record stay the profiling-off captures above.

So the storage refresh is the last mod cost that crosses 33 ms (about 2 frames
a minute with this stock). Decided 2026-10-20 (user): it stays at 30 s,
recorded as justified in DECISIONS (Performance).

## History: September measurements (game 1.0.4/1.0.5, before the matched baseline)

Condensed on 2026-10-20 from 17 notes of 2026-09-11 to 09-15 that were then
deleted (git history keeps them; names in the last column). Game 1.0.4.102642
until 09-13, 1.0.5.102999 from 09-15. Builds, scenes, session age and other
mods differ between rows, most windows had profiling on and none had a
mod-absent control, so this is a trend, not a baseline. The September
mod-absent comparison is [frame-correlation-2026-09-13.md](frame-correlation-2026-09-13.md).
Means in ms, inclusive; frames per 60 s clip.

| Date | State | Stand refresh | Scheduler pass | Storage scan | >16.67 / >33.33 ms, worst | Source note |
|---|---|---|---|---|---|---|
| 09-11 | stand grid broken (every refresh "unavailable") | 39.3 | 42.2 | 22.6 | n/a / 60-63, 56-99 | stand-capture |
| 09-12 19:19 | grid draws again (broken session before: 37.5) | 28.5 | 42.7 | 22.7 | n/a / 52-54, 81-84 | roster-native-retest, stand-retest |
| 09-12 22:35 | input on the 100 ms beat, pad read once | 30.2 (menu 10.2, roster 12.4) | 43.8-43.9 | 24.2-24.3 | n/a / 56-57, 81.6-82.9 | jump-restart, stand-input-retest |
| 09-13 12:09 | traversal trims | 27.2 (menu 10.1, roster 10.7) | 43.2-43.7 | 22.1-23.1 | n/a / 53-56, 80-83 | stand-cost-retest |
| 09-13 12:50 | row-scoped roster, storage backoff | 24.0 (roster 6.9) | 27-29 (max 45-47) | 23-24, 8 scans per 24 passes (before 19/19) | 58-60 / 7-11, 74-77 | performance-investigation, deep-performance-retest |
| 09-13 13:36 | background-job coordinator, label hints | 20.8 (labels 0.6-0.7, before 3.3-3.5) | 25-27 | 21-22 | 64-65 / 2-4, 48-160 | performance-bundle, performance-bundle-retest |
| 09-13 15:32 | after the targeted menu query (menu 10 -> 0.6, [viewport-and-icon-retest](viewport-and-icon-retest-2026-09-13.md)) | grid 10.6-10.7 | 27-29 (peak 41-44) | 21 | 61-64 / 3-4, 47-50 | remaining-stutter |
| 09-13 18:22 | stand closed, profiling off | - | 22.3 (camps 10.5, roster 8.3 for two camps) | 20 | 10-11 / 1-2, 45-78 | scheduler-read-reuse |
| 09-13 19:21 | roster read reuse | grid 10.7-10.9 | 20.6 (roster 4.1-4.2 per camp) | 20 | open 60-65 / 2; closed 12 / 2 | roster-read-retest |
| 09-15 22:16-22:30 | game 1.0.5, GetAllChildren trial (ABBA, 30 s clips) | 11.5 indexed, 11.6-11.9 bulk | 26 (max 38) | - | 32-34 / 0-2 per 30 s; one bulk clip 56 / 4 with a 1.63 s gap | performance-2026-09-15 |
| 09-15 23:29 | panel opening keeps the storage plan | - | 20 / 22 steady; 26.7 / 38 on panel open before, 19.4-20 / 21-22 after | 17.5-19.5 (background) | not recorded | panel-storage-refresh |

Findings that still hold:

- Long frames recurred at median gaps of 1.065-1.069 s (>33 ms) and
  10.69-10.72 s (>60 ms): the stand and scheduler cadence (09-13). With Lua
  and QPC clocks aligned within 4.9 ms, 57 of 67 frames over 16.67 ms
  overlapped a stand grid refresh (stand-name-retest); with the stand closed,
  11 of 14 overlapped scheduler or storage events and the three largest
  overlapped nothing recorded (scheduler-read-reuse). Correlation, not proof.
- The pattern stayed with profiling off in every on/off comparison, so the
  profiler is not the cause.
- Roster lookup 7.0-7.1 ms: row-owner validation 3.4-3.5 ms of it, checkbox
  contents 2.3 ms, menu ownership 0.8-0.9 ms (stand-tree-phases). Plain
  `GetWidgetFromName` is rejected (unreflected C++ on this runtime).
  Row-scoped search cut roster visits 909 -> 639.
- Bulk traversal through `GetAllChildren` (`pwp standbulk`, 09-15) was
  rejected: four ABBA PresentMon clips showed no frame benefit, and review
  found a duplicate-child hole (a batch `{a,a}` could hide a target that
  indexed reads return as `{a,b}`). Removed; archived in
  `test-results/rejected-stand-bulk-20260915/`.
- Menu lookup: `FindFirstOf` can select a hidden or wrong menu; stored
  wrappers and name-only freshness are rejected. Label lookup with scalar edge
  hints, re-checked each call, fell 3.3-3.5 -> 0.6-0.7 ms per grid. Text and
  colour writes cost 0.34 ms per grid; name-only write caches were rejected
  (blank or recycled cells).
- Storage: incomplete reads retry after 5, 10, 20, then at most 30 s (capped
  by the TTL; a verified read resets it), and only camps whose effective
  numeric limits need storage are scanned. Unfiltered zero-GUID holders skip
  class-name reads (534 -> 0) but stay unknown. Excluding no-base loot before
  module discovery was rejected (it would hide module failures).
- Opening the panel used to discard the storage plan (`forget_stock`), so the
  next pass re-scanned inline: a 38 ms pass with 17 ms storage. Now it marks
  the plan for an immediate background refresh: passes 19.4-20 ms mean, 21-22
  worst, clock batch 22 instead of 38 ms. The work is moved, not removed:
  background jobs still run on the game thread, on separate clock beats.
- Background coordinator (09-13): input first, at most one background job per
  beat, 8 ms soft budget, eligible after 300 ms lateness. Worst heartbeat
  70-74 -> 42-45 ms. Not a hard bound on any single native call.
- Input: the queue used to drain once a second, so a click could wait almost
  1 s; it now drains on the 100 ms beat. Rapid-click "jumps" came from the
  scheduler adopting a native checkbox change as a priority edit (saving X or
  1); native observations no longer overwrite saved priorities. Rejected: a
  mouse debounce (the runtime sends down edges, it would drop real rapid
  clicks), collapsing saturating clicks into a net direction (left then right
  at 1 must give 2), and the 150 ms draw-age click guard, removed because it
  discarded real clicks (a regression fails if it comes back).
- Pad polling reads the viewport and controller once per call for all eleven
  buttons: 0.30 -> 0.14-0.15 ms per call.
- Logging cost file 7 ms and console 2 ms per 170 s; a speculative buffering
  rewrite was rejected. Scheduler permission-read reuse (70 -> 56 reads in a
  14-Pal fixture) and roster read reuse gave no measurable pass saving.
- Unexplained outliers kept in the evidence: one 160 ms interval (09-13 13:36)
  and one 1.63 s gap (09-15, bulk clip).
