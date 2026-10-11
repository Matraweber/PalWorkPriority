# Async-save idle lookup reduction — October 1, 2026

Status: offline checks and live WARM/READWARM retest passed; scratch flag verified DISABLED.
Production persistence remains unchanged.

## Changes

The standalone scratch driver now evaluates warm baseline, round boundaries and
between-operation spacing using Lua state before resolving its bridge. Actual
requests and pending completions still resolve fresh, validate TrialTag and retain
no UObject wrapper across callbacks. Idle baselines no longer measure a repeated
StaticFindObject call. The active distribution includes idle callbacks as well as
working callbacks; a zero median is not a claim of zero save cost. The completion
report now counts bridge_resolves explicitly.

WARM records have distinct generations and payload prefixes 1–24, retaining the
four payload sizes per round. Explicit READWARM expects generations23/24;
WRITE/READ retain their eight-record protocol. Reusing an old READ token after
WARM intentionally cannot verify the final generation. These protocols share only
the named synthetic scratch slots; a fresh trial nonce is required.

## Offline verification

Lua5.4 compiles51 production modules; all81 regression scripts pass. The new
interruptions suite contains12 persisted fake-storage scenarios covering partial
writes, corruption, crashes before acknowledgement, stale completion and uncertain
IO locks. These are simulations, not native disk fault injections. Independent
review found a stale-round fixture weakness; it now injects the matching first-
round sample at the corresponding second-round operation. In-memory mutants that
restore idle lookups or repeat warm generations are rejected by the regressions.

Receipt: test-results/save-scratch-warm-20261001/lua-idle-reduction-all.txt.
Driver SHA256:07559f7530e537bfb44141b5864adbc3ef5d844b816f1c217ff9f49a0aa74b9e.
Metrics SHA256:441473b9e12c143aaab4ddcc731014cb542c858f3c71b33fec9c03e40bb677cb.

## Live protocol

Trial idle-20261001-154402 uses the prior V2 pak (hash verified), updated driver,
and unchanged metrics. FTP readback verified both scripts and control token before
restart. Production writer matches e87094dbb64dc7858e91301832dc3de4b7824abfe7bc8253aaa40ad4b381fef1.
The test repeats180s warmup, three30s baseline/active pairs and24 exact readbacks;
then READWARM on a new server process must recover final records23/24. Disarm and
verify player reconnect afterward. Preserve both successes and outliers.

Evidence directory: test-results/save-scratch-idle-20261001/.

## Native results

WARM armed15:44:33UTC; all24 sequential unique records passed; completed15:50:34.
Both actual WARM timers cancelled. There were49 bridge resolutions, exactly24
requests plus25 polls, with1255ms accumulated resolution cost (prior7999ms).
Across the six windows recorded callback work totalled1497ms (prior8106ms), an
81.5% descriptive reduction; resolution cost fell84.3%. This is harness overhead,
not proof of a comparable production-mod or whole-game improvement.

| Metric | Baseline rounds1/2/3 | Active rounds1/2/3 |
|---|---|---|
| Callback samples | 57 / 57 / 57 | 57 / 57 / 57 |
| Callback total ms | 0 / 0 / 0 | 529 / 487 / 481 |
| Callback max ms | 0 / 0 / 0 | 43 / 37 / 36 |
| Gap p95 ms | 67 / 67 / 67 | 67 / 67 / 67 |
| Gap max ms | 98 / 131 / 125 | 129 / 130 / 102 |

Zero baseline values mean below the uncalibrated Lua clock resolution. Active
medians were also zero because most callbacks were idle; this is not zero save
cost. All12 buckets retained every sample. Pending/request callbacks still incur
fresh object resolution and should be replaced by a verified event/current-context
route before a production design uses this observation mechanism.

Engine completion median71.161ms, maximum703.270ms (sample5, 32bytes; save stage
669.948ms and read33.322ms). Sample7 completed in128.594ms. No timeout, corruption,
overlap or premature success was reported. These are frame-quantized elapsed
completion intervals, not isolated blocking durations. The latency-tail concern
remains; warmup did not eliminate it.

READWARM on the next boot armed15:52:50UTC, recovered exact final generations23
and24 at15:52:54/55, then cancelled its operation timer. Engine read intervals
34.016/33.018ms. Unlike the earlier repeated payload test, these records distinguish
the final warm round. This still tests a controlled restart, not power loss.

## Presentation and scene limitations

PresentMon2.5.1 captured52,478 rows, one PID39804/swapchain,299.977s. Present p99
7.5936ms and maximum27.6625ms.52,475 positive display intervals had p99 10.2698ms
and maximum29.1517ms; neither series had any interval above50ms. Three presents
were undisplayed. Independent reviewer reproduced every summary statistic and
checked timestamps against interval fields.

Both runs report Composed:Flip and tearing disabled, yet the effective display
cadence changed substantially from the earlier run. Night-to-dawn lighting and
an open Vaelet tooltip also differ. No matched-scene FPS gain is inferred. No
remote/client clock calibration exists, so no individual save or phase is assigned
a client frame. The recording is evidence for this scene only.

## Closure and remaining work

FTP readback verified DISABLED after recovery. Production writer before/after
hashes match. Production server continues passes with one camp/nine pals after
restart. One warning at17:52:13local occurred during client departure: no owned
base-camp component, permission writes deferred. This is not a zero-warning test
and does not certify scheduling correctness. Client PID28888 completed RAM guild
handshake17:53:53local; final foreground screenshot shows all nine stand rows and
priorities. The unused scratch mod/pak remains installed but disabled on next boot.

Franklin independently reviewed code, tests, warm counts, frame calculations and
final-generation recovery. No production writer integration, release or commit.
Next gates: verify a cheap completion-context route; native storage failure and
interruption cases isolated to synthetic slots; then integrate and test the queue
with ownership, migration and truthful durable acknowledgement rules. The 703ms
completion outlier remains unexplained. Do not call this a full stutter fix.
