---
date: 2026-10-22
tags: [input, panel, stand-ui, research]
status: evidence
---
# Controller support: routes, build and in-game acceptance, 2026-10-22

Related: [controller-2026-10-21](controller-2026-10-21.md) · [widget-spec](widget-spec.md) · [stand-keyboard-2026-09-24](stand-keyboard-2026-09-24.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md)

Question (user, 2026-10-22): can a controller be made to work, perhaps with
help from PalPriority or another mod?

## What blocks it today (measured, see controller-2026-10-21)

The mod polls `PlayerController:IsInputKeyDown`. That works in the open world.
In menus the game's CommonUI takes the D-pad and A for its own navigation
before the player controller sees them, and the Monitoring Stand (a game menu)
takes every button. The open chord RB + View opens the game's map.

## What other mods do

- **PalPriority** (Nexus 3830, fenynro): mouse only, "Left click raises it ...
  right click lowers it" on the stand. No controller route to borrow.
- **DarnMenu** (Workshop 3769456391): builds its pages from the game's own
  buttons (`WBP_MenuESC_Button_S`). CommonUI then moves focus with the D-pad and
  turns A into a click, and DarnMenu hooks the button's bound click event
  (`...CommonButtonBaseClicked__DelegateSignature`) with `RegisterHook`. Mouse,
  keyboard and controller arrive as the same click. It also offers an
  `actionpanel` section: clickable tiles in the ESC menu that write a request
  to a shared file which the owning mod acts on.
- **Perfect Placement** (3769122127) reads `PalUtility:GetCurrentInputType` to
  know whether the player is on a controller (the function is reflected in this
  build, Functions.txt).

## What our own widgets already receive

- The panel (WBP_WorkRules, a CommonUI activatable widget) has a generated
  `OnPreviewKeyDown` (unreal/PalWidgetGen/Private/WorkRulesInput.h). Preview
  key events tunnel from the root down to the focused widget, so the panel sees
  every key, controller buttons included, before CommonUI acts on them. Today
  it only handles Escape.
- The stand receivers (StandInput, BuildStandInputWidgetCommandlet.cpp) have an
  `OnKeyDown` that dispatches numbers to Lua through `PWP_KeyDispatch` and
  deliberately returns Unhandled for `Gamepad_*` keys (lines 264-268, test
  cases 469-474), because the Lua pad poll was meant to own them. That poll
  cannot see them in the stand, so nothing owns them.
- Both widgets are built by commandlets in the Palworld Modding Kit with UE 5.1,
  which are installed on this PC (`tools/build_*.py`, `pak_mod.py`).

## Plan as approved (user: "In 0.5.0, all parts")

1. **Open the panel with a controller.** Two ways, both kept: a DarnMenu
   `actionpanel` tile "Open Production Limits" on the mod's DarnMenu page
   (controller-friendly through the ESC menu, needs DarnMenu), and a new chord
   that the game does not use (to be measured; RB + View is the map).
2. **Panel.** Extend `OnPreviewKeyDown` to hand D-pad, A, X, Y, LB/RB and the
   triggers to Lua (a `PWP_PadKey` dispatch like `PWP_KeyDispatch`) and return
   Handled so CommonUI does not also navigate. Lua maps them onto the existing
   panel actions (`panel.nav` up/down/left/right, A = confirm/open, X = Remove,
   LB/RB = tabs, triggers = pages, B stays CommonUI Back). Rebuild WBP_WorkRules.
3. **Stand.** Let StandInput dispatch D-pad, A, LB/RB and X instead of passing
   them through: D-pad moves between our receivers with the keyboard-arrow code
   that already exists, LB/RB step toward 1 / toward X, A toward 1, X sets X.
   When the stand opens and `GetCurrentInputType` says controller, Lua focuses
   the first receiver so the presses reach it. Rebuild the StandInput widget.
4. Tests: commandlet self-tests (they already press keys into the widgets),
   Lua regression tests, and live runs with the virtual pad connected before
   game start (scratchpad `pad_server.py`), plus one run with a real pad
   through Steam if the user has time.

Risks: cooked widget changes have caused crashes before (LESSONS: engine
rules), the stand route depends on focus moving onto our receivers, and the
new chord has to avoid every game binding.

## What was built (same day)

Widgets, rebuilt with the new `tools/build_widgets.py` (compile, both
generators with their compiled self-tests, fresh-process `-VerifyInputOnly`,
cook, pak; receipts under `test-results/widgets-*`). Final pak sha256
`73a312d4…` (13,822 bytes), `docs/asset-contract.json` updated.

- **StandInput contract 3.** The receiver's OnKeyDown maps controller buttons
  to the existing key codes: D-pad 6-9 (navigation), A 10 (step toward 1),
  X 0 (set X), LB 11 (toward 1), RB 12 (toward X), View 13 (open the limits
  panel). Left-stick keys stay consumed without dispatch. An `OnFocusLost`
  event calls `PWP_FocusDispatch` so Lua knows when the game took the focus.
- **WorkRules contract 4.** `OnPreviewKeyDown` hands D-pad/left stick (1-4,
  repeats included), A 5, X 6, Y 7, LB/RB 8/9, LT/RT 10/11 to Lua through
  `PWP_PadKey` + `PWP_PadDispatch`, only while the panel is active; B is left
  to the existing Back route. A second `RadialMenuCancel` binding on
  `IE_Released` sets `PWP_CancelReleased`. A `Jump` binding (A) is registered
  too but never fires in game.
- **Lua.** `overlay.hook_pad` → `panel.native_pad` (the same verbs as the
  old polled pad driver; Y confirms as well as A). `ui.pad_tick` asks
  `PalUtility:GetCurrentInputType` four times a second (1 = controller), hands
  the stand focus to the current selection when needed and picks the legend.
  `stand_pointer` hooks `PWP_FocusDispatch`. Codes 11-13 in `ui.bind_mouse`.
  `finish_cancel` waits for the release on a controller (at most 1.5 s).
- **Texts.** Stand legend and panel foot hint switch to a controller version
  ("LB / A: toward 1  RB: toward X  X: off … View: Production Limits";
  "Controller: D-pad moves, Y opens or raises, X removes, LB/RB tabs, LT/RT
  pages, B closes.") while the game reports a controller.

## In-game acceptance (virtual pad connected before game start)

All on the dev install, singleplayer test world, 18:01-18:42; priorities rows
and both limits identical to the snapshots afterwards (only the save counter
in the header moved).

| Check | Result |
|---|---|
| Stand opened with the controller (hold Y), selection handed to our receiver | PASS (`controller: focus handover done` in the log) |
| D-pad moves the mod's selection; game cursor stays out | PASS |
| LB X -> 5, RB 5 -> X, X 1 -> X, RB X -> 1 (wrap), A 3 -> 2 | PASS |
| Y (game's view switch) twice, then D-pad: focus comes back to us | PASS after the OnFocusLost report |
| View on the stand opens the panel | PASS (Y was taken by the game's view switch first, hence View) |
| Panel: D-pad moves, RB/LB switch tabs, D-pad in the item grid | PASS |
| Panel: Y on a tile opens it (notice "Version 0.5.0 cannot create...") | PASS |
| Panel: A | FAIL as designed around: the game's UI confirm takes A before any binding; Y confirms instead |
| B closes only the panel, stand stays (tap 0.15 s and hold 0.8 s) | PASS after the release fix |
| Keyboard Alt+F1 + Escape still close only the panel; mouse/keyboard legend returns | PASS |

Found on the way (each fixed and rechecked):

1. Y on the stand never reached the receiver: it is the stand's own action
   (switch to the task view). View is free on the stand and opens the panel.
2. After the view switch the game kept the focus; the receiver now reports
   `OnFocusLost` and the mod hands the focus back.
3. B closed the panel on its press and its release then closed the stand
   underneath (short press kept the stand, 0.8 s closed both). A
   `UIINputGuardCancel` binding and a CommonUI back handler were tried and
   made no difference; waiting for the release fixed it.
4. In a fresh editor process a back-handler fixture hit CommonUI's
   `bInputDataLoaded` ensure; the generator now loads the CommonInput
   module's own settings instance first.

Open: a real controller through Steam Input (the user's DualSense) was not
run; the virtual pad is an XInput device like Steam Input's own output.

