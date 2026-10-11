# Stand input correction — September 12, 2026

Status: the 20:21 input correction was restarted and tested. A later rapid-click sample exposed saved-priority overwrites and substantial per-action/refresh cost. The 22:29 correction was restarted at 22:31 and its [native retest](jump-restart-2026-09-12.md) confirms improved controller cost but persistent stand/frame spikes. Rapid clicks were not recorded in that session. A further checked two-module correction was installed at 22:51 and awaits restart. This is not a release or a stutter-free verdict.

## Reproduction and cause

The user reported that hovering a priority and pressing `1` produced `[1]`, while mouse cycling used plain numbers. `ScreenShot00335.png` from the existing game session confirms `[1]` on Verdash's Planting cell. Brackets represented keyboard/controller selection, not an unconfirmed save. The direct-key path established that selection even when its target came from pointer hover.

Both mouse clicks and number keys were queued for the game thread. The queue drained only inside `ui_body`, which ran once per second while the Production Limits panel was closed. Opening the Monitoring Stand did not change that panel flag. Input could therefore wait almost a second before execution, independently of the cost of the action itself. The independent review confirmed this path.

Number/navigation actions also enumerated the complete roster again to repaint it after selecting their target. Full maintenance could then repaint once more. Immediate authority saves remain deliberate: delaying them would weaken immediate-quit durability.

## Correction

- Drain pending FIFO actions on the existing 100 ms game-thread beat, separately from complete refresh/maintenance. A beat is a scheduling interval, not a guaranteed native response-time ceiling.
- Poll client edit coalescing on that beat so a queued outgoing change does not wait an additional maintenance second. Headless/authority idle beats perform no new client polling or viewport lookup.
- Consume panel/stand reconciliation flags together, once per batch. Keep requests raised during a pass for the next beat. The independent periodic scheduler remains separate; coincident periodic/edit passes are not deduplicated without evidence that one covered the other's edits.
- Hovered number keys and mouse clicks use the same unbracketed presentation. Navigation retains brackets; number keys without hover still edit the selected cell and retain its marker. Pending `*`, unsaved/rejected `!` and unavailable `?` remain distinct.
- Resolve the complete owned roster once per action, using callback-local wrappers only. Immediately repaint the edited cell and any previous focus cell. Complete snapshot refresh and failed-paint recovery remain pending at the normal cadence.
- Preserve every queued direction in order against the latest local/pending priority. Production cycling saturates: left then right at `1` yields `2`; opposing clicks must not be collapsed to zero.

## Evidence and limits

Three UI regressions fail before the correction: hovered keys introduce brackets, pointer input retains old navigation focus, and an action repeats the roster walk. The focused UI suite also covers clearing the old cell, selected-key fallback, queued rapid edits, no-op boundary clicks, partial drawing failures, session changes and row recycling. See `test-results/click-ui-before-20260912.txt` and `test-results/click-ui-after-20260912.txt`.

The before-change background profiling window ran from 20:09:40 to 20:13:52 in PID 32480 (started 19:16:13). There were 236 stand refreshes, mean 28.818 ms, worst 31 ms; 24 complete scheduler passes, mean 42.708 ms, worst 49 ms; worst complete clock batch 79 ms. Nested rows are inclusive and cannot be summed. No edit pass was recorded during this window, so it does not measure per-click native latency. Profiling was disabled afterward. Source: `test-results/click-baseline-end-20260912.txt`.

The core assignment/storage limitations from the reliability ledger remain open. This input correction does not supply missing producer or assignment adapters, prove multiplayer delivery, or eliminate the separately measured recurring frame spikes. Fresh-install checked work remains priority 1 and unchecked work X, as accepted by the user.

## Next native acceptance

After staging, restart completely and verify installed hashes against the new process identity before measuring. On the stand, compare a hovered `1`/`X` with mouse cycling, switch from controller navigation to pointer input, try several rapid directions on one cell, and close/reopen. Confirm saved values and markers as well as visible responsiveness. Use the new `input: queued actions` inclusive profiling row alongside complete scheduler/refresh rows; independent frame captures are still required to assess remaining stutter.

## Checked installation

The complete gate passed: 39 modules compiled with Lua 5.4, all 32 regression scripts passed (including 39 stand integration cases), and structural checks passed. The existing panel-local warning remains 194/200. The independent reviewer implemented the queue correction, reported five scheduling regressions failing before it, and completed a read-only review of the UI changes without an actionable finding. Consolidated output: `test-results/click-full-lua-20260912.txt` and `test-results/click-structural-20260912.txt`.

Installed at 20:21:20, following the user's approved checked-Lua staging workflow. Changed modules relative to the preceding installation: `main.lua`, `session.lua`, `ui.lua`. All 39 installed/source module hashes and Info.json match the tested generation. The previous 39-module generation was verified in `backups/deploy-20260912-202120-df588b5704c44761bcb09d9e144d7503`; root configuration and pak are unchanged. Automatic/hot reload were both disabled before the current process started; profiling and our frame captures had finished. No reload was invoked.

PID 32480 remained the same process started at 19:16:13 after staging, so its input behavior is still the old generation. Installed hashes are not evidence of the code loaded into that process. Full receipt: `test-results/click-stage-result-20260912.json`; preflight and previous hashes: `click-stage-preflight-20260912.json`, `click-stage-before-20260912.json` in the same directory. The preflight's PresentMonService entry is an existing service, not an active task recording; the separate `active_task_captures` list is empty.

## Restart and native observation, 22:00–22:05

The new process is PID 12896, started 22:00:27, with the 0.5.0-rc1 banner at 22:00:33 and world/session 1 ready at 22:01:17. All 39 installed hashes match the checked generation; runtime and pak retain their previous hashes. The new `input: queued actions` counter records 12 nonempty drains since boot, corroborating the new path, but these are not 12 proven successful clicks. Identity and start/status data are in `test-results/click-restart-identity-20260912.json` and `click-restart-start-20260912.txt`.

The owned roster is complete: 117 scoped cells, 77/512 owner visits and 909/4000 roster visits. Screenshots `ScreenShot00336.png` and `ScreenShot00337.png` in the game's local screenshot directory show all nine rows, ordinary numeric glyphs including Verdash's plain Planting `1`, and the footer legend. This verifies appearance at those instants, not a timed recording of the user's key/click sequence.

Six edit-triggered passes occurred at 22:01:27–22:01:34, before profiling began. They include one permission request; a sent request is not readback evidence. There are no WARN/ERROR lines in the copied session log. Status reports local authority and saved priority/limit files. Assignment and storage remain unverified on every pass; none of these observations completes the gameplay acceptance gates.

Profiling ran 22:02:36–22:04:44 (128 seconds), then was disabled. **No queued-input timer or edit pass appeared in this measurement window.** The user's interaction prompt had no response at the time the data were finalized. Thus this is an open-stand observation, not click-latency acceptance.

| Inclusive region | Timed samples | Mean | Worst |
|---|---:|---:|---:|
| Stand complete refresh | 120 | 28.858 ms | 31 ms |
| Scheduler complete | 12 | 44.333 ms | 52 ms |
| Storage bucketed totals | 12 | 23.000 ms | 25 ms |
| Camp enumeration | 12 | 10.750 ms | 19 ms |
| Complete clock batch | 1199 | 3.299 ms | 79 ms |

The profiler labels clock resolution unmeasured in this window. Nested totals overlap. There are 120 complete stand refreshes against 1200 UI clock calls: the faster input beat did not turn idle stand drawing into ten complete refreshes per second. The before-change stand mean was 28.818 ms, so these observations show no material reduction in recurring complete-refresh cost from the input correction.

A separate 60-second PresentMon recording targeted PID 12896 after a 5-second delay, 22:03:22 launch to approximately 22:04:27 completion. All 8,986 rows belong to one swapchain; timestamp/duration consistency checks pass. Mean Present interval is 6.675 ms, p99 9.273 ms, but **53 intervals exceed 33.333 ms**, six exceed 50 ms, and the maximum is 86.324 ms. Recurring stutter remains visible in independent capture data. This is not a mod-absent or matched scene comparison; exact input timestamps, physical display latency, and Lua/QPC alignment were not recorded. Specific slow frames cannot be assigned to a callback from these data.

Raw and analyzed evidence: `test-results/click-live-on-presentmon-20260912.csv`, `click-live-frame-evidence-20260912.json`, `click-restart-end-20260912.txt`, `click-restart-session-20260912.txt`. The task's recorder exited normally and no new code was installed during the test. The pending native checks remain the user's click/number-key sequence, immediate old-focus clearing, responsive editing, and close/reopen after editing.

## Rapid-click reproduction, 22:12–22:14

The user clarified that jumps occur when clicking faster. Profiling ran from 22:12:11 through 22:14:39 in the same PID 12896, then was explicitly disabled. No frame recording or deployment ran in this window. Source: `test-results/jump-baseline-start-20260912.txt` and `jump-baseline-end-20260912.txt`.

| Inclusive region | Timed samples | Mean | Worst |
|---|---:|---:|---:|
| Queued input drain | 27 | 29.185 ms | 34 ms |
| Complete stand refresh | 137 | 28.912 ms | 32 ms |
| Complete scheduler pass | 33 | 33.424 ms | 53 ms |
| Camp enumeration | 33 | 11.030 ms | 19 ms |
| Bucketed storage totals | 16 | 23.187 ms | 28 ms |
| Complete clock batch | 1369 | 4.299 ms | 85 ms |

Fourteen periodic scheduler callbacks and nineteen additional edit passes occurred. The 164 scoped tree calls minus 137 complete refreshes leave 27 extra lookups, consistent with one action per input drain in this sample. This does not establish that batched or held-button repetition caused the visible jumps. The actual runtime's Win32Async input source emits down edges; one mod loader instance is recorded. Do not add a mouse debounce that discards legitimate rapid clicks on the assumption of held repeats.

The native log reports `1 external permission edit(s) adopted` at both 22:13:11 and 22:13:18. The scheduler interpreted an observed native bit change as a deliberate priority edit, saving a disabled bit as X and an enabled bit as 1. A bit change alone cannot establish that intent. This is a demonstrated route by which a numeric choice can change between clicks; the capture does not identify the exact clicked cells or prove it explains every jump.

### Second correction and isolated evidence

- Native permission observations now update readback history without overwriting saved priorities. Only explicit priority edits or a future verified native input/sender adapter may change that policy. A new regression failed with `native checkbox disable overwrote numeric priority with X` before the change (`test-results/jump-adoption-before-20260912.txt`). Numeric choices and explicit X survive interleaved native bits afterward; failed explicit saves still block scheduling. Already-overwritten choices cannot be reconstructed from these bits.
- The current tree walk reuses its already-read full-name class token. The synthetic 77-owner/909-roster-visit fixture removes 2,604 class-reflection calls while preserving all 986 name reads, owner/completeness checks and conservative fallback. It does not cache collectable wrappers or assume matching names prove lifetime.
- Pad polling reads the local viewport/controller once for all eleven buttons, then dispatches actions using plain states. It re-resolves on the next call and never falls back to a remote player's controller. The independent review caught stale sampled taps after a callback called `forget()`; that case fails before and passes after invalidating the remainder of the sample (`test-results/pad-cancel-before-20260912.txt`, `pad-cancel-after-20260912.txt`). Isolated edge, release/repress, unknown input, viewport loss, controller replacement and opening-chord checks also pass. The `pad: down` timer now covers only button reads; use complete-drive timings for before/after comparison.
- Storage preparation waits until a readable, nonempty roster has prepared settings. Empty, unreadable and unprepared rosters perform no unused storage sweep. This does **not** remove the current fourteen-Pal session's storage sweep: incomplete storage evidence reduces the retry interval to five seconds, explaining the repeated scan. Unknown counts remain unknown.
- Separate inclusive menu, roster and grid-refresh rows identify the remaining stand costs on the next restart. Grid refresh includes roster lookup; nested durations must not be summed. The storage diagnostic reports evidence from an existing scan rather than triggering an extra one.

Automatic adoption of deliberate unmodded-client vanilla edits is now explicitly **unavailable** until there is a verified input/sender adapter. It must not be inferred from a checkbox difference or advertised as completed multiplayer behavior. This tradeoff protects saved choices; direct mod UI/protocol edits remain supported.

Native speedup and disappearance of the user's rapid-click symptom remain restart-test gates. Retest rapid left/right and number-key sequences, boundaries at 1/X, close/reopen, complete-pass/stand subregions and a matched frame capture. Camp enumeration and incomplete storage remain measured sources of recurring spikes; no stutter-free claim follows from reduced mocked call counts.

### Second checked installation, 22:29

The final integrated gate compiles all 39 Lua 5.4 modules and passes all 33 regression scripts, including 39 actual-UI integration cases. Structural checks pass with the existing panel warning at 194 top-level locals. The independent reviewer confirmed the cancellation correction and found no remaining issue in the focused pad/settings review. Results: `test-results/jump-full-lua-20260912.txt`, `jump-structural-20260912.txt`.

The checked Lua was installed at 22:29:46. Changed modules: `main.lua`, `pad.lua`, `palapi.lua`, `scheduler.lua`, `ui.lua`, `ui_tree.lua`. All 39 installed hashes match the tested source; all 39 previous module hashes match the backup at `backups/deploy-20260912-222946-9dde5c298e9840c2bfd4665921bc288d`. Root user configuration, pak and runtime hashes are unchanged. No settings file was overwritten. Profiling and task frame recording were off; automatic/hot reload were disabled before process startup, and no reload command was invoked.

The game remained PID 12896, started 22:00:27, so this running process still uses the previous generation. A full restart is necessary. Preflight/tested and previous hashes: `test-results/jump-stage-before-20260912.json`; verified installation/backup receipt: `jump-stage-result-20260912.json`; deployment output: `jump-deploy-20260912.txt`. No commit, release archive or publication was made.
