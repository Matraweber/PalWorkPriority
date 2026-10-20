---
date: 2026-09-24
tags: [input, stand-ui]
status: evidence
---
# Event-targeted stand mouse input — September 24, 2026

Related: [stand-keyboard-2026-09-24](stand-keyboard-2026-09-24.md) · [stand-lifecycle-2026-09-24](stand-lifecycle-2026-09-24.md) · [stand-close-events-2026-09-24](stand-close-events-2026-09-24.md)

## Scope and implementation

This candidate replaces the raw-keybind stand-edit path documented in
[the September 23 reproduction](DECISIONS.md).
Raw mouse callbacks no longer choose a stand target at queue-drain time.

Each eligible cell receives a transparent UMG UserWidget at its checkbox's
geometry. Its compiled mouse-down and double-click handlers distinguish left
and right presses and call its own `PWP_Dispatch` function. The Lua hook copies
only an opaque binding token, cell/Pal/work identity and session/UI generations
from the current native event context. The queue never retains that wrapper.
At execution, the current owned roster, binding token and Pal/work association
must still match. Moving the pointer does not change the accepted target.

Empty targets do not dispatch. Unknown data, stale/rebound/replaced widgets,
session changes and a blocking Production Limits panel reject edits. The raw
panel handler remains separate; there is no duplicate raw stand fallback.
A missing/mismatched input asset leaves mouse editing unavailable instead of
restoring the known wrong-target behavior. Existing numbers/navigation remain.

This was the mouse-path repair. The subsequent [keyboard follow-up](stand-keyboard-2026-09-24.md)
replaces raw queued direct-number targeting and upgrades StandInput to contract 2. Physical focus-transition,
controller, multiplayer and complete frontend acceptance are not implied.

## Automated checks and independent review

47 Lua modules compile; all 66 regression scripts pass, including 47 stand
integration checks. New cases cover A-click then hover-B, a raw callback with
no native target, duplicate raw/native delivery, blocking panels, stale surface
tokens, failed arming reuse, and missing assets. Existing rapid ordered edits,
row/session cancellation and current-tree replacement tests still pass.

Independent review caught an attachment/name-read failure that could leave an
untracked surface. The name is now validated before attachment; a regression
proves repeated failures leave no attached orphan and successful retry creates
one receiver. All retained ownership data is scalar.

The new editor-only generator builds `WBP_StandInput`, with no runtime C++
dependency. Blueprint compilation reports zero errors/warnings. Generated
handler fixtures, idempotent regeneration, fresh-process readback and Windows
cooking pass. Down followed by DoubleClick dispatches twice in total, for both
buttons; middle-button and empty-target events do not dispatch. These fixtures
do not establish real Palworld hit testing or UE4SS hook timing.

Evidence: `test-results/stand-pointer-{build,generate,idempotent,readback,cook}-20260924.log`,
`stand-pointer-lua-20260924.txt`, `stand-pointer-checker-20260924.txt`.

## Checked installation

Normal Return to Title / Quit exited PID33244. Checked Lua deployed with backup
`deploy-20260924-022654-e981831934964ebdb5cc6fe411ab3865`.
All 47 installed Lua hashes match source. Priorities, caps and configuration
matched the pre-test hashes before relaunch.

The six-file test package preserves the existing ModActor and contract3
WorkRules assets, adding only the StandInput pair. SHA256:
`bd21c216005d6a60fa6abbe6d60f146794a73334f7606fc781f52f682e0628d0`.
The previous installed pak/settings are backed up under
`test-results/stand-pointer-backup-20260924`.
Baseline release assets are not promoted; nothing is published.

The user's AHK helper started in `--launch` mode at 02:27:08 after checked
installation. First native run PID28588 correctly refused mouse editing because
`LoadAsset` could not find the mounted mod class. This is the same limitation
already documented by `overlay.mod_class`; the new receiver now uses that proven
asset-registry lookup on the game thread. A regression covers that exact fallback.
No priorities changed in the failed-loading run.

The corrected Lua passed all tests and checked deployment again (backup
`deploy-20260924-022923-dce2347df03b4e53b7fdd0c4174e1a59`). The helper started a
full `--world` restart at 02:30:01 and exited PID28588 normally at 02:30:24.
Second native run registered the script hook and created 33 receivers, but the
binding readback refused the FString target field. The receiver now converts
Unreal string wrappers to plain strings inside each callback; a wrapper fixture
covers binding, capture and execution. It does not retain the wrapper. The hook
does not require pre-versus-post ordering: direction is assigned before dispatch
and dispatch changes only its sequence counter.

Third checked deployment backup:
`deploy-20260924-023229-62fb72ba862044eb8ee552b652caeb26`.
The helper began the next full restart at 02:32:54 and exited PID10872 normally
at 02:33:17.

## Native result: mouse route verified, wider input acceptance remains open

PID35464 loaded the corrected build and the AHK helper reopened the stand at
02:34:21. Game 1.0.5.102999 / UE4SS 2281fa31, 1280x720. Readback showed the
hook installed, 33 receivers created, no binding error. Real UI input established:

- Left on Grizzbolt Generating Electricity 1 stayed at 1 (clamped).
- One right press changed 1 to 2; one left restored 1.
- A left double-click changed Grizzbolt Handiwork 3 to 1, with exactly two new
  native dispatches. Two separate right presses restored 3.
- A drag beginning on Generating Electricity 1 and ending on adjacent Handiwork
  3 left both unchanged. The offline test explicitly places the hover change
  between enqueue and drain; this live gesture does not prove that exact timing.
- Final counters: **8 native events, 8 queued, 0 rejected**, still 33 receivers.
  Raw callbacks did not double-apply edits. No WARN/ERROR in the final session.

One restoration attempt did not reach the receiver while another window took
foreground focus. Readback showed no additional event and no unrelated edits;
after fresh focus/observation the restoration succeeded. This is not complete
physical focus-transition acceptance. The automation tool does not support right
double-click; that variant remains compiled-handler tested only.

Priority payload is identical to the pre-test copy. Its save generation advanced
171 to 177 due to the six deliberate changes/restorations; payload size/checksum
remain 2918/737a8e16. Caps and configuration are byte-identical. All 47 installed
Lua files match source. Profiling is off; game and stand remain open.

The 156-second instrumented window has stand refresh mean12.338/worst19ms and
scheduler mean21/worst23ms, inclusive runtime-clock measurements. Three large
maintenance peaks (258/248/239ms) coincide with the explicit full `pwp stand`
dumps at 02:35:00, 02:35:51 and 02:36:35. They contaminate this diagnostic
window; it is not a clean performance comparison or frame-time acceptance.
No stutter-free claim is supported.

Final evidence: `test-results/stand-pointer-native-receipt-20260924.json`,
`stand-pointer-final-tree-20260924.txt`, `stand-pointer-final-native-20260924.txt`,
`stand-pointer-native-log-20260924.txt`. Independent review also reran the final
47 stand checks successfully. No commit or release was performed.
