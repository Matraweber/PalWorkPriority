# G5: performance, 2026-10-19

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

## Open: what is left, and why it needs a decision

1. Stand refresh, 12 ms once a second while the stand is open (about 60 slow
   frames a minute in that scene). Input already repaints its cells at once;
   the full refresh catches what the game redraws itself (scrolling, rows
   rebuilt, new Pals, server pushes). Less often means stale numbers for
   longer after such a redraw.
2. Camp enumeration, 10 ms per pass (FindAllOf, the only proven way to find
   live camps). It keeps the pass at 20 ms: a slow frame every 10 s, no frame
   over 33 ms.
3. Storage refresh, 31 ms every 30 s with this stock (FindAllOf 11 ms plus
   reading every slot). It cannot be sliced without a fresh FindAllOf per
   slice, because no engine object may be kept across callbacks.

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
  full refresh; keep 1 s whenever something changed.
- Scheduler pass: keep 10 s and the camp FindAllOf, recorded in DECISIONS.md.
- 30 s events: identify the second one before deciding on the storage refresh.
- Server RAM updated to 30ee360 (backup `Scripts-before-30ee360`, 58 files,
  palapi.lua 74.27 KiB and scheduler.lua 75.84 KiB match the commit), restart,
  `PWP_READY version=0.5.0-rc1` at 20:06:42, no error or warning.
