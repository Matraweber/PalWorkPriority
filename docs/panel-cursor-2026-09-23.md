# Native panel cursor correction — September 23

Unpublished candidate, following the [monitor retest](monitor-retest-2026-09-23.md) and [six new Steam reports](comment-update-2026-09-23.md). This does not establish the root cause of every stuck-panel report.

## Source evidence and narrow change

The local Palworld kit's `PalActivatableWidget.cpp` defaults `GameMouseCaptureMode` to `CapturePermanently`; `PalUserWidget.cpp` selects `GameAndMenu`. The candidate inherits both defaults. UE 5.1 `CommonUIActionRouterBase.cpp:1317` applies the native configuration: permanent capture takes viewport focus/capture and sets mouse visibility from `ShouldAlwaysShowCursor()`, while `NoCapture` releases capture and shows the cursor. This explains a credible conflict with our separate Lua GameAndUIEx setup; native testing must still establish its effect here.

`overlay.native_active` now sets the current owned contract2 widget's capture mode to `NoCapture` before activation and requires successful readback. Unknown/refused configuration aborts opening and follows existing cleanup. Legacy shells are unaffected. No recurring focus reset, vanilla-menu guard removal, stored widget wrapper, asset replacement or guessed new engine function was introduced.

Regression: contract2 activation must observe NoCapture. It failed before the edit and passed afterward. A refused property write must not activate or attach an unusable panel. All 44 Lua modules compiled, all 59 regression scripts passed, and the structural checker passed before deployment; the added refusal case also passes.

Installed Lua matches source (overlay SHA256 `1b7e9f92b30f72c8c484c0125ec82c4bc6fb453ddc526933ff8011d6648dda85`). Backup: `backups/deploy-20260923-214110-80ffb7ec99ec49d4a1e6ee9a0b57746c`. Existing contract2 test pak unchanged. Native results follow below.

## Separate focused-field Escape defect

UE 5.1 `SEditableTextBox.cpp:303` handles Escape while its editable child has focus by moving focus to the outer text box and returning Handled. `SlateEditableTextLayout.cpp:1427` can also consume Escape to clear selection/search or revert edited text. Thus changing text-revert settings alone cannot guarantee one-Escape cancellation. The pending native preview design must coexist with the consuming CommonUI binding; restoring a raw Lua key handler could reintroduce the stand/vanilla menu leak. This defect is not claimed fixed by the cursor change.

## Native result, 21:41–21:46 CEST

The default restart helper completed 21:41:22–21:42:51: PID27960 exited normally, PID34312 loaded session1, visible stand priorities returned. Game/runtime/pak unchanged from the earlier September 23 test.

- Opened panel through the explicit developer open request. One injected Alt+F1 attempt did not open it; no hotkey acceptance inferred.
- At 21:44:01, the panel is active with `native_escape=true`, `bShowMouseCursor=true`, and GameAndUIEx routing. Earlier contract2 without this change reported cursor=false under the same route.
- A normal injected left click on the visible Wood amount opened the editor (`editing=Wood` at 21:44:13), without a diagnostic `click rule` action. The same click failed in the earlier test.
- Clicking Cancel discarded the edit, retained Wood30000 and left the panel open. Clicking Close detached it and left the stand open.
- Reopened, clicked Add, and visibly entered the populated item picker. Escape closed only the panel; the stand stayed open. Final state reports no live panel, native escape=false, route=nil, cursor=true.
- No physical mouse/controller test or frame-time capture was performed. This is a before/after automated native hit-testing result, not proof that all reported stuck menus are solved.

**Restart-side finding:** an edit occurred at 21:41:22, coincident with helper startup and before the new code loaded: Verdash's work3 (Gathering) changed 4→3. The screenshot and prior saved generation establish the prior value; exact triggering input is not identified. Restored only that value via the stand to4 at 21:45:16. Full priority payload now matches the original backup; the generation header advanced normally to170. Caps remain byte-identical to the earlier baseline. See `test-results/panel-cursor-settings-20260923.json`. Do not call the helper data-preserving until this transition is reproduced and understood; future restarts must compare settings before/after.

Independent review found no fresh-activation correctness defect in the NoCapture guard, including in-memory write/read failure and deactivation cases. The persisted refusal regression now also covers a silently refused write. Already-active roots are not reconfigured by this guard. Focused-editor Escape remains the next native input change: an owned amount-editor-only preview handler, repeat protection, and the existing CommonUI binding must be tested together before asset promotion.

Game left running at the stand, panel closed, profiling off, no restart helper or recording active. Nothing published or committed.
