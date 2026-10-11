# Native whole-journal Lua adapter

Development-only. No production module loads this adapter. It accepts an already
bound native ID, never a pathname, and does not prove authority or current world.
Use the separate fresh local binding policy before admitting real work.

`save_native_backend.new` captures the native function, immutable scope,
incarnation, epoch, binding and game-thread ID. Its plain functions implement
`PWP-JOURNAL-DEV-1` for `save_journal_queue`. One operation can be outstanding.
Tickets increase across rejected admissions as well as accepted ones.

`schedule(fn)` routes to the runtime worker and `resume(fn)` routes to the game
thread. A scheduling exception or explicit false after native admission is
uncertain, not a retryable rejection. A nil scheduler return is accepted because
the runtime's scheduling API need not return a receipt. The callback is only
diagnostic: polling the retained native terminal decides completion. A lost
callback cannot lose the durable completion or trigger a second publication.

Only explicit native admission status zero is a definite rejection. Invalid or
missing replies retain the outstanding operation. Unknown publication results
cannot be consumed, retried or replaced. Successful consume is locally
idempotent; the native bridge must independently support retries when its success
reply was lost. Retiring/releasing the native owner is deliberately outside this
adapter: first revoke submissions and drain the original queue's accepted tail.

The fixed ABI takes command, binding, ticket, lowercase hex and hex byte count.
Input is a bounded list of length-prefixed binary strings encoded as hex because
the pinned public string getter uses a null-terminated view. Output uses the
public length-aware setter and carries binary strings directly. Reply shape,
thread identity, timing metadata, scope and epoch are checked before accepting
the result. Slot/payload semantic policy remains in the typed queue/codec.

Tests: `tests/test_save_native_backend.lua` and
`tests/test_native_settings_composition.lua`. These use a mocked native ABI;
native entry, filesystem and in-game trials are separate evidence.

`tools/bench_save_wire.py` compares input encoding using Lua 5.4 CPU time.
The lookup table avoids formatting every byte. Measurements are an offline
microbenchmark, not frame-time evidence; results below timer resolution must
not be interpreted as zero cost. The current receipt is
`test-results/native-wire-benchmark-20261004.json`.
