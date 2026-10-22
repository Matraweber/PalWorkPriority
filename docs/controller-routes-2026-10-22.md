---
date: 2026-10-22
tags: [input, panel, stand-ui, research]
status: current
---
# Controller support: routes that can work, 2026-10-22

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

## Plan (not started; needs the user's go-ahead)

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
