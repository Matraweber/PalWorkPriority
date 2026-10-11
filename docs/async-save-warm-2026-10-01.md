# Warm async-save trial — October 1, 2026

Status: **warm native trial and restart recovery completed through FTP**.
The separate scratch driver and metrics module were installed and verified;
the existing V2 pak matched its expected hash. Production persistence remains
unchanged. The trial control file is verified DISABLED and the client is back at
the Monitoring Stand. No release or production async-writer adoption occurred.

## Native outcome

Trial `ram-20261001-141758`, RAM (address withheld). WARM boot 14:18:56 UTC,
client guild handshake 14:20:40, six measurement windows 14:21:56–14:24:58.
All 24 synthetic write/readbacks matched (eight per active round, 32/4096/32768/
65536-byte payloads twice). Both actual WARM timers cancelled successfully.
READ after the next server restart armed 14:27:47 and completed 14:27:52: A7
32768 bytes and B8 65536 bytes matched, including trial scope and checksum.
READ has no observer timer; its monitor_cancelled=true is a no-op success.
This establishes controlled-restart recovery, not crash/power-loss durability.
Payloads repeat between rounds, so recovery cannot independently identify which
round supplied the final records.

| Observation | Baseline rounds 1/2/3 | Active rounds 1/2/3 |
|---|---|---|
| Inclusive callback samples | 56 / 56 / 56 | 56 / 55 / 56 |
| Callback median, ms | 23 / 24 / 24 | 24 / 24 / 24 |
| Callback maximum, ms | 29 / 25 / 27 | 34 / 35 / 34 |
| Observer gap samples | 653 / 656 / 649 | 657 / 651 / 662 |
| Gap p95, ms | 67 / 67 / 67 | 67 / 67 / 67 |
| Gap maximum, ms | 102 / 153 / 124 | 158 / 141 / 128 |

All samples were retained; none of the twelve buckets dropped samples. These are
Lua callback/gap observations, **not server frame times**. Inclusive callback
means were 23.607ms baseline and 24.790ms active, about 1.18ms apart. This is not
isolated engine save cost: lookups, object construction, payload/checksum work,
readback and formatting are included; asynchronous engine work is not enclosed.
Name-based bridge resolution alone accumulated 7999ms across the trial. The
observer's 33ms requested delay also quantizes against game-thread scheduling.
The harness itself is too expensive to adopt as a production polling design.

Engine completion intervals: median 68.801ms, range 65.683–204.240ms. Two samples
exceeded 100ms (102.013 and 204.240); the latter's save stage was 171.204ms.
These frame-quantized real-time intervals are neither blocking CPU duration nor
proof of a hitch. Enqueue total was 3ms, with uncalibrated Lua clock resolution.
The earlier 1123.722ms September29 result was not repeated in these 24 samples;
its cause remains unresolved.

## Independent client presentation capture

PresentMon 2.5.1 produced 49,979 rows over 299.965s, one Palworld PID34140 and one
swapchain. The Monitoring Stand was visibly open with nine pals before and after;
no test UI controls were sent during the capture. This was a fixed-camera scene,
not a combat/travel/edit test. No remote-server/client clock mapping was measured,
so individual frames are not attributed to server phases or save events.

- Presentation interval: median 5.8618ms, p95 7.0706ms, p99 7.9962ms, max 28.967ms.
- 17,994 positive displayed-change intervals: p99 16.7275ms, max 33.3658ms;
  no displayed interval above 50ms. Four exceeded 33.3333ms slightly.
- 31,985 presents were undisplayed. Submission exceeded the roughly 60Hz composed
  display cadence; this count is not itself a hitch count.

Independent reviewer Franklin reproduced the frame calculations and verified the
recovery log. This supports steady presentation in this capture, not a universal
stutter-free claim, phase-specific impact, or production readiness.

## Runtime, cleanup and outstanding gates

Server recovery boot: UE4SS v3.0.1 Beta #0 ba2efd55, Game__Shipping__Win64;
client capture boot: 2281fa31, same build configuration. Game reports v1.0.5.102999;
mod banner is unpublished 0.5.0-rc1. Production writer before/after SHA256 matches:
`e87094dbb64dc7858e91301832dc3de4b7824abfe7bc8253aaa40ad4b381fef1`.
Server production log contains one warning during initial reconnect at 16:20:27
local: repeated player announcements throttled. Do not report zero warnings.
Recovery log confirms authority/settings available and continued passes; this
does not verify the actual job assignments reported as unverified during startup.
UE4SS also emits its UGameEngine::Tick vtable/scan mismatch boot warning.

Control file readback verified DISABLED after recovery. New client PID36292
handshake 16:28:57 local; final foreground screenshot confirms stand priorities.
Scratch files/pak remain installed but inert on next boot. No production settings
writer change was made. FTP repeatedly timed out on data connections; uncertain
writes were read back before retry. The broken web file manager is not fixed.

Next: remove repeated global resolution from completion observation using a
verified fresh-context route, then exercise interruption, corrupt/missing record,
storage-failure and queue/scope ownership cases. Payloads need unique per-operation
identities for stronger latest-generation recovery evidence. Migration and truthful
durable edit acknowledgements remain gates before real settings integration.

Raw evidence: `test-results/save-scratch-warm-20261001/` contains warm-result.log,
recovery-result.log, client-frames.csv, frame-summary.json, capture-context.json,
runtime/production logs, backup driver/control files and final screenshots.

## Earlier access diagnosis and preparation

Follow-up diagnosis: the browser FileManager reports `AxiosError: Network Error`
while showing "Directory is empty". Direct authenticated FTP lists the root and
the production mod's scripts/config/priorities/backup/log. A fresh FTP connection
also retrieved scratch run.txt (still DISABLED) and main.lua; its SHA256 matches
the September29 installed driver exactly:
`4fdc90d9caddf6d2e3cd398bd2130646ff42cda4cc7601449807c2ce629d1624`.
The console Info reply identifies live RAM as v1.0.5.102999. These checks establish
a misleading failed web listing, not an empty installation. One initial FTP
directory request timed out; a fresh connection listed/read successfully, so
intermittent file access remains possible. No reset, credential change, upload or
restart occurred. Temporary FTP credential material was removed before connecting.
Direct FTP is a verified alternative for the next deployment; native testing
itself has not yet run. GPortal's public status page reported fully operational;
that does not exclude this specific panel/access failure.

## Live access check

GPortal initially returned HTTP 500 for the dashboard. After the user opened RAM's
status page, it reported Running, 0/8 players. File Manager displayed an empty
scratch Scripts directory, empty ue4ss directory and empty server root. This does
not prove files were deleted. The separate UE4SS-Logs viewer reported "Something
went wrong when loading the file, please refresh" and repeated the error after
Refresh. Uploading into an unverified installation or restarting would not produce
a trustworthy test. Palworld was not running at the process check.

## Prepared harness

Only experimental files outside production Scripts changed:

- `experiments/ue4ss-save-scratch/Scripts/main.lua`: explicit WARM mode, 180-second
  warmup, require a controller with readable PlayerState, then three baseline/
  active pairs. Each baseline lasts at least 30 seconds after asset initialization;
  each active period lasts at least 30 seconds and must finish eight exact
  synthetic write/readbacks (24 total). Samples start at least three seconds apart.
  The overall timeout is 600 seconds. Existing WRITE/READ modes remain available.
- A separate 33ms game-thread timer records callback arrival gaps. The 500ms
  operation callback records inclusive harness work. No native calls in the fast
  observer. Timing buckets are separated by round and phase. These are **not
  frames** and do not establish client frame rate or isolated save CPU cost.
- Logs buffer in memory during measured phases and flush in one final batch.
  Original event timestamps are retained. Setup and final report flushing are
  outside baseline/active comparison. Formatting/checksums/record construction
  and fresh actor lookups remain harness work, included in callbacks.
- `metrics.lua`: bounded first-sample retention, all-sample counts/totals/maxima,
  strict >50/>100/>250ms counts and explicitly retained-subset percentiles.
  Twelve per-round buckets fit within a 16-key limit, 4096 retained values each.
- Both timer cancellations are attempted independently. A failed cancellation is
  reported; the finished guard prevents further work even if callbacks continue.
  Missing/inert observers fail measurement acceptance instead of passing silently.
- Local run.txt defaults to DISABLED. Live opt-in, only after verified upload:
  `PWP_SCRATCH_V2_WARM <fresh-trial-id>`; subsequent READ must retain that ID.

## Verification

All **80 Lua regression scripts pass**; **51 production modules compile**.
Receipt: `test-results/save-scratch-v2/lua-warm-all.txt`.
Driver tests simulate delayed IO, exact recovery, corruption, stale scope,
missing package, no player, player departure, timeout, logger failure, observer
registration failure, inert observer and cancellation exceptions. They assert all
six phase windows, eight writes per active round, no setup contamination, buffered
logging and nonzero callback/observer measurements using an advancing test clock.
Independent review found the original first-baseline setup contamination and weak
timing/cancellation tests; those findings were corrected before this checkpoint.

## Original live protocol and limits (execution reported above)

1. Recover readable GPortal file/log access. Verify current runtime, production
   package and prior scratch asset identities before upload. Do not infer missing
   files from the broken file manager.
2. Install only the checked scratch driver plus metrics module; use the existing
   hash-verified V2 pak. Arm a fresh trial and restart once. Rejoin RAM through the
   documented macro and verify the world/stand visually before measurement.
3. Capture independent client frame times with the known PresentMon tool and
   verify actual output, process/swapchain and clock alignment. Prior no-output
   attempts do not count. Do not combine remote server and client clocks as though
   their offsets were measured.
4. Read back all 24 exact outcomes and six phase distributions. Require adequate
   samples. Examine worst intervals, callback durations and observer gaps separately.
   Player presence is checked at boundaries, not continuously; external observation
   must establish a comparable populated scene. No physical controller testing is
   implied by this experiment.
5. Run read-only recovery with the same trial ID, disable the scratch flag again,
   and check production health. Preserve raw data including errors/outliers.

The 1.12s September 29 completion outlier remains unexplained. Warmup elapsed time
does not establish storage-cache state. Lua os.clock resolution/elapsed behavior
still needs native calibration. Native file IO may be asynchronous while object
serialization/deserialization and completions run on the game thread. The Lua
queue is not integrated into this live harness or the production settings writer.
Storage faults, interrupted saves, migration, scope ownership and truthful durable
acknowledgements remain separate requirements before adoption.
