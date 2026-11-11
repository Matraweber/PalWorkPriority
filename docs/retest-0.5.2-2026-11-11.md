---
date: 2026-11-11
tags: [testing, evidence, stand, nexus]
status: evidence
---
# 0.5.2: clearer cell tooltip and a switch for the stand line (2026-11-11)

Related: [DECISIONS](DECISIONS.md) · [LESSONS](LESSONS.md) · [comment-ledger-2026-09-11](comment-ledger-2026-09-11.md) · [retest-0.5.1-2026-11-10](retest-0.5.1-2026-11-10.md)

Two suggestions from CerbinTalYalas on Nexus (ledger rows 98 and 99), done
on branch `dev-0.5.2` from 08967f0, worktree `pwp-wt/dev-052`. Local test
world (2 bases, 14 Pals, game 1.0.5.102999, 1280x720 window). Deployed with
`tools/deploy.ps1`; every installed file compared equal to the branch.

## What changed

- **Cell tooltip** (their layout, wording adjusted): the cell's number and the
  scale ("Priority 3 (1 = first, 5 = last, X = never)"), the cell's detail with
  its `* ! ?` mark in front, the equal-numbers hint where it applies, a blank
  line, one control per line, then the steering count on the host. The pad
  names its buttons. A missing pak replaces the controls; a locked stand still
  shows only its reason. `M.MARKS_HELP` and the old "focus the stand" lines
  are gone.
- **"raise / lower"** replace "toward 1 / toward X" in the footer and the
  tooltip. The footer got shorter, so three-digit steering counts now keep
  "(all bases)".
- **`show_stand_legend`** (default `true`; `config.lua`, validated, and a
  "Monitoring Stand" section on the DarnMenu page). `false` collapses the
  footer Border unless it has a notice (lock, store, pak, refused change,
  reset/conversion notices, a selected cell's "!", config paused). The
  visibility is written only when it changes.
- The steering count is kept per refresh (`legend_round.steering`), because
  the footer and every tooltip now both name it. Without this the scheduler
  was asked twice per refresh (caught by the existing "once per refresh" test).

## In-game results (1280x720)

- **Footer:** "1 first, X never | Steering 11 of 14 (all bases) | Left
  click/Enter: raise (1 wraps to X) | Right click: lower | Arrows, keys 1-5, X
  | ALT+F1: Limits panel", one line, in the same place (ScreenShot00419).
- **Tooltip** on Anubis's Mining 3 (ScreenShot00421): the layout above,
  "Steering 11 of 14 (all bases)" last. Still open after 16 s of hovering
  across a recheck (ScreenShot00422). Verdash's X cell reads "Priority X (1 =
  first, 5 = last, X = never)" (ScreenShot00423).
- **Line off:** `show_stand_legend = false` in the DarnMenu user file, game
  restarted ("DarnMenu options applied, 2 setting(s)"): no line and no empty
  box under the stand (ScreenShot00424); the tooltip still lists every control
  (ScreenShot00425).
- **Not seen in game:** a notice bringing the hidden line back (covered by
  the test below, with the config-paused notice), the pad tooltip, and
  1920x1080 (the footer only got shorter; the tooltip is drawn by Slate).

## Performance (`pwp perf`, stand open, 93 s)

| Region | 0.5.2 | 0.5.1 |
| --- | --- | --- |
| scheduler pass | 18.0 / 20 ms | 18.9 / 22 ms |
| stand complete refresh | 11.6 / 14 ms | 11.3 / 20 ms |
| stand cell refresh | 0.032 ms | 0.032 ms |
| stand legend refresh | 0.057 ms | not listed |

## Tests

New: the tooltip's order and text (client and host, pad, a rebound panel
key), `M.cell_help` for "?" and "X" with a mark and the hint, and
`show_stand_legend = false` (collapsed, comes back for the config-paused
notice, collapses again, no visibility write per beat, back on with nil).
DarnMenu: the option, apply, a refused non-boolean, the page default from
`config.lua`, and `configuration.validate`. Changed: the old wording asserts.

Lua 256 scripts 0 failures, luacheck clean (ui.lua 115 top-level locals,
panel.lua unchanged at 193), Python 842 OK (85 skipped).

## Test world restored

The DarnMenu user file was copied first to
`D:\PalWorkPriority-backups\before-0.5.2-tests-20261111-113928` and put back
(byte-compared); the test copy is kept there as `.during-test`. The two
temporary scheduled tasks (`pwp-hover`, `pwp-restart-stand`) were deleted.
The local install keeps the 0.5.2 dev build.
