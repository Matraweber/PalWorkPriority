# Rapid-click build restart and performance retest — September 12, 2026

Status: restarted build verified; three native frame captures complete. Controller polling improved, but recurring stand/scheduler hitches remain. No priority edit was recorded in this session through the saved log snapshot, so disappearance of the user's rapid-click jumps is not yet verified.

## Loaded identity and visible state

PID **6192**, started **22:31:11**, is newer than the 22:29:46 deployment. All **39 installed Lua hashes** match the checked generation and predate process startup. The loaded banner is 0.5.0-rc1 at 22:31:16; world/session 1 is ready at 22:33:47. Game screenshot identifies **Win S v1.0.4.102642** at 1920×1080. Runtime and pak fingerprints are in `test-results/jump-restart-identity-20260912.json`.

The current tree reports 117 scoped cells, 77 owner visits and 909 roster visits. `ScreenShot00338.png` and `ScreenShot00339.png` in `%LOCALAPPDATA%/Pal/Saved/Screenshots/Windows` show the stand and its numeric/X priorities at the start and end. Neither is a recording of a click sequence. Status reports local authority, saved priorities and saved limits. The client-transport field says `connecting` in this solo authority session; it does not prove a multiplayer connection.

The saved session log has zero WARN/ERROR lines, zero edit passes and zero unattributed permission-change reports. The timed windows have no queued-input row; scoped tree calls equal complete refreshes. These are idle-stand observations, despite the request for rapid-click input. They cannot close the jump regression's native acceptance gate.

## Repeat timings

Profiling began at **22:35:25**, was sampled/reset at **22:37:35**, and was sampled/disabled at **22:40:10**. Durations below are inclusive. Parent/child rows overlap and must not be summed. Lua clock resolution remained unmeasured; a zero duration is not proof of free work.

| Region | Window 1, 130 s | Window 2, 155 s |
|---|---:|---:|
| Complete stand refresh | 122 samples; mean 30.287 ms; max 32 ms | 145 samples; mean 30.193 ms; max 38 ms |
| Menu lookup | 10.238 ms mean | 10.269 ms mean |
| Roster lookup | 12.484 ms mean | 12.407 ms mean |
| Grid refresh, including roster | 19.910 ms mean | 19.786 ms mean |
| Complete pad drive | 6,615 samples; mean 0.150 ms; 7.654 ms/s | 7,821 samples; mean 0.139 ms; 7.019 ms/s |
| Complete scheduler | 12 samples; mean 43.833 ms; max 45 ms | 14 samples; mean 43.929 ms; max 45 ms |
| Bucketed storage scan | 24.333 ms mean | 24.214 ms mean |
| Camp enumeration | 10.000 ms mean | 10.071 ms mean |
| Complete clock batch | max 76 ms | max 75 ms |

The previous rapid-click window measured complete pad drive at 0.299 ms/call and 13.730 ms/s: the new samples are approximately half that per-call cost. Its complete stand refresh was 28.912 ms, versus 30.2 ms now. **No full-refresh improvement is established by eliminating the class queries in the synthetic test.** The preceding idle stand session also measured scheduler passes at 44.333 ms, consistent with this restart's approximately 44 ms. Comparing the old rapid-click mixed scheduler mean of 33.424 ms directly against these idle passes would mix different cache/trigger workloads.

Authority/component resolution is measured separately and stays small in these windows. Assignment identity and storage are still unverified. Healthy authority lookup, steady cadence and visible permissions do not prove production or worker allocation.

## Independent frame captures

PresentMon 2.5.1 targeted PID 6192. Each capture uses a unique trace session, a five-second lead-in and sixty-second recording, with keyboard/mouse tracking disabled. Each file has one target swapchain and passes monotonic timestamp/duration consistency checks. These are Present-call intervals, not physical display latency.

| Capture | Frames | Mean | p99 | >33.333 ms | >50 ms | Worst |
|---|---:|---:|---:|---:|---:|---:|
| Profiling on, first | 9,076 | 6.612 ms | 8.488 ms | 56 | 6 | 82.916 ms |
| Profiling on, second | 8,974 | 6.683 ms | 8.795 ms | 57 | 5 | 82.037 ms |
| Profiling off | 9,223 | 6.504 ms | 8.531 ms | 56 | 5 | 81.619 ms |

The previous 60-second capture had 53 intervals above 33.333 ms, six above 50 ms and an 86.324 ms maximum. The new observations do **not** show stutter elimination. Hitches persist with profiling off, so profiling is not required for the observed symptom. The windows are not fully controlled matched scenes: activity/camera/foreground and clicks were not independently timestamped, other mods remain installed, no mod-absent baseline exists, and there is no precise Lua/QPC clock alignment. They cannot quantify causal profiler overhead or attribute individual frames to a particular callback.

All three task recorders exited, and profiling remains off. No installed code changed during these measurements.

## Storage finding and next targeted changes

The existing-scan diagnostic repeatedly reports **complete=false, deduplicated=true, unknown_scope=532, failed_reads=532, reason scope=532**. It identifies ownership resolution as the failure stage, rather than item quantities or duplicate backing storage. The independent reviewer confirmed that the current code collapses a throwing/missing scope call, unreadable GUID fields and a readable all-zero GUID into this same result. This does not prove all 532 objects are out-of-camp scenery. Unknown evidence shortens storage retry to five seconds, causing the approximately 24 ms scan on periodic passes.

The next diagnostic retains the outcome of the existing scope/GUID reads under fixed reason names, without another enumeration or GUID field read. All-zero IDs remain unknown; no producer is admitted or stopped using fabricated counts. Public GUID callers retain their original single-value return contract. The detail regression fails before and passes afterward in `scope-detail-before-20260912.txt` / `scope-detail-after-20260912.txt`.

The remaining roster traversal also attempts child APIs on standard primitives that have no child widgets. Exact `Image`, `Spacer` and `TextBlock` contracts can terminate those branches before the unsupported probes. These classes are documented as childless by Epic: [UImage](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/UMG/UImage), [USpacer](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/UMG/USpacer), [UTextBlock](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/UMG/UTextBlock). **CheckBox must remain traversable**: it is a [single-child content widget](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/UMG/UCheckBox). Unknown subclasses and private user-widget trees retain conservative behavior. Native savings from this next change are not yet measured.

## Evidence

Artifacts live under `test-results/`: `jump-restart-identity-20260912.json`, `jump-restart-start-20260912.txt`, `jump-restart-tree-20260912.txt`, `jump-restart-perf-start-20260912.txt`, `jump-restart-sample1-20260912.txt`, `jump-restart-sample2-20260912.txt`, `jump-restart-end-20260912.txt`, `jump-restart-session-20260912.txt`. Each `jump-restart-{on1,on2,off1}-capture-20260912.json` records process/arguments/timing. Corresponding raw `*-presentmon-20260912.csv`, normalized `*-frames-20260912.csv`, metadata and `*-frame-evidence-20260912.json` preserve frame evidence and hashes.

The unresolved native gates are rapid-click behavior, remaining stand/global scans, storage scope semantics, actual assignment/output adapters and the broader lifecycle/multiplayer matrix. No release or performance acceptance follows from this retest.

## Next checked installation, 22:51

After all recordings finished, the parent implemented the exact native-terminal changes and GUID diagnostic refinement. Two new tree regression groups fail before and pass after: unsupported native child probes are eliminated, and a failed CheckBox child-count read cannot establish empty content. The test fixture now correctly models an empty CheckBox with a zero child count. Existing traversal order, 117-cell fixture, unknown subclasses, fresh-wrapper and named-label tests remain passing.

The independent reviewer found no material issue in either change. All 39 Lua 5.4 modules compile, all 33 regression scripts pass (including 39 actual UI integration cases), and structural checks pass with the existing panel 194-local warning. Evidence: `test-results/stand-terminal-before-20260912.txt`, `stand-terminal-after-20260912.txt`, `stand-cost-full-lua-20260912.txt`, `stand-cost-structural-20260912.txt`.

Installed at **22:51:40**, changing only `palapi.lua` and `ui_tree.lua`. All 39 installed files match tested source, and all 39 previous files match the verified backup at `backups/deploy-20260912-225140-1dbd57b5b7304ab1885c37113721b249`. Root user configuration, pak and runtime hashes remain unchanged. Automatic/hot reload were disabled before the running process started; no reload command was invoked. PID 6192 remains the previous loaded generation, so the new code requires a full restart.

Receipts: `test-results/stand-cost-stage-before-20260912.json`, `stand-cost-stage-result-20260912.json`, `stand-cost-deploy-20260912.txt`. No code was installed during a recording, no player priority/limit was edited by this test, and no commit or publication was made. The next restart must retest rapid clicks and the same stand/frame timing conditions before any native speedup claim.
