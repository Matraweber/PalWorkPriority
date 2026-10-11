# PresentMon capture procedure and evidence boundaries

Implementation passed offline and independent review, followed by main's bounded
title-screen smoke below. Historical September 23 empty captures remain unresolved.

## What the archive establishes

`test-results/capture-monitor-20260923.ps1` launched asynchronously and did not
record completion, exit code, post-capture process identity, or CSV validation.
Its CSV-only existence guard allowed failed-run logs/metadata to be overwritten.
The recorded PID20780 was the shipping game process, not the launcher. Its
recorded normal exit was later than the expected 45-second recording window.
The ten-second diagnostic retained stdout/stderr but no exact command receipt.

The generic process-query privilege warning is byte-identical in the two empty
captures and successful captures with 8,286 and 9,545 rows. It is not evidence of
an ETW permission denial. A separate `capture-probe-result.json` explicitly
records session-start access denied and exit code6. No session-collision error
was recorded for September23. Neither new privilege nor a new filter is a
proven repair for those empty recordings.

PresentMon2.5.1 creates its CSV lazily and silently returns on file-open failure.
Thus started/stopped messages alone cannot distinguish missing eligible rows
from output-open failure. Sources pinned to the inspected version:

- [MainThread.cpp](https://github.com/GameTechDev/PresentMon/blob/v2.5.1/PresentMon/MainThread.cpp)
- [OutputThread.cpp](https://github.com/GameTechDev/PresentMon/blob/v2.5.1/PresentMon/OutputThread.cpp)
- [CsvOutput.cpp](https://github.com/GameTechDev/PresentMon/blob/v2.5.1/PresentMon/CsvOutput.cpp)

## Read-only preflight, then explicitly requested capture

The wrapper is `tools/capture_frames.py`. It pins the existing portable executable
at `test-results/capture-tools/PresentMon-2.5.1-x64.exe` to SHA256
`9bec3083069f58f911e6a512f4806db51a27bd096103087bc1d05ef54c80a191`.
There is no CLI override for that hash and no download or installation.

For an already-running game, substitute its observed shipping PID and exact
executable path. These are procedure examples, not commands run during this work:

```powershell
python -B tools/capture_frames.py --pid <shipping-pid> --game-exe '<existing-path>/Palworld-Win64-Shipping.exe'
```

Without `--capture`, the tool only reads/hashes files and reads process identity.
It creates no attempt directory and starts no recorder. Record the returned
`game.created_ticks` string (Windows process creation FILETIME, not Unix time).
After independent review and explicit authorization for the smoke capture:

```powershell
python -B tools/capture_frames.py --pid <same-pid> --game-exe '<same-path>/Palworld-Win64-Shipping.exe' --expected-start <created_ticks> --duration 10 --delay 5 --capture
```

For the first smoke, keep the title scene visible and unchanged. A validated
title clip checks the acquisition route only; it does not measure base/stand
performance. Game launch, menu transitions and scene verification remain outside
this wrapper. Avoid diagnostics, input, screenshots or analysis during capture.

Duration is an integer10..300 seconds; lead is0..30 seconds. Every invocation
uses an exclusive UUID attempt directory under `test-results/frame-captures`
(or explicit `--output-root`) and a unique `PWPFrames_<uuid>` ETW session name.
Arguments are passed as a list without a shell, including paths with spaces.
No process-name filter, elevation/restart flag, session-stealing command, or
terminate-on-game-exit flag is used. The recorder's own timed exit bounds normal
acquisition. The wrapper verifies PID, image path and creation time before and
after recording; the game image is hashed separately as on-disk evidence.

## Receipts and validation

Each attempt preserves `attempt.json`, `stdout.txt`, `stderr.txt`, and, if
produced, `raw.csv`. Final `result.json` records exit code, elapsed time,
identities, failure details or validation, and artifact hashes. Final raw-CSV
hashing must match the hash of the bytes analyzed. A mismatch or missing raw
file makes the final state failed, retaining the analyzed hash, final hash (or
null if unavailable), integrity result and explicit error. Existing attempt
files are never reused. Missing CSV, header-only CSV and nonzero exits fail.
The generic privilege warning alone does not fail an otherwise valid capture;
reported ETW loss/overflow does. Failed runs must remain available for diagnosis.

The command explicitly selects `--v1_metrics`. Validation consumes the actual
PresentMon columns, including `ProcessID`, `SwapChainAddress`, `Dropped`,
`TimeInSeconds`, and `msBetweenPresents`; modern metric schemas are rejected
rather than silently reinterpreted. It requires the exact PID, one nonzero
swapchain, finite intervals, strictly increasing timestamps, and agreement
between timestamp deltas and intervals within0.02ms. Captures spanning less than
requested duration minus max(0.5s,2%) fail; excessive spans beyond the same
tolerance also fail. These edge tolerances are explicit acceptance policy.

The first row's interval is always excluded from derived statistics: its start
has no preceding recorded timestamp to validate. The raw row remains untouched;
`unanchored_first_interval_excluded=1` records this exclusion, with
`initial_zero_interval_excluded` additionally noting whether its value was zero.
Its timestamp anchors the first retained interval (row2), whose timestamp is
that interval's END. Explicit `coverage` therefore runs from the first raw
timestamp to the last retained timestamp. The analyzer's endpoint-only
`timestamp_span_s` starts at row2 and is separately reported; it is not used to
understate interval coverage. Later zero/negative intervals fail. No interval is
fabricated, and even an implausibly large first positive metric cannot bias
statistics. Dropped rows otherwise remain included; `dropped_raw_rows` counts
all raw dropped records. Multiple swapchains fail pending separate analysis.

Validated output includes `frames.csv` (`time_s,frame_ms`) and descriptive
statistics using `analyze_frames` helpers. These are application Present-call
intervals, not physical display or input latency. `validated` means acquisition
checks passed, not smoothness or causation. For matched comparisons, separately
provide the scene/build/settings metadata required by `tools/analyze_frames.py`.
The wrapper does not fabricate loaded-mod identity, scene, settings, or clock
alignment to Lua events from file hashes.

## Recorder cleanup only

Collection wait is bounded to lead + duration +15seconds. On timeout, exception
or Ctrl+C, cleanup targets only the retained launched-recorder process handle,
PID, creation identity and exact executable path. It locates that process's
message-only window (class`PresentMon`, title`PresentMonWnd`) and posts`WM_QUIT`.
This is the same normal exit message used by v2.5.1 `ExitMainThread`; the recorder
then stops its trace and joins its consumer/output threads. It never sends input
to the game, kills a process, or stops a global/named session belonging to others.

If normal shutdown is unavailable or hangs, `cleanup.json` records a pending
state when possible and the foreground wrapper continues supervising in5-second
waits until the recorder exits. Repeated Ctrl+C does not abandon the child.
Even a failed cleanup receipt write does not end supervision. `result.json`,
when present, records confirmed exit and supersedes the earlier pending receipt.
There is intentionally **no bounded total shutdown guarantee** for an
unresponsive recorder without force termination. Keep the wrapper running;
externally terminating the wrapper/OS is outside this cleanup guarantee.
The timeout/interruption attempt remains failed even if partial CSV is usable.

## Offline checks

```powershell
python -B -m unittest discover -s tests -p test_capture_frames.py -v
python -B -m unittest discover -s tests -p test_analyze_frames.py -v
```

Tests use fake processes/Win32 APIs and temporary output trees. They do not start
PresentMon, query live processes, change permissions, or launch games. The archive
test reads the existing 8,286-row PID7180 and 9,545-row PID34308 CSVs and verifies
their bytes remain unchanged. That test explicitly skips if these local archives
are absent from another checkout. Timeout-triggered external WM_QUIT delivery
remains tested with mocks only; the successful smoke used the recorder's normal
timed exit and did not exercise that fallback.

## Reviewed native title-only smoke — October 9

Main ran attempt `459a78a931184728bc5137c15345ed4f`, archived under
`test-results/frame-captures/459a78a931184728bc5137c15345ed4f/`.
The scene was operator-reported as the title screen; the wrapper does not attest
scene content. Requested recording: 5-second lead and 10 seconds of collection.
Receipts span 19:16:25.244610–19:16:40.488104 UTC, with 15.25 seconds total elapsed.

Independent read-only verification of the archived bytes established:

- All five artifact hashes in `result.json` match: `attempt.json`, `raw.csv`,
  `frames.csv`, `stdout.txt`, and `stderr.txt`. The analyzed/final raw hash is
  `397c6505a13a93b9246d56e21430762b49453f4befb117f643fca134570d433c`.
- One shipping-game PID43512 and swapchain `0x000001d17fe86980`; before/after
  process fingerprints agree, including creation ticks `134360467426469725` and
  executable path. The receipt records game disk SHA256
  `e590b5e7bfaa3fea40fab1a02cc72c8fc5fd6f8631ef2308e95ac56c25195837`
  and the pinned recorder hash. These are not loaded-memory or mod attestations.
- 2,392 raw rows produce 2,391 derived intervals, excluding the unanchored first
  interval. Every normalized row exactly matches its corresponding raw endpoint
  and duration. Timestamps are strictly increasing and interval/delta checks pass.
  Anchored coverage is 9.9690861 seconds; the endpoint-only span is 9.9649414 seconds.
- Recorder PID37492 exited with code0. Stdout records started/stopped; no timeout
  cleanup was invoked and no `cleanup.json` exists. This passes normal timed
  completion, not native testing of the external WM_QUIT fallback.
- Stderr contains the same generic process-query privilege warning seen in the
  earlier successful and failed archives. It did not prevent this exact-PID capture.

**Dropped semantics:** 1,793 of 2,392 raw rows (74.96%) have `Dropped=1`.
PresentMon v1 marks these presents as not presented; they are retained in the
application Present-interval analysis (apart from the unanchored first interval).
This flag is distinct from lost ETW events or omitted CSV rows. Consequently,
the approximately239.84 `duration_based_fps` in the receipt describes application
Present cadence, **not displayed FPS**, physical refresh rate, or smoothness.
Do not infer displayed FPS by multiplying that value by the non-dropped fraction;
display timing requires its own analysis.

Acceptance is limited to this title-only acquisition/validation path. It supplies
no base/stand workload, mod-on/off comparison, stutter-free claim, input latency,
or mod-performance result. No further capture was run during this independent
artifact check or documentation update.


## Raw-QPC gameplay correlation and scoped-proof comparison

The reviewed optional `--qpc-time` path retains integer QPCTime in raw CSV and
records QueryPerformanceFrequency before/after. It validates the relationship
between ticks, relative endpoints and intervals. The default relative capture
path remains unchanged. QPC output alone does not align Lua clocks.

For each gameplay capture we obtained two external nonce-bound Lua-clock
anchors before and two after the recorder, using
`tools/observe_frame_anchor.py`. Inclusive Lua event traces were enabled with a
4ms threshold and bounded capacity/window. No command, UI action or test suite
was run inside the recorded window. The independent correlation script checks
artifact hashes, constructs feasible affine clock maps and reports possible
and certain overlap; it repeats endpoint sensitivity at0/1/2ms. Ordered anchors
and affine models do not prove causality, exclude arbitrary clock drift or
measure physical display/input latency.

| Local async trial | Rules >50ms / >100ms | Rules p99 / max | Closed >50ms / >100ms | Closed p99 / max |
|---|---:|---:|---:|---:|
| Original proof resolution |42 /7|84.54 /123.69ms|18 /9|52.84 /125.46ms|
| One CDO resolution per authorization |23 /0|52.25 /76.29ms|14 /1|7.34 /116.83ms|

Each cell describes one approximately10-second recording. The world continued
simulating between tests and profiling was ON, so these are diagnostic paired
observations, not matched release acceptance or a universal improvement ratio.
All >50ms intervals overlapped persistence regions under the tested mappings;
these nested regions are inclusive and must not be added as independent costs.
PresentMon Dropped records remain counted; this is application Present cadence.

Archives and independent reproducible analysis:
- `test-results/persistence-cost-20261009/` (original local trial)
- `test-results/persistence-scope-20261009/` (scoped candidate)

Both folders contain `correlate_captures.py` and `correlation-results.txt`,
with per-scene capture IDs, four anchor receipts, raw event export and report.
The scope intervention halves forced CDO lookups while retaining both proof
snapshots. It leaves recurring spikes and does not complete the performance
gate. Public0.4.1 did not contain this opt-in async development trial.
