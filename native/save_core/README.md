# Experimental native first publication

## Additional isolated components (October 4)

The directory now also contains `record` (bounded integrity envelope and A/B
candidate selection), `record_reader` (checked local filesystem reads), `owner`
(cross-module/process claim and retained terminal mailbox), `journal` (checked
A/B updates preserving the latest generation), and `operation` (immutable owner
and destination binding for one execution). All remain development components;
none is a shipped UE4SS backend. The first-publication limits below describe
`initialization`, not the entire directory.

Run `tools/test_native_record.py`, `test_native_save_reader.py`,
`test_native_owner.py`, `test_native_save_journal.py`, and
`test_native_operation.py` for the corresponding native tests. They write
fingerprinted receipts under test-results and use disposable filesystem roots.
Do not treat the absence of a game test or active-storage verifier as a pass.

After successful journal publication, only this call's exact just-renamed
inactive backup handle is marked for deletion and closed, while both the new
target and prior active record remain exclusively held. Successful cycles no
longer accumulate backups. No pathname-based or preexisting-artifact cleanup is
performed. Interrupted stages/backups and cleanup failures still consume the
32-entry root-wide artifact budget; reaching it safely refuses further writes.

A failure before delete disposition is accepted retains the backup and returns
`updated` with `error=0` and a separate `cleanup_error` warning. It must never
authorize retrying publication. The operation mailbox adds an optional
`:cleanup-error=<code>` suffix while retaining its publication status/certainty.
Once disposition succeeds, close failure or process termination may remove the
backup; close ambiguity returns `uncertain`, without promising retention or an
ACK. Root-wide serialization/budget checks never delete unknown evidence.

Tests include 300 successful alternating writes, exact artifact preservation,
cleanup failure/interruption boundaries, and recovery of the newest generation.
These are process-level and injected-error tests, not power-loss durability.
Uncertain outcomes retain the owner and currently require process restart/recovery;
never silently switch to a synchronous writer while an old native operation
might still run. Storage authority and production integration remain unproved.

## Initial-publication primitive

This standalone Windows core is **not a UE4SS mod, installed helper, or enabled
asynchronous save backend**. It needs no Unreal headers and is tested only in
disposable folders. It is one prerequisite for explicit first initialization.

`initialize` accepts an existing local fixed-drive directory, two lowercase
32-hex scope identifiers, priorities/limits, and 1–262450 immutable encoded bytes.
The separate settings payload cap remains 262144 bytes; the extra bound permits
the versioned envelope. Callers must still negotiate both limits explicitly.
The caller still must prove the active storage destination, authority, schema,
checksum and payload scope. This routine provides none of those proofs.

It pins ordinary directory ancestors without delete sharing, rejects reparse
directories and ambiguous path syntax, exclusively creates a random stage, and
checks write length and flush results. It publishes that same exclusively open
handle with non-replacing `FileRenameInfo`, then closes it. This prevents the
close-before-rename stage substitution gap found in independent design review.
Existing targets are never removed or replaced. Competing publishers arbitrate
at the rename, not at an earlier absence check.

Results distinguish publication, invalid input, name conflict, IO failure, and
**publication followed by a close error**. The latter must never be treated as
a definite no-write failure or acknowledged without reconciliation. Failed
stages are not deleted by this primitive and must never be recovery candidates.
There is no automatic orphan cleanup or retry loop; a future owner must bound
retries and retention. Empty payloads are deliberately invalid for this contract.

Limits:

- No power-loss or directory-entry durability guarantee. Published is not a
  durable-settings acknowledgement.
- One target only; no existing-save update, A/B migration or recovery reader.
- Trust the configured local storage and its administrators. Denying delete
  sharing does not prove protection against hostile filesystem reconfiguration,
  mount remapping, privileged mutation, or in-place ancestor reparse changes.
- Payload validation and process-wide leases remain higher-layer duties.
- Directory pinning is deliberately short-lived; do not hold pins while waiting
  on another service. Test-only pauses do so solely to exercise races.
- CppUserModBase integration remains blocked on the exact authorized UEPseudo
  dependency. A separate public-header Lua entry has passed a constant-only
  game test. A separately isolated Lua entry now connects this primitive for a
  fixed-root disposable background publication/conflict test; see
  `docs/native-file-2026-10-04.md`. No production backend is enabled.

Build the disposable CLI with `tools/build_save_initialization.ps1`. Its
`PWP_INITIALIZATION_TESTING` hooks are absent when that define is omitted.
Set `PWP_NATIVE_INIT_EXE` to the resulting executable to run
`tests/test_native_save_initialization.py`; without it those tests explicitly
skip. The CLI is a test program, not a DLL to copy into the game.

Tests cover full binary/256 KiB payloads, rejected sizes and paths, existing
empty/nonempty/directory targets, scope separation, missing parents, junctions,
two synchronized processes, an external winner, stage mutation/rename refusal,
root rename refusal, pre-publication process termination, and failure boundaries.
Boundary injection simulates an error before/after OS operations; it does **not**
establish real disk-full, FlushFileBuffers-failure, CloseHandle-failure, short-
write, ACL-denial, sudden-power-loss, or in-game behavior. Those remain separate.
