# Native stand retest — September 12, 2026

**Result: current installed grid still fails; the next source correction is tested and reviewed but not deployed.** Permanent frame-capture permission now works without elevation. Repeated long Present intervals remain with profiling disabled.

## Verified running state

Palworld Shipping PID 7180, startup 18:50:21 local; game Win S v1.0.4.102642; UE4SS 3.0.1 Beta 2281fa31. All 39 installed Lua files matched the checked September 12 installation at the start of this test. Installed main SHA-256 `62c48ca51c64551039e9a8a6e428415826a5056a282b334da124bf45ea1fe2f9`, ui_tree `e4181d275ebc572c151c59efc44987168b7532d1e173217e0996ed4459466885`.

Current Windows token contains Performance Log Users SID S-1-5-32-559. All three PresentMon recordings ran unelevated and exited on their 60-second timers. The recorder emits its limited-process-access warning when unelevated; this did not prevent exact-PID capture. No service, administrator membership or UAC change was added during this test.

The stand showed nine rows with vanilla checkboxes and the mod legend in screenshots 00330–00332. The repaired dump completed: 117 global cells exist, but the current reader refused the whole menu at `GetChildrenCount`, class `PalUIActionWidgetBase`, first refusal visit 230; total 1990/4000, **budget_exhausted=false**. This prompt lives under `Overlay_Guide_Change → WBP_PalKeyGuideIcon_C`, outside the roster. Increasing the traversal budget cannot fix it. The earlier text-leaf correction was insufficient for native painting.

The captured roster belongs to the menu's own tree through `CanvasPanel_18 → CanvasPanel_82 → CanvasPanel_PalList → WBP_PalCommonScrollList_PalList` (class `WBP_PalCommonScrollList_C`). Its tree contains `ScrollBox_0` and Pal rows.

## Independent recordings

Portable PresentMon 2.5.1, exact PID 7180, five-second delay then 60 seconds, input tracking disabled. All recordings contain the same single DXGI swapchain. Timestamp differences match `msBetweenPresents` within 0.01 ms. These are application Present intervals, not independently measured physical displayed frames. [Column definitions](https://github.com/GameTechDev/PresentMon/blob/v1.9.2/README.md#csv-columns).

| Capture | Presents | Mean | p99 | Worst | Intervals >33.33 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Profiling off | 8,286 | 7.24 ms | 10.09 ms | 95.57 ms | 56 |
| Profiling on | 6,758 | 8.88 ms | 12.01 ms | 92.39 ms | 57 |
| Profiling off, repeat | 9,019 | 6.65 ms | 8.91 ms | 93.03 ms | 56 |

A common interior window of recorder seconds 15–60 contains 42 / 42 / 43 intervals above 33.33 ms, respectively. It was selected identically without filtering by spike size; full data remain preserved. No screenshots or diagnostic commands ran within the recordings.

![Open stand frame intervals](../test-results/stand-retest-frame-times-20260912.png)

This establishes a recurring hitch pattern with profiling off/on/off. It does not isolate profiling overhead: daylight and simulation changed, foreground focus was not independently recorded, and there is no mod-absent baseline or precise Lua-to-PresentMon clock alignment. Do not assign individual frames to callbacks or call the build stutter-free.

## Inclusive mod timings

Timing window 18:55:59–18:59:49, 230 seconds, surrounding the middle capture. Parent/child durations overlap and must not be summed. Runtime clock resolution remains unmeasured; zero durations may be below resolution.

| Region | Timed samples | Mean | Worst |
| --- | ---: | ---: | ---: |
| Complete stand refresh | 213 | 37.474 ms | 41 ms |
| Complete scheduler | 21 | 43.190 ms | 57 ms |
| Storage within scheduler | 21 | 23.048 ms | 31 ms |
| Camp enumeration | 21 | 10.143 ms | 16 ms |
| Complete pad drive | 10,511 | 0.318 ms | 3 ms |
| Complete clock batch | 2,129 | 4.187 ms | 94 ms |

Every stand refresh reported unavailable cells. Authority reported yes, two camps, priorities and limits saved. Assignment/manual-state and storage verification remain incomplete; these costs include refusal/deferral paths, not a functioning scheduler/limits acceptance workload. Status still says synchronization connecting on the local authority; no multiplayer success is inferred. Profiling was turned off and all recorders exited before the final status/screenshot.

## Reference comparison

A read-only agent inspected both downloaded PalPriority 1.2.0 ZIPs, extracting four Lua files under ignored `test-results/reference-palpriority`; nothing was executed or installed. Its binding and text-placement patterns are already represented here. It discovers cells globally and retains widget wrappers, which we did not adopt. It supplies no verified manual/fixed-assignment identity, storage scope or item-output control adapter. No reuse license was present in the archives; this patch is independently implemented from the captured native tree, with existing README credit retained.

## Source correction and review

`ui_tree.stand_cells` now discovers exactly one captured named roster in the current menu owner's panel-child tree. That bounded owner pass never follows another widget's private WidgetTree, regardless of class suffix. Missing, unreadable or ambiguous scopes refuse. Only then does the reader traverse the roster completely within its separate 4000-visit limit. Unknown native widgets inside a searched scope remain errors. Generic cell/text lookup rules are preserved; no engine wrapper survives the call. Drawing, input and the diagnostic share this resolver, and diagnostics identify which scope refused.

The new integration regressions failed before the source patch in three cases: unrelated prompt blocking the grid, missing roster importing loose cells, and foreign nested roster cells being imported. After correction, all 39 modules compile in Lua 5.4; all 32 Lua regression scripts pass, including 33 stand integration cases; the structural checker passes. Additional tests cover ambiguous scopes, unreadable candidate identities, scope budgets, unknown internal widgets, zero reads of native private trees, and fresh same-name replacement without touching stale wrappers.

Independent review found an owner traversal loophole for non-_C native widgets and a duplicate-identity test fixture. Both were corrected; the reviewer closed both findings with no new issue in the changed code. Python tooling was unchanged; its prior 102-test pass is historical, not rerun evidence from this turn.

**Not installed while Palworld is running.** Next: close the game, recheck sources/backup/deploy, restart, open/close/reopen the stand, confirm visible numbers and complete scoped counts, then repeat frame recordings. Further native reader failures remain possible; assignment, storage, producer and multiplayer release gates are still open.

[Capture analyses and raw hashes](../test-results/stand-retest-frame-evidence-20260912.json) · [Native tree](../test-results/stand-tree-retest-20260912.txt) · [Mod timing report](../test-results/stand-retest-profile-end-20260912.txt) · [Final state](../test-results/stand-retest-final-state-20260912.txt) · [Source/test evidence](stand-retest-evidence-2026-09-12.json).

## Subsequent staging — 19:12, pending restart

The user clarified their preferred workflow: install checked Lua while Palworld remains open, then restart to activate it. This supersedes the close-before-staging step above. Both UE4SS reload switches were verified disabled in a settings file predating the running process; no recorder was active, and the two changed modules were already loaded. No reload command was sent.

All 100 tested source/test/tool file hashes were rechecked, and the installer compiled all 39 modules twice before replacement. All 39 installed modules and Info.json now match the tested source. The previous 39-module generation is verified in `backups/deploy-20260912-191209-ec3b97b7bad3428f8df60430f249ea98`; root configuration and pak are unchanged. PID 7180 had exited by the final process check; a new loaded generation has not yet been verified. **Files are installed; activation and native acceptance still require a full restart.** [Staging receipt](../test-results/roster-stage-result-20260912.json).

Subsequent restart PID 32480 verifies the installed generation, visible priorities and one close/reopen. Three further captures still show recurring long intervals. [Native restart results](roster-native-retest-2026-09-12.md) supersede the pending-activation state above; full release acceptance remains open.
