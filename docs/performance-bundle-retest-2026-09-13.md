# Performance bundle native retest — September 13, 2026

## Outcome

The 13:29 bundle is running and reduces measured stand and combined-callback costs. It does **not** remove the recurring one-second frame-time bump. One unexplained 160 ms Present interval remains in the first clip and is retained in the evidence.

## Identity and scene

PID 9460 started at 13:31:28.4134585 after installation, with the 13:31:33 0.5.0-rc1 banner and world load at 13:31:48. All 39 installed Lua hashes match `test-results/perf-bundle-stage-result-20260913.json`. Runtime and pak identities are saved in `test-results/bundle-restart-identity-20260913.json`; hot reload remains disabled. Game Win S v1.0.4.102642, UE4SS 2281fa31, 1920×1080, existing other mods; MapCollectablesNative remains disabled.

Screenshots 00344 and 00345 show all nine stand rows with priorities. Bounded stand diagnostics retain 117 tree/global cells, 639/4000 roster visits, 77/512 owner visits, nine row scopes and zero fallbacks. This proves visible painting in these observations, not successful edits or rebinds.

## Timed idle windows

Profiling enabled at 13:36:46, reset at 13:38:10, and disabled at 13:39:33. Windows are 84 and 83 seconds. Each completed eight automatic passes. Baseline windows were 81/170 seconds in the preceding generation, documented in `deep-performance-retest-2026-09-13.md`.

| Region | Baseline mean ms | Bundle mean ms |
|---|---:|---:|
| Complete stand refresh | 24.00 / 24.04 | 20.77 / 20.87 |
| Fresh menu lookup | 10.17 / 10.26 | 9.91 / 10.08 |
| Roster lookup | 6.92 / 6.88 | 6.91 / 6.95 |
| Label lookup, aggregate per grid | 3.32 / 3.53 | 0.56 / 0.71 |
| Complete controller drive, per sample | 0.153 / 0.153 | 0.125 / 0.132 |
| Complete scheduler | 29.25 / 27.19 | 27.00 / 24.88 |
| Storage scan | 23.33 / 24.40 | 21.67 / 21.00 |
| Worst complete heartbeat batch | 70 / 74 | 42 / 45 |

Stand means improved approximately 13%; label discovery is approximately 80–84% cheaper per full grid. Roster discovery did not measurably improve. The remaining menu plus roster work is about 17 ms per refresh. All windows retain exactly 117 cell-refresh calls and 33 applicable-label calls per grid; the reduction is not caused by fewer cells. Refresh rate remains about 0.94/s, comparable to the baseline.

The new `clock: deferred: maintenance` row holds the moved stand/panel cost. The small `clock: ui` row is not itself a saving. Maintenance and complete-batch reports have one more call than finished timing because the reporting command runs inside an active maintenance/batch; means use timed samples. Nested inclusive durations must not be summed. Clock resolution remains unmeasured; zero durations and count-only route rows do not establish free work. No invalid-clock-sample warning was printed.

Storage ran five scans across sixteen timed passes, and three across eight off-window passes. Backoff state survives profiler resets. The native scan skipped 535 unnecessary class reads, retaining all 535 unknown-scope/zero-GUID failures. The prior session had 534: this is a changed live fixture, not proof of identical inventory. Actual counted-class reads changed with the live scene (264 then 259). Stock remains explicitly unverified.

## Independent frame captures

Three sequential PresentMon 2.5.1 recordings, five-second lead and sixty-second capture each, target only PID 9460. Each recorder exited before any diagnostic, profiling transition or next recorder. All have one swapchain, positive durations, monotonic timestamps and consistent timestamp/duration differences. A new helper refuses overlapping recorder processes. Its privilege warning concerns process-name discovery; explicit-PID recordings succeeded.

| Capture | Mean ms | p99 ms | >16.67 ms | >33.33 ms | >50 ms | Worst ms |
|---|---:|---:|---:|---:|---:|---:|
| Bundle On 1 | 6.908 | 10.692 | 65 | 4 | 2 | 160.004 |
| Bundle On 2 | 6.537 | 9.241 | 65 | 3 | 1 | 53.124 |
| Bundle Off 1 | 6.671 | 9.566 | 64 | 2 | 0 | 48.478 |
| Previous clean On 3 | 6.371 | 8.886 | 59 | 7 | 4 | 74.454 |
| Previous clean Off 1 | 7.043 | 10.319 | 60 | 8 | 4 | 76.944 |

The new captures have fewer >33 ms intervals but still about one >16.67 ms interval per second (median gaps 1.052–1.053 s). The first clip's 160 ms outlier exceeds every recorded mod callback in its window; available data cannot attribute it or exclude mod involvement. It was absent from the two later clips. The larger recurring combined-job peak is reduced, while regular stand work remains.

These are Present intervals, not physical display/input latency. Camera, foreground and live workload are not continuously controlled, there is no mod-absent baseline, and Lua events are not precisely aligned to QPC. Do not claim causal whole-game FPS gains, profiler overhead, all-stutter elimination, or exact per-frame attribution.

## Health and acceptance boundaries

The 13:40:54 snapshot contains 51 automatic ticks, no edit passes, no mod WARN/ERROR/FATAL messages and no logging-sink failures. All installed hashes remained unchanged. Authority is YES and its positive route counts match completed passes. This supports this singleplayer session only. Fourteen assignments remain unverified, zero permission requests were sent, and storage remains incomplete; cadence, fence lines and error absence do not accept scheduling or production limits.

After idle captures, profiling was re-enabled at 13:41:16 for a separate user-driven close/reopen and rapid alternating/direct-key input exercise. Input results, independent review and final profiler state are recorded below when complete. Cold/warm Production Limits pages, multiplayer transitions, mod-absent frame comparisons and broader release gates remain separate uncompleted tests.

Evidence prefix: `test-results/bundle-restart-`, including identity, source comparison, two timed reports, off report, raw and normalized frames, metadata/evidence, cadence, boot-session snapshot and preserved stand tree. No game files were changed, no hot reload occurred, and nothing was committed or published during this retest.


## User input and panel follow-up

The user confirmed the requested close/five-second wait/reopen, rapid alternating clicks and direct 1–5/X exercise: **“yes seems like it”** (numbers returned and edits stayed in order). Nine native row bindings were timed after reopening. The 91-second input window recorded 47 input-drain slices, mean **24.681 ms**, worst **38 ms**, and 18 deferred reconciliations plus eight periodic passes. Fifteen background-deferral events occurred; no starvation/error was observed, but aggregate data does not establish a hard queue-wait bound. These are drain-slice timings, not individual-click or physical input latency. The menu/roster lookups still dominate each accepted action. The complete heartbeat reached 49 ms during input. Priorities were saved afterward. No count of physical clicks exists to independently prove one-to-one acceptance; the user feedback is the behavioral evidence.

Production Limits was then opened through the existing remote UI action, followed by the item page, “show all craftable items,” page two and a return to page one. No rules were added/removed or amounts changed. ScreenShot00350 shows all 27 second-page tiles and icons, pagination above the list, and the underlying stand. A screenshot in the same command as a queued open/mode change can precede that action; delayed screenshots were used to establish the actual result. The remote “panel is now closed/open” message is likewise emitted before queued actions finish and is not reliable completion evidence.

The 101-second **mixed panel/stand** window is not an idle-panel-only benchmark. It recorded:

- Complete panel refresh: 439 samples, **18.446 ms mean / 101 ms worst**.
- Fresh overlay-host resolution: 480 samples, **12.419 ms mean / 23 ms worst**. This is nested in panel timing and remains a dominant recurring panel cost.
- Icon get: 195 samples, **7.405 ms mean / 49 ms worst**. Cold full-list draw logged **89 ms** (48 ms before search, 41 ms tiles); page changes produced several **38–45 ms** tile draws.
- Icon pump: 26 samples, **4.385 ms mean / 15 ms worst**. Its 4 ms soft budget does not bound a single load or final persistence.
- Complete heartbeat: **101 ms worst**. Separating periodic work does not prevent expensive individual panel refreshes or stand work inside maintenance.

The full-list UI completes, but **cold/steady panel performance is not accepted as fixed**. No independent frame capture accompanied this deliberately changing panel scene. The warmed return to page one was exercised, but no isolated warm distribution was collected. Eight-page coverage, close-during-fill, input-focus recovery, resolution/layout matrix and item/output correctness remain open.

The initially empty inventory list says “0 items” while stock is unavailable. That wording should express unavailable data rather than a verified empty inventory; the rules themselves correctly show `?` / Unavailable. This is a separate UI reliability finding, not a performance saving.

Profiling was turned **off at 13:44:48**, and the panel was closed via the queued action. The delayed final screenshot (00351) verifies closure. Final health snapshot at 13:45:20: **75 automatic ticks, 18 edit passes, no mod WARN/ERROR/FATAL lines, all 39 installed modules unchanged**. No task recorder remains active. The earlier idle health snapshot is preserved separately so post-capture edits do not contaminate its scope.

Remaining measured performance work, ranked by trigger:

1. Panel host discovery (~12.4 ms each) and synchronous cold icon discovery (~49 ms single get); fresh current-tree safety remains mandatory.
2. Open-stand menu (~10 ms) plus roster (~7 ms) discovery on its one-second refresh.
3. Stand edit resolution (~25 ms per drain slice); preserve FIFO and current-row ownership while reducing the work per action.
4. Single scheduler/storage passes still reaching 41–45 ms; whole-game capture still includes an unexplained 160 ms outlier.

This is a verified partial performance improvement with concrete remaining costs, not completion of the full reliability/release plan.

## Independent review

Kierkegaard independently checked the completed idle, frame, input and panel artifacts. It agrees on approximately 13.3% lower weighted stand cost and 82% lower label cost, while retaining the one-second cadence, 160 ms outlier, input costs and 101 ms panel maximum. It explicitly rejects adding nested rows, interpreting the many inactive fill calls as active-fill speed, or treating observed cadence/error absence as scheduling correctness. The final remote close message was flagged as insufficient proof; the parent separately resolved closure with delayed screenshot 00351, which shows only the stand. The 1 ms clock step first observed in the panel window is not retroactively assigned to the earlier idle windows.
