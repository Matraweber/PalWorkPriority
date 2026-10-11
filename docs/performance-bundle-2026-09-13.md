# Whole-mod performance bundle — September 13, 2026

This bundle follows the [12:45 native retest](deep-performance-retest-2026-09-13.md). The measured baseline still contains approximately one long Present interval per second and 74–77 ms worst intervals. The changes below remove redundant work and separate bursts. They cannot promise stutter-free gameplay: the required menu/camp sweeps and individual native asset loads remain indivisible, and native timing of this bundle requires a full restart.

## Cost inventory and disposition

Measurements refer to the preceding running generation, not this bundle. Durations are inclusive; parent/child rows overlap.

| Work / trigger | Baseline evidence | Bundle decision |
|---|---|---|
| Complete heartbeat | 70/74 ms worst | Input/default callbacks first; at most one eligible background job per beat. Maintain age-based fairness and an 8 ms soft admission budget. |
| Open-stand maintenance | 24.00/24.04 ms per refresh, about once a second | Separate from periodic and edit reconciliation. Preserve the one-second phase even after deferral; do not skip repaint based on instance names. |
| Fresh menu discovery | 10.17/10.26 ms per refresh and input discovery | Keep the verified class sweep. No safe faster UI-manager route has been established. FindFirstOf can select a hidden/wrong menu; stored wrappers and name-only freshness are rejected. |
| Roster traversal | 6.92/6.88 ms per lookup | Skip unsupported WidgetTree queries on exact native panels, skip child-count probing on exact UserWidget, and reuse row-owner reads within the current call. Unknown subclasses retain conservative checks. |
| Injected-label lookup | 3.53 ms per full grid in the longer sample | Store bounded scalar edge hints only. Re-read their ownership edges from each current cell; accept only the exact target, otherwise perform the complete bounded search. |
| Cell text/colour writes | 0.34 ms per full grid | Retain writes and successful-paint validation. This is not the dominant cost; name-only write caches risk blank/recycled cells. |
| Legend / checkbox hiding | About 0.15/0.14 ms per grid | Retain current correctness checks. |
| Rapid input burst | No input samples in latest idle recording; previous user-visible rapid-click defect repaired | Preserve every accepted directional edit and its FIFO order. Yield between actions after an 8 ms soft budget; reconcile once when the burst drains. Never collapse saturating cycles into a net direction. |
| Controller polling | 8.12 ms/s complete drive, 2 ms maximum | Reuse the positively identified local controller/viewport within a synchronous callback only. Entire 16 ms UI callback owns and releases that scope. Do not infer disconnected/keyboard-only use from quiet buttons; short taps must remain readable. |
| Complete scheduler | 27–29 ms mean, 45–47 ms maximum | Background admission separates it from stand maintenance. Individual pass body remains synchronous and conservative. |
| Camp enumeration | About 10 ms per pass | Keep fresh FindAllOf. Saved manager investigation found configuration, not a reflected live-camp container; its superclass walk crashed. Do not repeat it. Partial enumeration now remains unavailable. |
| Storage scan | 23–24 ms per scan; 8 scans / 24 passes after prior backoff | Preserve backoff and all unknown scope evidence. For unfiltered reads, skip class-name work after scope already excludes or cannot identify the model. Filters still run before scope. Zero GUIDs avoid unnecessary string/table assembly. |
| Owned network component | Positive children route in current SP | Avoid controller-name reads on the structural children route. Resolve work-progress manager lazily only when work IDs require it. Client/unknown role cannot fall back to an unowned world component. |
| Multiplayer transmitters and foreign senders | Current SP measurements do not price multiplayer traffic | Retain authorization, ownership and retry checks. Current two-guild/dedicated-server performance remains a separate required test; no estimated saving claimed. |
| Cold icon loading | Current stand test does not exercise cold picker | Add a 4 ms elapsed budget between loads, retaining twelve-load ceiling and eventual FIFO drainage. A single load or final learned-index write can exceed the budget. |
| Picker fill / full panel refresh | Current test is a closed-panel observation | Clear icon-frame wrappers before and after every public refresh, including errors. Delay a fill continuation until at least 16 ms after refresh completion. Never suppress mandatory maintenance updates. |
| Texture sweeps / cold sightings | Rare, synchronous calls; not measured in latest stand windows | Retain convergence, throttling and widget reuse. Cannot interrupt a single engine sweep; require cold/aged picker captures. |
| Startup icon probe | Diagnostic work, unpriced | Remove automatic startup probe. Delayed session work is guarded; ordinary diagnostics remain manual. |
| Logging | File 7 ms / 170 s; console 2 ms / 170 s, zero sink failures | Preserve failure reporting and aggregation. No speculative buffering rewrite. Expose storage class-read/skip counts from the existing diagnostic, without another scan. |
| Pure Lua ranking/GC/closure tuning | No current attributable hitch; rank memo previously measured and rejected | Do not reintroduce speculative caches or GC tuning. |

## Scheduling and input guarantees

The heartbeat takes a stable due snapshot. Input/role/default work runs before background work, then at most one background job runs. Background jobs are ordered by lateness and registration order; repeated coalesced requests retain their age. After 300 ms of budget-related lateness a job becomes eligible despite earlier input cost, preventing that cost alone from starving it. **This is not a hard 300 ms total wait bound when multiple jobs are already older**, nor an 8 ms bound on an individual native callback.

Maintenance, periodic passes, world-load passes and edit reconciliation use the same coordinator. Direct explicit diagnostic commands remain synchronous. There are still possible collisions with the independent 16 ms hover/fill callback and synchronous engine hooks; this does not establish one-job-per-rendered-frame scheduling. Fill-after-maintenance is spaced; fill-before-maintenance may still share a frame. Native captures must quantify what remains.

The input FIFO remains bounded at 128 accepted actions, including actions enqueued while draining. Completed actions are never replayed. Remaining old actions precede newly queued work, and UI/session invalidation prevents them reaching replacement contexts. A burst may now take several 100 ms beats to drain instead of blocking one callback; actual click-to-display latency and rapid-input feel need native validation. Persistence acknowledgements and network coalescing are retained.

World reset removes pending coalesced work and prevents old due snapshots from executing. Surviving ordinary one-shot deadlines retain their original elapsed time; delayed session startup work is separately guarded. Errors—including an error object whose string conversion fails—cannot poison later snapshots. Every controller memo is cleared at callback exit, including the fast UI exception path.

## Tree and storage proof boundaries

`ui_tree.find(root,target,valid,hint)` returns the current widget, completeness and an optional new scalar hint. Root/target names are capped at 2,048 bytes and paths at 255 edges. Hints are subordinate to exact positive current-tree discovery; they do not prove an old widget or a previous text write survived. Missing/failed replay falls back to the ordinary 256-visit search and clears the old hint when no new one is justified. Replay and fallback have separate bounds, so a failed hint can add work. The UI ownership registry bounds the number of stored hints, and reset clears them. No optional fused-label collector was retained.

The synthetic 101-child label fixture reduces full-name reads **103→2** and child reads **101→1** when replay succeeds. Those counts are not native milliseconds or a model of every installed cell. Existing same-name replacement, incomplete tree, duplicate scope, rebind and input regressions remain required.

The storage fixture reduces **534→0 class reads** for unfiltered zero-GUID holders while retaining all 534 unknown-scope failures. Container-module discovery still happens first; scenery does not become unknown storage. Include/exclude filters, deduplication, scope/read errors and content validation remain intact. This does not make the currently unverified stock complete or provide a guild-chest/output-control adapter.

## Review and verification

Three agents handled engine routes, tree lookup, and panel/icon costs; a fourth independently reviewed main/clock/session behavior. Parent integration and review covered shared callback scopes, tree hints, runtime boundaries and all changed code against the installed pre-bundle generation.

The independent coordinator review found three regressions in the first draft: reset shifted surviving one-shot deadlines, exceptional error formatting could leave stale due entries, and delayed refresh reset caused a skipped maintenance second. Saved `perf-bundle-review-before-20260913.txt` reproduces all three; `perf-bundle-review-after-20260913.txt` passes after correction, including the real main/clock composition with mocked native boundaries. Grid opportunities occur at beats 13, 21 and 31 in the delayed-first-refresh test.

Six new/extended focused suites reject the installed pre-bundle generation (`perf-bundle-baseline-results-20260913.txt`), then pass on the bundle. This is regression evidence, not live gameplay acceptance. The full gates compile 39 Lua 5.4 modules, run 41 Lua regression scripts and run the project's 102 Python unittest cases. Structural checking retains the existing panel warning at 194 top-level locals. The initial Python invocation used unavailable pytest; the documented unittest runner is the successful Python gate. No dependency was installed for that invocation.

Evidence prefix: `test-results/perf-bundle-`. Keep checked-source hashes, full gate logs, baseline failures, independent review repros and the subsequent staging receipt together. No commit, publication, hot reload, game change or frame recording was used to validate the source implementation.

## Required restart test

1. Verify process start after staging and all installed/runtime/pak hashes. Keep profiling off until the initial status and bounded stand diagnostic finish.
2. Confirm nine rows/117 cells, full priorities, close/reopen and same-name replacement behavior. Exercise rapid alternating clicks and direct 1–5/X while recording input callback durations separately from idle windows.
3. Record repeated open-stand timed windows and clean PresentMon clips on/off. Compare complete background jobs/batches, stand menu/roster/label means, worst input drain, queue response and frame distributions. Do not sum nested rows or treat counts-only zeros as timings.
4. Check scheduler count, storage scan count and new class-read/skip diagnostic with unchanged unknown scope. Verify no starvation and normal client edit deadlines under sustained input.
5. Exercise rules and several cold/warm picker pages: eventual completion, missing icons, close during fill, slow asset attempts, and all required layout boundaries. Record aged sessions and field/dungeon scenes separately.
6. Run listen/dedicated/two-guild tests and matched mod-absent captures before any claim covering multiplayer or all stutter. Manual assignments, storage completeness and output adapters remain open release gates.

No source-only result above establishes that all performance hits are fixed.

## Installed for next restart — 13:29

Checked installation completed at **13:29:05 Europe/Berlin**. Eight Lua files changed: `clock`, `icons`, `main`, `palapi`, `panel`, `session`, `ui_tree` and `ui`. All **39 installed modules** match the checked source, and all **39 previous modules** match the backup at `backups/deploy-20260913-132905-80979bf951094b4c82e044f2c94a9433`. All **88 source/test hashes** remain unchanged after the final checks.

The final Lua compile/41-script gate and structural checker pass; the 102-case Python unittest gate passes. User configuration, runtime and pak remain unchanged. Automatic and hot reload were disabled before PID 34308 started, profiling is off, no task frame recorder is active, and no hot-reload command was issued. **PID 34308 still runs the preceding generation; fully restart before collecting bundle measurements.**

Receipts: `test-results/perf-bundle-stage-before-20260913.json`, `perf-bundle-stage-result-20260913.json`, `perf-bundle-checked-source-20260913.json` and `perf-bundle-deploy-20260913.txt`. The evidence manifest hashes the completed gate/review/staging artifacts. Nothing was committed or published.


## Native follow-up

[September 13 restart/input/panel retest](performance-bundle-retest-2026-09-13.md) verifies PID 9460 running the installed bundle. Stand and combined-callback costs improve; repeated stand hitches, input lookup costs, cold icon spikes and panel host-resolution costs remain. User confirms reopening and rapid input. Profiling is off after the test. See the report for exact windows, the retained 160 ms frame outlier, independent-review limits and remaining gates.
