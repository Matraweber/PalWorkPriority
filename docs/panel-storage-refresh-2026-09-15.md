# Panel opening and the scheduler spike — September 15

Unpublished 0.5.0-rc1. Work continues from `performance-2026-09-15.md`.

## Cause isolated

The previous acceptance sample recorded a 38-ms complete scheduler pass, including a 17-ms inline storage scan. Established storage prefetch already separates recurring scans. However, panel opening called `scheduler.forget_stock()` which discarded both quantities and the scalar background refresh plan. The next pass necessarily re-seeded storage synchronously.

A fresh baseline on PID 4756, started 23:28:09, reproduced the distinction:

| Observation | Scheduler samples, mean / max | Separate storage work |
|---|---|---|
| 49-s steady-state window starting 23:29:23 | 4, 20 / 22 ms | 2 background scans, 19.5 / 20 ms |
| 37-s window, panel opened 23:31:41 | 3, 26.667 / 38 ms | 2 total scans; only 1 in background |

The 38-ms pass was seven seconds after opening. Camp enumeration still costs about 10–12 ms per pass. These inclusive region timings overlap; do not add parent/child totals. The panel-opening window includes a short external Lua test run, so it is not a clean frame-performance comparison. Its routing evidence and repeated spike support the specific causal path; no frame-time/FPS improvement is claimed.

## Narrow change

Panel opening passes an explicit `true` to stock invalidation. Quantities and grouped-cache validity are still discarded. If prefetch is enabled, the established **scalar** plan is retained and marked for immediate refresh in the existing separately budgeted background queue. Older candidates and any in-flight publication are invalidated by generation. A fresh scheduler scan/adoption clears the request.

The current authority, local settings readiness, storage filters, TTL, interest and fresh camp/guild key checks still gate scan/use. No engine wrappers survive callbacks. Missing plans, camp-local mode, disabled prefetch, changed scopes or an earlier scheduler pass keep the prior synchronous fallback. First-world seeding is unchanged. Newer failed evidence overrides earlier successful quantities and uses existing bounded retries.

This splits work when the background job wins; it neither removes the storage scan nor guarantees that every opening avoids the combined pass. Cold panel creation, native assets, camp enumeration, baseline work and assignment correctness are separate open issues.

Tests added to `test_scheduler_storage_cost.lua` and `test_storage_prefetch.lua` fail before the patch and pass after. They cover background adoption, no duplicate inline read, inline race cancellation, newer failed evidence, bounded retry, reset/in-flight invalidation, missing plan, scope change and disabled prefetch. Before/after receipts are `test-results/panel-prefetch-*-20260915.txt`.

## Installation and first retest

Independent code review found no blocker. All 58 Lua regression scripts passed and all 44 modules compiled; structural checker passed. The new failure-precedence assertions also passed the focused suite. Checked deployment at 23:33:28 backed up prior code/configuration to `backups/deploy-20260915-233328-87b6b0010a094e9da0e76dce49633b6d`. All 44 installed/source hashes match in `test-results/panel-prefetch-hashes-20260915.json`.

The checked AHK restart replaced PID 4756 with **44368** (process start 23:34:15, mod banner 23:34:21, world key 23:34:39, session-1 authority/settings ready 23:34:43). The stand displayed saved numbers and X values. Game 1.0.5.102999; source version stays 0.5.0-rc1.

Panel opening at 23:35:19, measured for 55 seconds: five complete scheduler passes, mean **20 ms**, maximum **22 ms**. Both storage scans ran through the background callback (mean17.5/max19ms), and both candidates were adopted. No extra inline storage scan appeared. Afterward the rules UI showed Wood 39,876 and Stone 40,842 with the existing 30,000/35,000 legacy rules intact. These are displayed totals, not an independent physical inventory audit.

This supports separation of the previously combined work, not elimination of native scans or broad frame-time improvement. Different process age and continued simulation preclude interpreting the percentage reduction as a controlled FPS measurement. First-world seeding and a pass that arrives before the queued refresh still retain synchronous behavior.

Second opening at 23:36:33, measured for 71 seconds: seven complete scheduler passes, mean **19.429 ms**, maximum **21 ms**. All three storage scans ran in the background (mean18/max20ms), with three adoptions. Complete clock-batch maximum was **22 ms in both after windows**, versus38ms before. Across the two after windows, 12 completed passes and five storage scans support the routing change. Scan frequency/total CPU savings are not established by these unequal windows; the operation is moved, not removed.

Final full regression rerun: 58 scripts, zero failures. Final session priority-log audit from the 23:34:21 banner through23:37:44 found no WARN/ERROR/Traceback. Fourteen assignments and three workers above the staffing limit remain explicitly unverified in normal status; this optimization does not claim to solve them. Timing was turned off at23:37:44 and the panel closed. No frame recorder was started during this turn, no public posting/release was performed, and saves/settings were preserved.

The parallel search-crash investigation is recorded in [search-crash-2026-09-15.md](search-crash-2026-09-15.md). It found no reporter crash artifact or identifiable Cosmetic Outfits archive locally; additional native fault attribution would be speculative. Retain the previous filtered-index mitigation, and request the reporter's existing crash context/log plus exact triggering operation before choosing another compatibility patch.

Independent results review confirmed both sample counts and the narrow conclusion. Background jobs still run on the **game thread**, on separate clock beats. First-opening overlay host resolution separately reached23ms; the21–22ms scheduler/batch readings are not a bound on every UI action. The remote close receipt prints the old open state because closing is queued: subsequent native screenshots confirmed gameplay with the panel absent, followed by successful stand reopening through the checked AHK segment. Saved numeric/X priorities were visible again; profiling remained off.
