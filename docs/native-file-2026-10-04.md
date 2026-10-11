# Native background file publication: October 4

Production asynchronous saving remains disabled. This closes a disposable-file
experiment, not real-settings integration or durable acknowledgement.

## Checked build and isolated installation

The native first-publication primitive was connected to the public-header
LuaMadeSimple entry, with nine exact runtime wrapper imports and no separate Lua
runtime. A second export supplies thread/QPC identity without IO. The fixed
scratch root is compiled into the probe; Lua cannot choose a save destination.
The input is validated hex and copied into owned native bytes before IO.

DLL SHA256:
`7b6b2b2341b8d652d0200bde7fcb27cf49325fa7e587f73bca4d4ca4c22aae44`.
Runtime SHA256:
`21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8`.
Build details: `experiments/native-file-probe/build/receipt.json`.

Review found and fixed a directory-handle ownership gap if vector allocation
throws. All 16 native initialization regressions passed afterward. Offline
publication/conflict, Lua adapter failure cases, and exact-link checks passed.
Offline scratch files were hash-checked and archived without deletion before
installing PWPFileProbe separately. Production Scripts were not deployed.

## Live result

The normal restart macro exited PID 38048 and launched PID 42708. World-ready
session 1 was recorded at 11:41:16 UTC. Both operations ran later:

| Phase | UTC | Native inclusive duration | Result |
|---|---|---:|---|
| Initial | 11:42:07 | 17.6866 ms | Published 262144 bytes |
| Conflicting payload | 11:42:22 | 30.6263 ms | Refused replacement, Windows error 183 |

Worker thread 25676 differed from game/completion thread 35196. These durations
include decoding and publication work; they are not game-frame durations.

An external reader compared every byte to `bytes(range(256))*1024` immediately
after each completion. The first comparison preceded the second operation.
SHA256 remained
`2312394bd99545d9de131c24efb781e765ac1aec243f2ed9347597a793a415e9`.
The different 35-byte payload did not replace the original. The native checksum
describes attempted input, so it was not used as disk-readback proof.

Evidence: `test-results/native-file-live-20261004/` contains installation,
readbacks, raw log, loaded module paths, macro log and acceptance. The standalone
acceptance tool rejects missing phases, inert runs, duplicate/failed events,
wrong identity, false byte receipts, wrong destination and late readbacks.
Its archive checks rely on the captured reader receipts; they do not themselves
repeat physical readback or authenticate arbitrary fabricated archives.

After completion, the probe disarmed itself and its enable marker was renamed.
No forced native-library unload was attempted. Production Scripts still match
the pre-test fingerprints. Status reports saved priorities/limits and authority;
a fresh screenshot shows stand numbers. This is not a performance acceptance.

## Remaining integration gates

First publication intentionally refuses an existing destination. We still need
safe successive generations and recovery, native ownership across duplicate
loads/reloads, queued/in-flight retirement, trusted active-storage/session
binding, and acknowledgements only after validated persistence. A timed-out
callback cannot cancel an OS write. No power-loss guarantee or bounded shutdown
latency has been established. These gates must pass before production enablement.
