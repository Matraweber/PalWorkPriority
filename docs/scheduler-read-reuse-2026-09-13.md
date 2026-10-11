# Scheduler read reuse — September 13, 2026

Status: checked and installed locally; not published. This is a small accessor reduction, **not a demonstrated stutter fix**.

## Change and safety

The scheduler reuses the enable phase's fresh scalar permission observation for immediate final confirmation only when no native write was attempted anywhere in that Pal's pass and no request was pending. Withdrawal verification remains a separate fresh read. Attempted, failed, delayed and pending writes retain final native readback. Nothing is retained across callbacks.

The actual scheduler regression reduces an unchanged 14-Pal fixture from 70 to 56 permission-list reads. It fails on the previous source and passes on the new source. Poisoned replacement wrappers, X choices, withdrawals, enables, failed delivery, pending expiry and unreadable confirmation are covered. All 55 Lua regression scripts passed; all 43 modules compiled with Lua 5.4; structural checker passed. Turing implemented and Gauss independently reviewed; parent repeated gates before deployment.

Deployment receipt: `test-results/readreuse-deploy-20260913.txt`. All installed module hashes: `test-results/readreuse-hashes-20260913.json`. Backup: installed mod `backups/deploy-20260913-182120-1817e11f30e4485aaa322207d94feac0`.

Storage reordering was rejected: excluding no-base loot before module discovery would hide currently reported module failures. No storage semantics were weakened to obtain a lower timing.

## Restart and measurements

Restarted with the checked helper. New PID 38472 started 18:22:26; banner 18:22:32, world loaded 18:22:50. Saved stand numbers and X values remained visible. Both comparison scenes were closed after opening the stand. Runtime/pak unchanged; graphics-settings hash identical. The world continued to advance; the old process was older. These are observational comparisons, not controlled causal speedup estimates.

| Capture | Seconds | Frames | p99 ms | Worst ms | >16.67 ms | >33.33 ms |
|---|---:|---:|---:|---:|---:|---:|
| Before, profiling off | 60 | 11132 | 7.321 | 78.188 | 11 | 1 |
| After, profiling off | 60 | 11757 | 6.645 | 45.097 | 10 | 2 |
| After, profiling on | 90 | 17603 | 6.631 | 60.366 | 14 | 4 |

Source files: `test-results/correlation-readreuse-*-20260913.csv/json`; parent analysis `test-results/readreuse-analysis-20260913.json`. Recorder completion, one PID/swapchain and raw-QPC/duration consistency checked. Timings/events: `test-results/readreuse-perf-20260913.txt`, `test-results/readreuse-frame-events-20260913.tsv`.

The 127-second detailed window completed 12 scheduler passes and four deferred storage refreshes:

| Region | Inclusive total | Interpretation |
|---|---:|---|
| Complete scheduler | 268 ms | 22.33 ms/pass; worst 31 ms |
| Camp enumeration | 126 ms | 10.50 ms/pass |
| Camp roster | 100 ms / 24 camps | 8.33 ms/pass across two camps |
| Fence planning | 21 ms | 1.75 ms/pass across two camps |
| Withdraw / verify / enable-confirm | 4 / 1 / 3 ms | Small remaining permission cost |
| Storage | 80 ms | 20 ms/refresh; worst 22 ms |
| Storage enumeration / traversal | 39 / 41 ms | Components of the same storage total |

Nested rows overlap; never sum parent and children. Zero samples can be below timer resolution. Compared with the prior ~21 ms complete-pass sample, a full-pass saving is not established.

Two external nonce publications constrain the Lua/QPC offset to a 5.638 ms intersection, under a constant rate/offset assumption. In the 90-second traced capture, 11 of 14 slow frame intervals have possible overlap with recorded scheduler/storage events (8 scheduler, 3 storage). Three larger intervals (49.965, 41.211 and 60.366 ms) have no recorded event overlap. Events below 4 ms and uninstrumented game/mod work are outside that statement; correlation is not causation.

## Remaining work

The roster and fresh camp enumeration dominate scheduler cost. No verified live camp collection replaces the global scan. Do not repeat the prior unsafe superclass probe or store collectable wrappers.

The roster has two small candidates for a separate measured change: consecutive duplicate parameter validity checks, and duplicate successful species lookup for unnamed Pals. Their share of the 8.33 ms is unknown; preserve fallback/retry behavior and test fresh replacements before changing them. Instrument roster subregions if needed rather than assuming those calls explain the whole cost.

Authority was confirmed; priorities and limits reported saved; storage reported complete/deduplicated with zero unknown scope or failed reads. No PWP WARN/ERROR appeared in the captured restarted session. These are health observations, not complete gameplay verification: 14 assignments remained unverified, three unverified workers exceeded the staffing limit, and SP synchronization still displayed connecting. Those reliability gates remain open.

Profiling and frame-event recording were stopped after collection. No release or public replies were made.

Independent analysis agrees on all slow-frame/overlap counts, including +/-2 ms endpoint sensitivity (9.638 ms offset range). See `test-results/readreuse-independent-analysis-20260913.json`. The table above uses nearest-rank p99; the independent interpolated p99 differs slightly. PresentMon dropped rows (5/19/14) are retained; none exceeds 16.67 ms. Neither statistic establishes a causal improvement. The stand was reopened and verified after measurements.

Final identity review: Gauss re-reviewed scheduler SHA-256 5CE63B4B23B5AFD07586345B234E7F74AA6A409C1017464F25DBDFF613027A3F (source, deployed and both after-capture receipts match); no blocking findings. This supersedes the earlier intermediate review hash.
