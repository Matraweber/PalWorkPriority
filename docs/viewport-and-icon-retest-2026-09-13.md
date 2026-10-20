---
date: 2026-09-13
tags: [stand-ui, panel, performance]
status: evidence
---
# Viewport and icon investigation — September 13, 2026

Related: [icon-prototype-2026-09-14](icon-prototype-2026-09-14.md) · [widget-spec](widget-spec.md)

Continuation of the [13:29 bundle retest](g5-performance-2026-10-19.md). This is an unreleased reliability candidate, not evidence of a stutter-free mod.

## Cause and verified improvement

`overlay.resolve_owned` reacquired the panel with `StaticFindObject` on every refresh. The safe string-only ownership model avoided stale wrappers but still paid for a global UObject lookup. In PID 5436, 810 root resolutions averaged 12.646 ms; rules refreshes averaged 13.841 ms over 183 seconds.

The current viewport can return fresh top-level UserWidgets via the reflected `UWidgetBlueprintLibrary.GetAllWidgetsOfClass`. Native probes verified its output and the panel's exact instance path. The first diagnostic failed because the array wrapper was not handled correctly; that failed reading was not treated as a valid timing result. Top-level queries then returned one OverallUILayout or two widgets including our panel in 0–1 ms. Enumerating all 1,299–1,345 widgets still took 8–10 ms, so that broad route was not substituted for the stand scan.

The attached panel now uses the fresh viewport query and exact instance-path comparison. It retains no generated class or widget between callbacks. Unavailable, partial or ambiguous viewport results are discarded; the existing fresh exact-path lookup is an independent fallback, including for detached panels. The fallback does not accept a cached or partial viewport result.

PID 38720 started at 14:29:01 after the 14:28 checked stage; all 40 installed hashes were verified. In a 95-second rules-panel window, 436 refreshes averaged **1.956 ms** and their root resolutions **0.693 ms**. Stand refreshes remained **20.655 ms**, including **10.195 ms** menu discovery and **6.655 ms** roster discovery. Timings are inclusive and must not be summed as independent work. The world continued changing naturally, so the windows are not a controlled whole-game speedup experiment.

## Icon demand path

Cold icon requests now enter the FIFO. Each fresh `LoadAsset` result is passed immediately to the existing pin callback, which transfers ownership to an engine brush. Pinless recovery reacquires fresh textures under the same load allowance. Ordinary requests no longer need the full Texture2D sweep. Rare missing-name discovery retains a deferred, throttled native scan; its indivisible duration is not bounded by the scheduling budget.

Native first-page, second-page and return-to-first-page browsing produced correct settled icons. Over the mixed 136-second browsing window: 60 `icons.get` calls took 1 ms total; 41 pump callbacks averaged 8.561 ms, with a 34 ms maximum. A single PalSphere load took 31 ms. The twelve-load ceiling and 4 ms allowance only stop subsequent loads; they cannot interrupt one native call or its pin callback.

Two additional issues were reproduced during that test: the first picture automatically ran a four-icon diagnostic unrelated to the requested page, and reused images retained old-page icons until their new token received a load allowance. Both were corrected in the final candidate and retested below. The initial catalogue build also spent about 50 ms before the search control: that cost is still open and must not be attributed to icon lookup alone.

## Independent frame captures

Two sequential 60-second PresentMon recordings, no overlapping recorders, no commands or UI input during the capture interval. Rules panel over the nine-row stand; layout was verified after on1 and before off1, not continuously. No mod-absent baseline or Lua-to-QPC correlation exists.

| Capture | Mean ms | p99 ms | >16.67 ms | >33.33 ms | >50 ms | Maximum ms |
|---|---:|---:|---:|---:|---:|---:|
| Profiling on | 9.275 | 16.086 | 64 | 11 | 0 | 49.632 |
| Profiling off | 7.505 | 10.606 | 64 | 3 | 2 | 60.451 |

The recurring bump remains. These naturally changing windows do not isolate profiler overhead, and present intervals are not input-to-display latency.

## Evidence and remaining work

Receipts and raw data are under `test-results/`: `lookup-probe-stage-20260913.json`, `icon-lookup-stage-20260913.json`, `viewport-stage-20260913.json`, `viewport-restart-identity-20260913.json`, `lookup-native-probe1/2-*`, `lookup-native-tree-probe3-20260913.txt`, `icon-only-native-profile-20260913.txt`, `viewport-native-rules-on-20260913.txt`, `viewport-icon-page2-profile-20260913.txt`, `viewport-icon-final-profile-20260913.txt`, and `viewport-restart-{on1,off1}-*`. Raw frame captures have normalized tables, metadata, hashes and consistency checks. All recorder processes exited before post-capture commands.

The user's desktop restart recording was inspected before execution. A checked copy omits its accidental final F8 (which opened another mod's breeding overlay). Fixed timing does not prove world readiness; every restart is verified against a new process, loaded-world evidence and installed hashes. A short checked copy of its V-key action holds the key long enough to open the stand after loading. The original desktop file is unchanged.

## Final typed stand query and acceptance sample

The broad all-UserWidget query was rejected for the stand: it still traversed over 1,300 widgets. A bounded walk from OverallUILayout also did not find the stand within its 256-node budget. The successful native probe instead reacquired the exact generated stand class through its asset path and queried only that class. Three queries with the stand open returned one stand each in 0, 1 and 0 ms, including fresh `LoadAsset`; the old global discovery took about 10 ms. These are coarse runtime-clock measurements, not proof of zero cost.

`widget_lookup.remember_stand` retains only the discovered class path and full-name strings. Every later query reacquires and verifies the class, local controller and returned widgets. `ui.live_menu` preserves its visibility/tree/root validation. Missing, unreadable and empty query results fall back to fresh global discovery. Tests cover malformed/partial/ambiguous viewport results, independent exact-path fallback, nil/empty typed queries, all 117 cells, and same-name replacement widgets with poisoned old wrappers. No collectable wrapper is retained by the adapter across callbacks.

The final checked stage completed **14:48:56**, followed by PID **20272**, started **14:49:41**. All **40 installed Lua hashes** match the stage receipt. Before installation, all 40 modules compiled with Lua 5.4 and **47 Lua regression scripts passed**; structural checking passed with the existing panel local-count warning. The **102 Python tests** passed earlier in this turn; no Python production changes followed. These are automated evidence, not blanket native acceptance.

Two clean stand-open profiling windows, without click commands, gave:

| Region / route | 110-second window | 83-second window |
|---|---:|---:|
| Complete stand refresh | 105 samples, mean 11.867 ms, max 19 | 79 samples, mean 11.582 ms, max 13 |
| Stand menu lookup | mean 0.657 ms, max 1 | mean 0.608 ms, max 2 |
| Roster lookup | mean 7.095 ms | mean 6.962 ms |
| Typed menu query | 105 calls | 79 calls |
| Global menu fallback | 0 calls | 0 calls |
| Complete scheduler pass | 10 samples, mean 27.700 ms, max 43 | 8 samples, mean 29.125 ms, max 42 |

Thus the observed complete stand refresh falls from roughly **20.7 to 11.6–11.9 ms**, while discovery falls from roughly **10 to 0.6–0.7 ms**. Different live windows do not establish an equivalent FPS or input-latency improvement. The roster and per-cell work remain significant. Stand controller polling also remains measurable at roughly 0.13–0.14 ms per complete drive (~7 ms per wall second while open); its nested key rows must not be added again.

Three sequential 60-second PresentMon clips on this final PID used the nine-row stand alone. Each recorder exited with `Stopped recording` before analysis, commands or the next recorder. No UI input or game commands were sent within a clip. The layout was checked before and after, not continuously; background world activity was uncontrolled.

| Final capture | Mean ms | p99 ms | >16.67 ms | >33.33 ms | >50 ms | Maximum ms |
|---|---:|---:|---:|---:|---:|---:|
| Profiling on 1 | 6.689 | 8.912 | 63 | 3 | 2 | 57.862 |
| Profiling on 2 | 6.565 | 8.816 | 64 | 3 | 0 | 47.512 |
| Profiling off | 6.793 | 9.394 | 61 | 3 | 1 | 51.041 |

The approximately once-per-second long-frame pattern remains, as do occasional larger spikes. Profiling off does not remove them. There is no Lua-to-QPC alignment or mod-absent baseline: these data do not assign a specific long frame to one callback and do not isolate profiling overhead.

## Reopening and icon acceptance on the final candidate

The stand was closed, left closed more than five seconds, and reopened using the checked V-hold action. All nine rows returned visibly. The mixed close/reopen window recorded 18 grid refreshes / 2,106 cell refreshes (117 each), 19 typed menu queries, and zero global fallback. The fresh tree dump is preserved. This complements the replacement-wrapper regression; it does not prove lifetime safety across every engine transition.

Production Limits was then opened over the stand without changing a saved rule. The first and second catalogue pages showed blank image spaces while pending, then the correct 27 icons each. Returning to the first page showed already-applied correct images and blank pending spaces, then all 27 correct images. No old-page image/new-label mismatch was visible at the observed transition points. Final counters: **54 loads**, worst **1 ms**, average **0.4 ms**, zero still loading and zero missing icons. These are fresh mod-session loads, not guaranteed cold OS/engine caches. Warm return did not add asset loads. The automatic four-icon probe no longer runs.

The mixed 107-second panel window measured **36 pump callbacks, mean 4.889 ms, max 9 ms**; 54 timed `icons.get` samples fell below the clock's resolution. Complete panel refresh averaged **3.870 ms** over 453 samples, max **56 ms**. Root resolution averaged **0.643 ms**, including a 25 ms opening fallback. This corroborates the earlier viewport improvement without claiming every root resolution is bounded.

The first catalogue draw still spent **51 ms before search**, and the encompassing maintenance batch reached **70 ms**. That region builds the catalogue before normal per-tile work; it needs narrower timing of item data, localized names, filtering and sorting before selecting another optimization. A native asset load can also exceed the soft budget (31 ms in the earlier candidate), even though none did in these final two pages. Rare missing-icon discovery was not exercised in this final window.

Pressing Escape while the mod panel overlaid the stand closed both menus in this session. The stand was reopened afterward and its numbers returned. Do not treat this as proof of separate Escape consumption or full vanilla-menu handoff acceptance. Profiling is off and all recorders have stopped.

Final artifacts: `typed-stand-final-stage-20260913.json`, `typed-final-identity-20260913.json`, `typed-stand-final-checks-{lua,structural}-20260913.txt`, `typed-final-{on1,on2}-profile-20260913.txt`, `typed-final-{on1,on2,off1}-frame-evidence-20260913.json` with raw CSV/normalized tables/metadata, `typed-final-reopen-20260913.txt`, `typed-final-reopened-stand-tree-20260913.txt`, `typed-final-icons-{page1,page2,profile}-20260913.txt`, and `typed-final-status-20260913.txt`. The evidence manifest is `viewport-icon-final-manifest-20260913.json` under `test-results/`.

At 15:05:35, PID 20272 was still running; all 40 source/installed hashes still matched the final stage. The preserved session slice contains 88 tick lines and no WARN/ERROR/FATAL/Traceback lines. No recorder remained; the last profiler state was off. This log-health check is separate from the frame evidence. Turing independently reviewed the final small artifacts and agreed that targeted lookup/icon improvements are supported while the catalogue, scheduler and roster remain measured performance targets. Both reviews reject a stutter-free or release-ready conclusion.

Assignment/output, multiplayer, 546 zero-GUID storage observations, misleading unavailable-stock `0 items` text, broader UI transitions and release gates remain open. No commit or publication was made.
