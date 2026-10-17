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

## C. Death while editing: NOT DONE (no hostile spawn available)

With the editor open the character cannot move, so death needs an outside
attacker. Tried the UE4SS console route (user-approved, test world): enabled
`ConsoleEnablerMod` and `CheatManagerEnablerMod` (bundled, normally off) and
restarted. Neither F10 nor ~ opened the console in Palworld (the console object
was created and the keys mapped, per UE4SS.log). Calling
`CheatManager:Summon('/Game/Pal/Blueprint/Character/Monster/PalActorBP/ElecPanda/BP_ElecPanda_BOSS.BP_ElecPanda_BOSS_C')`
from a temporary Lua helper (the lazily re-read `stand_lifecycle_probe.lua`,
restored afterwards) with the editor open did spawn a Grizzbolt model at
13:49:27, but it stood still: no AI, no attack, HP 1250/1250 for 25 s.
Class paths of loaded Pals follow
`/Game/Pal/Blueprint/Character/Monster/PalActorBP/<Name>/BP_<Name>.BP_<Name>_C`.
Cleanup: editor cancelled (30,000), helper file restored (cmp equal), both
console mods back to `: 0`. The inert Grizzbolt stays until the next restart.

Remaining routes: a real wild hostile Pal lured to the stand (needs the user in
the game) or a Summoning Altar next to a stand.

## Finding: a limit stepped without a deliberate input

At 13:44:22, during an Esc chain that started right after a focus click on the
title bar (the panel had just been rebuilt, "overlay: host ... fresh root" at
13:44:17), the log shows `Lumbering Wood limit requested: 50000`: the Wood rule
went from 30000 to the next ladder rung. Only Enter, the right arrow and the
gamepad A button raise a selected row (main.lua RETURN / RIGHT_ARROW, pad.lua
FaceButton_Bottom); none was sent by the test. Sunshine was running, so a
Moonlight virtual gamepad is a candidate, unproven. Restored with
`!pwp limit Lumbering Wood 30000` at 13:48; rules diff equal to the snapshot.
Open question for 0.5.0: a raise or lower on Enter/A/arrow changes a saved
limit with no confirmation, only an announcement.

0 ERROR / WARN in priority.log 12:48-12:59.
