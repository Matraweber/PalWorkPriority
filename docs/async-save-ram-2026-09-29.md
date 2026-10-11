# Async save/read scratch trial on RAM — September 29, 2026

## Result

The isolated V2 bridge mounted and ran on RAM. Eight synthetic writes read back
exactly, and a second server restart recovered the final A/B records in read-only
mode. Both timers cancelled successfully. The test is now disabled. Production
priority/caps persistence and acknowledgement behavior were not replaced.

This supersedes the installation/readback status of the earlier
[editor-only V1 experiment](async-save-scratch-2026-09-29.md), not its historical
results. It proves a usable engine API path on this server, **not a stutter fix**.

## Changes and checks

- V2 Blueprint uses stock AsyncSaveGameToSlot followed by AsyncLoadGameFromSlot.
  Independent LoadScratch supports recovery. ActiveSlot is captured before
  yielding; both entry points share a Busy guard. The actor retains native record
  references; Lua retains only names and plain request state between callbacks.
- Editor tests cover exact async readback, overlapping opposite-slot Submit
  rejection, forced GC, null-record failure, standalone recovery and a fresh
  process reload. Cook/package verification passed. These are not storage-fault
  tests or exhaustive overlapping Submit/Load phase tests.
- Pure-Lua experimental queue now has asynchronous recovery and readback. Delayed
  completion, uncertain outcomes and failure/recovery regressions pass. The live
  driver exercises the engine bridge directly, not that queue's orchestration.
- A standalone developer mod reads an explicit boot token, writes only two fixed
  synthetic slots, checks trial scope/generation/payload/checksum, and stops at
  completion or a 180-second deadline. It polls every 500ms on the game thread.
  Startup logging precedes arming the timer. A session tag detects actor reuse.
- Final local run: all **79 regression scripts passed**, 51 production modules
  compiled. An independent agent reviewed the driver and both live logs without
  finding a blocker; it explicitly rejected interpreting this as frame evidence.

## Installed identities

RAM GPortal server 8684515. Uploaded files were downloaded again and hash-checked.
The read-boot UE4SS log identifies **v3.0.1 Beta #0, Git ba2efd55,
Game__Shipping__Win64 (MSVC)** at 21:03:46.972. Client title screen showed
Palworld v1.0.5.102999; this is a client identity, not an independently extracted
server executable version. Runtime evidence is retained as
`test-results/save-scratch-v2/ram-ue4ss-read-boot.log`.

| Artifact | Location / SHA256 |
|---|---|
| Driver | `/Pal/Binaries/Win64/ue4ss/Mods/PWPAsyncSaveScratch/Scripts/main.lua` |
| Driver SHA256 | `4fdc90d9caddf6d2e3cd398bd2130646ff42cda4cc7601449807c2ce629d1624` |
| Separate pak | `/Pal/Content/Paks/PalWorkPrioritySaveScratchV2.pak` |
| Pak SHA256 | `094c0ed6a0104da8163cadc19eaa06953405cf1472957fe7c9ed9efb0093b757` |
| Assets | BP_ScratchRecord and BP_ScratchBridgeV2, four cooked files total |
| Slots | `PWP_SaveScratch_v1_A` / `PWP_SaveScratch_v1_B` |
| Trial identity | `ram-20260929-2058`, persisted in scope and checksum |

Build artifacts/logs: `test-results/save-scratch-v2/`. Build manifest describes
the build-time editor-only state; this document records subsequent installation.
Neither pak nor driver belongs in release staging. No production files were
uploaded during this trial. Client datafile.lua hash remains
`e87094dbb64dc7858e91301832dc3de4b7824abfe7bc8253aaa40ad4b381fef1`.

## Live measurements

Times below are from engine world-real-seconds, **frame-quantized**. Each stage
includes asynchronous waiting and callback scheduling; it is not CPU occupancy.
Lua enqueue timings have unmeasured clock resolution; printed zero is not zero
cost. Observed completion additionally includes the 500ms polling delay.

| WRITE sample | Bytes | Save interval ms | Read interval ms | Total interval ms | Lua enqueue ms |
|---|---:|---:|---:|---:|---:|
| 1 | 32 | 33.240 | 57.570 | 90.809 | 0 |
| 2 | 4,096 | 34.042 | 33.038 | 67.080 | 1 |
| 3 | 32,768 | 232.613 | 891.110 | **1,123.722** | 0 |
| 4 | 65,536 | 33.041 | 33.036 | 66.077 | 1 |
| 5 | 32 | 33.052 | 33.026 | 66.077 | 0 |
| 6 | 4,096 | 33.036 | 33.040 | 66.076 | 0 |
| 7 | 32,768 | 33.045 | 33.036 | 66.080 | 0 |
| 8 | 65,536 | 33.380 | 33.777 | 67.158 | 0 |

WRITE boot: 19:02:18 UTC (21:02:18 local), READY 19:02:20, COMPLETE
19:02:29. All eight exact readbacks passed; nine pending polls. Total measured
enqueue 2ms, setup 41ms, actor re-resolution 118ms. The last two are partial
harness costs, not complete callback budgets. Synchronous harness logging and
record construction/checksum validation add unpriced costs.

READ boot: 19:03:49 UTC (21:03:49 local), READY 19:03:52, COMPLETE
19:03:54. Record 7/A (32,768 bytes) read interval **33.735ms**; record 8/B
(65,536 bytes) **33.041ms**. Both exact records recovered with the same persisted
trial identity; enqueue printed 0ms, observed intervals 550/549ms. Setup 40ms,
re-resolution 50ms. No FAIL in either run; `timer_cancelled=true` in both.

Evidence: `ram-write.log`, `ram-write-read.log` in the artifact directory.
The main mod log independently records fresh 0.5.0-rc1 boots at 21:02:18 and
21:03:49; scheduler ticks continued afterward. Unverified assignments while no
player was connected are not evidence of successful scheduling acceptance.

## Final state and limits

Server run.txt saved as `PWP_SCRATCH_V2_DISABLED ram-20260929-2058`; parser refuses
to arm another trial on future boots. The current read timer already stopped.
Pak and scratch records remain for inspection. Proof: `ram-disarmed.png`.
The existing server macro rejoined with a fresh client process, verified RAM's
guild at 21:06:17, and the Monitoring Stand visibly showed its priority numbers.

The 1.12s completion outlier remains unexplained. These samples ran just after
server startup, with no connected player. There is no independent frame-time
capture, matched baseline, aged-session measurement or proof that serialization,
deserialization and callback work cannot stall. Native async file IO does not
make every phase run off the game thread. No percentage stutter reduction is
claimed.

Next acceptance: a warm, populated scratch trial with bounded game-thread callback
measurements and independent frame evidence; queue/adapter integration tests;
interruption, unreadable/corrupt slot and storage-failure handling; then scoped
ownership, migration/backups, bounded retries, pending/durable acknowledgements
and shutdown behavior. A successful callback/readback does not prove physical
power-loss durability. Keep the checked production writer until those gates pass.
