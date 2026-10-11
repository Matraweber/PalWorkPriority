# Dedicated clock-only probe â€” October 11, 2026

Native shared-table binding and clock advancement now **PASS** on the pinned
runtime after two diagnostic failures. Independent elapsed validation and total
callback cost remain unverified. The separate clock-only harness below is now implemented; native acceptance
remains outstanding. The existing parameter installer is unchanged and must not
be used as a clock-only harness.

## Invocation contract for a separately reviewed native harness

Load the pinned `dedicated_parameter_clock.lua` and `dedicated_clock_probe.lua`
from explicit, reviewed paths. Neither module auto-starts. After the harness has
validated and consumed its own one-shot nonce arm, call:

```lua
local control, reason = Probe.start {
    enabled = true,
    nonce = nonce, -- exact nonzero lowercase 32-hex run nonce
    clock_module = Clock, -- reviewed dedicated_parameter_clock module
    resolve = function()
        return StaticFindObject('/Script/Engine.Default__GameplayStatics')
    end,
    schedule = LoopInGameThreadWithDelay,
    cancel = CancelDelayedAction,
    emit = bounded_scalar_log_sink,
}
```

The harness must supply those exact native adapters, preserve source/runtime
hashes and process identity, and record bounded scalar output without credentials.
It must not supply parameter, world, guild, actor, save or writer adapters. This
entry performs no filesystem IO. Logging/arming and installation remain outside
this module and are implemented in the separately reviewed harness below.

The scheduler must return a non-nil/non-false cancellable handle (zero is valid)
and call on the game thread. `cancel(handle)` must return exactly `true` to report
successful cancellation. Nil/false/throw is recorded as unconfirmed. A scheduler
that creates a timer then throws or loses its handle cannot be physically
cancelled by this module; later callbacks are inert but timer removal is unknown.
The external harness must preserve that distinction during cleanup.

Retain `control` only to call `control.close()` on harness shutdown. Close is
idempotent. Never connect this control to the parameter observer. Changing options
after start cannot replace the captured providers.

## Bounds and output

- Eight callback attempts, requested one second apart. A frozen or rapidly invoked
  clock does not extend the callback cap. No unbounded wait or progress loop.
- One clock-specific CDO resolution per sample; no wrapper survives the callback.
  Each time read still invokes the reviewed native clock afresh.
- At most 34 clock reads per callback: initial read, 32 consecutive intervals,
  then one read after exactly 4,096 arithmetic iterations. No sleeping or native
  workload loop. At most 272 clock reads and eight resolutions in the run.
- A cooperative 100 ms first-to-last-read span budget is checked after each measured read; a 60 second
  run limit uses the tested clock. Neither can interrupt a blocked native call or
  prove an external elapsed bound when the clock is frozen/misbehaving.
- At most eight sample records and one terminal emission attempt. Failures emit
  fixed reasons rather than raw exceptions. Each record contains only bounded
  scalar fields, the run nonce, and false `verified`, `active`, `storage_grant`,
  `authority_grant`, and `coverage_grant` flags. `samples` counts attempted samples.
- Reentry or explicit close revokes immediately. The clock lease is released before
  emission and on all protected exits. Cancellation is attempted once after an
  active callback unwinds; reentry during registration defers cancellation until
  the handle is available. Terminal sink failure cannot be guaranteed to log.

Successful sample records use `status=observed`, `reason=sample`, and
`measurement=clock_under_test`. They report:

| Field | Meaning |
| --- | --- |
| `between_sample_ms` | Difference between sample-start readings; first is `unknown` |
| `between_sample_advanced` | Whether the reading exceeds the previous sample start; first is false |
| `read_burst_ms` | Span from initial read through 32 additional clock reads |
| `mean_read_interval_ms` | That span divided by 32; includes Lua/validation overhead |
| `work_and_final_read_ms` | Fixed arithmetic work plus final read/validation interval |
| `first_to_last_read_ms` | Span from first to last clock reading; excludes resolver and initial-read cost |
| `total_callback_ms`, `resolver_ms` | Always `unknown`; neither is independently measured |
| `within_sample_advanced` | Whether the final reading exceeds the first |
| `reads`, `read_intervals`, `work_steps`, `checksum` | Bounded operation counts/checksum |

Frozen readings produce explicit zero observed deltas and false advancement,
never a PASS. Terminal `advancement_observed` requires eight observed samples,
all seven between-sample intervals strictly forward, and at least one advancing
within-sample span. Missing progress ends with `no_between_sample_advancement` or
`no_within_sample_advancement`; even positive observed progress leaves
`elapsed_validated=false`. Native exceptions, invalid/missing named outputs, backwards values
or invalid CDOs produce `clock_unavailable`. Budget/elapsed limits and scheduler,
emission, cancellation and reentry outcomes remain separately visible.

## Native acceptance still outstanding

The existing clock validates named `Seconds`/`PartialSeconds` outputs and their
ranges, monotonicity and lease validity. Offline fixtures prove only control flow.
Before parameter sampling, a separate reviewed native run must establish these
outputs on the pinned installed runtime and actual progress both between callbacks
and during synchronous work. Zero work deltas may reflect resolution limits;
they are inconclusive, not evidence of advancement.

The probe's cost fields use the clock under test and exclude resolution/initial
read time. Independently aligned elapsed evidence, such as a reviewed external
QPC measurement, is needed to validate elapsed semantics and total callback cost.
No independent reference is invented here; requested timer spacing is not an
external clock measurement. Empirical `os.clock` alignment is not a fallback.
Record normal cancellation/restoration separately. Even a native clock PASS does
not establish parameter membership, Pal classification, IO ownership or authority.

## Offline verification

```text
python -B tools/test_lua.py tests/test_dedicated_clock_probe.lua tests/test_dedicated_parameter_clock.lua
```

Coverage includes normal/frozen timing, synchronous scheduling, callback/clock/
emission reentry, close during native read, malformed/backwards/slow clock values,
invalid CDO, resolve/read/emission/scheduler/cancellation failure, duplicate close,
elapsed limit, provider mutation and counters outside swallowed exceptions.


## Clock-only native harness

- `experiments/dedicated-clock-probe/main.lua` supplies only the fixed
  GameplayStatics clock CDO resolver, game-thread timer and cancellation API.
- `experiments/dedicated_clock_entry.lua` consumes an exact nonce arm before
  scheduling. It writes bounded scalar records only to its own clock.log. Arm
  read/write/close failures prevent start; log failures stop the bounded probe.
- `tools/install_dedicated_clock_probe.py` stages just those two modules and the
  clock/probe modules, plus nonce-only config. It pins the manual runtime, requires
  the stopped isolated clock fixture, checks staged bytes and arms enabled.txt
  last. Default invocation is read-only preflight.
- `tools/prepare_dedicated_clock_fixture.py` uses a new clock-20261011 backup and
  dedicated-clock-native-20261011 receipts. Historical identity receipts remain
  untouched. Only archived disposable Saved data, three runtime files and the
  pinned proxy are copied; production/observer mods are not copied. Originals
  are hashed, restoration is resumable after individual rename interruptions,
  and no deletion, launch or force-kill is performed by this tool.
- `tools/accept_dedicated_clock_probe.py` requires all eight ordered samples,
  consistent operation counts/timing arithmetic, cumulative start time below
  60 seconds and one confirmed cancellation. It rejects empty/frozen/partial
  evidence and never grants elapsed validation, native identity or restoration.

The existing server.py start readiness is intentionally not reused: it expects
production PWP_READY, which this clock-only mod cannot provide. Native readiness
must use the exact nonce clock log, matching disk/process fingerprints and normal
server exit. `server.py stop` remains the normal REST shutdown route.

Offline tests cover one-shot start, arm and log IO failures, bounded output,
explicit close, installer changed inputs/short writes/close failures, restoration
interruption and original hashes, and invalid/partial clock logs. An independent
review found and fixed cumulative elapsed validation: seven individually valid
60-second intervals must not pass a probe with a 60-second total limit.


## Native observations — October 11

Two separate disposable dedicated boots used the pinned runtime/proxy and copied
archived fixture. No production mod or writer was loaded. Stage checks confirmed
exact archived Saved bytes, empty mod/pak directories, runtime/config equality,
loopback REST binding with listener overrides cleared, and matching installed
probe-source hashes. Both runs used normal REST shutdown, followed by restoration
with every original file/directory hash matched. The actual launched shipping
image was PalServer-Win64-Shipping-Cmd.exe; process receipts record its path/time.
The first launch receipt's guessed non-Cmd expected path is not identity evidence.

1. `test-results/dedicated-clock-native-20261011/`: nonce
   a09ea44f074946efb9a5a94fe33d9ca9. One attempted callback, zero observed samples,
   clock_unavailable and timer_cancelled=true. Strict acceptance correctly rejects.
2. `test-results/dedicated-clock-binding-20261011/`: nonce
   4aecd52adc9b41e4b608dedc82b2af3c. Added fixed scalar failure diagnostics, without
   altering acceptance. Failure stage=fraction; Seconds type=number/kind=integer,
   PartialSeconds type=nil/kind=none. One attempted callback, zero observed
   samples, timer_cancelled=true. No raw engine exception/value or UObject was
   retained/logged. Both source receipts and raw clock logs are archived.

These runs do not validate elapsed time, callback cost or parameter membership.
The missing named fractional output must be explained from the pinned binding
implementation and/or another bounded diagnostic. Never substitute zero, CPU
clock, frame-cached time or an assumed return layout merely to pass acceptance.
The current installer/preparation constants point to the second run, whose
restored receipt correctly prevents accidental reuse; a future trial needs a
fresh receipt/backup. Historical evidence is not overwritten.


## Shared-table correction and native advancement — October 11

Pinned UE4SS source commit2281fa311e417b1dfddedbcd49972d764fddb244 explains the
failure: LuaUObject.cpp:193 captures scalar out-parameter references at Lua stack
slot1, and the non-struct/non-array branch continues without consuming that
argument. Both named outputs therefore land in argument one. DoubleProperty
conversion itself supports Lua numbers. See the local pinned source under
`test-results/native-helper-prerequisites-2281fa31/source/UE4SS/src/LuaType/`.
The generic [named-output documentation](https://github.com/UE4SS-RE/RE-UE4SS/issues/920)
does not establish separate-table consumption for consecutive scalar outputs.

The adapter now explicitly passes one fresh table twice and reads strict named
Seconds/PartialSeconds fields from it. No guessing, alternate-layout fallback,
zero substitution or weakened validation was added. A pinned-binding regression
fails when the adapter is mutated back to separate tables. Independent review
passed this delta before the third boot.

Third isolated boot: `test-results/dedicated-clock-shared-20261011/`, nonce
0383ef29e243412896b04183fff958c3. All8 samples completed34reads each; all7 between-
sample intervals and all8 synchronous spans advanced. Terminal sample_limit,
advancement_observed=true, timer_cancelled=true. Strict parser passed. Source
hashes matched installation receipt. Normal shutdown and original-hash restoration
both passed. Source/runtime/process receipts and raw logs are retained.

This supersedes the failed-binding status above only for this pinned runtime.
Measured first-to-last spans were about0.162–0.218ms using the clock under test;
CDO lookup and initial-read costs are excluded. Do not call this total callback
cost or independent elapsed validation. The next timing gate needs an independent
elapsed reference before interpreting parameter-observer budgets as measured
performance. No Pal membership, save ownership, writer, or async gate closed.

Current installer/preparation constants now point at the third (restored) trial.
Future runs need fresh backup/receipt paths; retain all three histories.
