# Roster patch: native restart verification — September 12, 2026

**The stand grid now draws and survives one close/reopen. Recurring long Present intervals remain.** This is a bounded native rendering result, not full release acceptance.

## Runtime and lifecycle evidence

New Palworld Shipping PID 32480 started at 19:16:13 local, after the checked 19:12 deployment. All 39 installed modules and Info.json match that staged build; final hash readback also matches. Version 0.5.0-rc1; UE4SS 3.0.1 Beta 2281fa31; game Win S v1.0.4.102642. Native scoped diagnostics exercise the new `stand_cells` path, beyond a version string alone.

Initial screenshot00333 shows nine rows with 33 colored numeric priority labels and preserved incapable-work dashes/battle checkboxes. The agent independently confirmed alignment without obvious duplicate labels. Anubis displays Handiwork 3, Mining 1, Transporting 2; its separate 6/6/4 values are suitability ranks, not conflicting priorities.

Both initial and post-reopen diagnostics report **117 current scoped cells**, owner traversal **77/512**, roster traversal **909/4000**, no refusal or budget exhaustion. The formerly blocking header prompt remains in the whole diagnostic tree but is correctly outside the editable roster search. `cells via tree` counts successful discovery calls, not rendered labels; 117 widgets is not 117 numeric priorities.

After all recordings ended, the user closed the stand, waited five seconds and reopened it, reporting that the numbers returned. Screenshot00334 independently confirms that view. The current menu's instance path changed; captured row-binding total rose 9→18, and the new counts-only window contains nine new binding callbacks. This supports one genuine menu reconstruction/reopen without losing or duplicating visible numbers. Rapid edits, X persistence, many repeated cycles, controller navigation, pause/inventory/map/photo-mode handoff and other layouts are not established by this test.

## Frame recordings

PresentMon 2.5.1, exact PID 32480, five-second delay followed by 60 seconds, no input tracking, no elevation prompts. Single unchanged DXGI swapchain in each capture, strictly increasing timestamps and duration agreement within 0.01 ms. All samples retained; no screenshots or diagnostics within recording windows. These are application Present-call intervals, not physical displayed-frame timing. [Metric definitions](https://github.com/GameTechDev/PresentMon/blob/v1.9.2/README.md#csv-columns).

| Profiling | Presents | Mean interval | p99 | Worst | Intervals >33.33 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Off | 8,606 | 6.97 ms | 9.47 ms | 82.81 ms | 54 |
| On | 8,861 | 6.77 ms | 9.42 ms | 80.77 ms | 52 |
| Off, repeat | 8,858 | 6.77 ms | 9.32 ms | 84.00 ms | 54 |

A common fixed 45-second interior (recorder seconds 15–60) contains 39 / 39 / 41 intervals over 33.33 ms; worst 82.81 / 80.77 / 81.47 ms. Full recordings remain available. The recurring spikes survive disabling profiling.

![Three recordings of the repaired stand](../test-results/roster-live-frame-times-20260912.png)

Live daylight, simulation and animations changed; Anubis remained selected in the before/after screenshots. Foreground focus was not independently recorded. No mod-absent baseline or precise mapping between Lua clock and Present timestamps exists. This does not quantify pure profiling overhead or attribute a particular Present interval to a particular callback. The earlier broken build/session is a descriptive comparison, not a controlled baseline.

## Inclusive mod costs

Profiling window 19:19:29–19:20:39, 70 seconds. Clock resolution remains unmeasured; zero durations can be below resolution. Parent/child rows overlap and must not be summed.

| Scope | Timed samples | Mean | Worst |
| --- | ---: | ---: | ---: |
| Complete stand refresh | 66 | 28.530 ms | 31 ms |
| Complete scheduler | 6 | 42.667 ms | 44 ms |
| Storage, within scheduler | 6 | 22.667 ms | 24 ms |
| Camp enumeration, within scheduler | 6 | 10.333 ms | 11 ms |
| Complete pad drive | 3,482 | 0.311 ms | 3 ms |
| Complete clock batch | 659 | 3.240 ms | 73 ms |

The previous broken session averaged 37.474 ms per stand refresh; this session's 28.530 ms is about 24% lower, while now drawing labels. It remains a substantial one-second-cadence callback. Complete batches reach 73 ms, consistent with stand and scheduler costs occurring together; exact attribution of recorded frames remains unproven. Successful tree-discovery count was 66; no unavailable-tree row appeared during the timed window.

Authority reports yes with two camps/14 Pals; saved priorities and limits report saved. **All 14 assignment/manual states and storage remain unverified, with zero permission requests sent.** The planner's `fenced:` text does not prove permissions were applied. The host status still prints synchronization connecting; this is not multiplayer acceptance. No new WARN/ERROR was found in the captured current-session mod log. Absence of errors does not establish correctness beyond the exercised paths.

## Next measurements and remaining gates

Agent and coordinator agree the next performance change should be instrumentation only: split current-menu lookup, owner discovery, roster traversal, legend work and complete cell processing. Keep the complete-refresh timer and account for residual time; collect examined/rendered/skipped/failed and reused/new-label counters without per-widget logging. Separate refresh and input invocations. If cells dominate, then split label resolution from native writes. Preserve current-call object resolution, completeness checks and rendering behavior.

No source code was modified or deployed during this retest. Profiling is off; all three recorders have exited; the observer agent is closed. Assignment/storage/output adapters, multiplayer, full UI lifecycle and absent/present performance gates remain open. The corrected stand display is useful progress, not a shippable reliability-release claim.

[Raw/normalized frame evidence](../test-results/roster-live-frame-evidence-20260912.json) · [Timing report](../test-results/roster-live-profiler-end-20260912.txt) · [Reopen result](../test-results/roster-reopen-result-20260912.txt) · [Reopen tree](../test-results/roster-reopen-tree-20260912.txt) · [Runtime identity](../test-results/roster-restart-identity-20260912.json) · [Artifact hashes](roster-native-evidence-2026-09-12.json).
