---
date: 2026-09-13
tags: [storage, performance, limits]
status: evidence
---
# Storage scheduling and dropped loot — September 13

Related: [storage-scope-2026-09-13](storage-scope-2026-09-13.md) · [g5-performance-2026-10-19](g5-performance-2026-10-19.md)

Local **0.5.0-rc1**, unpublished. The repeated native test supports separating storage work from scheduler passes. It does **not** establish that remaining stutter is fixed.

## Implementation and safeguards

In global/all-loaded-guild-bases mode, an established, verified storage snapshot can now be refreshed through the clock's separately budgeted background queue. Refresh is eligible up to two seconds before the existing expiry. The next scheduler pass groups the scalar snapshot using fresh camp/guild identities. Camp-local mode keeps its existing path.

`storage_prefetch.lua` retains only cloned scalar tables, identities, filters and timestamps. It retains no Unreal wrappers. Current authority, session guards, applicable guild limits/panel interest, filter signatures, interest expiry and original sample age all gate use. Resets discard pending results. A newer failed read supersedes an older verified result; incomplete candidates have the existing five-second retry age, not the normal 30-second cache age. Invalid/expired candidates fall back to the existing inline reader.

`pwp prefetch on|off` is a protected, session-only developer comparison switch. Default is on; it changes no saved player settings. Both modes retain the new cheap eligibility timer. Actual storage enumeration and traversal now have separate inclusive timing rows; they must not be added to their enclosing storage/callback totals.

This separates bursts, rather than speeding up the indivisible storage scan. It can slightly increase scan frequency because refreshing starts earlier. The first unseeded or incomplete read can still run inline.

## A reliability problem found before recording

The previous PID 16836 developed five zero-base-ID `PalMapObjectDropItemModel` instances while running. Its panel changed from complete stock to **Unavailable**. A restart into PID 36916 retained four such objects. Prefetch correctly refused to arm on incomplete stock, so those sessions could not test the intended performance path.

The exact dropped-item class was added to the existing authority-only no-base-loot set. Exclusion still requires a successful, strict four-integer zero GUID on that scan. The same class with a positive base ID remains counted; missing/malformed/throwing reads, unknown Blueprint types, stations and guild chests remain unknown. This is **game-assigned base stock**, not a claim about physical distance or permanent ownership.

The extended regression fails before the change specifically on DropItemModel. It covers zero→nonzero→zero, role/session resets, scoped quantities/counts, malformed IDs and filter/unscoped diagnostic behavior. All **53 Lua regression scripts pass; all 42 modules compile under Lua 5.4**. The structural check passes (panel: 193 top-level locals). Prefetch regressions also use the real clock and scheduler; the previous scheduler fails the recurring-scan separation case. Two earlier review findings—newer failure precedence and incomplete candidate expiry—were fixed before installation. Independent review cleared both the prefetch implementation and the narrow dropped-loot extension.

## Installed identity and stock evidence

Final checked deployment: `deploy-20260913-171055-9bf39b2e1c9a491bbc39a03f0b7ab21f`; previous code/configuration preserved by the installer. Final **PID 40108**, process start **17:11:42**, banner **17:11:48**, world key **17:12:07**, session-1 authority ready **17:12:12**. Game **v1.0.4.102642**, UE4SS beta **2281fa31**. All 42 source/install hashes were checked before captures, and each capture revalidated those hashes and the process start time. Identity and recorder arguments are retained under `test-results/storage-prefetch-*20260913*`.

- **17:12:28:** complete/deduplicated storage, zero unknowns/failures, 556 excluded no-base loot objects. Independent positive-base projection matched every item quantity and container count: 41 + 114 scoped holders, including 53 scoped dropped-item holders.
- **17:19:54:** the second comparison also matched, with 39 + 113 scoped holders, 50 scoped dropped-item holders and the same 556 exclusions. Both censuses had no traversal failure, truncation or ownership conflict. Each comparison uses two successive reads, **not an atomic snapshot**.
- **17:20 visual check:** Production Limits displayed Wood **38,800 = 18,667 + 20,133** and Stone **40,366 = 30,619 + 9,747**, with the saved legacy group limits intact.
- Through **17:20:46:** 49 completed ticks, no priority-log WARN/ERROR, profiler off, no own recorder or restart helper. These health checks do not prove actual assignment or output behavior.

## Repeated native comparison

Order: **off, on, off, on**, same PID, stationary at the stand, all menus closed, no inputs during recordings. Profiling was on in all four clips. Each PresentMon 2.5.1 recording has a five-second lead and roughly 60 seconds of valid present intervals. One process/swapchain per clip, positive monotonic intervals, timestamp-to-duration agreement within 0.01 ms. No synthetic scans, screenshots, tests or agent analysis ran during the recordings.

| Mode | Profiler window | Complete scheduler samples; mean / worst | Full clock batch worst | Storage samples; mean / worst | Background scans / adopted snapshots |
|---|---:|---:|---:|---:|---:|
| Off 1 | 95 s | 9; 27.33 / 41 ms | 41 ms | 3; 20.33 / 21 ms | 0 / 0 |
| On 1 | 98 s | 9; 19.22 / 22 ms | 23 ms | 3; 21.33 / 22 ms | 3 / 3 |
| Off 2 | 92 s | 8; 26.50 / 41 ms | 41 ms | 3; 20.67 / 22 ms | 0 / 0 |
| On 2 | 86 s | 8; 20.50 / 23 ms | 23 ms | 3; 21.67 / 23 ms | 3 / 3 |

The full batch maximum fell **41→23 ms (about 44%)** in both pairs. Storage still costs 20–23 ms; roughly half is model enumeration and half traversal. Background refresh and pass work ran as separate clock jobs. Three scans occurred in each observation window, but unequal windows and early refresh mean this is not proof of identical long-run scan frequency. Inclusive batch cost per second was **2.95, 2.79, 2.70, 3.07 ms/s**: no total CPU-cost reduction is established.

| Mode | Frame intervals | Mean | p99 | Worst | Above 16.67 ms | Above 33.33 ms |
|---|---:|---:|---:|---:|---:|---:|
| Off 1 | 10,105 | 5.936 ms | 7.817 ms | 47.795 ms | 10 | 2 |
| On 1 | 9,770 | 6.139 ms | 7.974 ms | 42.695 ms | 10 | 2 |
| Off 2 | 9,604 | 6.245 ms | 8.075 ms | 46.822 ms | 8 | 2 |
| On 2 | 12,226 | 4.906 ms | 6.535 ms | 45.153 ms | 10 | 1 |

No clip had an interval above 50 ms. These clips show **no convincing broad frame-tail improvement**: totals above 16.67 ms are 18 off versus 20 on; above 33.33 ms are four versus three. **On 2 contains 55 PresentMon `Dropped=1` records, versus zero in the other clips. They remain included in the present-interval statistics; they are not omitted analysis rows.** The lower average in On 2 must not be credited to the mod or treated as smoother displayed output—the world transitioned toward night and normal activity changed. The new scheduling is retained for the repeated, smaller measured mod burst, not a claim of higher FPS or eliminated stutter. The independent results reviewer confirmed the narrow conclusion and identified this dropped-present caveat.

Profiler windows include lead/readback gaps and are longer than frame captures. There is no precise Lua-to-QPC alignment, so individual long frames are not attributed. Timings are inclusive; native resolution probing remained unmeasured and zero rows do not establish zero cost. No absent-mod or profiling-off control was run in this experiment. Present intervals are not physical-display or input-latency measurements.

## Remaining work

The next performance target is the remaining complete-pass/camp-enumeration cost, with explicit event/frame correlation before choosing another change. The individual storage scan still needs a verified safe narrower engine route to become shorter; replacing it with retained wrappers is unsafe.

Shared guild-chest coverage, two guilds, host/client transitions, camp-local native behavior, controlled quantity/ownership changes, actual assignments and item-specific output control remain release gates. Fourteen assignments still report unverified. The diagnostic status also continues to report synchronization connecting on this singleplayer host; that is not accepted multiplayer evidence. No release or public reply was made.

During cleanup, Escape closed Production Limits and also opened the vanilla Options menu. A second Escape returned to gameplay. This reproduces the still-open key-consumption issue; no crash occurred. The Monitoring Stand was subsequently reopened for the user. It is not counted as an accepted lifecycle test.
