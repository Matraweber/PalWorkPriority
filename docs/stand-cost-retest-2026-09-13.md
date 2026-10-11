# Stand rapid-click and traversal retest — September 13, 2026

The user restarted and reports that rapid clicks no longer skip priorities. Today's native edits exercise the new permission-preservation path. Stand refresh cost is modestly lower than the previous restart, but recurring long frames remain. This is not release acceptance or a claim of stutter-free performance.

## Identity and actions

Game PID **29584**, started **12:03:12 Europe/Berlin**, is newer than the September 12 22:51 installation. All **39 installed Lua hashes** match `test-results/stand-cost-stage-result-20260912.json`, and every installed Lua file predates process startup. The runtime/pak hashes are unchanged; both automatic and hot reload were disabled before startup. Full identity: `test-results/stand-cost-restart-identity-20260913.json`.

The visible game is **Win S v1.0.4.102642**, 1920×1080, with **0.5.0-rc1** and UE4SS **2281fa31**. `ScreenShot00340.png` shows the open Monitoring Stand with plain numeric/X priorities. The initial bounded stand diagnostic ran before profiling and recording. Local authority and saved priorities/limits are reported. No game code, runtime, pak or player setting was changed by the assistant during this retest.

## Rapid-click result and independent review

The independent reviewer examined the current boot through 12:09:54 and counted **38 edit passes and 13 unattributed permission-change reports**, all stating that priorities were preserved. These are scheduler observations, not physical-click counts. The code records native readback without saving X/1 over durable numeric priorities. Existing regression evidence covers interleaved 3→4→5, explicit X preservation, and no persistence writes caused solely by native observations.

Together with the user's direct report, this supports recovery of the previously reproduced jumping behavior. It does not establish exact input latency, every alternating/boundary sequence, reconnect behavior, or actual Pal assignment. No ERROR/FATAL/traceback was found in the reviewed boot portion. The separate icon probe reports a refused `LoadIconToImage` call; absence of hard errors is not complete compatibility evidence.

## Repeated inclusive timings

Profiling began at **12:09:16**, was sampled/reset at **12:11:06**, and was sampled/disabled at **12:12:41**. The recording windows below lie inside these longer profiling windows. Rows are inclusive and overlap; do not sum them. Clock resolution remained unmeasured, so zero-duration samples do not prove zero cost. There were no queued-input timing rows in these two windows; the earlier rapid edits are separate evidence.

| Region | First window, 110 s | Second window, 95 s |
|---|---:|---:|
| Complete stand refresh | 103 samples; mean 27.184 ms; max 29 ms | 89 samples; mean 27.213 ms; max 30 ms |
| Menu lookup | 10.136 ms mean | 10.056 ms mean |
| Roster lookup | 10.738 ms mean | 10.697 ms mean |
| Grid refresh, including roster | 16.903 ms mean | 16.978 ms mean |
| Complete pad drive | 4,835 samples; mean 0.157 ms | 4,746 samples; mean 0.157 ms |
| Complete scheduler | 10 samples; mean 43.700 ms; max 48 ms | 9 samples; mean 43.222 ms; max 45 ms |
| Bucketed storage scan | 23.100 ms mean | 22.111 ms mean |
| Camp enumeration | 9.900 ms mean | 9.556 ms mean |
| Complete clock batch | max 77 ms | max 74 ms |

The [previous restart](jump-restart-2026-09-12.md) measured 30.287/30.193 ms for complete stand refresh and 12.484/12.407 ms for roster lookup. Today's observed complete refresh is approximately **10% lower**, and roster lookup approximately **14% lower**. This supports a modest traversal improvement, not a controlled causal benchmark: scene workload and overall frame rate differ. The complete scheduler remains approximately 43–44 ms. The remaining menu scan, roster traversal and storage scan are substantial targets; no saved UObject cache or unverified storage exclusion is justified by these measurements.

## Independent frame recordings

PresentMon 2.5.1 targeted the verified PID using three unique trace sessions, five-second lead-ins and sixty-second recordings. Input tracking was disabled. Raw files retain process/swapchain IDs; normalized captures are checked for one target swapchain, monotonic timestamps and duration consistency. These are Present-call intervals, not physical display or input-to-display latency.

| Capture | Frames | Mean | p99 | >33.333 ms | >50 ms | Worst |
|---|---:|---:|---:|---:|---:|---:|
| Profiling on, first | 7,423 | 8.082 ms | 10.718 ms | 53 | 6 | 80.145 ms |
| Profiling on, second | 6,951 | 8.629 ms | 11.553 ms | 56 | 5 | 82.488 ms |
| Profiling off | 6,732 | 8.913 ms | 11.616 ms | 55 | 6 | 83.388 ms |

All three recordings still show recurring long frames, including with profiling off. No mod-absent baseline or exact Lua/QPC alignment exists, and clicks/camera/foreground were not independently timestamped. Other installed mods and live world activity remain potential contributors. These observations cannot attribute individual slow frames or quantify profiler overhead. Frame rate differs from yesterday and drifts during today's recordings, so the small traversal improvement is not a general frame-rate claim.

All three recorders exited normally and profiling was disabled at 12:12:41. The final 12:14:22 status still reports saved priorities/limits and local authority. `ScreenShot00341.png` shows the same visible priority values as the initial screenshot. The saved boot log through that final read contains 38 edit passes, 13 preservation reports and no WARN/ERROR/FATAL/traceback. The 39 installed hashes still match the initial identity. No later game-code change was staged.

## Storage evidence and remaining gates

The existing scan consistently reports **complete=false, unknown_scope=533, failed_reads=533, scope_zero_guid=533**. The new reason means the scope call returned a value whose four GUID components were readable and zero. It does not mean outside-camp ownership, empty stock, scenery, or a safe exclusion. Scope rejection precedes backing-container identity/deduplication, so these are **533 failed scope observations, not 533 proven unique chests**. Yesterday's 532 versus today's 533 does not prove one chest was added. The conservative storage response remains necessary until a verified scope contract exists.

The current run still has **14 unverified assignments** and unverified storage. The client synchronization field says `connecting` even on this local authority; it does not establish a multiplayer connection. Actual staffing/output, manual assignments, producer adapters, multiplayer transitions, and the wider UI/lifecycle matrix remain open release gates.

## Evidence locations

Local artifacts are under ignored `test-results/` and are excluded from the release payload:

- `stand-cost-restart-identity-20260913.json`, `stand-cost-restart-initial-20260913.txt`.
- `stand-cost-restart-perf-start-20260913.txt`, `stand-cost-restart-sample1-20260913.txt`, `stand-cost-restart-sample2-20260913.txt`.
- `stand-cost-restart-final-20260913.txt`, `stand-cost-restart-session-20260913.txt`, `stand-cost-restart-health-20260913.json`, `stand-cost-restart-tree-20260913.txt`.
- `stand-cost-restart-{on1,on2,off1}-capture-20260913.json`, corresponding raw `*-presentmon-20260913.csv`, normalized `*-frames-20260913.csv`, metadata and `*-frame-evidence-20260913.json`.
- `capture-stand-cost-20260913.ps1` and `analyze-stand-cost-restart-20260913.py` record the capture/analysis procedure.

The reviewer stayed read-only and did not issue game commands or analyze frames; the parent controlled the developer channel and recordings. No commit or publication was made.
