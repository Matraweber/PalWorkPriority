# Isolated native Lua handoff probe V2

Offline implementation only. Nothing here installs, loads a DLL, or controls the
game. This is not a save test and does not enable production async.

## Contract and ownership

`package.loadlib(path, 'luaopen_pwp_handoff_probe')` returns the direct function.
Call it as `native(lowercase_ascii_hex, delay_ms, expected_hex_length)`.
Decoded payload limit: 256 KiB; encoded limit: 512 KiB. Delay is integer 0..200 ms.
Success returns exactly five integers: checksum, native thread ID, QPC integer
microseconds start, QPC integer microseconds end, QPC frequency in Hz.
Invalid arguments or caught C++ exceptions return zero
results; the driver treats that as failure. Sleep first requests the selected
0..200 ms. For nonzero delay, QPC then verifies at least delay*1000+2 microseconds;
early wakeups trigger at most eight remaining-duration sleeps (rounded up to ms).
Exhausted retries fail closed. OS scheduling does not guarantee a 200 ms wall-clock
maximum. The driver still requires at least 200000 observed microseconds.

QueryPerformanceFrequency must succeed and lie in [1000000, 9223372036854] Hz:
counter ticks are <=1 us and remainder*1000000 cannot overflow int64. QPC calls
and nonnegative counters are checked. Quotient/remainder conversion avoids
absolute-counter multiplication overflow and truncates by <1 us per timestamp.
QPC frequency is checked across worker, baseline, completion and observed beats.
Cross-thread comparisons require a beat >3 us inside both worker endpoints,
covering the documented +/-1 QPC tick ordering ambiguity plus conversion error.
This is a resolution/ordering bound, not a claim of absolute clock accuracy.
See [Microsoft QPC guidance](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps)
and [Sleep semantics](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-sleep).

The original tick-clock live run, nonce handoff-20261004T105421Z, failed its
duration assertion without recording timestamps. Its cause remains unclassified.
V2 is a revised experiment, never a retroactive pass for that run.

Checksum is uint32 DJB2 starting at 5381 over decoded bytes, including 0 and 255.
Lua independently decodes/checksums the same immutable hex. The native getter is
NOT binary-safe: pinned LuaMadeSimple.cpp:754 uses a NUL-terminated string_view
and removes its argument. Expected length comparison rejects NUL truncation for
the honest Lua driver's `#hex` contract; native code cannot detect a dishonest
short length hiding a suffix after NUL. This is a controlled ASCII contract, not
an arbitrary-binary security boundary. Oversized hostile strings can also incur
strlen work before the native length check; the driver bounds input beforehand.

Pinned insert_value (line 732) calls lua_pushvalue then lua_insert. Native reads
arguments 3 and 2, duplicates argument 1 into slot 2, and gets/removes only slot 2.
Slot 1 remains rooted throughout validation, decoding, delay, and return. Thus
GC on another coroutine cannot collect the immutable string between getter and
copy under the host's normal Lua locking/GC invariants. The owned decoded copy
is used for checksum. The queued closure also retains the payload; dropping the
original variable does not mean all references disappear. No Lua execution,
callbacks, retained state, UObject access, or native threads are introduced.
catch(...) contains C++ exceptions, not access violations or Lua longjmp.

## Offline validation

From repository root:

    python tools/test_lua.py tests/test_native_handoff_driver.lua
    python experiments/native-lua-handoff-probe/check_link.py

Build outputs and receipt stay in this experiment's `build/`. The build uses
untouched pinned public headers, release /MD compiler 14.50, and the previously
staged official 14.51 linker/lib tools. It only reads the installed UE4SS for
hash/export auditing. There is no second Lua in the helper. The offline mock
uses the repository's separate Lua 5.4 test runtime, never loaded into the game.

## Proposed later live acceptance (not executed here)

Adapter expects main.lua, driver.lua, and pwp_handoff_probe_v2.dll together. A future
explicit deployment must select one canonical DLL path. An arm file containing
`PWP_HANDOFF_PROBE <unique-nonce>` is consumed before loading. No arm is supplied.
Worker runs through ExecuteAsync; completion uses ExecuteInGameThread. A game
callback schedules independent 25 ms delayed beats; each beat calls native with
empty hex and zero delay to obtain a same-clock timestamp and thread ID.
PASS requires checksum, distinct worker/game threads, game-thread completion,
and a complete beat inside the native interval with the >3 us edge margins. No beat is FAIL,
even if checksum succeeds. A 1000 ms scheduled watchdog fails missing completion
if game callbacks still execute; it cannot diagnose a fully frozen process.
On game-thread completion, DIAG records raw native count/checksum/thread/start/
end/elapsed/frequency, baseline and completion metadata, generation, and every
beat timestamp before result-shape or semantic assertions. Subsequent failures
also append this diagnostic. Early failures before completion can only include
data available at that time; no timestamps are reconstructed or inferred.

Mocks cover success and fail-closed checksum/thread/heartbeat/generation cases,
invalid hex, GC, disarming, too-short duration, frequency mismatch, missing native
results and ambiguous beat edges. They do not establish native ABI, actual parallel
execution, fairness, or unloading. The constant probe's live passes do not prove
the added getter/duplicate imports; this DLL needs its own controlled live gate.

## Remaining duplicate-copy and teardown gates

Before live acceptance, record loaded full path/hash/module identity and ensure
only one intended helper instance. Repeated canonical-path loads should reuse
it. Equal bytes at different paths do not establish one instance; duplicate-copy
behavior is NOT proven here and there is no process-wide singleton enforcement.

Test generation invalidation while queued and in flight: stale completion must
fail and never publish a result. The adapter invalidates its prior generation
on same-state re-entry, not automatically on every world/mod lifecycle event.
Test supported mod teardown during work and then clean restart; UE4SS must join
its async worker before Lua closes/unloads libraries. No manual FreeLibrary,
DllMain waits, detached worker, or forced unload is supported. Closures retain
the function for ordinary queue lifetime; DLL residency through actual teardown
is NOT proven by mocks. Production files and save paths must remain untouched.
