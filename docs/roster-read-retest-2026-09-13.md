# Roster read reduction and AHK retest — September 13

Local 0.5.0-rc1, unpublished. Correctness smoke checks passed within the scope below; **no measurable performance improvement established**.

## Checked change

The initial roster patch still called IsValid twice on a successful parameter and removed the second species attempt after a failed display-name fallback. The added real-module regression failed on the duplicate validity assertion before correction. The corrected code reuses only successful results within the current call, validates replicated fallback parameters, retains a failed species retry, and reads replacement wrappers afresh. No wrapper survives a callback. All 56 Lua regression scripts passed; all 43 modules compiled under Lua 5.4; structural checker passed (panel 193 locals).

Deployment receipt: `test-results/roster-deploy-20260913.txt`; backup `deploy-20260913-192032-5fc498c180af48be8ac401bcebbcdbf4`. Automatic reload was disabled. Source and installed hashes after restart match for all 43 modules (`test-results/roster-after-hashes-20260913.json`).

## Restart and behavior

Used the existing checked derivative of the user's Desktop AHK recording (`test-results/restart-checked-20260913.ahk`), whose final stray key event is omitted. Restart receipt `test-results/roster-restart-20260913.json`. Old PID 35812 exited; PID 38504 started 19:21:14; banner 19:21:19; gameplay world 19:21:38; session-1 authority readiness 19:21:43.

The fixed-time recording reached the stand but did not open it this time. Therefore the first post-restart recording is explicitly **stand closed**, not a matched open-stand comparison. Opened the stand before the subsequent recordings and visually verified all nine displayed rows, including saved X choices and numeric priorities. After recordings Escape closed it; brief V presses did not reopen it, but the existing 800 ms held-V helper (`open-stand-checked-20260913.ahk`) did. All numbers returned. Leave the stand open for the user. Never equate an AHK exit code with successful menu opening.

Saved priorities and backed-up configuration files remained byte-identical. Status reports authority, priorities saved, limits saved, complete/deduplicated storage with zero unknown scope or failed reads. There were 29 completed tick lines and no PWP WARN/ERROR in the archived session through the initial analysis. These are limited observations: actual assignments remain unverified (14), three unverified workers exceed staffing capacity, and SP synchronization still says connecting. No native input-edit, producer-output, multiplayer, fresh-install or failure-injection gate is closed by this run.

## Measurements

Four independent PresentMon 2.5.1 captures, each about 60 seconds plus a five-second lead, with recorder completion, one PID/swapchain, monotonic timestamps and raw duration consistency verified. No test suite or analysis ran during captures. Captures include present records regardless of drop status; these are present intervals, not physical-display or input-latency measurements. Graphics-settings hashes match; world activity, camera orientation and process age differ across restart, so these are observational comparisons. No mod-absent control or event/frame correlation was collected here.

| Scene | Frames | p99 ms | Worst ms | >16.67 ms | >33.33 ms |
|---|---:|---:|---:|---:|---:|
| Before correction, stand open, profiling on | 9,313 | 8.54 | 41.87 | 60 | 2 |
| After, stand closed, profiling on | 11,791 | 6.48 | 53.71 | 12 | 2 |
| After, stand open, profiling on | 8,928 | 9.33 | 51.20 | 65 | 2 |
| After, stand open, profiling off | 8,993 | 9.08 | 48.45 | 61 | 2 |

Before/open versus after/open profiler windows: complete scheduler 20.67 ms (9 passes) versus 20.57 ms (7 passes); camp roster 4.11 versus 4.21 ms per camp (two camps/pass); stand grid refresh 10.86 versus 10.67 ms; storage 20 ms in both. Inclusive rows overlap. Differences are too small and uncontrolled to establish a benefit. The baseline already contained the preceding species reuse patch; this comparison measures the correction, not the whole earlier roster proposal.

The roughly once-per-second open-stand slow frames persist with profiling off. Investigate the measured ~10.7 ms grid refresh and ~6.9 ms stand roster lookup with event/frame correlation before another change; this run alone does not attribute each long frame. Scheduler enumeration and storage bursts also remain. Retain the narrow checked reduction without describing it as a stutter fix.

Raw data: `test-results/correlation-roster-*-20260913.csv/json/stdout/stderr`. Analysis and integrity checks: `test-results/roster-retest-analysis-20260913.json` and `analyze-roster-20260913.py`. Profiler reports: `roster-before-perf-20260913.txt`, `roster-after-closed-perf-20260913.txt`, `roster-after-stand-perf-20260913.txt`. Final status: `roster-final-status-20260913.txt`. Profiling is off; recorders and AHK helpers exited. No commit or release was made.
