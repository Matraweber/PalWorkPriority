# Scoped asynchronous save prototype â€” October 3, 2026

V6 extends the separate rooted V5 mailbox with immutable world/guild/stream
storage and explicit owner epochs. Production persistence is unchanged.

## Contract

`BindStorage` accepts two nonzero 32-digit GUIDs and exactly `priorities` or
`limits`. It canonicalizes case and derives the same collision-free development
slot names as `experiments/save_scope.lua`. Storage cannot be rebound.

`BindOwner` takes a positive epoch. A current owner may retire, but pending IO
and an unconsumed terminal result must drain before a strictly newer epoch can
claim the object. Retirement prohibits new admissions, not completion or exact
consumption. Same owner text in another epoch does not grant old callbacks
access. Operation tickets remain monotonic across handovers. No wrappers are
stored by the Lua live driver between callbacks.

## Native evidence

`test-results/save-scratch-v6/`: native build, verification, asset reload,
fresh-process readback, Windows cook and four-file pak validation passed.
The scope matrix writes all sixteen A/B slots (two worlds, two guilds, two
streams) before reading any back. It checks canonicalization, invalid identities,
immutable binding and pairwise uniqueness. Fresh-process checks read persisted
payloads instead of issuing replacement writes.

Additional cases cover retirement with a pending read, retirement during
save/readback, forced garbage collection, retained terminal results, stale epochs,
monotonic tickets and completion-callback reentry that retires, consumes, claims
a newer epoch and starts another read. Reentry test graphs are not shipped.

One initial fixture failure was a collected raw class pointer in the comparison
oracle: generation, session and payload still matched. The oracle now explicitly
owns its class through forced GC. The failed diagnostic log is retained.

Independent review found no confirmed logic defect in the inspected scope.
The live driver regression uses the real scope encoder and detects 30 injected
failures, including stale request admission, premature takeover, ticket reset,
old acknowledgement damage and unexpected synchronous completion. All 88 Lua
regression scripts pass; 51 production modules compile under Lua 5.4.

Coverage limits: forcing GC while a save is pending does not deterministically
place it inside the retired readback subphase. The reentrant replacement proxy
also has no separate forced-GC assertion yet. Do not describe those narrower
interleavings as specifically demonstrated.

## Live acceptance

Passed the isolated V6 trial through the documented normal client restart into
RAM, October 3 at 12:37–12:38 local time. Evidence:
`test-results/save-scoped-live-20261003/` (installation receipt, full Lua run,
scoped log, UE4SS log and acceptance receipt).

The actual UE4SS Lua 5.4 VM ran the transport/session fixtures, then the native
coordinator wrote and read back exactly 65,536 bytes. The driver observed Busy
before retirement, rejected undrained handover, consumed the exact result,
claimed epoch 2 and rejected stale epoch-1 request/retirement/acknowledgement.
Read 102 remained unconsumed from the splash world through MainWorld5; only then
was it consumed, epoch 3 claimed and retired. All native/Lua slot names matched.

The timer cancelled and V4/V5/V6 controls are DISABLED. Eight diagnostic files
were hash-verified; all production Lua hashes remain identical to installation.
The final production-log window contains the expected dedicated-client authority
warning and no other WARN/ERROR. The macro verified the RAM guild handshake;
a fresh screenshot confirmed the Monitoring Stand open with priority numbers.
Synthetic identities only: no real server storage identity, settings migration
or server installation. Independent review agreed with the bounded live verdict.
Pending-IO world teardown is separate native-fixture evidence; this live travel
held a completed result, not an IO operation still in flight.

## Remaining integration gates

Per-object binding is not process-wide native singleton enforcement. Persistent
world/storage identity discovery, missing versus unreadable classification,
copied completion envelopes, larger payloads, migration/backups and truthful
network durable acknowledgements remain. This prototype makes no frame-time or
stutter-elimination claim. Keep the production baseline-capture barrier.
