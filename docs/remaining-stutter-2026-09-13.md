# Remaining stutter investigation — September 13

The local candidate remains **0.5.0-rc1, unpublished**. This work reduces specific costs; it does not establish a stutter-free release or close all user reports. See [reported-issue status](report-status-2026-09-13.md).

## Changes and regression evidence

- Stand maintenance and Production Limits rendering now use separate session-bound background jobs. A real main/clock regression failed with the combined callback and passes with separate callbacks; it also checks progress and session cancellation.
- Stand-only traversal consumes fresh panel-child edges directly, removing duplicate validity calls. The simulated nine-row tree returns the same ordered 117 cells and complete scope, with validity calls reduced from 1,454 to 759. Tests cover invalid edges, fallback, duplicates/cycles, budgets and poisoned replacement objects. No collectable wrapper survives the collector callback. Generic lookup and path hints keep their existing traversal.
- Show-all captures scalar catalogue IDs without building the full localized search index. Non-job IDs are rejected before name lookup. Search builds its complete index in slices of at most 128 names with a soft 2 ms budget; an individual native call can exceed that budget. Partial/unavailable results are never cached as a completed empty result. Retry is bounded to three attempts per world with five-second cooldown. Native row wrappers are consumed synchronously before slicing.
- The picker shows preparation/unavailable states; unknown storage is explicitly unavailable rather than a known zero-item inventory.
- Native testing exposed an obsolete 150 ms draw-age guard that discarded clicks despite the action dispatcher already reacquiring the current tree and checking epochs. Removing it passes a delayed-click regression; reinstating the old gate fails that regression. Missing current trees still reject the action. The final restart adds only this click correction to the first measured candidate.

All **40 modules compile under Lua 5.4**, the structural checker passes, and **50 regression scripts pass**. Two independent agents reviewed their owned changes and the integration. No production Python changed in this bundle; the preceding 102-test Python result is historical, not a new run.

## First native candidate

Installed at 15:31:46, PID **8892**, started 15:32:31.5474155+02:00. All 40 installed/source hashes matched. Runtime DLL SHA256 `21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8`; game Win S v1.0.4.102642. Stand had nine rows; saved priorities returned. The final click correction was not loaded in this process.

| Timed region | Previous candidate | New observations |
|---|---:|---:|
| Stand grid, including roster | 10.810–11.086 ms mean | 10.687 ms / 99 samples; 10.640 ms / 89 samples |
| Roster lookup | 6.962–7.095 ms mean | 6.838 and 6.820 ms mean |
| First catalogue draw | 54 ms, 51 ms before search | 32 ms, 31 ms before search |
| Complete panel refresh at that opening | 56 ms | 34 ms |
| First search indexing | Previously synchronous | 21 slices, 23 ms total, 1.095 ms mean, 3 ms maximum |

The roster gain is modest and is not established as causal by a matched A/B replay. Both stand scopes are inclusive. The first sample's `stand: complete refresh` includes closed-state calls, so the table uses `stand: grid refresh` for the open-stand comparison. Independent review corrected the earlier progress update: 11.582–11.867 ms were prior complete-refresh means, not grid means. The matching grid comparison only supports a small observed reduction.

The catalogue still contains **195 items across eight pages**; Ore search returns 12 matches with Ore first. Its synchronous capture was 12 ms inclusive: table lookup 2, native row names 1, row strings 3 and scalar sort 5 ms. These children overlap the parent; do not add the parent again. The rest of the first draw remains filtering/localization/rendering cost. Preparation finished before the post-command screenshot; no exact input-to-result latency was captured. The loading caption and continuation behavior have integration tests.

The mixed panel window separately recorded maintenance max 16 ms and panel-render max 34 ms. The prior combined 70 ms example is no longer the same callback shape. This does **not** establish that separate native timers cannot coincide in an engine frame. A later search-window icon-pump callback reached 20 ms; individual asset loading remains indivisible.

## Independent frame observations

Three sequential 60-second PresentMon recordings, five-second lead-in, one PID/swapchain, no input, diagnostic commands, screenshots or heavy tests during each clip. Every recorder exited before the next command. Stand position was verified before the sequence, not continuously observed. These are presentation intervals, not input latency or physical-display measurements.

| Clip | Mean | p99 | >16.67 ms | >33.33 ms | >50 ms | Maximum |
|---|---:|---:|---:|---:|---:|---:|
| Profiling on 1 | 7.532 ms | 10.240 ms | 64 | 4 | 0 | 49.909 ms |
| Profiling on 2 | 7.619 ms | 10.292 ms | 64 | 4 | 0 | 49.389 ms |
| Profiling off | 7.339 ms | 10.651 ms | 61 | 3 | 1 | 50.299 ms |

Slow frames persist with profiling off. These results do **not** show an overall frame-time improvement over the preceding session: its means and p99 were lower. Live world activity, session age and other mods were not controlled. There is no mod-absent baseline or Lua/QPC clock alignment, so individual frames cannot be assigned to this mod from these clips alone.

## Remaining measured costs and acceptance gaps

Scheduler complete passes averaged **26.9–29.2 ms**, peaking **41–44 ms** in the stand samples. Camp enumeration averaged 10.1 ms; three storage sweeps averaged 21 ms each. Authority/component resolution were about 0.1 ms each. Next optimization must address verified camp/storage access or safely split the work with fresh evidence, rather than cache collectable wrappers or pretend unknown storage is known. The stand still adds approximately 10.6 ms when it refreshes.

Current gameplay evidence is incomplete: 14 assignments are unverified, existing worker-limit conflicts remain unverified, and zero-GUID storage observations prevent complete inventory proof. Correct permissions do not prove actual job selection/output. Dedicated multiplayer, original Escape/photo-mode reports, clean installation and broader display acceptance remain open in the report ledger.

Raw evidence lives in `test-results/remaining-stutter-*`: separate stage/process identities, compiler/checker output, native samples, recorder receipts, raw/normalized CSVs and frame-analysis JSON. Each receipt identifies which candidate was loaded. No publish or commit was performed.

## Final click-correction retest

Checked installation at 15:42:44; identity receipt stamped after hash verification at 15:43. PID **42972** started 15:43:26.4438797+02:00 and loaded the final 40-module generation. The only runtime delta from PID 8892 is the removed click-age gate in panel.lua.

Real mouse clicks on **Add, Show all, Next, Previous and Close** each activated their intended control on the first attempt. Show-all again contained 195 items; page one and two completed their icons, and warm return showed the correct first-page icons. The final cold draw took **36 ms** (33 ms before search), complete refresh **38 ms**. Its catalogue capture was 13 ms inclusive. First Ore search used **20 slices, 20 ms total, 1 ms mean and 2 ms maximum**, returning the same 12 matches. Search was invoked through the developer filter command, not a measured keyboard-to-display test.

The panel's Close button left the stand visible. Escape then closed the stand; after a six-second wait, reopening restored all nine rows and saved priorities. This is narrow close/reopen acceptance, not the original Escape-while-editing crash scenario.

A final **profiling-off 60-second stand clip from PID 42972** recorded 8,371 intervals: mean **7.165 ms**, p99 **9.744 ms**, **62 >16.67 ms**, **3 >33.33 ms**, none >50 ms, maximum **47.086 ms**. The same capture controls and attribution limitations apply. This verifies the installed revision still has periodic long frames; it does not establish a stutter-free build.

At 15:50:07 all 40 source/installed hashes matched, no recorder remained, profiling was off, and the final session had 35 tick lines with zero priority.log WARN/ERROR lines. The sampled UE4SS tail contained no Lua error/access-violation matches. Status reports authority yes and priorities/limits saved, but **548 zero-GUID scope failures** now prevent storage verification. The generic synchronization status still says connecting on this solo authority; this is not a completed multiplayer test. The final mixed window's scheduler mean was 32.909 ms, maximum 46 ms. Game remains running with the stand open.
