# Stand search phase measurements — September 13

Local 0.5.0-rc1, unpublished. This change adds opt-in measurements, not a performance fix. The existing complete search and fresh-target rules remain unchanged.

## Implementation and checks

`ui_tree.stand_cells` accepts an optional measurement provider. `ui.lua` supplies it only while profiling is enabled. Four timed regions cover menu ownership, roster including rows, row ownership and checkbox contents; a fifth covers full-row fallback if used. No timing writes to disk occur in the traversal. Results/metadata remain unchanged and no provider or target is retained between calls. Nested totals are inclusive and must not be added together.

All 56 Lua regression scripts pass; all 43 modules compile under Lua 5.4 and structural checks pass. The added real-tree/real-profiler test requires completed timed samples (1 menu, 1 roster, 2 ownership, 2 contents in a two-row fixture), preventing count-only rows from masquerading as zero duration. Gate output: `tree-phases-lua-20260913.txt`, `tree-phases-checker-20260913.txt`.

Backup: `deploy-20260913-201953-a3ed3da2d8c345caa13ab01d3c10cbea`; receipt `tree-phases-deploy-20260913.txt`. Checked AHK restart replaced the earlier process with PID 31296, started 20:20:36. Gameplay/session-1 readiness and the visible open stand were checked. All 43 source/install module hashes match in `tree-phases-hashes-20260913.json`. Saved priorities were displayed; no priority edits were made in this measurement run. This is not a full persistence or input acceptance test.

## Repeated samples

No commands or analysis during each waiting window; readback/reset only between windows. Source reports: `tree-phases-sample1-20260913.txt` and `tree-phases-sample2-20260913.txt`.

| Region | First window: 67 refreshes / 71 seconds | Second: 78 refreshes / 83 seconds |
|---|---:|---:|
| Complete grid refresh | 10.731 ms/refresh | 10.551 ms/refresh |
| Roster lookup including all search work | 7.075 | 6.987 |
| Menu ownership | 0.791 | 0.897 |
| Roster including rows (nested parent) | 6.239 | 6.077 |
| Row ownership, all nine rows | 3.493 | 3.397 |
| Checkbox contents, all nine rows | 2.299 | 2.346 |

Row values above divide aggregate row time by completed refresh count (603 and 702 row samples respectively). They are not per-row times. All reported scopes are inclusive; the roster parent already contains row ownership and checkbox contents. Millisecond clock quantization and instrumentation overhead apply. The roughly 3.6 ms remainder between full refresh and roster lookup includes painting and loop work, not an independently measured exclusive scope.

The breakdown repeats: row-owner validation is the largest measured search component, rather than the menu-owner discovery. No full-row fallback occurred. This instrumentation-only experiment has no independent frame capture and establishes no speedup. Earlier event/frame overlap evidence remains in `stand-name-retest-2026-09-13.md`.

## Next investigation and boundaries

Investigate a verified reflected ownership route to the row's checkbox bar, or a cheaper complete enumeration route, before removing the owner walk. A property name alone does not prove a reflected/native contract; current ownership, duplicate scopes, cells outside the bar, incomplete reads, replacement widgets and fallback must still be addressed. Plain `GetWidgetFromName` is already rejected: the existing overlay investigation records it as unreflected C++ on this runtime. Do not repeat broad class/property dumps, retain wrappers, or exchange correctness checks for an epoch-only assumption.

End state: profiling off, stand open, authority yes, priorities/limits saved; cached storage complete/deduplicated with zero unknown scope/read failures. Fourteen assignments, three excess unverified workers and SP synchronization connecting remain unresolved. No commit or public release.
