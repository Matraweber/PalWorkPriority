# Native panel handoff checks — September 24, 2026

Candidate 0.5.0-rc1, unchanged installed Lua and WorkRules3/StandInput2 test
package, game PID15092. Native checks ran 19:43–19:45 without restarting,
deploying or changing saved priorities/limits. Panel opening used the authorized
remote `open` command, not a keyboard-shortcut acceptance test. All subsequent
interactions used actual mouse/keyboard routing through the game.

## Observed results

- Opened Production Limits over the stand. Clicked Wood's existing 30000 amount,
  used Backspace to alter the draft, then clicked the whole panel's Close button.
  The panel disappeared; the stand and its priority numbers remained usable.
- Escape closed the stand, then another Escape opened the vanilla pause menu.
  Clicking its Inventory tab succeeded after waiting through the menu transition.
  Escape returned to gameplay. No input watchdog took focus from that menu.
- M opened the map. Opened Production Limits over the map; Wood still showed
  30000. Escape closed only Production Limits, leaving the map visible.
- F opened the map's filter controls after handoff. Escape dismissed the filter,
  then a second Escape closed the map. No filter value was changed.
- Final panel state: open=false, editing=no, native_escape=false.
- Priorities, caps and external config stayed byte-identical to the pre-test
  backup. No WARN/ERROR matched the captured test window in priority.log.

Log receipt: test-results/panel-handoff-native-20260924.txt. The game was left
in gameplay at the stand before restoring the stand view.

## Limits

This is native acceptance of draft cancellation via whole-panel Close, and
ordinary stand/map handoff plus subsequent pause/inventory access. No new code
fix was needed for these cases. It does not establish photo-mode, bed, respawn,
physical-controller, duplicate/missing-pak or rapid simultaneous input safety.
It is not a frame-time or stutter-free result. The original crash reports remain
open until their actual failing paths are reproduced or specifically covered.
