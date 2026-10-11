# Remaining stand and scheduler pauses â€” September 13, 2026

The [native retest](stand-cost-retest-2026-09-13.md) established user-confirmed rapid-click recovery, but measured stand refreshes around 27 ms, scheduler passes around 43â€“44 ms, and recurring 80â€“83 ms Present intervals. This follow-up reduces verified repeated work and improves the next measurement's breakdown. Native savings from the new code require a full restart; the earlier recordings do not measure these changes.

## Timing pattern

Analysis of the three existing sixty-second recordings gives these median gaps between long Present intervals:

| Capture | Above 33.333 ms | Above 60 ms |
|---|---:|---:|
| Profiling on, first | 1.065 s | 10.705 s |
| Profiling on, second | 1.069 s | 10.722 s |
| Profiling off | 1.067 s | 10.689 s |

These cadences correspond to the observed stand and periodic scheduler callbacks. The largest complete clock batches measured 74â€“77 ms, while their inclusive stand and scheduler children overlap that parent timing. This supports investigating those callbacks, but is not exact Lua/QPC event alignment or causal attribution of each frame. Other mods and live workload remain uncontrolled; no mod-absent baseline exists. Artifact: `test-results/deep-perf-cadence-20260913.json`.

## Row-owned priority lookup

The saved native tree contains nine `WBP_WorlSuitabilityPreference_PalList_C` rows. Each row's own tree contains a named `HorizontalBox_CheckBox`; sanity gauges and task/detail widgets own separate private trees. The old roster lookup entered those unrelated trees on every refresh and input action.

The new resolver finds the checkbox bar through current row-owned panel edges, checks its identity and duplicates, then searches every child in that editing scope. A complete unfamiliar row layout without the bar, or with cells outside it, uses a complete-row fallback. Incomplete owner/content reads refuse editable targets. Nested and sibling duplicate bars both refuse the result. Unknown widgets inside the editing scope retain the existing completeness rules.

All nested searches share the roster's 4,000-visit budget. The independent 512-visit menu-owner limit remains. Wrappers, paths and successful results are not cached between calls. Diagnostic metadata contains scalar counts only, including `row_scopes` and `row_fallbacks`.

A readable fixture returns the same 117 cells in the same order with **281 scoped visits versus 820 full-tree visits**. These are synthetic accessor counts, not native milliseconds. Ten focused cases cover target equivalence, unrelated private trees, missing and duplicate bars, unknown content, fallback layouts, replacement wrappers and budget exhaustion. The independent reviewer found a nested-duplicate hole in the first draft; `deep-stand-nested-before-20260913.txt` reproduces it and the corresponding after result passes. A second review found that the generic-row fallback also needed duplicate validation and that an empty guild grouping could incorrectly reset unknown-read retries. Both combinations fail before and pass after the final corrections (`deep-perf-review-before/after-20260913.txt`).

New inclusive timers separate cell refresh, label lookup/construction, text/colour writes, vanilla-checkbox hiding and legend refresh. They use the existing bounded profiler, add no engine queries and emit no per-cell log lines. Nested timings must not be summed. Profiling-on/off captures remain necessary to assess instrumentation effects.

## Storage scan demand and retries

The scheduler now asks whether **this camp's effective numeric limits** require storage, using the existing config/shared/guild merge and OFF-mask behavior. Another guild's rules no longer force a rule-free camp to scan or retain storage-dependent restrictions. A panel-requested read still publishes its real uncertainty; unknown diagnostic stock does not restrict a camp that has no applicable production limits. Unknown camp ownership cannot establish that no limits apply.

Persistent incomplete reads now retry after **5, 10, 20, then at most 30 seconds**, capped by any shorter configured TTL. Verified reads reset the retry count. Explicit cache, policy and session resets clear it, and zero TTL still forces scans. Cached incomplete results stay incomplete throughout; no scope or item quantity becomes known merely because a retry was delayed.

In direct-camp, shared camp-scan and guild-scope fixtures, this changes **13 scans over thirteen ten-second passes to six scans**, eventually settling at one per thirty seconds. A successful scan is recognized on the next retry, so the tradeoff is delayed recovery detection. Individual scan cost is unchanged. Twenty-four focused tests cover retries, rule layers, masks, X, verified recovery, forced scans, resets, clock rollback, mixed guilds, assignment uncertainty and pending writes.

The installed saved limits include Wood 30,000 and Stone 35,000 for one guild. Disk configuration says camp scope, while the earlier live status says global scope; file contents alone do not establish the in-memory settings. All three reader paths are tested, and the next native status must record the actual scope. The observed **533 readable zero-GUID scope failures remain unknown**. They are failed scope observations, not proven unique chests or safe-to-exclude scenery.

## Verification and next native test

The full candidate compiles **39 Lua 5.4 modules**, passes **35 regression scripts** including 39 stand-integration cases, and passes structural checking with the existing panel 194-local warning. Parent review checked the storage proof and invalidation paths; independent review checked the row-scoping boundary. No native job/producer adapter, storage exclusion or stale-wrapper cache was introduced.

Local evidence is under ignored `test-results/`: `deep-stand-scope-before/after-20260913.txt`, `deep-stand-nested-before/after-20260913.txt`, `deep-stand-ui-focused-20260913.txt`, `deep-storage-before/after-20260913.txt`, `deep-perf-full-lua-20260913.txt`, and `deep-perf-structural-20260913.txt`. The storage baseline uses the verified previously installed scheduler modules with the new tests, without modifying that installation.

After the next full restart:

1. Verify all installed hashes against the staging receipt and verify process startup is newer than staging.
2. With the stand open, run status and the bounded stand diagnostic before recording. Expect nine row scopes, zero fallbacks for the captured layout, and all 117 cells; verify visuals and one close/reopen.
3. Take repeated profiling windows long enough to observe the retry backoff settling. Distinguish scan passes from cached passes. Storage must remain unverified until the reader actually establishes completeness.
4. Repeat independent frame captures with profiling on/off. Check the approximately one-second and ten-second spike patterns; do not equate a lower average callback cost with stutter elimination.
5. Exercise rapid alternating clicks and direct number/X input. Verify preserved priorities, pending/error presentation and no new skips. Record actual input evidence separately from idle timing.

Broader assignment/output, multiplayer and UI-lifecycle release gates remain open. This investigation does not authorize publication.

## Checked installation — 12:39

Installed at **12:39:05 Europe/Berlin**, changing only `scheduler.lua`, `scheduler_storage.lua`, `ui.lua` and `ui_tree.lua`. All 39 installed modules match the final tested source, and all 39 previous modules match the backup at `backups/deploy-20260913-123905-df12286d106548d796bb69bf4248bd11`. User configuration, runtime and pak remain unchanged. All 74 source/test file hashes remained unchanged after the final full gates.

The independent review is closed after the duplicate/fallback and empty-grouping corrections; it independently reran the row-scope suite and all 24 storage checks. The parent reran all 35 Lua scripts and structural checking afterward. No Python production code changed in this follow-up.

PID 29584 is still the **previous loaded generation**. Automatic/hot reload were disabled before it started, profiling is off, all task recorders have exited, and no reload command was issued. A full user restart is required before new measurements. No commit or publication was made.

Receipts: `test-results/deep-perf-stage-before-20260913.json`, `deep-perf-stage-result-20260913.json`, `deep-perf-deploy-20260913.txt`, `deep-perf-checked-source-20260913.json` and `deep-perf-evidence-manifest-20260913.json`. The manifest hashes the final gate/installation artifacts. Nothing was installed during a recording.

## 12:45 restart: native results

[Completed native retest](deep-performance-retest-2026-09-13.md): PID 34308 loads the checked generation, all 39 hashes unchanged. Scoped discovery finds 117 cells with 639 roster visits, nine row scopes and zero fallback. Roster timing falls from 10.7 to 6.9 ms; stand refresh from 27.2 to 24.0 ms. Storage scans fall from every pass to eight of 24 timed passes, while unknown-scope evidence remains unknown. Scheduler mean falls to 27–29 ms, with 45–47 ms peaks retained. Clean frame captures still show 59/60 intervals above 16.67 ms per minute and worst 74–77 ms; profiling-off does not remove the hitches. Independent review agrees with these bounded conclusions. Profiling is off, all recorders exited, and this turn changed no installed code. One close/reopen and input exercise has been requested separately; broader release gates remain open.
