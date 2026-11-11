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

## Review round (newcomer UX, stand bugs, test coverage)

No P1. Confirmed, the user picked fixes 1, 2, 4, 5 and "drop the number":

- **P2 (UX, also stand bugs P3-2):** a tooltip opens only under the mouse,
  so with the line off a controller player had no button names, and four
  texts said every tooltip lists the controls. The line now stays while the
  last input was a controller; texts reworded.
- **P2 (UX):** "(click or arrow into the stand first)" made the first click an
  edit (stand_pointer queues a step on the press). Now "(if nothing happens,
  press an arrow key first)"; README the same. Seen in game: one Right arrow
  on a freshly opened stand selected Verdash's X cell without a click
  (ScreenShot00426).
- **P3 (stand bugs):** the first line carried the number, so an edit of the
  hovered cell rewrote the text and closed the tooltip on the host. Now
  "Priority: 1 = first, 5 = last, X = never". Seen in game: tooltip open,
  number key 3, cell 2 -> 3, tooltip still open (ScreenShot00437/00438).
- **P2 (tests):** pak-missing tooltip, settings-lock tooltip, hidden line
  updated by an arrow (M.nav passes cfg), rebuilt Border stays collapsed,
  pad keeps the line, steering asked once per input paint. Each new test
  fails with its fix taken out (8 of 8, scratchpad mutate052.py).
- **P3 cleanups:** dead guard in give_back removed; paint_input runs in one
  legend round.
- Not changed: "raise (3>2, 1>X)" in the footer (user skipped); the tooltip
  font size is the game's tooltip style.

In-game check of the fixes: deployed after a normal quit (quit-only copy of
the restart macro), relaunched. Hovering needs one real click on the game
window after a launch; a number key then needed one arrow key first, which is
what the new hint says. Anubis's Mining went 3 -> 2 -> 3 and is stored as 3.

Tests after the fixes: Lua 256 scripts 0 failures (stand 101 checks),
luacheck clean.

## Controls in one place (the user's call after seeing it)

With the line on (then the default) and the new tooltip, the scale, the
controls and the steering count were on screen twice. The user: "only when
hovering on one we dont need it in 2 places". Now:

- `show_stand_legend` defaults to `false` (config.lua, DarnMenu page; no key
  at all is off). The line shows only notices, and the buttons on a
  controller.
- `M.legend_text` returns whether its text is the controls line;
  `refresh_legend` keeps that in `M.line_names_controls`, and a cell's
  tooltip adds the controls block only when the line is not showing it
  (also while a notice stands in its place, and without a line).
- Tests: the fixture runs with the line on (its footer tests are about the
  line); new asserts for "line on: no controls or count in the tooltip",
  "no key: collapsed", "pad: the line has the buttons, the tooltip not",
  and the count once per refresh with the line off. Three breaks of the
  rule (tooltip always with controls, a notice hiding them, no key = on)
  are each caught (scratchpad mutate053.py).
- Re-review of 8ac55e8 (stand bugs agent): no P1; its P2 was the CHANGELOG
  line "an edit keeps the tooltip open", not true on a Pal's first edit
  (the equal-numbers hint goes), a second later on the host (the steering
  count moves) and on every client edit ("Sending"). The line was removed.
- In game (deployed after a normal quit, relaunched, no setting saved
  anywhere): no line under the stand (ScreenShot00439); the hovered cell's
  tooltip has the scale, the controls and "Steering 11 of 14 (all bases)"
  (ScreenShot00440). Not seen in game: `show_stand_legend = true` with the
  short tooltip (covered by the tests).

Lua 256 scripts 0 failures, luacheck clean, public texts OK.

Re-review P3s (user: "fix both"): the steering test now runs with the line
off and asserts exactly 1 call per arrow (it measured 1 with the fix, 2
without; the old `<= 2` also passed at 0). The other P3, controller mode
leaking into later tests, does not happen: every check builds a fresh
fixture with a new palapi table and reloads ui.lua; nothing changed.

## Test world restored

The DarnMenu user file was copied first to
`D:\PalWorkPriority-backups\before-0.5.2-tests-20261111-113928` and put back
(byte-compared); the test copy is kept there as `.during-test`. The two
temporary scheduled tasks (`pwp-hover`, `pwp-restart-stand`) were deleted.
The local install keeps the 0.5.2 dev build.
