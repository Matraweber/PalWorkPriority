# Restart-associated priority edit investigation — September 23, 2026

## Finding and confidence

**Confirmed offline defect:** a queued stand mouse edit selects its target from hover when the queue drains, not when the input callback arrives. A callback received with no hovered cell can later edit a newly hovered cell. A callback over cell A can instead edit cell B. Existing world, menu and row generation checks do not reject either case when the generation stays unchanged.

This is a concrete possible path to the reported Verdash Gathering **4 → 3** change around helper startup. **It does not establish the historical triggering input.** Neither the saved log nor this synthetic reproduction proves a launcher click leaked into the game, a native hover remained stale, or a physical mouse malfunctioned.

Scope: offline source and saved-log inspection plus in-memory Lua fixtures. No game input, capture, process launch, restart, deployment, remote-channel use or settings changes. This investigation changes only this document; production code and existing dirty work are preserved.

## Saved timeline

Times are September 23, CEST. Sources: [cursor incident report](panel-cursor-2026-09-23.md), [saved native log](../test-results/panel-cursor-native-20260923.txt), and `C:/Users/matra/Desktop/restart-stand-last-run.log`.

| Time | Recorded evidence |
| --- | --- |
| 21:41:22 | Helper logs `Starting --stand`; old game logs `INFO edit` in the same second. |
| 21:41:47 | Helper records old PID 27960 exited. |
| 21:41:55 | Native log records new Lua startup, after the incident. |
| 21:42:20 | Helper records discovery of new PID 34312. This is its observation time, not necessarily process creation time. |
| 21:42:51 | Helper records world ready and stand-open key sent. |
| 21:45:16 | Cursor incident report records restoring Verdash Gathering to 4. |

The incident report identifies Gathering/work3 as the sole priority payload change. The [settings receipt](../test-results/panel-cursor-settings-20260923.json) records `priority_payload_restored=true` and generation 170. That receipt does not identify an input event; this investigation did not independently reconstruct the original screenshot/save comparison.

`Scripts/main.lua:624–627` runs an `edit` reconciliation pass when `ui.wants_pass` is set. Thus **21:41:22 is a pass timestamp, not a logged mouse-down or exact mutation timestamp**. Same-second timestamps cannot establish which startup/input event came first. The change precedes the new NoCapture code loading and cannot be attributed to that new activation guard.

## Helper and input-path evidence

The repository [restart helper](../tools/restart-stand.ahk) and desktop `Restart and open monitoring stand.ahk` have the same SHA256:

`A304DACCB415511603A5ABB497739B1C4228F7CAC948CF4C7666CAE5EE386F27`

In `--stand`, lines 32–37 send Escape, wait 1200 ms, send Escape again, wait 1500 ms, then call the first `Point`. Each Escape has a 120 ms hold. The first programmed mouse click therefore occurs at least approximately **2.94 seconds after startup**, excluding focus overhead: too late to produce the 21:41:22 pass. `Focus` calls `WinActivate` and waits for activation; it does not explicitly click. `Point` performs the actual move/down/up at lines 119–124. A launcher/activation click remains a hypothesis, not an operation demonstrated by this helper's startup code.

The relevant stand path is:

1. `Scripts/ui.lua:1603–1627`: `RegisterKeyBind` queues a closure carrying mouse direction. Left is −1; right is +1. It carries no event target, coordinates, input-owner state or focus generation.
2. `Scripts/session.lua:17–39`: enqueue/drain validate world and UI generations. Neither records a foreground transition. The bounded queue preserves accepted action order.
3. `Scripts/main.lua:597`: the game-thread UI tick drains that queue with an 8 ms budget. Its normal interval is 100 ms; budget deferral can extend the gap.
4. `Scripts/ui.lua:1450–1468`: `bump` freshly resolves the menu and cells, then chooses `hovered_cell`. `store.cycle` and `store.set` apply the edit to that later target. Successful edits request the reconciliation pass.

Fresh UObject discovery protects against stale wrappers, but it does not establish event-time intent. Local UE 5.1 `Runtime/UMG/Private/Components/Widget.cpp:518` implements `UWidget::IsHovered` through the cached Slate widget; `Runtime/SlateCore/Public/Widgets/SWidget.h:997` returns its hover attribute. These sources do **not** prove how long hover persisted during this incident or whether UE4SS delivered a background callback.

The main Escape binding (`Scripts/main.lua:2763`) routes panel cancellation; it does not decrement stand priority. Return/stand enter, direct numeric input and controller actions provide other ways to reach 3. `Scripts/pad.lua` polls gamepad actions, not a second copy of the raw mouse binding. Its viewport guard ultimately checks for a local player controller (`Scripts/palapi.lua:380`), which is not OS foreground proof. No saved event receipt selects among these possibilities.

## Offline reproduction and controls

Executed with Lua 5.4 from `.test-deps/lupa`, loading the fixture prefix of `tests/test_ui_integration.lua` before its first `check`. This runs real `ui.lua`, `session.lua` and `store.cycle`, with synthetic widget hover and an in-memory `store.set`. The synthetic cells use work1; the name Verdash is a fixture label, not a native Gathering/work3 reproduction.

For each case, create `fixture(keys)`, set all `f.net.pals[*].prios[1]=4`, call `f.ui.refresh(f.cfg)`, and bind with `f.ui.bind_mouse(function() return f.cfg end)`.

| Input sequence before `f.session.drain(error)` | Observed result |
| --- | --- |
| Hover A; call `f.bindings.leftmouse()`; unhover A and hover B | One write to B, value 3. **Wrong-target path reproduced.** |
| No hovered cell; call leftmouse; then hover B | One write to B, value 3. **Late-target path reproduced.** |
| Hover B; call leftmouse twice | Two writes, 3 then 2. Repeated callbacks are not silently merged into one decrement. |
| Hover B; call leftmouse; call `f.session.invalidate_ui()` | No write. Existing generation rejection works. |

The first reproduction's essential assertions are:

```lua
local f = fixture({'first', 'Verdash'})
for _, pal in pairs(f.net.pals) do pal.prios[1] = 4 end
assert(f.ui.refresh(f.cfg))
f.ui.bind_mouse(function() return f.cfg end)
f.cells[1].hovered = true
f.bindings.leftmouse()
f.cells[1].hovered = false
f.cells[2].hovered = true
f.session.drain(error)
assert(#f.writes == 1)
assert(f.writes[1].key == 'Verdash' and f.writes[1].value == 3)
```

All four probes passed their assertions, confirming the current defect and controls. They are diagnostic reproductions, **not passing assertions of corrected behavior**. No production fix or before/after fix claim is made.

Existing regression command, also run offline:

```text
python -B tools/test_lua.py tests/test_ui_integration.lua tests/test_session.lua tests/test_pad.lua
```

Result: **44 modules compiled, 39 stand integration checks passed, all 3 regression scripts passed.** Their current coverage does not reject the two newly demonstrated hover transitions.

## Smallest justified repair and tests

For the confirmed targeting defect, bind a mouse edit to an **event-time scalar target identity and menu/row generation** from a supported game-thread/native input path, then validate that identity against the fresh tree at execution. An input with no eligible target must stay a no-op; it must never acquire a target later. Do not query UObjects from a potentially off-thread raw key callback or retain widget wrappers to achieve this.

For the specific activation hypothesis, the narrow candidate is an input-owner/focus generation barrier: reject raw edits outside a proven foreground owner, invalidate pre-transition actions before draining, and require release followed by a fresh press after reacquisition. Check that generation at acceptance and execution. A foreground check only at drain would still accept an older background event. This requires a verified focus signal; `has_viewport` and `IsHovered` are insufficient. It is a candidate until that signal and native event ordering are established, not a demonstrated cure for this incident.

Required regression expectations: A→B never edits B; absent initial target stays absent; background-to-foreground and focus-loss-between-enqueue/drain drop old actions; a button held through activation stays disarmed until release/new press; intentional rapid clicks retain their order; existing row/world cancellation still works. Avoid arbitrary debounce, netting opposite directions or delay-only helper changes: these either lose legitimate input or leave the queue defect intact.

Attribution needs event source/sequence, enqueue/drain times, focus generation, scalar target and before/after value alongside a settings comparison. None was collected live for this incident. **The helper remains unproven data-preserving in its stand-start mode; physical mouse acceptance and the historical trigger remain unresolved.**

## Follow-up review: cached-hover proposal rejected as a complete fix

A game-thread sample could publish scalar identity and generations, with the raw key callback copying them and drain refusing a different fresh target. That would reject sampled A-to-B and absent-to-B transitions. It cannot establish event-time intent for an unsampled A-to-B-click-to-A excursion, or prove foreground ownership; a short expiry does not solve either limitation. No production targeting patch was made from that proposal.

The next step is verifying a native stand-cell pointer event in the shipped class and this UE4SS build, capturing scalar identity during its actual hit-test/input route, and disabling duplicate raw stand edits once that path is verified. Failed native evidence must remain a release gap, rather than being replaced with a stored UObject wrapper or arbitrary debounce.
