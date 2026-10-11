# Stand refresh correlation and name reuse — September 13

Local 0.5.0-rc1, unpublished. The baseline establishes substantial temporal overlap between long frames and stand refresh; the narrow optimization is tested but **does not fix remaining stutter**.

## Evidence before editing

PresentMon 2.5.1, PID 38504, stand open, 60-second recording. Two nonce publications bound the Lua/QPC offset to a consistent 4.905 ms interval under constant-rate/offset assumptions. Of 67 present intervals longer than 16.67 ms, 57 overlap a recorded stand grid refresh for every offset in that interval. This is correlation, not proof of exclusive causation. Events shorter than 4 ms and other uninstrumented work are excluded. Raw trace: `test-results/stand-correlation-before-events-20260913.tsv`; anchors `correlation-anchor-standcorr1.json` and `standcorr2.json`; analysis `stand-correlation-before-analysis-20260913.json`.

## Change and regression

The complete current-call tree traversal now supplies an aligned array of cell names to the paint loop. This avoids rereading names already obtained while discovering the cells. The full search, scope/uniqueness checks, incomplete-tree refusal, fallback behavior and handle_cell validity check remain. Names are not lifetime evidence and no target survives the callback. Input paths retain their existing reads.

The new real-tree regression checks aligned scalar names, fresh same-name replacements and no partial name result on failure. It fails against the installed prior tree implementation and passes on the candidate. All 56 Lua scripts pass; all 43 modules compile; structural checker passes. Artifacts: `stand-name-before-regression.txt`, `stand-name-lua-20260913.txt`, `stand-name-checker-20260913.txt`.

## Native follow-through

Checked installer preserved backup `deploy-20260913-194004-707d1aa7b2bb4e07b18eb1079bc1ac36`. The checked AHK restart derivative replaced PID 38504 with 35496 (started 19:40:25), reached gameplay/session-1 authority and opened the stand. All installed module hashes match the capture manifest `stand-name-hashes-20260913.json`.

Saved numbers/X displayed correctly. After capture, one left click changed Incineram Kindling 2→1, one right click restored 1→2. Escape closed the stand; the checked held-V helper reopened it and all numbers returned. Status reports priorities and limits saved, authority yes and complete/deduplicated storage without unknown scope or failed reads. No PWP WARN/ERROR in the archived 19:40+ observation segment. These checks do not establish rapid-click, multiplayer, actual assignment or producer-output acceptance.

## Timings and limits

| Stand open capture | Frames | p99 ms | Worst ms | >16.67 ms | >33.33 ms |
|---|---:|---:|---:|---:|---:|
| Before, profiling/events on | 8,012 | 10.59 | 42.96 | 67 | 1 |
| After, profiling on | 9,676 | 8.21 | 29.83 | 51 | 0 |
| After, profiling off | 9,811 | 7.93 | 54.69 | 41 | 2 |

All recordings completed; one PID/swapchain and timestamp-duration consistency verified. Present intervals include dropped presentations; they are not physical-display latency. No tests, screenshots or analysis ran during recordings. Each capture rechecked module hashes. Before/after differs in process age, world activity and day/night state; only the baseline has event recording enabled. Thus the frame differences do not establish a causal speedup.

Inclusive mean stand refresh: 10.919 ms over 86 samples before, 10.367 ms over 79 after. Roster discovery: 6.977→6.747 ms; per-cell refresh remained 0.030 ms. Nested regions overlap. The small overall reduction is consistent with removing duplicate reads but not isolated from noise. Most discovery cost remains; recurring long frames persist even with profiling off. A broader safe traversal change requires completeness/lifetime regressions and another native comparison, not an epoch-only skip of the whole refresh.

Artifacts: `correlation-standcorr-before-20260913.*`, `correlation-standname-after-on-20260913.*`, `correlation-standname-after-off-20260913.*`, `stand-name-frame-analysis-20260913.json`, profiler reports and `stand-name-final-status-20260913.txt`. Profiling off, event recording off, recorder/helper processes exited, stand open. No commit or release. Assignment/staffing, synchronization and remaining reliability gates are still open.
