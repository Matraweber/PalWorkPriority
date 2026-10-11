# Scoped stand lookup and storage retry: native retest

The September 13 12:39 candidate reduces measured lookup work and storage-scan frequency, but recurring frame pauses remain. This is performance evidence for two changes, not release acceptance.

## Loaded identity and visible results

Palworld PID **34308**, started **12:45:16 Europe/Berlin**, loaded the **0.5.0-rc1** banner at 12:45:22. All **39 installed Lua hashes** match the checked staging receipt and remain unchanged after measurement. Game Win S v1.0.4.102642, UE4SS DLL SHA `21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8`, and pak SHA `f266971e7c4ffea00039fd892de7b47cbaeecca959ba8cb36f546caff522e310` identify this installation. No source was changed or deployed during this retest.

The bounded stand diagnostic returns **117 tree cells / 117 global cells**. Roster visits fall **909 → 639**, with 77 owner visits unchanged, nine scoped rows, zero row fallbacks and no budget exhaustion. Visits describe traversal operations, not distinct widget identities. Screenshots `ScreenShot00342.png` and `ScreenShot00343.png` show all nine rows and the same 33 numeric/X priorities. They do not independently verify every input or prove all unavailable work cells are rendered by the mod.

## Inclusive callback measurements

The preceding baseline is [the earlier September 13 retest](stand-cost-retest-2026-09-13.md). Current windows ran 12:50:44–12:52:05 (81 seconds), then 12:52:05–12:54:55 (170 seconds). No queued-input samples or edit passes occurred in these windows; these are open-stand idle measurements.

| Region | Previous means, ms | Current first / second means, ms | Current samples |
|---|---:|---:|---:|
| Complete stand refresh | 27.184 / 27.213 | 24.000 / 24.043 | 77 / 161 |
| Menu lookup | 10.136 / 10.056 | 10.169 / 10.261 | 77 / 161 |
| Roster lookup | 10.738 / 10.697 | 6.922 / 6.876 | 77 / 161 |
| Grid including roster | 16.903 / 16.978 | 13.649 / 13.590 | 77 / 161 |
| Complete scheduler | 43.700 / 43.222 | 29.250 / 27.187 | 8 / 16 |
| Storage scan | 23.100 / 22.111 | 23.333 / 24.400 | 3 / 5 |
| Camp enumeration | 9.900 / 9.556 | 10.125 / 10.250 | 8 / 16 |
| Complete pad drive | 0.157 / 0.157 | 0.153 / 0.153 | 4340 / 9024 |

The roster lookup is approximately **36% cheaper**, and complete stand refresh approximately **12% cheaper**, in these observations. Menu lookup remains unchanged and is the largest remaining single stand subregion.

Storage performed **8 scans over 24 completed timed passes**, versus **19/19** in the preceding baseline. The profiling-off count window also reports **3/8**. This is consistent with settled retries around one scan per three passes. Profiler resets do not reset the retry state: these windows do not measure the initial 5/10/20-second progression. Aggregate rows do not establish exact individual retry intervals or cached-pass durations. Individual scan cost has not improved; complete scheduler maxima remain **45/47 ms**, and complete clock-batch maxima **70/74 ms**.

Live status still reports global storage scope, despite the root configuration file saying camp. Cached evidence stays **complete=false, deduplicated=true, unknown_scope=534, failed_reads=534, scope_zero_guid=534**. These are failed scope observations, not 534 proven unique chests. Reduced scan frequency has not resolved the underlying storage uncertainty.

The new breakdown in the second window is:

- Cell refresh: 18,837 samples, 1,003 ms inclusive total, or **6.23 ms per full grid** across all 117 cells.
- Label lookup/construction: 5,313 samples, 569 ms, or **3.53 ms per grid** across 33 applicable cells.
- Text/colour writes: 54 ms total, **0.34 ms per grid**.
- Vanilla-checkbox hiding: 23 ms total, **0.14 ms per grid**.
- Legend refresh: **0.15 ms per grid**.

The latter regions are nested inside cell/stand timing; do not add them to parent totals. Label lookup and construction are not separately counted. Timings use Lua `os.clock`; resolution remains unmeasured, so zero durations are not proof of zero cost. Counts-only route rows correctly say unmeasured. The new data does not justify prioritizing text-write caching over menu discovery, roster traversal or label discovery.

## Independent frame recordings

PresentMon 2.5.1 recorded the target PID using QPC-based Present intervals, five seconds lead-in and sixty seconds per clip. All clips have one target swapchain and pass positive-duration, monotonic-timestamp and duration-consistency checks.

| Recording | Mean, ms | p99, ms | Above 16.67 ms | Above 33.33 ms | Above 50 ms | Worst, ms |
|---|---:|---:|---:|---:|---:|---:|
| On 1: supporting only | 6.285 | 8.817 | 60 | 11 | 6 | 75.476 |
| On 2: supporting only | 6.264 | 8.545 | 58 | 7 | 4 | 75.970 |
| On 3: clean | 6.371 | 8.886 | 59 | 7 | 4 | 74.454 |
| Off 1: clean | 7.043 | 10.319 | 60 | 8 | 4 | 76.944 |

On 1 includes the 12:52:05 report/reset near its end; On 2 begins with approximately one second of overlapping recorder activity. They are retained transparently as supporting evidence. On 3 and Off 1 ran without those overlaps or in-clip remote commands. The initial recorder launch also refused a PowerShell JSON date-conversion mismatch; comparing the unchanged timestamp as a string corrected that helper issue before any recording began. An attempted read of the still-open first CSV failed and was retried only after it closed.

The earlier baseline had 53–56 intervals above 33.33 ms and worst intervals 80–83 ms. However, its ordinary frame interval was 8–9 ms, versus 6–7 ms now. Day/night and live background workload changed, camera/foreground were not continuously observed, other mods remained installed, and there is no mod-absent capture. **Do not attribute the entire threshold-count reduction or average-FPS change to this patch, or interpret On/Off as a causal profiler-overhead estimate.**

The clean clips still have **59/60 long intervals above 16.67 ms**, with median gaps **1.059/1.059 seconds**. Their five intervals above 45 ms have median gaps **10.634/10.628 seconds**. On 3 contains two intervals above 60 ms separated by 31.946 seconds; Off 1 contains one. The recurring stand/pass pattern remains, while the largest storage-related pattern is consistent with reduced scan frequency. Without Lua-to-QPC event alignment this is cadence correspondence, not attribution of individual frames.

## Health, interpretation and remaining work

At the saved health snapshot, the boot session contains **66 automatic ticks, zero edit passes and zero mod WARN/ERROR/FATAL lines**. Both logging sinks report zero failures. Local authority remains YES; route counts match completed passes. This does not verify multiplayer role transitions. All 14 assignments remain unverified, no permission requests were sent, and storage remains unverified; scheduler correctness and output limits are not accepted by these measurements.

Profiling was explicitly turned **off at 12:54:55** and confirmed off at 12:56:23. All task recorders exited. The parent requested one close/reopen plus rapid left/right and direct-number/X input check after recordings; its result is pending separately from these timing windows. The previous build's user-confirmed rapid-click success remains prior evidence, not an input test of this build.

Next performance targets, by measured cost, are fresh menu discovery (~10.2 ms per refresh), roster discovery (~6.9 ms), and fresh label lookup (~3.5 ms per grid). Any replacement must retain current-tree lifetime and completeness checks; matching object names are insufficient to justify stored wrappers or write-cache validity. Scheduler camp enumeration (~10 ms/pass) and unresolved storage scans (~24 ms/scan) remain independent work. No native adapter or speculative cache was added during this observation turn.

Independent reviewer Cicero compared the completed raw sample reports and clean frame-evidence files. It confirmed the lookup percentages, scan/pass ratios, retained uncertainty, and exact 117 cell-refresh calls per grid in both timed windows and the off window. It agreed that hitches remain and that background-frame differences prevent causal threshold-count or profiler-overhead claims. Hash verification and screenshots were checked by the parent; successful editing and native assignment correctness remain outside this review.

Evidence prefix: `test-results/deep-perf-restart-` (identity, initial/tree diagnostics, two timed samples, profiling-off final sample, raw/normalized frame captures and metadata, frame-evidence JSONs, cadence, health and saved boot-session log). Recording/analysis helpers use unique deep-perf prefixes. The original staging evidence remains unchanged. No publication or commit was performed.
