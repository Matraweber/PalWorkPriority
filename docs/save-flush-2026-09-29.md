# Save flush/close investigation — September 29

## Reason and scope

The transmitter-first native test recorded a 738 ms edit, including a 482 ms
save and 478 ms temporary-file close. It did not identify an OS/hosting cause.
The priority file displayed by the server manager was approximately 2.43 KiB.

Microsoft documents that fclose flushes buffered output before closing the
underlying handle. Lua file:flush explicitly flushes the stream. Therefore a
slow close does not distinguish buffered writing from handle close/filter work.
Sources: [Microsoft fclose](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/fclose-fcloseall?view=msvc-170),
[Lua 5.4 file:flush](https://www.lua.org/manual/5.4/manual.html#pdf-file:flush).

## Diagnostic intervention

Only with profiling enabled, datafile.write_raw now performs one checked flush
after a successful write and before the existing checked close. Close is still
attempted after nil, false or thrown flush failures. Failure blocks verification,
replacement and a saved acknowledgement. Error precedence is write, flush, close.
With profiling off, the filesystem operation sequence is unchanged.

This intentionally changes the profiled I/O sequence. It is not passive timing,
an asynchronous save, a stable-storage/fsync guarantee, or a performance fix.
Compare the complete save and combined write/flush/close durations, never claim
success merely because the close column became smaller.

77 regression scripts passed; 51 modules compiled under Lua 5.4. Structural
checks pass with the existing panel 194-local warning. Added tests distinguish
a simulated 478 ms flush from a 7 ms close, exercise nil/false/thrown flush
failures, write failures and simultaneous flush/close failure, verify cleanup
and preserve the previous live generation. These fixtures test control flow,
not physical disk buffering. Independent review found no blocking defect.

Source, client and downloaded server module SHA256:
E87094DBB64DC7858E91301832DC3DE4B7824ABFE7BC8253AAA40AD4B381FEF1.
Client backup: mod-root backups/save-flush-20260929-195619/datafile.lua.
Only datafile.lua was installed. Existing saves, configuration and pak retained.
Server readback: .tmp/assignment-census/datafile-flush-server.lua.
Test output: .tmp/assignment-census/save-flush-tests.txt.

## Native results

Server boot 19:58:10. The existing --stand AHK workflow exited client PID 20040
normally at 19:58:13, launched PID 37032 and verified the RAM endpoint/guild at
19:59:41. Nine stand rows returned with Vixy Gathering at its original green 1.
Eight native edits, four cycles 1->2->1, were acknowledged and the final green 1
was visually verified. Server receipts: 20:00:11, :24, :33, :44; 20:01:02, :18,
:27, :38. These are server receipt timestamps, not exact input-to-ack latency.

Profiling window 19:59:53–20:01:48, 115 seconds; intermediate sample at 59 seconds.

| Inclusive region | Samples | Total | Mean | Worst |
|---|---:|---:|---:|---:|
| Incoming edit | 8 | 5694 ms | 711.75 ms | 2534 ms |
| Save and notify | 8 | 3477 ms | 434.625 ms | 2246 ms |
| Temporary flush | 8 | 3434 ms | 429.25 ms | 2237 ms |
| Temporary close | 8 | 0 reported | below resolution | below resolution |
| Temporary write | 8 | 0 reported | below resolution | below resolution |
| Stand delta | 8 | 668 ms | 83.5 ms | 88 ms |
| Push roster | 8 | 466 ms | 58.25 ms | 63 ms |
| Transmitter scan | 8 | 201 ms | 25.125 ms | 28 ms |
| Complete scheduler | 17 | 1295 ms | 76.176 ms | 93 ms |

The two flush outliers were 1197 ms and 2237 ms (sum 3434 ms, all reported flush
time). Their containing saves were 1204 ms and 2246 ms; incoming edit callbacks
1483 ms and 2534 ms. The other six saves totaled 27 ms (4.5 ms mean). Nested
rows overlap. Clock resolution was unmeasured; reported zero is not zero cost.

This reproduces the severe stall during explicit buffer flushing, before close.
It rules against treating the measured close as only handle cleanup in this
sample. It does not distinguish filesystem/storage latency, filters, scheduling
or runtime locking; no OS trace was captured. The earlier 478 ms event was not
split, so the same cause there remains an inference. Sequential windows are not
a controlled comparison of explicit flush versus implicit close-flush. No speedup
from this diagnostic is claimed. The separate transmitter-first delta saving
holds at 83.5 ms; no fallback component-scan row appeared.

No WARN/ERROR in the measurement window. Both logging sinks recorded 81 attempts
and zero failures at the final report. Authority remained yes and priorities
saved. Profiling off verified 20:01:48. No independent client frame capture.
Evidence: .tmp/assignment-census/server-save-flush.log, client-save-flush.log,
save-flush-server-running.png and tools/restart-server-last-run.log.

## Independent verification and next boundary

Independent review confirmed the final cumulative eight-edit report, both flush
spikes, restored value, authority, saved state and profiler shutdown. The 59-second
snapshot is part of the final 115-second window; do not add their totals.

Do not implement a blind ExecuteAsync wrapper. The cached pinned LuaMod.cpp
creates the async Lua thread using new_thread, stores callback registry references,
and releases its action queue lock before invoking callbacks. That visible queue
lock therefore does not prove file I/O would block game callbacks. Conversely,
shared Lua state and missing LuaMadeSimple call_function/thread/locking source mean
safe concurrent execution and absence of lower-level serialization are unproven.
The server runtime identity must also be verified independently of the client.

Next investigation: obtain the missing implementations at the pinned revision
before an async prototype, or obtain a host-side file-I/O trace to identify the
stall below flush. A genuinely isolated native writer could own copied bytes and
serialized transactions, with completion/failure/shutdown handling on the game
thread, but this is not yet implemented or validated. Retain synchronous checked
saves until those gates are satisfied. Delaying a save to a later game tick alone
does not eliminate its blocking work; early saved acknowledgements are unacceptable.
