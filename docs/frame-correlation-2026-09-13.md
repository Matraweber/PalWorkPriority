---
date: 2026-09-13
tags: [performance, testing]
status: evidence
---
# Frame correlation and physically absent-mod comparison, September 13

Related: [g5-performance-2026-10-19](g5-performance-2026-10-19.md) · [frame-capture-procedure-2026-10-09](frame-capture-procedure-2026-10-09.md)

Local **0.5.0-rc1**, unpublished. The experiment identifies recurring mod work associated with smaller pauses. It does not establish stutter-free gameplay or resolve the gameplay release gates.

## What changed

Added an opt-in, bounded scalar event trace: actual start/end intervals from the existing profiler, inclusive labels, a 4 ms event threshold, 4096-event limit and 180-second recording limit. No file writes occur when events are collected. Export and clock anchors are explicit developer commands outside frame recordings. The trace records drops and expiry; neither occurred in these recordings. It retains no Unreal objects. Commands remain protected from other players' chat.

Publication anchors bracket a fixed nonce file with Lua timestamps and an independent Windows QPC observer. The observer brackets the last nonmatching and first matching reads, refuses preexisting/nonfresh markers, and treats read errors as unknown. Nonces are consumed before publication, including failed writes/closes, and cannot be reused across trace resets. This prevents stale publication from becoming a false clock match.

All **43 Lua modules compile under Lua 5.4; 54 regression scripts pass**. The QPC observer has 12 passing Python tests. The structural checker initially misclassified `require('frame_trace').new()` as a module alias and falsely rejected its instance methods. That tool defect is corrected without changing the loaded Lua: six focused regressions pass (four failed before), factory-member typos remain checked, and the final structural scan passes. The earlier failed checker receipt is retained; the final receipt is `test-results/correlation-final-checker-20260913.txt`.

## Identity and safe removal/restoration

Game **1.0.4.102642**, UE4SS beta **2281fa31**. The trace build was checked and installed before full restart. Source/install hashes for all 43 modules are in `test-results/frame-correlation-hashes-20260913.json`.

1. **PID 36252**, start 17:34:48, banner 17:34:53, world 17:35:11: aligned mixed-stand and closed-after-opening recordings.
2. At **17:41:10**, disabling restored allowed permissions after 18 requests with readback verification; explicit X remained disabled. A second restoration at **17:41:38** verified the same state with zero requests. The world was saved through Return to Title, then the process exited through Quit Game.
3. All SaveGames, native mod files, pak, activation metadata, managed manifest and shared user configuration were copied and hash-verified to `C:\Users\matra\Desktop\PalWorkPriority-test-backups\correlation-20260913-174659` (1305 manifest entries). No world rollback was performed.
4. Native PalWorkPriority and its pak were moved outside scanned game/Workshop directories. `mods.txt` was set to zero. The game rewrote that entry to one on startup, but **both payloads stayed absent and the fresh UE4SS log contained no PalWorkPriority entries**. Managed activation was kept to avoid invoking its old-package uninstall/restore behavior.
5. **PID 40036**, start 17:47:24: two absent-mod captures. UE4SS and the other mods remained installed. This is a PalWorkPriority-absent comparison, not vanilla Palworld.
6. After saving and quitting, the exact quarantined payload and original mods.txt were restored. **1058 mod/configuration files matched their backup hashes.** Activation entries also matched; the sole other metadata difference was the game's transient error-warning flag changing True to False, which was retained. The initial restoration script deliberately stopped at that byte difference; the follow-up verified it was the only exception. Receipt: `test-results/correlation-absence-state-20260913.json`.
7. **PID 41324**, start 17:54:32, banner 17:54:38: restored build enabled, profiling off, two comparison captures. Stand first opened after these recordings, with saved numeric/X values visible again.

At the first absent launch the game showed a previous-session error warning. Other mods were kept enabled for the comparison. No new crash directory was found (latest September 11); that does not prove the prior shutdown had no fault. Save confirmation and the updated world-selection timestamp were observed.

## Aligned events

Two recordings use PresentMon 2.5.1 raw QPC timestamps. One PID/swapchain, monotonic timestamps, present-delta consistency and placement between the external markers were checked. A constant Lua/QPC clock rate is an explicit assumption. The eight publication brackets admit a common offset interval about **4.91 ms wide**; a sensitivity calculation with +/-2 ms Lua endpoints widens it to **8.91 ms**. The endpoint allowance is an assumption, not a measured clock-resolution guarantee. No extrapolation beyond the markers is used.

The 90-second `traced` clip is **mixed**: the stand opened during recording. It is not a controlled stand-only baseline. The 60-second `closed` clip is **closed after previously opening the stand** in the same process. It is distinct from the restored process's never-opened state.

| Recording | Frames >16.67 ms | Any recorded-event overlap | Frames >33.33 ms | Recorded-event overlap above 33.33 ms |
|---|---:|---:|---:|---:|
| Mixed, 90 s | 84 | 75 | 3 | 0 |
| Closed after opening, 60 s | 11 | 8 | 2 | 0 |

These overlap counts hold across both tested offset/endpoint scenarios. They mean temporal association, not causal certainty. In the closed recording, six slow frames overlap scheduler passes and two overlap separate storage refreshes. Complete scheduler work measured about **20-23 ms**, including approximately **10-12 ms** camp enumeration; separate storage work was about **20-24 ms**. Nested timings are inclusive and must not be added.

The closed recording's two >33.33 ms intervals are separated by about 30 seconds, and neither intersects a recorded >=4 ms mod event. The mixed recording's three large intervals also recur about 30 seconds apart without recorded overlap. This is a useful lead for game/runtime/other-mod investigation, not proof of an autosave or other particular cause. Shorter or uninstrumented mod work is not excluded.

Independent analysis and reproducible script: `test-results/correlation-analysis-20260913.json` and `test-results/analyze-correlation-20260913.py`. Individual CSV, metadata, anchor JSON and event TSV paths/hashes are included in the analysis.

## Absent versus restored, profiling off

Each clip is approximately 60 seconds, with a five-second lead. No game controls, synthetic commands, screenshots, test runs or agent computation occurred during recording. The camera/location and closed-menu state were checked around the clips. Current-world progress was preserved: no save rollback, weather/time lock or randomized ordering was used.

| State | Present intervals | Mean ms | p99 ms (nearest-rank check) | Worst ms | >16.67 ms | >33.33 ms | >50 ms | Dropped=1 rows |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Absent 1 | 11839 | 5.066 | 6.748 | 57.484 | 2 | 2 | 1 | 5 |
| Absent 2 | 11115 | 5.397 | 7.200 | 44.354 | 2 | 2 | 0 | 1 |
| Restored 1, profiling off | 9531 | 6.292 | 8.166 | 29.900 | 10 | 0 | 0 | 0 |
| Restored 2, profiling off | 9652 | 6.214 | 8.024 | 66.427 | 11 | 1 | 1 | 0 |

Dropped rows remain included, separately reported; these are present intervals, not physical-display or input latency. The restored pair progressed into **night/sleeping Pals**. The restored mod also sent 16 permission requests before capture. Matching settings and location therefore do not establish identical worker activity or rendering workload. Do not attribute the difference in mean FPS to the mod or derive a precise causal slowdown percentage.

The repeated result supports the narrower conclusions: large spikes still occur with PalWorkPriority physically absent; smaller recurring pauses remain with the restored mod even when profiling is off. Combined with aligned events, scheduler/camp enumeration and storage are justified next optimization targets. The profiler is not a sufficient explanation for all remaining moderate pauses.

The independent reviewer reproduced the table and validated each process/swapchain, timestamp progression, recorder completion, settings fingerprints and restored module hashes. The frozen comparison is `test-results/correlation-absence-restored-comparison-20260913.json`. Both startup logs contain the same PalSchema errors, so this is not an error-free other-mod cohort; the scoped restored PalWorkPriority log has no WARN/ERROR markers. The second reviewer cleared the narrow checker correction and confirmed the scene/permission confounds. Neither reviewer operated the game.

## Lifecycle lead and next work

Untagged `Asset loaded` lines repeated near 1 Hz in the earlier opened-stand session. They were absent from the physically absent log, but also did not repeat in the restored, never-opened session (only one startup load). Code review identifies fresh typed menu lookup reloading its generated class, gated by a menu-likely-open flag. Visibility/tree readability alone may accept a detached surviving menu; a later row bind could also re-arm discovery. **This is an unproven lifecycle hypothesis, not an accepted fix or measured LoadAsset cost.** A targeted close/attachment reproduction is needed before altering discovery.

Next changes should reduce the measured complete pass and storage burst without retaining engine wrappers, skipping unknown state, or merely hiding the measurements. The base-manager shortcut was already rejected after missing reflected collection evidence and a native crash; do not repeat broad dumps or exchange a global walk for an equally expensive name lookup without evidence. Allocation/assignment evidence remains a correctness gate alongside performance work.

Final native status at 18:00:35: local authority yes, priorities and limits saved, two camps, complete/deduplicated storage, zero unknown scope/read failures and 561 excluded no-base loot objects. All 14 assignments remain unverified; singleplayer status still says synchronization connecting. Those limitations, item-specific production control, shared guild storage, multiplayer and the other reliability gates remain open. No publishing or comment replies occurred. Profiling and event tracing are off; recordings and restart helpers have ended.
