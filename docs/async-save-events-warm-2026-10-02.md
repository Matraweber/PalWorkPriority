# V3 populated async-save trial — October 2, 2026

Status: 24-record WARM protocol and controlled-restart READWARM passed.
Both scratch controls verified DISABLED. Client restored to the Monitoring Stand.
Production persistence remains unchanged; no commit or release performed.

## Identity and verification

RAM server 8684515, trial `warm-events-20261002-162701`.
Deployed V3 main/completion/metrics files were compared byte-for-byte with local
files before arming. Pak SHA-256:
`00fd37d0d9d14f1a209a14bebae2c3c53dd4158ca50cf16af595cf3b81add61f`.
V2/V3 were disabled before arming. Intermittent FTP data-transfer failures were
resolved by reading the control before retrying; WARM was verified before restart.
The existing 83-suite offline receipt applies: no driver/native code changed.

WARM armed 16:28:22 UTC (18:28:22 Europe/Berlin). Client PID38880 joined the
expected guild at 18:29:55 local. Screenshots show nine Pals with priority numbers,
night transitioning to dawn, and a Vaelet tooltip. Visible game v1.0.5.102999;
client UE4SS2281fa31, server ba2efd55; production mod0.5.0-rc1.

## Functional evidence

Three baseline/active pairs completed at 16:34:23 UTC. Exact payload/session/
generation/checksum checks passed for generations1–24. Each round contains
32,4096,32768,65536-byte payloads twice (six observations per size overall).
There were24 completion hooks,24 dispatch bridge resolutions,30 plain-Lua inbox
polls, six phases and12 metric groups. Both timers cancelled. No retained metric
samples were dropped. `check_trial.py` rejects missing generations, phases,
metric coverage, hook counts or cancellation.

After normal client exit, READWARM was verified and RAM restarted. At16:37:10 UTC
the driver recovered generation23/32768bytes and generation24/65536bytes exactly,
with two completion hooks, one post-initialization resolution and timer shutdown.
This establishes the final two slot contents survived a controlled restart, not
that every historical generation is retained or that interrupted writes are safe.

V3 DISABLED was verified immediately and again in the final health download.
V2 also remained DISABLED. The production writer SHA-256 remains
`e87094dbb64dc7858e91301832dc3de4b7824abfe7bc8253aaa40ad4b381fef1`.
The macro rejoined with PID35364 at18:38:05 local; `stand-restored.png` visibly
confirms priority numbers. No deliberate priority edits were made.

## Performance observations, not a universal acceptance claim

| Measurement | Result |
|---|---:|
| Engine save/read completion median | 69.574ms |
| Engine save/read completion maximum | 1505.007ms |
| Operations above500ms | 4 of24 |
| Bridge lookup total / count | 553ms /24 |
| Setup | 107ms |
| Enqueue total | 4ms |
| Completion-hook total | 8ms |
| Active operation-callback totals by round | 267 /259 /262ms |
| Active operation-callback maximum | 35ms |

Slow samples:1=999.088ms,8=1335.763ms,16=1505.007ms,19=203.230ms,
24=669.597ms. Sample16 spent1471.747ms in the asynchronous save stage.
These are elapsed completion times, not game-thread CPU or frame durations.
The ~500ms observer cadence further delays reported observations.

Routine baseline operation callbacks printed zero at unmeasured Lua clock
resolution. Boundary population checks do enumerate engine objects and are
excluded from phase callback distributions. Inclusive callback/hook/lookup
figures overlap and must not be summed. Callback-gap maxima were95–132ms in
baselines and99–125ms in active phases; these are scheduler observations, not FPS.
The remaining24 dispatch resolutions still average about23ms each.

PresentMon2.5.1 captured one PID/swapchain for299.979 seconds, Composed: Flip:

| Independent client measurement | Result |
|---|---:|
| Presents | 51,343 |
| Present interval p99 / maximum | 7.9208 /34.5597ms |
| Display changes | 51,341 |
| Display interval p99 / maximum | 10.2898 /38.1146ms |
| Present or display intervals above50ms | 0 |
| Dropped presents | 2 |

Capture started after visible reconnect and ended after WARM completion. There
is no calibrated remote-server/client clock map, so no individual save or phase
attribution. There is no matched mod-absent or profiling-off capture. Lighting,
world activity and tooltip rendering vary; no causal FPS improvement or
stutter-free claim is supported. The final buffered log flush is part of the
overall capture window, not part of the per-phase callback distributions.

Server warnings: announcement throttling at18:29:40 during reconnect, and missing
owned camp component/write deferral at18:36:26 during normal client departure.
These must not be reported as a warning-free test. Independent review agrees
with the narrow functional/recovery pass and these performance limitations.

## Next gates

Integrate the pure queue/ownership model only behind an explicit development
gate, with realistic serialized data and truthful pending/durable states.
Handle uncertain completion and session transitions without blind retries.
Remaining fault coverage includes native interrupted IO, corruption, storage
errors and migration/backup recovery. Reducing fresh dispatch resolution cost
is a candidate, but retaining Unreal wrappers across callbacks is forbidden.

Evidence: `test-results/save-scratch-events-warm-20261002/`, including raw logs,
trial/frame summaries, scripts, capture context, screenshots and disabled flags.
