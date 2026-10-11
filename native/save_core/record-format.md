# Experimental record envelope and recovery candidate

Not installed in the game; no save writer calls this codec yet.

Wire layout: eight bytes `PWPJNL1\n`, little-endian uint16 scope length,
uint32 generation, uint32 payload length, scope bytes, payload bytes, then
32 raw SHA-256 bytes over all preceding bytes. The fixed-width scope is exactly
`PWP-SCOPE-1:<32 lowercase hex storage>:<32 lowercase hex guild>:priorities|limits`;
zero GUIDs are rejected. Generation range is 1..2147483646. Empty opaque payloads
are allowed by the envelope; settings validators decide whether they are valid.

Hashing uses the Windows BCryptHash API, checking its result. Reference:
https://learn.microsoft.com/en-us/windows/win32/api/bcrypt/nf-bcrypt-bcrypthash
SHA-256 detects integrity failures, not provenance or malicious modification.

Payload capacity is 262144 bytes. Maximum parser allocation contract is 262450
bytes (18 header + 256 scope allowance + 262144 payload + 32 digest). Actual
maximum priorities envelope is 262282 bytes. Review found the first-publication
primitive's earlier 262144-byte total bound was insufficient. Its source now
accepts 262450 encoded bytes, independently tested with a maximum settings
envelope and exact upper boundary. The earlier installed probe remains its
original build. Callers must explicitly negotiate payload versus record capacity;
the existing 256 KiB hex probe has not acquired a larger contract automatically.

`decode` distinguishes valid, corrupt, unsupported, foreign and unreadable
(invalid expected scope). Unknown format or larger capacities block fallback.
Hash service failure throws: caller must classify it unreadable, not corrupt.
Only a trusted filesystem reader may report missing; decoding bytes never does.

`candidate` selects the newer of two valid records. Equal generations with
different payloads block. Valid+corrupt may return the valid candidate. Foreign,
unsupported and unreadable block even if the other slot is valid. Both missing
returns the empty candidate; all other no-valid combinations block.

This does not authorize initialization or replacement. Before selection is used,
the caller must validate settings schemas on BOTH integrity-valid records,
establish the same expected active scope and exclusive writer ownership, and
preserve classifications through the publication decision. Test CLI sentinel
arguments MISSING/UNREADABLE simulate reader outputs and are never production
filesystem evidence. Staging files are not recovery candidates.

Verification: `python tools/test_native_record.py` builds a release CLI, runs
native tests against a separately implemented Python wire encoder, and writes
fingerprinted evidence to `test-results/native-record-20261004/`. It checks
binary/empty/max payloads, generation ordering, conflict ties, truncation at
every byte of one small record, header/scope/payload/digest mutations, and all
36 pairs of six read classifications. No game, disk-fault or power-loss test
is claimed by this suite.
