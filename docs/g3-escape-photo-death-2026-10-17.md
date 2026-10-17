# G3: Escape, photo mode, death while editing, 2026-10-17

Singleplayer test world, build 34c95ad (0.5.0-rc1), Monitoring Stand +
Production Limits panel, amount editor opened on the Wood rule (30,000). Keys
and clicks through computer use, the game focused with `pwp-focus` before each
batch.

## A. Escape while editing: PASS (12:52)

Editor open ("Set Wood: whole number; confirm saves, Esc cancels") -> Esc
cancelled the draft (30,000 unchanged) -> Esc closed only Production Limits ->
Esc closed the stand -> Esc / Esc opened and closed the pause menu -> Tab opened
the inventory 1.2 s later. No grey box, no stale editor, no lost input.

An earlier attempt (12:51) had not opened the editor (the click landed with no
hover first; a real mouse always hovers) and after the same Esc chain one Tab
1.2 s after closing the pause menu did not open the inventory. Not reproduced:
the vanilla control (pause open/close, Tab after 1.2 s, panel never used) and
the repeat of the full chain with the editor open both opened the inventory.
Recorded as a single unexplained miss.

## B. Photo mode while editing: PASS (12:53-12:55)

- Editor open, key 4 (Command Pal wheel): the digit went into the field
  ("300004"), the wheel stayed closed. Esc discarded it: 30,000 unchanged.
- Panel open without editor, key 4: wheel stays closed (the panel's input
  route blocks it, as on 2026-09-24).
- Panel and stand closed, key 4 -> Photo Mode: photo mode shows no grey box,
  with the HUD shown, hidden (F) and restored (F). Esc returned to play.
- Stand and panel reopened normally afterwards, rules unchanged.

Not covered: photo mode from a Pal bed (Zekrom144's report).

## C. Death while editing

See below.

0 ERROR / WARN in priority.log 12:48-12:59.
