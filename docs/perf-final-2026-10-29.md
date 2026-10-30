---
date: 2026-10-29
tags: [performance, testing, release]
status: evidence
---
# Performance check of the 0.5.0 build (2026-10-29)

Related: [g5-performance-2026-10-19](g5-performance-2026-10-19.md) · [frame-capture-procedure-2026-10-09](frame-capture-procedure-2026-10-09.md) · [retest-r3-2026-10-29](retest-r3-2026-10-29.md) · [DECISIONS](DECISIONS.md)

The user asked for a thorough performance check of everything and reported that the
item picker felt "super laggy with the mouse" while "Show all" felt fine. Local test
world (2 bases, 14 Pals, game 1.0.5.102999, 1280x720 window), character at the Palbox;
the GPortal server "RAM" (1 base, 9 Pals, 0 players). `pwp perf` is the mod's own
timer (1 ms resolution, inclusive). Frames: `tools/capture_frames.py` (PresentMon
2.5.1), 3 x 60 s per condition, profiling off, no input.

## UI closed (build after c777643)

| Region (181 s) | Mean / worst | Calls |
| --- | --- | --- |
| scheduler pass | 18.1 / 27 ms | every ~10 s |
| camp enumeration (FindAllOf) | 10.4 / 12 ms | once per pass |
| camp works | 0.74 / 1 ms | per base |
| per-item rock limits | 0.06 / 1 ms | per base |
| storage refresh | 22.2 / 23 ms | every 30 s |

Same as G5 round 3 (pass 20.2 ms). No regression from the round-3 work.

## Frames, UI closed

| Condition | Mean frame | >16.7 ms per min | >33.3 ms per min |
| --- | --- | --- | --- |
| Mod present, game in front, daylight | 6.0-6.1 ms | 11, 10, 10 | 3, 2, 2 |
| Mod absent, game in front, daylight | 7.4-7.8 ms | 3, 5, 2 | 0, 0, 0 |

Matches G5 final (10 and 3-4 per minute present). The mod was removed and restored
with `tools/mod_absent.py` (7,030 files and the pak, 0 hash mismatches after restore),
after `pwp off` gave back every job. Two earlier runs were discarded as confounded:
present at in-game night (11.1 ms frames) and absent with Chrome in front. The 2-3
frames per minute over 33 ms are not attributed to any measured mod event.

## Panel and picker

- Limits tab open: 2.3 / 9 ms per redraw, about 4.6 per second.
- Picker default list: 4.1 / 9 ms per redraw, about 5 per second (about 20 ms/s).
- **Bug found and fixed: "Show all" never finished filling.** The fill loop counted
  tiles that were already drawn against its 8 ms slice, so after 20 of 27 tiles it
  broke every frame and redrew at 60 Hz: 324 redraws in 10 s at 12.4 ms, about
  400 ms of game-thread work per second, for as long as Show all was open. After the
  fix: 27 tiles, 60 redraws in 13 s at 5.2 ms (24 ms/s). A guard stops the fast loop
  after one second without progress.
- **The reported mouse lag:** the highlight followed the pointer only at the ~5 Hz
  redraw rate (up to ~200 ms behind). "Show all" felt smooth only because of the 60 Hz
  bug. Fix: the panel keeps a map of its targets from its own layout numbers and
  redraws on the next 16 ms beat when the pointer reaches another target (at most every
  33 ms). Engine geometry (`GetCachedGeometry`) comes back empty through UE4SS, so the
  map uses the panel's layout and `GetMousePositionOnViewport`. In game it learned a
  constant offset of 0,5 units and stayed on. A cursor parked at the viewport centre
  right after opening is ignored.
- **Icon pins:** every icon pin was a child of the panel root and was rescanned on
  every redraw (up to 400 per session). Pins now live under one shelf the rescan
  skips; the "panel refresh worst" line reports the rescan and pin counts.

## Dedicated server

| Region | Before | After the fix |
| --- | --- | --- |
| scheduler pass | 65.9 / 81 ms | 31.3 / 37 ms |
| authority check | 20.5 ms (object walk) | 0.14 ms (game instance) |
| camp works | 20.5 ms (controller walk) | 1.4 ms |
| camp enumeration | 20.8 ms | 18.5 ms (kept) |

A headless server has no viewport and no local controller, so both answers came from
full object walks on every pass, and on a server without players the works read
failed, so station handling and per-item rock limits did nothing there. Both now use
the game instance and are still checked on every pass.

## Server join on the final build (99a2e26)

Uploaded as `Scripts.zip` (60 files at its root, `git archive 99a2e26:Scripts`, key
sizes match; previous folder kept as `Scripts-before-99a2e26`). The client went from
connecting to "sync: ready" in 5 s, so the game-instance authority route works with a
player online.

On the client, the picker's hover follow drew once per tile change (12 extra draws of
4.9 ms during a 12-tile sweep) and stayed on.

## Notes

- The "0 work(s) ... 1 idle camp(s) reconciled" lines on the empty server count the
  game's own demand pulses, not the works read; the pulses stop when nothing asks for
  workers (for example at night). The trees, rocks and ranch numbers after the bar come
  from the station counters, which only work on the server since this fix.
- The untyped-work warning named `HatchingPalEgg_0`. Incubator hatch timers are now
  ignored (no Pal works them), and the warning no longer blames Construction.
- The growing controller-walk gap is reset when a player joins, so the first player
  after an empty spell is not delayed.

## Open

- ~~The hover offset learning can be misled by an instant pointer jump~~: fixed on
  2026-10-30 (5ce28a6, learning only from steady samples). In game: 12 redraws for 12
  tile changes, no contradictions, offset 0,7 learned once, map stayed on.
- No frame capture with the panel open exists.
- The 2-3 frames per minute over 33 ms with the UI closed are not attributed.
