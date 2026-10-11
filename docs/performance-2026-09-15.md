# Performance work and new reports — September 15

Unpublished 0.5.0-rc1. Game now visibly reports **1.0.5.102999**, so prior 1.0.4 timings are historical context, not a matched baseline. See the [new comment and bug ledger](comment-update-2026-09-15.md).

## Stand batch-child experiment

**Final disposition: rejected and removed from active source.** The discussion below describes the archived experiment, not an available command in the final candidate. Its four source/test files are retained in `test-results/rejected-stand-bulk-20260915/`.

The measured row-ownership/checkbox traversal remains a recurring cost. UE 5.1's local `Runtime/UMG/Public/Components/PanelWidget.h` declares BlueprintCallable `GetAllChildren`; its implementation returns slot contents in order. This can replace repeated GetChildAt calls on exact known panel classes. It does not justify omitting ownership, uniqueness, completeness or current-widget checks.

The experiment is default-off, controlled by `pwp standbulk on|off`. `pwp standbulk compare` performs two complete read-only walks in one game-thread callback and compares ordered cell names; it restores the prior mode even after an error. The comparison itself is extra synchronous work and must not run during frame recordings.

The optimized route checks an independently read child count, handles Lua arrays/RemoteUnrealParam and TArray iteration, validates every returned child, and falls back to indexed reads on a failed/partial batch. All wrappers are confined to the synchronous collector. Generic find/hint traversal is unchanged. Additional validity checks are intentional and their cost must be included in native measurements.

Regression coverage includes order, nine rows/117 cells, missing/extra/throwing batches, failed indexed fallback, invalid/replaced widgets and duplicate checkbox bars. The synthetic nine-row fixture reduces indexed child calls from 136 to 10 while adding 10 batch calls. This is call-count evidence, not native milliseconds.

Early native attempts are **not performance evidence**:

- PID 43824, 22:07:58: both routes found 117 cells, but all 110 batch attempts fell back. The apparent 9 versus 6 ms comparison is noise/warmup of the old path, not a speedup.
- PID 49044, 22:10:31: accepting the returned Lua table without unwrapping its entries yielded an incomplete result after one panel. No editable targets were returned by that probe; default mode remained off. The next candidate unwraps returned parameters and validates the batch before acceptance.

Deployment/test receipts and raw comparisons are under `test-results/stand-bulk-*-20260915.*`. Two earlier restarts used the checked AHK workflow; process replacement and the visible stand were verified. No settings or priorities were edited by the comparison command.

## Catalogue-search review

The new Nexus abort report is not reproduced. Independent review found that typed search indexed every catalogue item's localized name before the picker discarded non-job/internal/variant IDs. Show-all already applied a scalar eligibility check earlier. Native GetItemName/FText conversion and asset loading remain possible abort boundaries; pcall cannot contain a native access violation. The linked Cosmetic Outfits mod is a suspicion, not an established cause.

The chosen improvement is a separate filtered picker index, retaining the general catalogue API for other users. Eligible items retain exact/prefix/substring ranking; excluded items cannot consume the result cap. This narrows work and native exposure but does not establish compatibility with arbitrary modded items.

Steam Deck reports apply to the public 0.4.1 package. Candidate D-pad/A/shoulder/X stand wiring exists, but physical Deck/Steam Input acceptance is still pending. Cooling, fishing pools, manual assignments and actual output remain gameplay gates independent of UI performance.

## Completed comparison and final candidate

The third probe (PID 25524, 22:16:35) found the same ordered 117 cells in both routes. It reported 110 batch panels and no fallbacks for the roster scope. Those counters exclude menu-owner traversal and must not be described as full-walk counters. The probe always runs indexed first, so its 7 vs 6 ms result is warm-order confounded.

Four subsequent independent 30-second PresentMon captures used a five-second lead, the same nine-row stand scene, process, source hashes and profiling-on setting. Order was indexed / bulk / bulk / indexed. No commands or screenshots ran during recordings. Scene simulation continued, so these are short sequential observations, not a controlled attribution of each slow frame.

| Recording | Complete refresh mean / max, ms | Present interval p95 / p99 / max, ms | Intervals over 16.67 / 33.33 / 50 ms |
|---|---|---|---|
| Indexed A1 | 11.486 / 14 | 9.00 / 10.95 / 57.76 | 32 / 1 / 1 |
| Bulk B1 | 11.940 / 14 | 9.67 / 13.53 / 56.87 | 34 / 2 / 1 |
| Bulk B2 | 11.596 / 15 | 9.84 / 20.04 / 1629.75 | 56 / 4 / 4 |
| Indexed A2 | 11.490 / 15 | 9.59 / 11.44 / 30.70 | 33 / 0 / 0 |

Refresh reports cover longer profiler windows than the 30-second recordings; do not align their maxima to individual frames. Child regions are inclusive, not independent costs to sum. The B2 1.63-second gap is real in the present stream but its cause is not established by these captures. No frame-time benefit supports adopting the batch path.

Independent review also demonstrated a missing duplicate-child check: a batch `{a,a}` could suppress one target even if indexed reads returned `{a,b}`. This synthetic defect and incomplete diagnostic scope reinforce removal, rather than retaining an unused experimental path. Existing conservative indexed traversal is restored. Reproduction source and raw receipts remain available.

Frame analysis is reproducible with `python test-results/analyze-stand-abba-20260915.py`; outputs are `stand-abba-analysis-20260915.json`. It validates PID, one swap chain, identical module identities and profiling mode; excludes the first interval and uses linear percentile interpolation. `msBetweenPresents` measures application presentation intervals, not input latency or confirmed display time.

### Retained change: filter before localized picker indexing

`items.prepare_picker` now builds a separate index only for the picker's existing scalar-eligible IDs. It does not retain the eligibility callback or engine objects. Rejected IDs still count against the 128-ID/2-ms soft slice budget. Generic catalogue indexing is unchanged. Search result ranking remains exact, then prefix, then substring; eligibility precedes the 400-result cap. Catalogue replacement invalidates the picker result cache.

The predicate reuses current item/type heuristics; it is not a verified producer adapter. A native name lookup for an eligible item can still fail outside Lua error handling, and one native call can exceed the soft budget. This narrows unnecessary exposure but does **not** prove that Nexus bug 1133489 is fixed or that Cosmetic Outfits caused it.

Native combined-build smoke test at 22:21:44 returned 12 `ore` matches, with Ore first and icons visible. The filtered index took 15 ms total over 20 slices, maximum 2 ms. Initial catalogue capture/sort was a separate 16 ms call. AI Core's icon load took 15 ms and a panel refresh reached 18 ms. Earlier whole-catalogue readings were on different builds/scenes and are not a matched speedup estimate. Fewer native name lookups does not imply fewer ID-examination slices.

Final search-only validation: all 44 modules compile under Lua 5.4, all 58 regression scripts pass, structural checker passes. New search tests cover excluded resolver sentinels, general-catalogue independence, order, caps, preparation budgets, reset and incomplete data. Archive-only bulk tests are not part of the final active suite.

Checked final deployment at 22:26:34 preserved prior code/configuration in `backups/deploy-20260915-222634-0c7d0fd9159447ca9096163897c16dce`. Final source/installed hashes are recorded separately in `test-results/picker-filter-hashes-20260915.json`; the earlier combined manifest remains intact for the four recordings. No save, priority, production rule or package version was deliberately changed during this test.

### Final restart acceptance

The existing checked AHK restart macro replaced PID 25524 with **47304**, started 22:28:49. The 0.5.0-rc1 banner arrived at 22:28:55, world key at 22:29:12, and session 1 reported authority/settings available at 22:29:16. Visible game build remained 1.0.5.102999. Nine stand rows displayed their saved numeric and X values after load.

In the final build, `ore` returned 12 matches with Ore first; `wood` returned 6 with Wood first and the existing rule marker intact. Index preparation was **13 ms total across 20 slices, max 2 ms**. After the second query the slice count remained exactly 20: the completed index was reused. Initial catalogue IDs/capture/sort still cost 16 ms. The panel closed successfully afterward. Timing was disabled at 22:30:50. The bounded final session log contained no WARN/ERROR/Traceback; this is a smoke check, not crash-compatibility proof.

The same short acceptance window recorded a complete scheduler pass of 38 ms (three passes, average 26 ms), and new Wood icon loads of 14 and 15 ms. Those are remaining native spikes, not costs fixed by the search change. No target-application frame recording was run during this final interactive search smoke test, so do not infer a frame-rate improvement from its region timings.

Receipts: `test-results/picker-final-{open,mode,search,wood,perf,complete,lua,checker,deploy}-20260915.txt`, `picker-final-session-20260915.log`, and the final hash manifest. Public posting, version bump, and release packaging were not performed.

After the picker closed, the checked stand-opening AHK segment reopened the Monitoring Stand. All nine visible rows again showed numeric/X priorities, including Verdash's X Handiwork and Grizzbolt's X Transporting. The game was left on that stand with profiling off; no frame recorder remained active. Short injected V presses did not open this hold interaction; the existing 800-ms AHK segment did.
