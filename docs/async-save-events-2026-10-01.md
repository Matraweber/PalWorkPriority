# Async-save completion events — October 1, 2026

Status updated October 2: native completion delivery, null-input failure and
controlled-restart readback passed. V2 and V3 controls read back DISABLED.
Production persistence is unchanged. This is an isolated developer experiment,
not a release or production queue integration.

## Purpose and boundaries

V2's optimized warm trial still spent 1255 ms across 49 bridge resolutions:
24 dispatches and 25 completion polls. V3 receives an engine completion event
and copies only scalar record data inside its current callback. Waiting timer
callbacks inspect that Lua inbox without resolving a UObject. Dispatch still
resolves fresh and validates the bridge's incarnation. No engine wrappers are
retained across callbacks; missing hooks/results fail closed, without a polling
fallback or a retry of uncertain storage operations.

The generated V3 bridge calls a nonempty, public, zero-argument UFunction
`ScratchCompleted` after publishing its terminal state, on both success and
failure. The receiver validates incarnation, path and ticket and bounds the
copied payload. It rejects stale/duplicate results and stops accepting callbacks
after completion. Callback costs are inclusive; overlapping timings must not be
added as independent work.

## Offline evidence

- Lua 5.4 compiles 51 production modules; all 83 regression scripts pass.
- New completion-inbox and event-driver suites cover copied ownership, stale
  and duplicate events, inline null-save failure, missing hooks/results,
  timeouts, READFAIL recovery and the 24 distinct WARM generations.
- Pending completions perform no global bridge lookup in the driver fixture;
  a mutant restoring that lookup is rejected.
- Native editor verification confirms the callable function has 202 script
  bytes, terminal state precedes completion, busy rejection emits no completion,
  success/failure/recovery each emit exactly once, and forced-GC readback works.
  Fresh-process native verification, cook and pak generation passed.
- These native editor checks do not establish UE4SS hook delivery on RAM.

## Live protocol

Trial nonce: `event-20261001-174304`.

FAILURE writes synthetic slot A generation 1 and verifies its exact record,
submits a null save expecting an explicit failure, then rereads generation 1.
READFAIL after another controlled restart must recover the same record. This
tests invalid-input failure and retained prior data, not full disks, physical
storage failure, interrupted writes or power-loss durability. The driver has a
180-second timeout and touches only the named synthetic scratch slots.

V2 was verified DISABLED before installation. V3 scripts and pak were uploaded
and read back for hash verification, with FAILURE armed last. The production
writer's pretrial SHA-256 remains
`e87094dbb64dc7858e91301832dc3de4b7824abfe7bc8253aaa40ad4b381fef1`.

V3 pak SHA-256:
`00fd37d0d9d14f1a209a14bebae2c3c53dd4158ca50cf16af595cf3b81add61f`.

The October 1 restart initially remained in provider Updating with FTP connection
timeouts. Retrieval resumed October 2. The retained log establishes three
completed FAILURE boots: October 1 17:54:29–35 UTC, October 2 04:32:41–47 UTC,
and October 2 08:12:02–08 UTC. The latter two demonstrate that the armed control
replayed on later boots; their restart cause was not established.

Each run verified the 32-byte generation-1 record, received an explicit null-save
failure, and read the seed back exactly. Each reports three samples, three hooks,
two post-initialization bridge resolutions, and timer cancellation. Those two
resolutions are request dispatches; waiting callbacks read only the inbox.
The write/read engine totals were 127.673, 130.892 and 139.586 ms. The following
read-only totals were 33.029, 33.037 and 32.698 ms. Hook totals were printed as
0, 1 and 0 ms at unmeasured Lua clock resolution; zero does not mean free work.

After confirming the seed, READFAIL was uploaded and read back before a single
controlled restart on October 2. The run armed at 16:22:08 UTC and completed at
16:22:11 UTC (18:22:11 Europe/Berlin), recovering the exact generation-1 record
without writing. Engine read time was 33.797 ms; observed time 515 ms includes
the 500 ms observer cadence. It reports one sample, one hook, no subsequent
bridge resolutions and successful timer cancellation. Initialization supplies
the bridge for that sole read; its 63 ms setup is not included in resolve_ms.

V3 was then set to DISABLED and verified by readback; a subsequent health fetch
also saved both DISABLED control files. Production datafile.lua still matches
the pretrial hash above. UE4SS identifies ba2efd55 / v3.0.1 Beta #0, and the
production mod reports 0.5.0-rc1, authority, settings available, 1 camp/9 Pals.
Boot includes a UE4SS GameEngine Tick vtable/scan-address warning; no scratch
failure appears. Ordinary scheduler lines still mark assignments unverified:
this test does not establish actual Pal activity. No game client was launched.

Independent review agrees with the narrow pass. Reused identical contents in
the three FAILURE runs cannot identify which previous write survived. This is
one selected slot, not alternate-slot/corruption/interruption coverage. Stopping
observation does not cancel an outstanding native operation or unregister the
hook/destroy the bridge. Production timeouts must remain unknown outcomes, not
confident failed writes or permission to retry blindly.

## Evidence and remaining gates

Raw build/native evidence: `test-results/save-scratch-v3/`.
Live evidence and latest offline receipt:
`test-results/save-scratch-events-20261001/`.
The generated build manifest describes build-time installation state; the
separate live trial record tracks actual deployment.

No frame capture is part of this startup functional test. No measured frame-time
gain or stutter-free claim follows from eliminating polling in the prototype.
Production queue integration, ownership across session changes, migrations,
durable edit acknowledgements, real storage faults and matched populated
performance acceptance remain gates.
