# Native background handoff: isolated test

Production async saving remains disabled. This experiment uses synthetic bytes,
encoded as hex, and never opens a production save destination. It calls a native
copy/checksum operation through UE4SS ExecuteAsync, then queues completion on the
game thread. Passing requires correct data, different native thread identities,
game-thread completion and a heartbeat strictly inside the native work interval.

## First live trial

Nonce `handoff-20261004T105421Z`, new process 35600. The normal restart macro
observed old process 35736 exit before starting it. The driver reported
`delay too short`; this is a failed trial, not async acceptance. Its failure
message omitted raw timestamps, so the cause is not established by that log.
The game subsequently loaded normally and reported saved priorities/limits,
authority and a live heartbeat. Production scripts were not deployed.

Evidence: `test-results/native-lua-handoff-live-20261004/installation.json`,
`first-result.json`, `first-handoff.log`, `first-driver.lua` and the loaded-module
snapshot. The adapter disarmed itself before loading.

One test-design concern is the strict 200 ms threshold applied to GetTickCount64
around Sleep(200). Microsoft documents coarse 10–16 ms timer resolution and
tick-dependent sleep duration. Capture actual timestamps before attributing this
failure to that concern. Do not remove the independent heartbeat-overlap gate.
[Timer resolution](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-gettickcount64)
and [Sleep behavior](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-sleep).

Offline Lua tests cover incorrect checksums, same-thread execution, missing
heartbeats, stale generation, malformed input and one-shot disarming. Those tests
validate rejection logic; they do not establish native concurrency, DLL unload,
file durability, active-world binding or save acknowledgements.

## Revised measurement (V2)

V2 uses validated QPC frequency and integer microseconds. The native operation
still requires the full 200,000 microseconds: after its initial sleep it performs
at most eight bounded additional waits if needed. It does not relax the duration
gate. Overlap must clear both interval edges by more than three microseconds.
Raw worker, baseline, completion and every heartbeat measurement are recorded
before completion assertions. The offline suite additionally rejects short
duration, incorrect result shape, differing clock frequency and ambiguous overlap.

This is a revised experiment, not a reclassification of the first failed trial.
Its DLL uses a new filename and a separate diagnostic mod; the old diagnostic is
disabled for the next normal restart. Both versions leave production scripts and
saving unchanged. `v2-installation.json` records the exact source/build hashes.

## V2 live result: handoff passed

Nonce `handoff2-20261004T110123Z`, PID 43312. Native checksum 2382238981 matches
an independent Python calculation over all 256 byte values repeated 1,024 times
(256 KiB decoded). Worker thread 13340 differed from game/completion thread 42092.
QPC frequency was 10 MHz. Native start/end were 6800332051 / 6800532319 us:
**200,268 us** elapsed. Four game-thread beats occurred inside this interval;
the tightest endpoint margin was 6,292 us. Completion followed by 1,981 us.
An independent agent checked the raw measurements and reached the same verdict.

Evidence: `v2-result.json`, `v2-handoff.log`, `v2-loaded-modules.json`,
`v2-priority.log`, `v2-macro.log` in the live evidence directory. Exactly one
helper was loaded from the intended path. This is not alternate-path singleton
proof. Production Scripts still match pre-install hashes. After world load,
status reported saved priorities/limits and authority, and stand numbers were
visible. No WARN/ERROR appears in the captured production-log interval.

The diagnostic ran during startup **before world load**. It demonstrates native
worker/game-thread overlap in that phase, not a warm gameplay or frame-time test.
The arm is disabled and the enable marker renamed; no forced library unload was
performed. Production async saving is still disabled.

Next gates: repeat the handoff during warm gameplay; use disposable file IO with
the tested publication primitive; exercise stale generation, queued/in-flight
teardown and duplicate ownership; bind actual session/storage identity; then
verify recovery and durable acknowledgements before production enablement.

## Warm gameplay repetition passed (11:25 UTC)

Three independent 256 KiB synthetic trials ran after the 11:24:14 UTC world-ready
marker: 11:25:05, 11:25:15 and 11:25:25. Native durations were 201,190 / 200,674 /
200,596 microseconds. Each checksum was 2382238981; worker 43944 differed from
game/completion thread 34948. There were 7 / 7 / 6 game-thread beats inside the
native intervals. These are handoff/concurrency observations, not frame-time or
save-durability acceptance.

Raw evidence and independently parsed acceptance are in
`test-results/native-lua-handoff-warm-20261004/`. The acceptance tool also rejects
inert, missing, duplicated, short, same-thread and inconsistent raw results.
The diagnostic is disarmed/disabled, and production Scripts are unchanged.
