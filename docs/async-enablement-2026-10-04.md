---
date: 2026-10-09
tags: [async-save, native]
status: evidence
---
# Asynchronous saving enablement — October 4, 2026

Related: [async-save-route-research-2026-10-04](async-save-route-research-2026-10-04.md) · [async-save-history](async-save-history.md) · [staged-recovery-native-2026-10-11](staged-recovery-native-2026-10-11.md) · [work-log-2026-10-09-to-11](work-log-2026-10-09-to-11.md)

**Status 2026-10-20: async stays off; 0.5.0 ships the synchronous writer unless
optional gate G2b closes first ([RELEASE-0.5.0.md](RELEASE-0.5.0.md) G2/G2b).**
The checked local async trial was disarmed on 2026-10-11 and the client runs the
shipping path ([DECISIONS](DECISIONS.md), Test installation). The sections below
are chronological evidence from 2026-10-04 to 2026-10-09; the last dated
sections hold the latest limits. The parked cutover tooling of 2026-10-04..11
is summarised in the final section. The rejected Blueprint routes before this
are in [async-save-history.md](async-save-history.md).

User authorized implementation and testing through eventual enablement. That
authorization does not waive the data-integrity gates. Public installations keep
the synchronous default; the explicitly checked local trial (disarmed
2026-10-11) was the exception, not public release acceptance.

## Evidence acceptance

Added `tools/accept_save_transition.py`: a separate acceptance command, not a
log collector. Nonzero exit on incomplete/failed evidence, wrong phase order,
wrong world/role/load state, insufficient dwell, mismatched process receipts,
evidence predating the process, wrong directory comparisons or failed timer
cancellation. The accepted result explicitly does not authorize async saving.

The archived reverse trial passes. Four Python tests include synthetic valid
evidence, deliberately corrupted variants, deletion of every individual phase,
process/nonce mismatches, and actual CLI exit checks on incomplete archives.
Full Python suite:124 tests pass. Existing Lua suite:102 scripts pass before
the subsequent snapshot extraction. Archive validation trusts the recorded
installation/hash receipts; it is not a fresh check of deployed files.

## Snapshot preparation

Extracted `store.serialize()` and `caps.serialize()` from the current synchronous
writers. They return immutable full text snapshots without disk IO, generation
advancement, notifications or claiming saved state. The synchronous save paths
use the same serialization and retain their existing persistence behavior.
No async backend is connected and these source edits are not deployed yet.

The new regression checks X and OFF, deterministic ordering, isolation from
remote rules, validation failure and unchanged dirty/generation state. A300-Pal,
14-type fixture serializes to194799 bytes, including600 X rows. This exceeds the
64KiB prototype contract, so the previous native size trial is insufficient for
realistic larger rosters. Raising a Lua limit alone cannot close this gate.

## Work in progress and gates

- Headless current-world observation: isolated probe implemented, regressions
  passed and installed in a backed-up local test server; runtime blocked before
  UE4SS loads. No headless observation acceptance yet.
- Process-wide writer uniqueness: fixed shared registry prototype being built;
  per-coordinator V6 ownership is insufficient on its own.
- Positive absence: Engine's generic FileSize-based existence implementation
  cannot distinguish every access error. Exact runtime destination mapping and
  operation-scoped error classification are still required.
- Trusted active-storage binding and a distinct-local-save test remain open.
- Native interrupted IO/errors, recovery/migration with
  backups, baseline fence barriers, and generation-bound durable network ACKs
  remain open.
- Matched frame captures and full restart/readback acceptance follow integration.

Do not substitute successful observation or editor-only fixtures for runtime
acceptance. Do not mark the overall request complete until async saves have been
enabled safely and tested end to end, or report a concrete external blocker.

## Larger native record and restart recovery

Separate `ue4ss-save-scoped-large` driver reuses the unchanged V6 asset and
synthetic world8/guilde namespace. The existing driver fixture was adapted to
the new namespace/262144-byte payload; all30 failure cases are rejected.
The native local trial wrote/read back262144 exact bytes, then retained and
consumed the completed result across Splash→MainWorld5. Timer cancelled; arm
disabled; seven installed diagnostic files hash-verified; production unchanged.
Evidence: `test-results/save-large-live-20261004/`.

A separate read-only driver ran after the normal macro exited PID39116 and
launched PID37644. It invoked only LoadScratch(ticket201), recovered the prior
nonce-bearing record/generation101 exactly, consumed the result and retired.
It never invoked SubmitScratch/CreateSaveGameObject or rewrote the slot.
The dedicated regression rejects duplicate coordinators, corrupt/foreign data,
read failures, timeout, bad consumption and retirement. Physical development
slot contents independently contain the exact prior262144-byte payload.
Evidence: `test-results/save-large-recovery-20261004/` (including restart log).
After this restart a fresh screenshot confirmed the local stand with priorities
and X visible. This closes that visual check for this restart, not retroactively
for the earlier reverse-transition trial.

This demonstrates256KiB native capacity on this runtime and fresh-process
readback. It does not change the transport's64KiB contract, establish safe
production migration, prove power-loss durability, or cover arbitrarily large
settings. There is no frame-time claim.

## Filesystem error evidence

Two actual Windows Lua5.4 file-IO tests use disposable temporary files:
an empty file is readable/present; absent file and absent parent both return
errno2; exclusive sharing denial returns a non-absence error; unlocking preserves
the prior bytes. This supports requiring a verified readable destination root
before interpreting absence, rather than changing `save_read` to accept any
false Engine existence result. These tests do not establish the Engine backend
mapping on every supported runtime/platform.

## Registry and headless runtime checkpoint

Fixed-CDO registry prototype passed28 editor checks, fresh-process reload, cook,
pak verification, and a Lua driver suite detecting28 injected failures. The
checked local install is a separate diagnostic with no save IO. Production
scripts remain unchanged. Its first restart was blocked by a Windows firewall
dialog; the exact restart macro process was stopped and the user was asked to
handle the security prompt. No registry live result is recorded yet.
Evidence: `test-results/save-registry-v1/20261003T232926518771Z/`,
`test-results/save-registry-driver-v1/`, and
`test-results/save-registry-live-20261004/installation.json`.

`tools/accept_save_registry.py` requires every exact phase, successful timer
cancellation, one nonce, monotonic timestamps and unchanged process identity.
Missing phases, duplicates, changed process, late failure and an empty archive
fail acceptance. Even successful fixture acceptance explicitly grants neither
production integration nor async enablement. Python suite:130 tests passed at
this checkpoint. These are offline tests, not a substitute for native results.

The local server's original SaveGames directory was copied to the test archive;
the old native runtime was moved intact to its named PWPTestBackups directory.
A checked2281fa31 runtime and the observation-only probe were isolated for the
test. Explicit Workshop path, server install rule and enabled package settings
were verified. Server world loading alone succeeded, but UE4SS was not present
in loaded modules, no new runtime log or ManagedMods manifest appeared, and the
probe arm was untouched. Trying both server entry points did not establish a
cause. The firewall prompt is not evidence of that cause. Do not count these
launches as passed mod tests or deploy this setup to a user's remote server.
Receipts/config backup/world backup: `test-results/save-headless-live-20261004/`.

## Integration review findings

The existing synchronous baseline barrier is already covered by
`tests/test_scheduler_persistence.lua`: a failed capture's in-memory row cannot
bypass `settings_ready`, including after a second edit changes error to saving.
That test passes; no speculative baseline fix was applied. Async integration
must replace the synchronous proof with required-versus-durable generation
checks, not weaken it to "accepted".

Full serializers currently cover all stored Pals/guilds. They must not be sent
as independent guild-owned snapshots. Scoped partitioning must preserve orphan
legacy Pal rows and `ANY_GUILD` provenance until explicit migration; loaded-camp
absence cannot authorize deletion. Durable edit acknowledgements need captured
request coverage, scope, incarnation and committed revision, not the latest UI
revision when an older completion arrives.

Local Engine source confirms the generic SaveGame backend builds
`ProjectSavedDir()/SaveGames/<slot>.sav` and ignores UserIndex in that path.
The measured development slot lies outside the account/world directory. This
correlation does not verify every deployed backend/root. Generic existence
uses a negative file size as DoesNotExist, losing native errors. A future
verifier must distinguish missing leaf from inaccessible/missing parent and
capture results under the reservation. Even that observation does not prevent
an external writer creating a file before initialization; in-process registry
tests do not prove exclusive-create or cross-process exclusion.

## Capacity agreement and downgrade protection

Experimental session/queue/transport/read boundaries now negotiate a captured
payload limit:64KiB by default, explicit matching agreement up to256KiB. No
implicit upgrade from a peer's larger advertisement. Terminal capacity must
match before consumption; a mismatch retains ownership and may resolve only
when the matching result arrives. Cap+1 writes are rejected before admission.

The real300-Pal serializer and large OFF-containing limits snapshot pass the
pure full pipeline, including coalescing and reconstruction of a fresh reader.
This pipeline uses fake IO and establishes no native authorization. Persisted
oversized data is unreadable rather than replaceable corruption: a64KiB reader
cannot fall back to an older small generation and overwrite a valid256KiB one.
Classifier, transport and queue independently enforce that rule. Downgrade
regressions cover both A/B orders and incorrect lower-layer classifications.
111 Lua scripts pass at this checkpoint; later partition work is separate.

## Native integration not yet implemented

V7 does not exist. The agent's inspected next design is a bounded retained-scope
CDO registry integrated into every admission/completion/consume/retire/release
path, plus one callback receiver per operation carrying immutable scope, owner,
epoch, ticket, kind and slot. Keep high-water marks after release; refuse full
capacity instead of evicting. Verify bootstrap anchoring and callback publication
reentry. Generated map wiring, native IO integration, cook and shipping travel
would all require new evidence. The successful standalone two-scope registry
build must not be described as this integrated implementation.

Local test server is now stopped. Its original runtime and exact prior config
were restored; experimental runtime was archived intact, diagnostic arms
disabled, and save directories were not moved by restoration. Receipt:
`test-results/save-headless-live-20261004/restoration.json`. The Windows firewall
dialog remained visible after teardown; it still requires the user's action.

## Scoped snapshot checkpoint and final offline validation

`experiments/save_partition.lua` copies explicitly supplied records into guild
snapshots plus a separate legacy preservation bundle. Unknown Pal ownership,
wildcard rules and noncanonical legacy guild groups are preserved without
duplication into active guild payloads. Conflicting claims, case aliases,
foreign storage and invalid work groups fail the partition. Every result is
`verified=false`; it supplies no current-world or ownership proof.

Store/caps now expose pure `serialize_snapshot` formatters; their normal full
serialize/save/load behavior remains unchanged. Regression uses those real
formatters, proves row conservation, X/OFF and wildcard provenance, copied
records/immutable strings, no IO and unchanged module state/generation. No
production deployment or migration occurred.

Final offline run:51 production modules compile,112 Lua regression scripts and
130 Python tests pass. Receipts/logs/source hashes:
`test-results/async-enablement-20261004/offline-final.json`, `lua-final.log`,
`python-final.log`. These results do not enable async production persistence.

At pause: client remains in its existing process with the Windows firewall
dialog covering it; restart macro was stopped. The isolated no-IO registry
fixture is installed and armed for the next normal restart, but has not run.
Handle the security prompt personally, then re-observe the game before using
the restart macro. Native registry integration, active-storage verification,
positive absence/initialization, migration and durable network acknowledgements
remain open after that immediate UI blocker.

## Continued live registry trial

The user cleared the firewall prompt. Source/install hashes and the sole armed
diagnostic were checked before the normal restart. Old client PID37644 exited;
new PID41756 (UTC start23:46:19.2556280) completed all five registry phases.
At23:46:24 duplicate same-class and independent-class claims were refused and
distinct scopes admitted. At23:46:59 busy/terminal state survived Splash→
MainWorld5, drained ownership transferred, stale owners were refused and the
timer cancelled. A fresh screenshot confirmed the stand with priorities/X.

Strict acceptance passed; installed hashes still match and the arm is disabled.
Evidence: `test-results/save-registry-live-20261004/acceptance.json`, archived
log, restart log and process receipts. Initial receipt composition through
PowerShell normalized a trailing zero in the start timestamp, causing strict
string equality to reject it. The rejected receipt is retained; recomposition
from the original raw before receipt preserves the exact unchanged timestamp.
No validator requirement was weakened and no native result was altered.

This closes the standalone two-scope registry's shipping travel fixture. It is
not integrated native-save protection or authorization to save real settings.
Next bounded work:32-scope retained registry fixture and a read-only runtime
root probe using Engine `KismetSystemLibrary.GetProjectSavedDirectory` (UE5.1
source returns the full `FPaths::ProjectSavedDir`). Correlate that copied root
with the previous exact native development-slot readback; do not infer active
world identity or positive file absence from a path alone.

## Runtime root and repeated read-only recovery

Installed the independently tested root observer only after source/hash checks,
and rearmed the unchanged read-only large-record recovery driver. Normal restart
PID41756→29720 completed. Engine reported
`C:/Users/matra/AppData/Local/Pal/Saved/` at23:52:59 UTC. The derived exact
development slot matches the previous native record's physical path, SHA256
and nonce-bearing262144-byte payload. Fresh native recovery returned the same
record at23:53:00 with writes=0 and timer cancelled. No new native save was
performed in this particular trial.

Root observer's enabled marker was renamed after completion; recovery arm is
disabled. Source/install hashes and production hashes match. A fresh screenshot
after the macro completed showed the Monitoring Stand's priorities and X.
Evidence: `test-results/save-root-live-20261004/acceptance.json`, root/recovery
logs, restart log and post-callback process observation. The receipt explicitly
labels that process observation as after callbacks, not a pre-operation capture.
Game executable/runtime hashes are included for this bounded correlation.

This establishes observed root/slot/readback correlation on this configuration,
not active-world binding, absence classification, external-writer exclusion,
native integrated ownership or production async enablement.

## Guarded 32-scope registry: editor and shipping travel

Review rejected the first V2 map build: a nested call before `Map_Add` could
claim an entry between the recheck and insertion. The replacement acquires a
registry-wide game-thread reentry guard before any helper UFunction. Nested
rejection does not release the outer guard; owner returns evaluate their result
before unlocking. Native editor prehooks exercise map insertion, entry comparison
and first-helper reentry across all six methods. Generation and fresh reload
each pass 38 checks; build/cook/pak and preservation checks pass. Receipt:
`test-results/save-registry-v2/20261004T000227486484Z/receipt.json`.

The guarded build alone was installed, after source/pak hashes, disabled arms
and unchanged production Scripts were checked. Normal restart PID29720 to
PID44364 (UTC start00:09:04.1732318) passed the six-event V2 protocol. At00:09:09,
32 entries were retained and the 33rd refused. At00:09:45, pending and terminal
operations survived Splash to MainWorld5; stale owners/epochs/tickets were
refused, drain/reclaim succeeded and the timer cancelled. The first process
receipt was captured during pending travel, then matched after completion.
The stand visibly reopened with priorities and X after the macro completed.

Strict acceptance and installed hashes pass; arm is disabled. Evidence:
`test-results/save-registry-v2-live-20261004/acceptance.json`. This fixture
performs no save IO and provides neither cross-thread/external-process exclusion
nor integrated asynchronous-save acceptance. Production remains synchronous.
V7 integrated ownership/callback work is now underway; it has no acceptance yet.

Offline checkpoint after these driver/validator changes: 51 production modules
compile, 114 Lua regression scripts and 131 Python tests pass. This is offline
behavioral evidence, not authorization to enable asynchronous settings writes.

## Recovery semantics and shared-stream durability

Added pure bounded Store/Caps `decode_snapshot` APIs without changing legacy
load or write behavior. The new priority API rejects temporary slot identifiers
instead of silently dropping them. Tests cover real 1–5/X and OFF round trips,
duplicates, malformed/truncated rows, oversized inputs and no IO/state mutation.

The first `test_save_payload_semantics.lua` run failed because the queue admitted
invalid settings text. Captured `validate_payload` policy now rejects before
incrementing a generation or issuing IO. A checksum-valid but unsupported
recovery payload blocks the whole recovery in either slot order; it cannot
select an older generation and overwrite newer unknown settings. Policies must
be pure/nonreentrant and return literal true; raw diagnostic queues can still
omit one, but settings integration must supply it. Independent review and six
targeted suites passed.

`save_settings_codec.lua` adds a versioned storage/guild/stream/length envelope
around canonical real serializer output. It rejects unknown schemas, scope
mismatch, wildcard/foreign limit groups, extra/unsupported metadata and payloads
whose envelope exceeds negotiated capacity. Real queue tests use checksum-valid
unknown-version records and prove no fallback/writes. This is copied-data
validation, not active storage or Pal-ownership proof.

The first durability ledger's per-camp binding was rejected in review because
save generations belong to the shared guild stream. The replacement uses one
bounded ledger per stream, with per-entry camp ACK routes and per-camp baseline
coverage. The new regression uses one real session/queue for A1/B2/A3 edits,
coalescing, old completions, failure/retry and camp-specific replies. Four unsafe
barrier mutants remain rejected. None of this is wired into production yet.

## Native reference proof and initialization boundary

V7's latest reference receipt is
`test-results/save-native-v7/20261004T002234067345Z/receipt.json`:32 integrated
editor checks pass during generation and fresh reload, including real async
save/readback, stale operation callbacks, exact ACK retries and GC retention.
Fresh-process read-only verification leaves owned development-slot hashes
unchanged. The coordinator and operation receiver are editor C++ classes;
they do not exist in the shipping game. The final build emits no pak. An earlier
dependency-only pak is explicitly marked not a backend and was not installed.
This evidence does not authorize a shipping async backend.

The API audit and seven disposable Windows tests establish an initialization
gap: missing leaf, missing parent, sharing denial and access denial cannot be
reliably distinguished by the audited exposed Blueprint/Lua save APIs. Engine
normal writes can overwrite a file created after an absence check. The review
at [save-initialization-review-2026-10-04.md](save-initialization-review-2026-10-04.md) records the exact source
and tests. A typed native filesystem boundary and atomic initialization protocol
remain necessary; failed native loads continue to mean unreadable, never empty.
Supported version-matched C++ mod prerequisites are being recovered separately;
no helper has been installed or loaded into the game.

An isolated active provider now composes fresh copied role/world/GameState/guild
and lifecycle evidence, but deliberately returns candidate/unverified data until
a separate active-storage proof succeeds. Same-map host/client transitions and
evidence gaps retire prior incarnations. The engine collector, complete lifecycle
coverage, distinct local-world test and headless binding remain unproved.

Read-only client status at02:21:50 local: authority yes, two camps, priorities
and limits saved, storage scan complete with no recorded read failures. This
continues to describe the unchanged synchronous production path.

Independent codec review also reproduced a weaker adapter boundary: a newer
checksum-valid unknown payload labeled invalid, or a foreign-owner record,
could be skipped by the queue. The new regression failed before the fix. Queue
now refuses copied foreign records regardless of status, valid records labeled
non-ok, and any record labeled missing. It caches checksum validation once.
Both slot orders and ok/invalid/missing labels pass, as do 16 independent
adversarial cases. Adapter omission/falsification of evidence remains a native
contract responsibility; these checks do not invent absent metadata.

## Shipping helper prerequisite blocker

The selected next route is one version-matched native helper owning scalar IO
and the process registry. This avoids separate Blueprint and filesystem-helper
ownership systems. Workers must never access Lua/Unreal objects. `on_update`
is not a game-thread boundary in this runtime; shipping polling must use the
verified Lua/game-thread route. Native hot reload is unsupported until draining
and unload behavior are proven. No helper is installed or loaded.

Official source revision `2281fa311e417b1dfddedbcd49972d764fddb244` and both
matching release archives were retrieved and verified. Both archive DLLs match
the installed runtime SHA256 exactly. A minimal compile against untouched
headers fails on `Unreal/UFunctionStructs.hpp`, supplied by the inaccessible
pinned UEPseudo dependency `1cb4c98746f03dfcbf2f0394b59dfec0c9f83a04`. No private
types or virtual tables were reconstructed. A complete authorized matching SDK
and compiler/CRT compatibility verification are prerequisites to building this
helper. Evidence and legitimate acquisition route:
`test-results/native-helper-prerequisites-2281fa31/README.md` and `receipt.json`.

This is a concrete build blocker, not a failed game install or authorization
request. The existing game runtime was not replaced. Production asynchronous
saving remains disabled; active storage, explicit initialization/migration and
live durable-ACK integration remain required even after the SDK is available.

## Final composition checkpoint

`experiments/settings_session.lua` now connects the real Codec, Transport, Queue,
Session and shared-stream Barrier. Typed semantic validation is mandatory;
external authorization defaults to denial. It stages before submission, records
acceptance before consuming commit events, handles multiple camps and refuses
first initialization from missing slots. Decoded recovery remains an explicit
handoff; production settings are never installed by this wrapper.

Review reproduced a retired-owner failure: the initial wrapper hid the session's
explicit retry path, leaving accepted dirty data unable to drain after a definite
failure and transition. The fix permits only the original binding's accepted-data
retry. Pending/uncertain IO, new edits, activation, readiness, replacement identities
and stale ACKs remain refused. Close and revocation cases, coalescing, lease release
and fresh replacement recovery pass. Red/green evidence:
`test-results/settings-session-retired-retry-20261004T003401Z/receipt.json`.

Final offline receipt:51 compiled production modules,122 Lua regression scripts
and138 Python tests pass. The validation harness now fingerprints all production,
experimental and test Lua plus Python tools/tests both before and after execution;
source changes during testing fail acceptance. This run reports sources_stable=true
and no changed sources. Scripts store/caps diff whitespace check also passed.
See `test-results/async-enablement-20261004/offline-final.json` and its logs.

An existing-access prerequisite check did not resolve the SDK: strict batch SSH
refused because GitHub has no trusted host-key entry on this machine; no host-key
checking was disabled or trust entry added. GitHub CLI is unavailable. No credentials
were requested, entered or printed. The documented authorized upstream SDK route
remains the next external prerequisite, not a reason to substitute guessed headers.

Client remains PID44364 with the stand open after the successful V2 travel test.
All diagnostic arms are disabled, the root observer's enabled marker is disabled,
and no native helper/runtime replacement was installed. The changes to production
source in this checkpoint are pure decoder APIs; installed production Scripts
remain unchanged. Production persistence remains synchronous. No commit or release.

## Standalone native first-publication checkpoint (09:36 UTC)

Continued independently of the unavailable SDK with `native/save_core/`.
This is a Windows scalar-file primitive, **not an installed UE4SS helper**.
It accepts bounded opaque data and explicit scope identifiers, exclusively
creates a stage, checks its write/flush, and publishes the still-open handle
without replacing an existing target. Active-world, authority, typed-payload,
recovery and durable-ACK proofs remain outside this primitive.

Independent review found a substitution window in the original proposed
close-then-path-rename sequence. The implementation now uses handle-based
non-replacing rename while retaining exclusive ownership. It separately reports
publication followed by close error; that cannot authorize a definite-failure
retry or a durable acknowledgement. Handle ownership is relinquished before
the checked close, preventing an ambiguous second close from the destructor.

Real tests caught an initial rename-buffer defect: publication returned success
but the destination name was wrong. The buffer now includes initialized trailing
space; acceptance asserts the exact destination and byte contents, not merely
the return code. Review also strengthened the junction test: creation must
succeed and actual reparse/same-target identity must be verified before refusal
can count as evidence.

`python tools/test_native_initialization.py` builds both the hook-free core and
test executable with warnings as errors. Final receipt records **16 tests passed,
0 skipped, stable source fingerprints**. Tests use disposable folders and separate
native processes: concurrent publishers, winner still open, external winner,
stage tampering, root renaming, junction root/ancestor refusal, interrupted stage,
binary 256 KiB payload, storage/guild/stream isolation and injected error boundaries.
Evidence: `test-results/save-native-initialization-20261004/receipt.json`,
`tests.log`, `no-hooks-build.log`, `test-build.log`.

This does not prove real disk-full/flush/close failures, power-loss durability,
hostile filesystem reconfiguration or game integration. Boundary injections
are explicitly simulated; process termination is only the disposable helper.
No game restart, installation, production edit or async enablement occurred.
The exact matching SDK remains the shipping integration prerequisite; explicit
initialization/migration, active storage and live durable-ACK tests still follow.

## Alternative-entry research supersedes the universal SDK-blocker wording

The SDK requirement above applies to the selected CppUserModBase route. A new
minimal Lua C-library entry now compiles and links against the exact installed
UE4SS LuaMadeSimple exports using only public pinned headers. It uses no private
Unreal dependency, guessed layout, address call or second Lua runtime. It has not
been loaded or installed, and ABI/lifetime compatibility remains unverified.
Therefore the private SDK is no longer the only candidate path forward.

Newly available pinned Lua sources also show that the global Lua lock is released
around C calls; a claim that ExecuteAsync necessarily holds it across file IO is
unsupported. Shared-state ownership and shutdown still need explicit validation.
Read-only reference-mod research and the next controlled-entry gate are recorded
in `docs/async-save-route-research-2026-10-04.md`. Production async remains off.

## First native Lua entry passed in game (10:39 UTC)

The alternative entry has now passed one real launch: 1,000 exact integer
returns, then garbage collection and continued Lua execution. The normal mod
loaded its world, reported saved settings and authority, and displayed stand
numbers. Its deployed Scripts are unchanged. This supersedes the preceding
"not loaded or installed" checkpoint only for the constant-entry experiment.

Evidence lives in `test-results/native-lua-entry-live-20261004/` with a separate
first-launch receipt, actual loaded module identities and archived log excerpts.
The diagnostic disarms before loading. No worker, async save or live file
publication was enabled. Clean shutdown/restart and reload lifetime tests are
still pending; a Windows Security prompt requires user handling before the
restart macro can run. Do not treat this as native save integration acceptance.

## Clean restart passed (10:46–10:48 UTC)

The user dismissed the prompt. The authorized macro then saved and quit normally
(old PID 13192 exited) and loaded a fresh process (35736). The native entry passed
another 1,000 exact-return calls, GC and Lua execution checks. Stand numbers were
visible again; status reported saved priorities and limits. Deployed production
Scripts remain identical to the pre-install fingerprints. The second-session
priority-log excerpt has no WARN/ERROR lines.

See `test-results/native-lua-entry-live-20261004/second-launch-receipt.json` and
its companion logs/module snapshot. The constant diagnostic is disarmed and its
enable marker was renamed, without manually unloading the live DLL. No async
save is enabled. Same-process reload and worker/data/durability tests remain open.

The next isolated test uses UE4SS's existing worker for bounded native work,
avoiding a separately owned native thread at this stage. Source inspection found
that LuaMadeSimple's get_string removes the stack entry and derives length from
a NUL-terminated pointer. The handoff must retain a Lua root while copying and
use checked text encoding, not claim arbitrary binary-string support through
that accessor. This is a test-design constraint, not a production save change.

## Native background handoff checkpoint (11:01 UTC)

The separate V2 probe passed a 256 KiB synthetic checksum round trip on UE4SS's
async worker. Its measured native interval was 200.268 ms with four game-thread
beats inside it and correct game-thread completion. Independent review confirmed
the raw numbers. The first coarse-timer trial failed; its missing timestamps
prevent assigning a definitive cause. It remains a failed trial.

See "Parked cutover tooling" below and its evidence. The passing test
ran before world load; warm gameplay, file IO, ownership and in-flight teardown
are not proven. The game subsequently loaded, saved settings reported healthy,
and stand numbers were visible. Both diagnostic mods are disarmed/disabled for
future starts. Production Scripts are unchanged and async saving remains off.

## Warm handoff checkpoint (11:25 UTC)

Three post-world-ready synthetic handoffs passed with independent checksum,
thread identity and overlapping game-thread heartbeat verification. Details and
raw evidence are in "Parked cutover tooling" below. This closes the
warm synthetic handoff gate only. A separately installed fixed-root file probe
is next; no production save destination or production async setting is enabled.

## Warm background file publication passed (11:42 UTC)

The fixed-root native probe published 256 KiB on the UE4SS worker, then rejected
a different payload for the same target. Independent whole-byte readback passed
between operations and after the conflict. Game-thread completion and actual
runtime/helper paths were captured. Details: "Parked cutover tooling" below.
The probe is disarmed/disabled; production Scripts remain unchanged. This
establishes the native background-file route, not replacement/recovery, exclusive
backend ownership, real storage binding or durable edit acknowledgements.

## Native record/recovery candidate layer

Added isolated `native/save_core/record.*`: bounded versioned envelopes with
scope/generation/length metadata and SHA-256, plus conservative A/B candidate
selection. Independent Python wire encoding checks the native implementation.
Unknown formats, foreign scopes, unreadable slots and conflicting equal
generations block recovery; only two positively missing slots yield empty.

See `native/save_core/record-format.md` and the fingerprinted
`test-results/native-record-20261004/receipt.json`. This is not a filesystem
reader, safe update implementation, semantic settings validator or IO grant.
Review caught an integration capacity mismatch: max payload plus envelope
exceeds the initial-publication primitive's raw-byte bound. Connecting those
layers requires explicit encoded-record capacity negotiation. Nothing from
this checkpoint was installed in the game; production async remains disabled.

The capacity mismatch is fixed in source: the file primitive now distinguishes
262450 maximum encoded bytes from the unchanged 262144 payload capacity.
Seventeen real filesystem publication tests and nine native record tests pass,
including the maximum envelope and exact encoded boundary. Existing game probe
binaries retain their earlier contract; no runtime acceptance is inferred.

The observation-only identity collector now emits scalar world/instance/manager
addresses only after same-callback manager ownership and root revalidation.
This fixes the missing identity fields needed by the candidate provider, but
does not mark storage verified. A distinct-save A→B→A trial and complete
lifecycle invalidation remain outstanding, alongside the native ownership
registry/mailbox. The collector change is not deployed.

## Native ownership and checked reader checkpoint

The isolated native owner now enforces kernel-name exclusion across duplicate
DLLs/processes, retains pending/terminal/uncertain claims, rejects new work after
retirement and pins its code lifetime. Nine native tests pass, including a real
FreeLibrary attempt and independent process arbitration. Contract and limitations
are in `native/save_core/owner-contract.md`; uncertain/drop recovery still
requires process restart, and operation identity must retain the exact owner.

A separate checked record reader has fourteen passing disposable filesystem
tests. It derives A/B leaf names from validated scope, pins ordinary ancestors,
rejects reparse/directory targets, refuses sharing conflicts and distinguishes
missing leaf from unavailable root. This supplies read classifications, not an
atomic pair-wide write grant. It remains uninstalled.

The updated property-only identity collector is now installed ONLY in the new
PWPDistinctWorlds diagnostic for an A-title-B-title-A observation. Its test refuses
same-world substitution, missing title boundaries and unestablished ownership.
No production scripts or async settings were changed. Live evidence is pending
in `test-results/save-distinct-worlds-20261004/`.

## Distinct local worlds and immutable operations (13:43 UTC)

The property observer completed A → title → B → title → A and cancelled its
timer. A is Palpagos Islands (`31141b9948fe8b9a8b4cc399974dddf1`); B is the
new, explicitly named PWP Async Test 2026-10-04 world
(`d869345b47be6df49eb658a4a3b0c06b`). B was independently visible in the game
world list and appeared as a new save directory at creation. The original
world was restored. Production Scripts and backed-up priorities/caps bytes are
unchanged; the observer is disabled. Evidence and receipt are in the same folder.

Important negative: on B's first creation, playable gameplay had a valid new
GameState directory but selected=nil and loaded_world=false. The observer did
not accept that as a loaded host. After a normal save/title/reload of B, selected
matched and loaded_world became true. Fresh-world async admission remains closed;
do not weaken it by interpreting a directory string alone as active storage.
This observation still does not prove complete lifecycle coverage or grant IO.

Added an internal native immutable operation wrapper capturing the original
owner, binding, ticket, destination, preimages and bytes. Concurrent run calls
execute once; retirement before execution cancels without IO; late old closures
cannot complete a replacement owner's reused ticket. Actual owner+journal tests
and independent Python SHA/payload readback pass in
`test-results/native-operation-20261004T134107297169Z/`. Not installed. This is
not yet the production admission layer or a durability acknowledgement.

The original Monitoring Stand was visibly restored with priority numbers at
13:44 UTC. Status reported authority=yes and both settings saved. The restart
macro now supports `--stand-select` (and other restart modes with `-select`)
to stop before choosing a save. This was exercised successfully at 13:48 UTC:
old PID43956 exited normally; new PID32928 stopped at world selection without
clicking a world or sending the stand key. Ordinary first-row modes must not be
used blindly now that this machine has two visible worlds.

A separate checked PWPLifecycleProbe is installed for the next local traversal.
The actual-entry driver passed 48 fixtures and the epoch module passed its
regressions. It explicitly returns nil from LoadMap callbacks and records only
scalar observations. Live startup already emits paired load/init callbacks; the
complete world-switch route still needs acceptance. Source fingerprints and
pre-install production hashes: `test-results/lifecycle-20261004T134742Z/`.

## Live lifecycle route passed (13:54 UTC)

PID32928 observed 32 correctly paired callbacks across startup plus local
A/title/B/title/A. Host epochs were A=8, B=12, returning A=16. Each identity
sample followed its load/init completion; the two title boundaries advanced the
epoch as well. `tools/accept_save_lifecycle.py` accepts this route and rejects
inert, missing, malformed and stale-epoch fixtures (four tests). Raw log and
receipt are in the lifecycle evidence folder above. This is evidence for this
local route only, not client/dedicated/seamless travel or storage authorization.
Production hashes remain unchanged. The observer is disarmed and disabled for
future starts; its bounded current-process timer remains until normal restart
or timeout. The original world and stand-facing position were restored.

## Journal cleanup and combined-probe review

The native journal now removes only its own just-created backup through the
still-open exact file handle after publication. An ordinary cleanup refusal is
reported as a warning on an already-published result; an ambiguous close remains
uncertain and retains ownership. Unknown files are never cleaned up. The 32-case
filesystem suite includes 300 alternating updates without backup accumulation:
`test-results/save-native-journal-20261004T135714961729Z/receipt.json`.
The six-case immutable-operation suite also passes, including cleanup warning and
uncertain-close propagation:
`test-results/native-operation-20261004T135736159180Z/receipt.json`.

Review of the combined synthetic in-game probe found two installation blockers:
dispatch selected the current global operation rather than a captured expected
generation, and worker-thread rejection occurred after IO. These are being
repaired before installation. They do not affect deployed production Scripts.
The full Lua regression run also found six failures in older experimental driver
fixtures; see `test-results/async-full-suite-20261004.log`. These are unresolved
until their causes and repaired negative cases pass. Production async stays off.

Those six driver failures were stale strict mocks missing GetAddress/GetOuter
from the updated collector, not a production regression. Each fixture now supplies
explicit native identities and manager ownership, with replacement-identity
assertions; strict unexpected-access guards remain. The full run now passes all
131 Lua scripts: `test-results/async-full-suite-20261004-fixed.log`. The original
failed run is retained separately.

The first combined native live trial (nonce `journal-20261004T141405Z`,
PID38540) stopped at initial admission before creating any records. Context
pairing agreed on the loaded original world, role3, non-dedicated, matching
selected/directory and loaded=true. Failure is in
`test-results/native-journal-live-20261004-failed-admission/failed-admission.log`.
Pinned LuaMadeSimple.cpp:810 shows get_integer removes the stack entry. The
two-argument entry read index1 then index2, shifting ticket away and effectively
passing zero; metadata (0,0) hid that bug. Read order is corrected to descending
indices. A regression at the actual stack-access boundary is being added before
the retry. Dispatcher-only tests were insufficient. Probe was disabled; settings
and production code were not changed. The failed evidence is retained.

## Combined native journal passed in game (15:30 UTC)

Corrected entry compiled with the actual entry source under a stack-removing
LuaMadeSimple test double. The corrected code passes; restoring the old read
order fails specifically at first-ticket admission. Dispatch and Lua driver
regressions also pass. The reviewed DLL is
`f188edd64a142a89a742e1fd9a967b61ce6a8213abf11d8266a740662821b29a`.

The retry, nonce `journal-20261004T152816Z`, PID41364, completed three warm-world
256 KiB journal writes. Worker38472 differs from game/completion5972. Inclusive
native command intervals were 12.694, 17.5572 and 4.809 ms. Independent Python
readback checks the complete A-generation3 and B-generation2 envelopes, SHA-256
and every payload byte; no stage/backup artifacts remain. Original world identity
pairing agrees and reports loaded=true, role3, dedicated=false. Production Lua
and root text files matched the installation snapshot before the status command.
Status then reported authority=yes, priorities=saved and limits=saved; stand
numbers were visible. The probe self-disarmed and its enabled marker was renamed.
Evidence: `test-results/native-journal-live-20261004/` (receipt, raw log, store,
installation/source fingerprints, loaded modules and macro/production logs).

This proves this three-phase synthetic native path, not production settings
integration, power-loss behavior, frame-time improvement or multiplayer support.
Real settings still use the synchronous path. Next integration separates logical
edit coverage from physical journal generations; a coalesced revision3 must
produce journal generation2 after the first write, not skip the journal sequence.

## Whole-journal settings integration checkpoint

The fixed-root native backend now owns recovery, exact preimages, generation
selection and publication as one operation. It issues a random per-instance
preimage token, so reopening an owner cannot accidentally reuse an older token.
All allocating terminal copies precede owner completion. Independent review
confirmed both repairs. Native normal and post-publication-failure tests pass:
`test-results/native-backend-20261004T154217999349Z/receipt.json`.

`experiments/save_native_backend.lua` adapts the fixed five-argument/six-result
bridge to the whole-journal queue. It preserves uncertain admissions, captures
immutable tickets, validates scope/epoch and binary packets, retains completion
until consumption succeeds, and ignores late callbacks as durability evidence.
Its regression covers scheduling refusal/throw, lost native return, malformed
scope, copied result isolation, binary payloads and repeated acknowledged consume.
The full Lua run passes 134 scripts:
`test-results/async-full-suite-20261004-native-adapter.log`.

The session integration now offers explicit initialization only after positively
observing both slots missing and freshly authorizing the original context. It
does not activate settings on enqueue. Revoked initialization drains to its
original destination without activation or client acknowledgement. Existing
default transport behavior is unchanged.

Review found an additional bridge blocker: a lost reply after native consume
could leave Lua waiting forever because the dispatch layer forgot the consumed
ticket. The bridge needs exact-ticket idempotency, including while newer work
is pending. The Lua cache alone cannot cover that failure. Actual-entry tests
and an end-to-end composition test are being completed before installation.

Production async is still disabled. The new bridge/adapter has not yet passed
an in-game typed-settings trial; the earlier successful three-write live test
covered the separate synthetic journal probe only. No production deployment,
migration, settings activation, multiplayer validation or release is claimed.

The bridge consume retry is now fixed and tested at the actual native entry,
including a lost success reply and a newer outstanding job. The checked build
also runs the actual entry against the real root/owner/journal/backend with only
the Lua stack mocked. It writes, releases, rebinds and recovers typed payloads.
An independent reviewer confirmed the real final A/B bytes using Python.
Bridge build receipt: `experiments/native-settings-bridge/build/receipt.json`;
DLL `e5c368ce43d2069b03a50b8312e2f7f247b479c9ef9d074f9aaab3d50b2b9ad1`.

The full Lua suite now passes 137 scripts, including the actual Lua adapter,
queue, settings session, typed codec and acknowledgement barrier composed with
only the native ABI and scheduler mocked. Evidence:
`test-results/async-full-suite-20261004-typed-trial.log`.

The new disposable game trial was checked and installed as `PWPSettingsTrial`,
nonce `settings-20261004T160440Z`. Production fingerprints were unchanged and
text settings backed up. It uses synthetic world/guild GUIDs of repeated 1/2
inside the fixed test profile; these never identify the player's actual settings.
Both streams must positively recover missing, initialize, coalesce logical
revision3 into physical generation2, release/rebind and recover the exact latest
typed payload. Eight worker receipts and four records are independently checked
by `tools/accept_native_settings_trial.py`. The game trial is pending acceptance.

Input hex encoding was separately measured in offline Lua 5.4: a precomputed byte
lookup reduced 64 KiB mean CPU time from 12.7 ms to 1.35 ms and 256 KiB from
49.85 ms to 5.7 ms (20 samples each). All 256 byte values have regression coverage.
This is not a game frame-time result. Receipt:
`test-results/native-wire-benchmark-20261004.json`.

## Typed native game trial passed (16:06:54 UTC)

The normal restart macro closed PID41364 and launched PID38852. The original
Palpagos Islands world was selected by name; production reported session1 ready
at 16:06:30 UTC, before the disposable trial ran. Stand numbers were visible after
the trial. Both streams completed all stages and independently verified A1/B2
records, preserving priorities1–5/X and limits OFF. The worker was38732; the game
thread was17132. Eight native worker intervals were 0.5372,25.8703,5.1742,0.5633,
1.0124,31.5884,4.8088,0.5103 ms (recover, initialize, update, reopen-recover per
stream). These are inclusive native-call durations, not independent frame times.

`tools/accept_native_settings_trial.py` independently reconstructs expected
typed bytes in Python, validates both envelopes/SHA hashes, operation identity,
worker routes, release identities and exact directory contents. Acceptance and
postcheck passed. Installed code hashes and all production Lua/root-text hashes
matched their preinstall snapshots. The one-shot marker self-disabled and its
enabled file was renamed; the loaded native module remains pinned until normal
exit. Evidence: `test-results/native-settings-live-20261004/` (`receipt.json`,
`postcheck.json`, raw log, installation/build hashes, loaded modules, four records
and restart/production logs).

This closes runtime execution for this fixed-root typed trial. It does NOT yet
prove recovery across process restart for this bridge, real-world binding and
migration, actual edit/ACK integration, shutdown draining, headless/multiplayer,
power-loss behavior or frame-time improvement. Production async stays off.

## Fresh-process recovery passed (16:12:53 UTC)

A separate read-only trial used the same native DLL and unchanged fixed store.
Normal macro exit ended PID38852; the new PID35944 loaded the original world and
reported session1 ready at 16:12:26 UTC. Recovery nonce
`settings-20261004T161049Z` admitted exactly two recovery jobs and no initialize
or update. Both latest physical-generation2 typed payloads matched exactly.
Worker37368 differed from game37080; inclusive native reads were 0.4657 and
1.1427 ms. All four before/after record hashes matched, as did production
Lua/root text files and the checked installed package. The stand numbers were
visible after recovery. The separate probe is disabled and its marker consumed.
Evidence: `test-results/native-settings-recovery-20261004/`.

Final Lua regression run: 137 scripts, zero failures,
`test-results/async-full-suite-20261004-recovery.log`. Python acceptance regression
also rejects incomplete logs, missing workers, wrong mode and altered record
bytes. The accepted fixture's final bytes are independently reconstructed rather
than copied from the log's expected-data field.

Next integration work, still required before real-settings opt-in:

1. Connect fresh local world/guild/lifecycle authorization to the native binding;
   revoke submissions on transitions while draining the original accepted tail.
2. Preserve and explicitly migrate existing settings into that scope. Keep
   unsupported/ambiguous recovery separate from positive missing initialization.
3. Connect store/caps edits, saved-state UI, scheduler readiness and deferred
   network acknowledgements to committed revisions, not enqueue success.
4. Verify immediate exit, shutdown draining, world transitions, failure recovery
   and real rapid edits with the production integration. Keep unsupported client
   and headless paths on their existing behavior until independently verified.

The writer and fresh-process typed recovery now have live evidence. This is not
production activation or a release; no player settings have been migrated.

## Settings integration and shutdown boundary (follow-up)

`save_local_authority.lua` now reads a local authoritative controller and its
guild twice, within one callback, matching the expected world/GameState/instance.
Only plain scalar evidence escapes. It returns both the canonical guild GUID and
the signed-decimal alias used by existing settings. Unknown or changing evidence
does not authorize migration. Its tests pass; this exact reader is not yet live
validated and must not be treated as an established runtime admission route.

The migration planner and old-binding lifetime coordinator also pass focused
regressions with real settings codecs/session composition. Migration preserves
X/OFF and unassigned rows and requires exact original backups; it does not write
or activate anything. Discarding a binding fences new edits immediately, but
native retirement follows completion of its accepted/coalesced tail.

**Shutdown remains a concrete enablement blocker.** The pinned 2281fa31 source,
`test-results/native-helper-prerequisites-2281fa31/source/UE4SS/src/Mod/LuaMod.cpp`,
calls `request_stop()` and joins the async thread at lines 6093–6098, before
`fire_on_lua_stop_for_self()` at 6105. The worker loop at 7220 exits on the stop
token; remaining delayed callbacks are not a promised drain. Scheduling a final
write from the unload callback therefore cannot establish durability. A running
native operation and a newer coalesced snapshot still held only in Lua are also
different cases: finishing the former does not persist the latter.

The fresh-process recovery trial proved recovery of **already completed** writes.
It did not test edit-then-immediate-exit. Before production enablement, that case
needs an implementation with an explicit shutdown/drain contract and a negative
regression where the worker has not started and a newer revision is queued.
Neither a quiet log nor normal process exit substitutes for exact recovered bytes.

### Production attachment regressions and local identity live check

The default-off `settings_writer` adapter is now attached explicitly through
store/caps APIs only when a recovered, ready scoped session exactly matches the
current canonical snapshot. Existing startup does not call these APIs. Accepted
edits return `false, 'pending', receipt`; saved status and notifications wait for
the current complete snapshot's committed revision. Definite rejection leaves
live settings unchanged, and ambiguous admission retains uncertainty. Role/load
changes detach activation while retaining the old drain. Ownership-callback,
nested-attachment and notification reentry regressions are included. Independent
review and the main run passed 142 Lua scripts with 52 production modules compiled:
`test-results/async-full-suite-20261004-attachment.log`.

A separate read-only addon then exercised the new local authority reader after
normal macro restart (PID35944 to PID6752). At 18:57:46 UTC it matched original
world `31141b9948fe8b9a8b4cc399974dddf1`, authoritative local player and guild
`d2c75eae4e5c0c4c4d24b89b2010b5eb`. Independent Python verification reconstructed
that GUID from the signed-decimal legacy alias. Installed probe hashes and all
production Lua/root-text hashes matched their preinstall snapshots. No save was
admitted or migrated. The marker self-disarmed and the addon is disabled.
Evidence: `test-results/local-authority-live-20261004/`.

Binder `binding_kind='revocable-owner'` explicitly permits the native exclusive
owner claim without journal IO/admission; fresh postchecks remain mandatory.
The inert default is unchanged. Claim allocation is not an authority grant.
Native-owned accepted-tail/drain work remains separate and uninstalled. Complete
immediate-exit and real-edit integration are still required before opt-in.

### Native accepted-tail drain implementation

`native/save_core/draining_writer.hpp/.cpp` now retain immutable accepted
snapshots and advance the latest coalesced revision on a dedicated native worker.
No Lua/game-thread callback is needed to complete the tail. Initial publication
preserves the first authorized initialization snapshot even if newer edits arrive
before worker selection. `open()` claims only; explicit `start_recovery()` must
follow the caller's fresh postcheck. The caller still validates typed recovery.

Closing fences admission; drain joins without holding a mutex needed by the
worker. Only confirmed publication advances committed revision. Conflict, write
failure or uncertainty retain unresolved ownership and data. Uncertain publication
of a newer tail does not acknowledge it even if its bytes reached disk. Drain is
not time-bounded and must not run in DllMain/loader lock.

Twelve native scenarios passed, including initialization/existing records, pending
edits during close, pre-selection coalescing, concurrent drain calls, destruction,
capacity, inert claims, conflict, I/O failure, cleanup warning and uncertain tail.
The build uses warnings-as-errors and separately compiles without fault seams.
An independent Python encoder checked complete final envelopes, SHA-256 and
payloads after test processes exited. Independent review also matched all source
and binary hashes. Receipt: `test-results/drain-20261004-final/receipt.json`.
This is native executable evidence, **not** an installed bridge or game-exit test.

Actual legacy caps headers additionally required explicit `validated-legacy-v1`
migration policy: checked original bytes may have old comments/order, but their
real-codec canonical meaning must exactly match the supplied candidate source.
Original bytes remain retained for backup; corrupt/nested envelopes and changed
values reject. The read-only installed-file plan selects two guild limits and
preserves all 41 priority rows because no Pal membership claims were supplied.
It performs no backup, activation or write. Evidence:
`test-results/local-authority-live-20261004/migration-readonly.json`.

### Native drain bridge passed in the game (19:19:52 UTC)

Separate `experiments/native-draining-bridge` exposes bounded owner-only binding,
explicit recovery/typed approval, native snapshot admission, status, close, drain
and confirmed-closed cleanup. Tickets are consumed before mutations; replies lost
after admission cannot replay an edit. Its process-lifetime registry deliberately
has no DLL/CRT teardown destructor that could join a worker under loader lock.
Actual-entry/native-filesystem tests, parser/rooting mutants and ten-import ABI
checks passed before installation; independent review matched all 44 source hashes.
DLL SHA256: `8f620ec138ce661910e8e73e03168a5e6e4f2826302048a40fbd5e20a54323b1`.

The checked disposable addon ran after normal restart PID6752 to PID36520 and
world-ready at 19:19:36 UTC. Both streams accepted logical revisions 1–3, published
physical A1/B2 with exact payloads 1/3, explicitly drained and reopened with latest
typed bytes intact. Four owners released. Write-drain calls took 13.6881 and
13.7670 ms on the control thread; read-only reopen drains took 0.4000 and 0.3855 ms.
These are deliberately blocking drain-call durations, not frame-time measurements
or independently observed native-worker timings.

Independent Python verification reconstructed every complete envelope/SHA/payload.
Nine verifier test groups include missing completion, wrong handles/tickets,
pending mutation replies, mismatched scopes/threads and altered record bytes.
Independent review initially exposed permissive handle/ticket checks; those were
fixed before live acceptance. All 3,174 selected production Lua/root-text hashes
and installed probe hashes matched. The marker is consumed; the addon is disabled.
Evidence: `test-results/native-draining-live-20261004/receipt.json` and raw logs.

The subsequent normal macro exit observed EndPlay reason Quit (4) at 19:22:13 UTC,
before PID36520 exited at 19:22:15 UTC. This observer ONLY logged; it did not drain.
Its earlier LevelTransition observation was at boot and does not establish exit
coverage. All four journal hashes still matched after process exit. Archived
`exit-observation.jsonl` and `restart-log.txt` preserve the ordering. The original
world was loaded again in PID4612 with the probe disabled.

Runtime limits now support an explicitly proven `runtime_guild` alias: existing
signed-decimal runtime keys/lookups stay intact while only persistence snapshots
map to canonical GUID keys. Foreign/colliding aliases and mismatched recovered
bodies reject. Independent review and the full 144-script Lua suite pass
(`test-results/async-full-suite-20261004-draining.log`).

**Still not production async enablement.** Next close the normal-exit boundary by
submitting disposable pending revisions and invoking native drain from the observed
Quit callback, validating the callback's control thread, completion-before-exit and
exact bytes after restart. Then integrate native-owned admission into the settings
session (so no accepted tail remains only in Lua), explicit backed-up migration /
recovery selection and real edit/saved-state handling. The default-off store/caps
attachment exists, but main/net/UI do not activate it. No player settings migrated.

### Quit-boundary trial exposed concurrent stream contention (19:40:57 UTC)

The first real Quit write trial FAILED; it is not acceptance evidence. Both
synthetic streams initialized revision1 before exit. During Quit, priorities
accepted revisions2/3 (observed accepted3, committed1); limits accepted revision2
then refused revision3. The harness retained owners and never reported a drain
or success. PID42684 exited normally at 19:40:59 UTC. Production settings remain
synchronous and unchanged. Raw events, installed trial source and seven final
record hashes are preserved in `test-results/native-exit-drain-live-20261004/`.

Source inspection found the journal's root-wide artifact-budget gate returns a
conflict when another stream already holds it. Independent native workers can
therefore collide even though their scope owners differ. Prior successful trials
ran streams serially and missed this case. The first live failure did not capture
the terminal error number, so source consistency alone is not final causation.
A deterministic two-stream reproduction and native publication serialization
are being added; a fresh-scope live retest is required. No automatic retry of
conflicting or uncertain publication is authorized by this change.

The deterministic native regression now reproduces `conflict`, Windows error183
(`ERROR_ALREADY_EXISTS`), followed by `third_admission=0` with the pre-fix writer.
This matches the live refusal pattern. Evidence:
`test-results/drain-lane-before-20261004/reproduction.txt`. The fix must make the
second worker wait off the game thread while still accepting its latest revision.

The corrected native writer uses one SRW publication lane per loaded implementation.
Only worker threads take that lane, before update admission; submit/status/close
do not wait on it. No state mutex is held while waiting. The external named-root
gate, preimage checks and uncertain-result handling remain unchanged. Thirteen
native cases and independent complete-byte readback pass, including the new
deterministic overlap case. `test-results/drain-lane-after-20261004/receipt.json`
captures source/binary hashes. Separate DLLs/processes can still conflict by design.
The rebuilt checked bridge is `d5aa6e80135705dfaed8d776c2bb2500325ef465f0f5b96f93ef00cab3397d32`.

### Settings integration, still default-off

`save_draining_backend.lua` validates the real bridge wire protocol, typed recovery,
consumed mutation tickets and original-owner identity. `save_draining_queue.lua`
lets `settings_session` opt into `PWP-DRAINING-DEV-1` while retaining its existing
durability barrier and staged-edit behavior. Every accepted candidate is copied
natively immediately. The first initialization payload becomes available only
after confirmed publication. Lost/ambiguous replies remain uncertain; no saved
status, ACK or ownership cleanup escapes that state.

Close fences admissions without joining. The new explicit `settings_session:drain`
joins outside DLL teardown and releases its lease only after confirmed cleanup.
`settings_writer:drain` still only polls; the owner must invoke the explicit native
drain boundary. Integration tests compose the actual writer/session/queue/adapter
with a native protocol model, including native progress without Lua polling,
coalescing, first initialization, revocation and lost replies. Independent review
found no remaining blocker. All 148 Lua scripts pass; the native fake is not a
substitute for a live complete-stack settings test. Main/net/UI activation and
player-settings migration remain absent.

### Revised live Quit trial PASSED (19:50:36 UTC)

Checked install `exitdrain-20261004T194749Z` used the rebuilt DLL and fresh
synthetic storage5/guild6, preserving all seven prior records. Both streams were
initialized before Quit. During the actual Quit4 callback, both accepted revisions
2/3 and each independently reported accepted3/committed1 before drain. Both drained
to committed3, closed and released on the original control thread2668. Complete
record bytes, headers and SHA hashes match independent Python reconstruction after
process exit. Old records and all selected production Lua/root-text files match
their preinstall hashes. The addon is disabled and its marker consumed.

Evidence: `test-results/native-exit-drain-live-20261004-v2/receipt.json`, raw log,
`exit-chronology.json` and `restart-log.txt`. PID40036 normal exit was confirmed at
19:50:38 UTC, after callback completion at 19:50:36. These second-resolution times
do NOT establish a guaranteed two-second shutdown window. Blocking drain calls
took 41.1399ms (priorities) and 13.7166ms (limits); these are not frame-time or
worker-time measurements. Normal menu exit is tested; crash/power-loss, Alt+F4,
forced termination, server shutdown and mod reload are not established by it.

An independent agent reran the verifier and checked the raw native fields and
chronology. Both new streams have A=physical3/revision3 and B=physical2/revision2;
both were pending before either drain. Preflight through final cleanup return
spanned57.2883ms (including intervening control-thread logging), not a frame trace.

Verifier negative suites pass all30 tests normally and under Python `-O`; the Lua
suite passes all148 scripts. Production async remains OFF. Next: exercise the
complete settings adapter/session/writer chain live, then verified backup/migration
and startup recovery selection before attaching real settings. Pal membership
coverage is still needed for priorities; the earlier read-only plan deliberately
preserved all41 unproven rows. Keep staged production changes separate from these
isolated probes, and never reuse a disposable success as authority to migrate.

### Complete settings chain live: WRITE passed (20:23:51 UTC)

The isolated `native_settings_chain_trial` now runs the actual production
`settings_writer` through `settings_session`, its durability barrier and
`save_draining_queue` into `save_draining_backend` and the frozen native DLL.
This is still synthetic storage7/guild8; no player data is attached or migrated.
Both streams initialized revision1, accepted rapid revisions2/3 as pending, and
reported saved3 only after native committed3. At actual normal Quit4 both accepted
revisions4/5, closed nonblocking, then explicitly drained and released to5/5.
Independent reconstruction confirms A=physical5/body5 and B=physical4/body4 for
both priorities and limits, including X and OFF. All prior11 hashes and3174
selected production fingerprints are unchanged. The live run did not coalesce;
all four coalescing schedules have modeled full-chain regression coverage.

Evidence: `test-results/native-settings-chain-live-20261004/receipt.json`, raw
JSONL, `exit-chronology.json`, `restart-log.txt` and frozen install hashes. Thread
34096 handled all36 native calls. Drains measured11.322ms and13.2506ms, not frame
or worker timings. PID16916 normal exit confirmed20:23:53UTC after completion at
20:23:51. A preceding macro stopped at its focus guard and made no Quit attempt;
the stand was reobserved and the normal stand restart succeeded. The addon is
now disabled. Two agents independently checked the final bytes and native fields.

The one-shot bootstrap was hardened after negative testing exposed work retained
following startup/scheduler failure. Initial registration/report/scheduling now
fail-stop; false scheduler returns reject while the API's normal nil is accepted.
Forty injected bootstrap failures pass. The independent Python checker tests actual
Lua bootstrap/composition, lost identity, false saved/completion, corrupt records,
existing-only recovery and full15-record recovery baselines. Eight suites pass
normally and under -O. The checked installer verifies complete44-file native
source coverage, captured approved bytes, dependency closure, test results and a
second source/runtime/production/store check before arming last.

Remaining before real caps activation: durable nonreplacing backups of the full
legacy recovery set, source identity recheck and write fencing, journal-first
startup selection, guarded recovery-to-memory activation under the proven guild
alias, and lifecycle claim tracking adapted to explicit drain8/cleanup9. Existing
settings_writer:drain only polls/closes and cannot substitute for session:drain.
Priorities still require actual Pal membership coverage. No production async claim.

### Complete settings chain live: fresh recovery PASSED (20:26:52 UTC)

After normal exit of intermediate PID44784, fresh PID33980 loaded the recovery
addon with nonce `chainrecover-20261004T202440Z`. Both typed journal slots recovered;
newest physical generation5 restored exact body5 through settings_session and
settings_writer. Session-local accepted/committed revisions were0/0 (correct for
recovery, not a zero-byte save); existing physical generation5 was retained. There
were no initialization or submission commands. Both owners explicitly drained,
closed and cleaned up on thread20756. Independent full-byte verification shows
all15 record hashes unchanged, as well as selected production files. Recovery
drain calls measured0.0080ms/0.0057ms and do not measure full recovery or frames.

Evidence: `test-results/native-settings-chain-recovery-20261004/receipt.json`, raw
JSONL, `process-chronology.json`, archived restart log and install manifest.
Recovery addon is disabled; its marker is DISABLED and no callback work remains.
Current game is the original world. Both live stages passed; production async is
still OFF pending the real backup/migration/activation contracts above. Final
Lua suite:150 regression scripts,52 production modules compiled,0 failures.

Independent observer confirmed both stages, exact typed bytes and all15 unchanged
recovery hashes. Observation finished; no monitor remains running. Post-acceptance
read-only `pwp status` at22:28:02local reports heartbeat alive, authority yes,
priorities saved, limits saved,2camps and complete/deduplicated storage with no
recorded read failures. That command updates remote.txt after the accepted file
fingerprint snapshots; it is not a settings change. Structural checker also passes
(`test-results/async-structural-20261004-chain.log`). No production deployment,
version bump, commit or publication was made in this step.

### 2026-10-06: real legacy backup and guarded caps activation

Production async remains OFF; no install or native rebuild in this step. Game and
recognized dedicated-server processes were absent during the offline backup.
`tools/settings_migration_backup.py` captures all eight live/tmp/pending/bak paths
for priorities and caps, including exact corrupt/empty bytes and explicit absence.
Two captures must agree including file identities; write uses exclusive creation,
checked write, flush, fsync, close and exact readback. Manifest is written last;
partial destinations are retained, never automatically reused. Backup paths must
be outside the source directory (checked by directory identity, including aliases).
Source set and process checks are repeated before/after completion.

Actual backup: `test-results/legacy-backup-20261006`. Three files preserved:
priorities.txt, priorities.txt.bak, caps.txt; five paths were missing. No originals
were changed. This is preparation under stable offline directories, not an atomic
snapshot/security fence or prevention of another process starting. verify() checks
internal byte consistency, not authenticated proof of past flush/future authority.
Directory-metadata/device power-loss survival is not established by these tests.

`tools/settings_migration_plan.py` runs the actual Lua5.4 datafile recovery parser
and existing migration planner on captured bytes only. The v2 proposal selects
priorities.txt generation184 and caps.txt generation0. All41 priority rows remain
preserved without unproven Pal membership; two limit rows are candidates under
an explicitly supplied alias claim. Existing October4 world/guild observations
were used only to construct this proposal, NOT as current authorization. Backup
original byte strings now use explicit base64 so non-UTF8 comments are lossless.
Proposal: `test-results/legacy-migration-plan-20261006-v2.json`; the earlier textual
v1 proposal is retained as evidence. Live scope/authorization/activation flags
remain false. Reuse must recheck current sources and prove a missing native journal.
A valid existing native journal must take precedence over lingering legacy files.

`caps.activate_recovered` is an explicit default-off boundary for installing newer
typed journal limits into runtime memory before attaching settings_writer. It
requires an explicit proven alias, ready recovered session and fresh authority
checks before/after callbacks; copies context/candidate data, blocks reentrant
edits and legacy fallback, rejects foreign/wildcard rows, and retains old/uncertain
owners. A typed empty journal can clear stale legacy rows. OFF values survive;
subsequent writes report pending until durable. Main does not call this API yet.
Missing/corrupt/unreconciled legacy state still refuses activation: safe startup
provenance/selection needs an explicit policy, not forcing state=saved.

Regression evidence:151 Lua scripts passed; focused activation/attachment tests
rerun after additional callback-mutation cases;26 Python backup/proposal tests
pass (including failure injection, source changes, protected path refusal, large
manifests, actual recovery selection and non-UTF8 preservation). Structural check
passes. Independent agents reviewed both areas; their concrete findings were fixed.
Source fingerprints: `test-results/migration-preparation-20261006.json`.

Next integration gate: bind backup/source checks, native journal-first selection,
limits initialization and guarded activation to a fresh local world/guild/session;
wire explicit original-owner drain/cleanup on lifecycle changes. Refresh the native
build receipt before any install because caps.lua is a captured build input and
changed here. Then test migrated limits edits + normal exit + journal recovery
with stale legacy still present. Priorities need separate Pal membership coverage;
dedicated/multiplayer activation is not established by the local trial.

### 2026-10-07: limits startup and original-owner retirement coordinator

Added default-off `experiments/settings_startup.lua`. It constructs the real
settings_session with a draining backend, captures the scope/session/incarnation
and callbacks, recovers journals before considering migration, and attempts
initialization only after positive missing recovery plus an explicit migration
verifier. Existing journals bypass legacy import entirely. Initialization stays
pending until durable recovery, then registers the limits baseline and invokes
guarded Caps activation. Missing proof, lost returns, authority loss and callback
reentry retire admission without replaying initialization or discarding owners.

Retirement remains separate from blocking native drain. Caps now exposes
`retire_persistence(context)` (edits fenced, NOT saved) and
`finish_retirement(context)` (original writer observed closed). Both check writer
identity and refuse to detach a replacement. Native drain precedes finalization;
failed/uncertain native drains are not automatically repeated. Startup refused
before queue construction recognizes positive controller absence without draining
another lease holder. These two cases were found by independent review and fixed.

A further review reproduced pending-edit retirement leaving Caps stuck in saving
after successful native drain. Retirement now captures exact accepted memory
bytes before closing; finalization clears pending state only after confirmed
writer drain with unchanged memory/epoch and no uncertainty. It emits no stale
on_change notification or network ACK. Modified memory or a role transition
cannot be labelled saved by old-owner cleanup. The replacement regression now
includes an edit still pending at shutdown, plus both stale-memory cases.
Final review also exercised set_role(client/replacement-authority) before
coordinator retirement. Captured role/session/submit fields are now compared as
well as epoch, preventing old-owner cleanup from labelling replacement-session
data saved. Five focused scripts passed the independent final review with no
remaining blocker in that scope; the final full152-script suite also passed.

`tests/test_settings_startup.lua` composes actual Caps, settings_writer,
settings_session, typed codec and draining queue; only native storage and proof
providers are simulated. Covers stale legacy vs newer journal, OFF preservation,
pending/durable edits, missing import evidence, backup rejection/exception,
corrupt recovery, lost submit/activation/drain replies, reentry, lost authority
while initialization is pending, changed caller options, lease contention,
wrong-owner retirement, and two successive coordinators against the same Caps
instance without incidental polling. Full Lua suite:152 scripts passed;52
production modules compile. Structural check passes (existing panel local-count
warning). Logs: `test-results/async-full-suite-20261007-startup.log` and
`test-results/async-structural-20261007-startup.log`.

Limits of this evidence: coordinator is NOT imported by main and does not itself
prove backup durability, source equality, current storage identity, runtime guild
ownership or execution thread. Its callbacks must provide those guarantees. Legacy
writers/consumers must be fenced through startup and initialization admission;
Caps still conservatively requires clean authoritative legacy state before
activation. Missing/corrupt legacy policy remains unresolved. No game install,
native rebuild, settings migration, version bump or publication in this step.
Production async remains OFF. Next: bind the coordinator to verified runtime
identity and the backup/source verifier, establish the consumer/writer fence,
then refresh the native build receipt and test a checked limits-only live cutover
and fresh recovery. Priorities and dedicated/multiplayer acceptance remain separate.

### 2026-10-07: fresh authority and complete recovery-set migration guards

Added default-off `settings_startup_authority.lua`: fresh double observations of
the existing Pair/local-authority readers, exact loaded/selected storage identity,
local-host role, canonical guild/decimal alias, stable lifecycle epoch/token and
world/state/instance/manager identities. Any mismatch, uncertainty, reentry or
provider exception permanently revokes this instance. Providers must resolve fresh
wrappers per callback; the adapter retains only scalar fields and lifecycle token.
Independent implementation tests128 cases, including real-reader composition and
weak-table collection proving wrapper extras are not retained. No cached grant.

Added `settings_migration_guard.lua`: immutable exact eight-path recovery capture,
separate instance of the real datafile parser (does not replace production fs),
real migration planner recomputation of the limits candidate, one-shot receipt
check and source/backup/source byte comparisons with writer-fence checks around
reads. ENOENT alone proves absence. Newer pending generations, OFF/X preservation,
changed backups/source, callback mutation/reentry/errors, missing and corrupt
fallbacks are tested. A wholly absent stream rejects; no defaults are invented.
An integration case composes this guard through settings_startup, Caps, writer,
session, codec and draining queue. Native storage and proof providers remain
simulated; neither verifier performs writes or activation independently.

Independent review found no blocker in the stated migration callback contract;
suggested edge cases were added to the regression script. Final full suite154
scripts passed;52 production modules compile; structural checker passes with the
existing panel local-count warning. Evidence:
`test-results/async-full-suite-20261007-binding.log` and
`test-results/async-structural-20261007-binding.log`.

Remaining caller obligations are concrete: authenticate the offline backup/flush
receipt and path identity, provide actual runtime readers, keep BOTH legacy writers
and limits consumers fenced through verification/initialization, wire lifecycle
revocation and original-owner drain/finalization, and handle missing/corrupt legacy
startup explicitly. Byte equality does not establish durability or exclude another
writer. These new guards are not imported by production main. No install, game
restart, native rebuild or real-data migration occurred; production async is OFF.

### 2026-10-07: shared legacy-write and scheduler recovery fence

Added dormant production `settings_gate.lua` shared by Store, Caps and scheduler.
Opaque exact-owner tokens prevent a competing/stale startup releasing the fence.
While held, both modules refuse load/save/flush, editing, baseline capture or
wildcard adoption as applicable, and persistence notification polling. The main
pass wrapper and scheduler readiness/restore paths refuse work; Caps view_status
reports unavailable. Pure serializers remain usable by the migration verifier.
Role changes and original-owner retirement remain available for cleanup.

The experimental startup coordinator now acquires the fence before opening native
recovery and exposes original-token `fenced()` evidence for the migration guard.
It releases only after successful activation or safe pre-journal cleanup. Native
uncertainty retains ownership/fencing. Confirmed native drain without completed
activation after a journal may have been created/recovered reports
`recovery_required` and keeps legacy writers blocked: native cleanup is not
permission to fall back to a stale text file. That path currently requires a
fresh-process recovery; in-process transfer/rollback is not implemented.

Independent review reproduced a second race: component resolution could acquire
the fence after the initial scheduler readiness check. apply_pal now rechecks
after resolution and before pending bookkeeping/RPC. A regression confirms zero
requests, then a normal request after release (no falsely pending permission).
The interrupted-initialization regression confirms original bytes drain, native
cleanup completes, and subsequent legacy edits/saves still perform no IO.
Final review also reproduced cancellation before the first recovery poll with
an existing journal. Presence is now unknown/potentially existing from open;
only positive missing recovery clears that latch before initialization. Early
cancellation therefore retains the recovery fence after cleanup. Confirmed
no-queue/lease-refusal cleanup remains the separate safe exception.

Tests exercise both actual persistence modules with memory filesystem and the
actual scheduler with engine spies, plus startup/migration/writer/session/queue
composition.155 Lua regression scripts pass;53 production modules compile;
structural checker passes with the existing panel local-count warning. Evidence:
`test-results/async-full-suite-20261007-fence.log` and
`test-results/async-structural-20261007-fence.log`.

No startup is constructed by main yet, so the new production guards remain
dormant and installed files are unchanged. Remaining live wiring: authenticated
backup receipt/runtime filesystem readers, fresh authority/lifecycle provider,
native setup/build receipt and original-owner exit/transition hooks. Then run a
checked limits-only migration/recovery trial. Missing/corrupt legacy startup,
priority membership and dedicated/multiplayer acceptance remain separate gates.

### 2026-10-07: runtime backup readers and checked receipt preparation

Added `settings_startup_files.lua` with captured absolute source/backup roots,
an eight-name allowlist, bounded binary reads, checked read/close results and an
exact pinned-manifest comparison. Empty bytes remain distinct from ENOENT;
permission failures/close failures never become absence. No writes or constructor
IO. Caller-selected paths and manifest access through the general readers refuse.
This does not authenticate arbitrary supplied receipts or prevent OS path changes:
the installer owns verified backup completion and root-identity checks.

Added `tools/settings_startup_receipt.py`: reverify the complete offline backup
and current source identities, capture/recheck exact manifest bytes, generate
lossless hex-encoded Lua data, publish exclusively with checked flush/readback,
then recheck backup/source/process prerequisites. Output outside source/backup,
never overwritten. A failed postcheck retains an unapproved artifact. No enabled
flag, authority grant or migration operation is generated.

Actual preparation succeeded from `test-results/legacy-backup-20261006` into
`test-results/limits-startup-receipt-20261007.lua`. Recognized game/server processes
were absent during preparation; original source identities/bytes still matched.
The actual Lua reader then read all8 source and backup paths and matched every
present byte string/missing slot plus the manifest. No settings were modified.
These are sampled offline checks, not a runtime authority grant/exclusive OS lock.

Native draining/settings/exit-drain/settings-chain trial installers now package
the new required settings_gate module; none was run. Full156-script Lua suite
passes,53 production modules compile, structural checker passes.26 existing
backup/planner Python tests,6 new receipt tests (including real temporary Windows
files through the actual Lua reader) and8 settings-chain acceptance tests pass.
Logs: `test-results/async-full-suite-20261007-readers.log` and
`test-results/async-structural-20261007-readers.log`.

No live bootstrap/main construction, native rebuild or installation in this
step. Production async remains OFF. Remaining: lifecycle/provider composition
and authenticated staging of the receipt with the refreshed native build,
then the guarded real-limits migration/normal-exit/fresh-recovery acceptance.

Independent review found and reproduced two Windows-only preparation issues:
8.3 aliases bypassed lexical destination containment, and non-ASCII roots emitted
paths this Lua build's narrow io.open could not read. Preparation now compares
ancestor filesystem identities to source/backup and rejects non-ASCII runtime
roots before publishing. Runtime readers reject those roots too. Nine receipt
tests pass, including the real Windows GetShortPathNameW alias regression (not
skipped here) and a non-ASCII no-output regression. The already prepared ASCII
receipt was revalidated byte-for-byte against the checked backup and unchanged
source with the game closed; it was not overwritten. Full156-script Lua suite
passes after the reader change. No installation or activation.

### 2026-10-07: production-VM limits startup and first live migration

The explicitly installed local launcher now composes the existing modules inside
main's Lua state. It shares the real Caps/Store recovery gate; this is not a second
UE4SS mod with disconnected settings copies. Release packaging/defaults remain
off. The bounded trial is local authority, one world per process, limits only.
Fresh lifecycle tokens, viewport/selected/loaded world and guild evidence are
required. Transitions close admission and explicitly drain the original owner;
the trial remains fenced until process restart rather than resuming stale legacy
files. Native ownership remains tracked independently before a session queue
exists. Dormant cleanup verifies exact identity and zero native activity; lost
binding replies remain unknown and fenced, never retried.

Role refresh was corrected to retain a writer when role/session are unchanged;
actual transitions still detach. Readiness no longer claims settings available
while the shared gate is held. Lifecycle regression covers93 cases, and the full
159-script Lua suite plus53 compiled production modules passed before install.
Structural checker passed with the existing194-local panel warning. Native bridge
rebuild passed actual entry/filesystem and failure-injection gates; its fixed
compiled root is `test-results/native-limits-live-20261007/store`, separate from
all synthetic journals. DLL SHA256:
`0dea75080b1f9e0636da2455dc952bb27b318fa1e6e69dde24890230a9a52dd0`.

Checked installation evidence: `test-results/limits-startup-install-ca1b738045c5`.
The installer retained old code through deploy.ps1, verified unchanged legacy
settings against `legacy-backup-20261006`, checked source/runtime/DLL fingerprints
and installed dependency bytes, then armed the launcher last. No public upload.

First process33244 (launched via documented AHK --launch-select): selected the
existing Palpagos Islands world visually. Fresh authority matched storage
`31141b9948fe8b9a8b4cc399974dddf1` and guild
`d2c75eae4e5c0c4c4d24b89b2010b5eb`. Live startup initialized and durably activated
generation1 at12:24:37: wood30000 and stone35000 preserved. The delayed normal
role refresh did not detach it; scheduler resumed after activation.

At12:25:34 normal Return to Title reached LoadMapPre before Quit. This route
revoked/drained/released the owner: cleanup_verified=true, owner_retained=false,
accepted=committed=1, joined=true, cleaned=true, phase=closed. Title-menu Quit then
closed the process normally. `migration-acceptance.json` independently checks the
entire native record envelope, scope, payload and SHA256, exact active runtime
limits and unchanged eight-path legacy recovery set. Record SHA256:
`059566abda1885a5298e1d9d859740b241b57246ce690d17c386c596fd56db46`.
This is positive LoadMapPre exit evidence, not a fabricated Quit4 observation.
Fresh-process recovery is the next live leg; first migration alone does not
establish recovery or accepted-edit persistence.

### 2026-10-07: fresh recovery, real pending edits and final recovery passed

All four launches used the documented AHK --launch-select workflow followed by
visually selecting Palpagos Islands. The game was closed normally between runs;
no force-kill, player-save rewrite or public release was performed.

| Process / boot suffix | Check | Observed result |
|---|---|---|
|33244 /1791368611|First real migration|generation1, initialization=true, accepted=committed=1; normal Return to Title drained at LoadMapPre|
|16856 /1791368826|Fresh process, existing journal|generation1, initialization=false, zero accepted writes; identical record hash; normal engine Quit4 drained/joined/cleaned|
|31012 /1791369048|Real edits and immediate normal exit|Stone35000→35001 produced durable generation2. Restore35000 and `cmd quit` in one developer-channel poll produced generation3; accepted=committed=2 before cleanup|
|38140 /1791369359|Fresh process after the pending restore|generation3 selected, initialization=false, zero accepted writes; exact original limits restored; both journal slot hashes unchanged; normal Quit4 cleanup passed|

The full nonce prefix is `limits-94ac341914f44c3386074d012674d9d3-`.
Every completed owner reported cleanup_verified=true, uncertain=false,
owner_retained=false, phase=closed, joined=true and cleaned=true. The restored
write was accepted immediately before requesting Quit; native completion may
race that request, so this demonstrates accepted-tail preservation, not an
injected blocked-IO drain duration. Prior synthetic failure tests cover the
controlled blocked and uncertain cases.

Latest slotA generation3 exact restored-body hash:
`0685fe12e80b42f61a69ae49111f92f5263647eddf1417867f10697ab91edcfc`.
Older slotB generation2 exact changed-body hash:
`bce2dd2631008b976bfcebba58eda6be20b99bc102ce19b3ee9b082f116db7bf`.
Both live records and all eight legacy recovery paths were rechecked after the
last process exited. Legacy file identities/bytes and missing paths still match
the original verified backup. Original effective limits remain wood30000 and
stone35000. No priority settings were migrated or modified.

Evidence lives in `test-results/limits-startup-install-ca1b738045c5`:
`migration-acceptance.json`, `recovery-acceptance.json`,
`edit-exit-acceptance.json`, `edited-recovery-acceptance.json`, `live-trial.log`,
`journal-final/`, the independently captured changed generation2 record,
restart-macro chronology and mapped runtime/bridge paths. The read-only checker
validates exact scoped envelopes, complete payloads and SHA256, the expected
initialization/recovery path, original runtime limits, complete native durable
prefix and observed exit route. Seven acceptance regressions reject wrong scope/
payload/generation, failed or missing cleanup, wrong nonce, corrupt/extra files
and an unacknowledged prefix. Process identity and normal-exit chronology are
separate observed evidence, not inferred from log silence.

The real edit exposed a command presentation bug: `pending` was labelled
unavailable even though it had been accepted. Main now reports “accepted;
saving asynchronously” without claiming durability. The actual main integration
regression distinguishes pending from rejected and rejects a saved claim for
both. Only main changed in this final checked redeploy; source/installed hashes
and untouched legacy data are recorded in `pending-wording-checked.json`.
The final recovery run used that build. This wording branch was regression-tested;
no additional real edit was made in the final recovery-only run.

**Current boundary:** local limits async is enabled only by the checked installed
trial launcher. Public defaults remain off. This single-world trial deliberately
fences on respawn/world/session transitions until restart; it is not the finished
general runtime experience. Do not simply remove its launcher after journal edits
and resume stale legacy files. Priority baseline migration, multi-world rearming,
dedicated/listen/client acceptance, multiple guilds, packaging and performance
comparison still require separate work. No “stutter-free” or release-ready claim
follows from these persistence tests. Game left normally closed after acceptance.

Independent observer reran final acceptance and confirmed both complete records,
unchanged legacy paths and ordered activation→closing→cleanup→native exit. The
review identified that ordering was independently observed but not yet enforced
by the checker. The checker now requires exactly one armed/bound/active/closing/
cleanup/exit sequence in order for the exact boot nonce and expected world/guild.
Missing, duplicated, reordered and foreign-scope events fail regressions. The
actual final run passes this stronger gate too:
`edited-recovery-ordered-acceptance.json`. Crash/power-loss recovery remains
outside this normal-exit live evidence.

### 2026-10-07: priority recovery and migration guards (offline preparation)

The next stream now has an explicit, default-off recovery path. Store can accept
a typed recovered priority snapshot, preserve 1–5/X and the baseline marker,
retire the original writer and finalize only after its confirmed drain. Ownership
proof covers the union of current and recovered Pal keys: unknown legacy rows
cannot silently disappear during replacement. Same-role refresh retains the
writer; undecided/new-session transitions detach it. Failed activation fences
synchronous fallback and leaves existing values intact.

The startup coordinator still defaults to limits. Explicit priorities startup
requires a current camp coverage proof before registering readiness, plus fresh
scope-bound Pal ownership callbacks during cutover and editing. The pure coverage
checker requires an explicitly complete roster with valid, unique durable keys
and known capable work types. With baseline mode enabled, every capable work type
must have a recovered value; X counts as known, nil does not. A baseline header
alone cannot establish coverage. Legacy baseline=false retains its existing
configuration-fallback semantics rather than inventing fresh-install choices.

The migration guard can prepare priorities only as a complete legacy selection:
every key is re-proven before and after source/backup/source byte checks under the
writer fence. No unknown rows are discarded, no remainder overwrites legacy
files, and constructing a candidate is not an authority grant. The existing local
authority adapter accepts an exact priorities scope without weakening its fresh
world/guild/lifecycle checks or permitting cross-stream authorization.

Read-only verification of the original backup and current installed legacy files
found generation184, 41 priority rows across15 keys, including2 X values, with
baseline=false. Every legacy file still matched the verified backup. These counts
do not prove current Pal membership or that a current camp census is complete.

No code was installed for this preparation; the proven limits-only launcher and
journals remain unchanged. Before any priority live trial, implement/validate a
fresh ownership and roster provider (including saved Pals absent from the loaded
camp), then build checked native binding/lifecycle composition for both streams.
Do not replace unknown ownership with blanket guild membership or silently import
an empty snapshot. Multiplayer, transition rearming and public enablement remain
separate gates.

Validation for this priority preparation: all163 Lua regression scripts pass,
all53 production modules compile, structural checks pass, and the seven existing
limits acceptance-checker tests pass. The new composition tests use actual
Store/SettingsWriter/SettingsSession/draining-queue code with fake native IO and
explicit simulated proof providers; this is not additional live engine evidence.
Both implementation lanes cross-reviewed integration. Review added rejection of
coverage callbacks that mutate even their disposable proof copies, including
filling missing baseline rows before returning true. Lost activation replies,
ownership failures, reentry, pending edits and original-owner cleanup are covered.

Evidence: `test-results/async-priority-preparation-20261007.json`,
`async-priority-preparation-20261007-lua.log` and
`async-priority-preparation-20261007-structural.log`. The JSON pins changed source
hashes and records the final read-only check: all53 installed production modules
still match the prior checked limits build, legacy recovery files are unchanged,
and the game is closed. Priority runtime activation remains off.

### 2026-10-07: live loaded-camp priority coverage observation

Installed a separate one-shot read-only diagnostic after Lua compilation,
regression checks, pinned runtime/source checks and independent review. Production
code and settings were not deployed or edited. The documented AHK launch-select
workflow opened Palpagos Islands (level28, multiplayer OFF), process2840.

Three samples at approximately13:15:36–13:15:57 local each performed two fresh
camp roster reads bracketed by current-world/local-player/guild identity checks.
All three observed two camps,14 workers, complete and stable duplicate reads,
and12 of15 saved priority keys. No foreign camps were seen. The same three saved
keys remained unknown in every sample (instance suffixes):

- `7807820A4C4F1B8E12BB309DC176EF42`
- `99C0B2BB417170F8D8777F94B703B42A`
- `AFE1342E42BC0F2622CFC09448CBBEA2`

Unknown does not mean foreign, deleted, or discardable. A successful UObject
class sweep also does not prove each camp's world membership. Every sample
explicitly reports activation_allowed=false and world_membership_proven=false.
The observation identifies the exact coverage gap; it does not grant migration.
No broad class/function dumps or unverified out-parameter calls were used.

Normal engine Quit at13:16:26 drained the unchanged limits owner: generation3,
accepted=committed=0, joined/cleaned=true. Game closed; the complete legacy recovery
set still matched the verified backup. Evidence:
`test-results/roster-9ba6d43cec1f4eb8b24c71468a282a45/` contains checked installation
sources, three full observations, and analyzed unknown-key sets. The analyzer
rejects partial/unstable, miscounted, duplicated, mismatched and incomplete runs.

### 2026-10-07: guild roster closes the observed saved-key gap

A separate one-shot guild diagnostic followed the declared property chain from
fresh GuildBelongTo through IndividualIdArray.IndividualCharacterHandleIds.Items
and HandleId. Independent pre-install review caught potentially mutating UE4SS
out-of-range indexing. LocalPlayers is now checked before index1; Items length is
checked immediately before every index. Trap tests prove empty/shrinking arrays
are refused before unsafe access. No broad dumps or new native UFunctions used.

The documented AHK launch-select workflow loaded Palpagos Islands (level28,
multiplayer OFF), process27740. At13:27:38,13:27:48 and13:27:58 local, paired fresh
reads were complete/stable and bracketed by matching world/local-authority checks.
Each found the same18 unique guild IDs and all15 saved priority keys, including
all three absent from the camp census. Guild IDs do not necessarily mean18 Pals.
Independent review confirmed the raw results and all15 installed source hashes.

This closes observed coverage only: the collection's current-membership semantics
remain to be validated. Priority async remains disabled. Both activation_allowed
and world_membership_proven remain false. Next: validate those semantics, enforce
fresh per-key checks under the migration/edit lifecycle fence, then compose and
test both native streams. Diagnostic samples must not be reused as authorization.

Normal engine Quit at13:28:23 drained the existing limits owner: generation3,
accepted=committed=0, joined/cleaned=true, cleanup_verified=true,
owner_retained=false. Game closed; every legacy recovery path matches the verified
backup. Production code/settings hashes are unchanged; only remote.txt changed
for the authorized Quit command. The consumed diagnostic trigger is DISABLED.

Evidence: test-results/guild-55248d9811634f85adc8d6ed70fd64cd/ contains installation
hashes/checks, raw observations, analysis, normal-exit log and post-run checks.
All166 Lua regressions pass,53 production modules compile, structural checks pass,
and four Python analyzer tests pass. This is roster/persistence-safety evidence,
not frame-time, multiplayer or general release acceptance evidence.

### 2026-10-07: live current-parameter group corroboration

Added the isolated parameter route to the one-shot diagnostic, installer and
strict analyzer. SDK PalIndividualCharacterParameter.h declares IndividualId and
GetGroupId() const returning FGuid without arguments/out-parameters; the retained
Discovery.txt also lists GetGroupId. Independent review approved diagnostic-only
use after strict copied eight-word identity validation was added. The actual
palapi formatter is tested against malformed/fractional/out-of-range GUID words.
Duplicate targets, identity/address changes, unreadable parameters and late errors
publish no partial match set. Non-target objects never receive GetGroupId calls.
All wrappers remain within the synchronous observation. The Lua array processing
bound does not bound native FindAllOf duration.

Checked install: PWPPriorityParameterRead; AHK launch-select loaded Palpagos
Islands, level28, multiplayer OFF, process41656. At13:38:38,13:38:48 and13:38:58
local, all15 saved keys matched both the fresh guild list and current parameter
GetGroupId. Paired reads were complete/stable; parameter keys/groups/addresses
also agreed across the three samples. Independent parsing and installed-source
hash verification confirmed this. Stable refers to the compared records and
intersection, not the full raw guild array.

This corroborates current group assignment, rather than relying only on guild
array inclusion. It is not yet parameter-world proof: global enumeration can
include objects beyond the active world. Both authorization flags remain false
and priority async remains disabled. The next concrete route to investigate is
PalUtility.GetIndividualCharacterParameterByIstanceID(WorldContextObject,
const FPalInstanceID&) or the active world's PalCharacterManager parameter map.
The SDK and retained Functions.txt declare the utility route; no live call to that
route was made. Verify native struct-input handling and world/context binding
before using it; never manufacture an out-table or retain a struct wrapper.

Normal engine Quit at13:39:16 drained the unchanged limits owner (generation3,
accepted=committed=0, joined/cleaned=true). Game closed; every legacy recovery file
matches the verified backup, production hashes unchanged except remote.txt from
Quit, and the probe's consumed trigger is DISABLED. All167 Lua scripts pass,
53 production modules compile, and five Python analyzer tests pass.
Evidence: test-results/parameter-6dd31b034e9a4a2e85b390440dcb6295/ (installation,
raw observations, analysis, normal exit, post-run checks). Full regressions:
test-results/priority-parameter-20261007-regressions.log.

### 2026-10-07: supplied-world resolver agreement

The isolated world route now forwards the original callback-local reflected
FPalInstanceID into PalUtility.GetIndividualCharacterParameterByIstanceID, after
strict validation of all eight identity words. It does not reconstruct a Lua
input/out table. SDK declaration and retained reflection dump match; checked
UE4SS source LuaUObject.cpp supports native UScriptStruct type-checking and
CopyCompleteValue. The const-input declaration avoids the non-const out-table
path. FPalInstanceID also contains DebugName: the whole native struct is copied,
so its source parameter/struct lifetime stays within the synchronous callback.

WorldLookup checks fresh world/state/game-instance/save-manager addresses before
and after each call. Returned validity, address, strict identity and group must
agree with the fresh parameter observation. Missing/mismatching results publish
no records. Unit fixtures cover altered world links, malformed arguments,
identity changes, foreign results and failures; they are not native marshalling
proof. Independent review preceded installation.

AHK launch-select loaded Palpagos Islands (level28, MP OFF), process28388. Three
paired observations on2026-10-07 each matched all15 saved IDs through the guild
list, current GetGroupId and supplied-world lookup. Every per-parameter record
has world_resolved=true. This means agreement with the supplied-world resolver
in this live observation; it does not mean cross-world/session transition
acceptance. Both broad authorization flags remain false, priority async off.

Normal engine Quit at13:47:06 drained unchanged limits generation3, accepted and
committed0, joined/cleaned=true. Game closed, all legacy recovery files unchanged,
production unchanged except remote.txt for Quit, trigger DISABLED. Evidence:
test-results/world-1315e2e614474d7ba53da5e85e049e56/ contains sources receipt,
checks, raw samples, analyzed results, exit and post-run verification.
All168 Lua regression scripts and five Python analyzer tests passed before run;
53 production modules compiled and structural checks passed. Next is fresh
lifecycle-bound ownership composition and transition/recovery acceptance, not
turning these diagnostic records into a reusable grant.

### 2026-10-07: default-off fresh membership adapter composition

Added settings_priority_membership.lua, not imported by production. It binds the
exact priority scope/session/incarnation/epoch/camp and an immutable runtime guild
alias. Every owns_key call performs fresh authorization, one fresh membership
observation, and fresh authorization again; positives are never cached. Missing,
foreign, malformed, mutated or reentrant evidence permanently fences that adapter.
It accepts only exact scalar observation fields, not truthy substitutes or an old
diagnostic report. Providers remain trusted synchronous code: the pure adapter
cannot prove that a dishonest callback actually queried the engine.

Independent review found an integration issue before runtime use: the real
settings_startup_authority callback also requires runtime_guild. The membership
adapter now captures and supplies this alias on both calls. Integration tests use
the actual authority adapter, startup coordinator, Store, SettingsWriter/session
and queue with simulated engine/native storage. They exercise successful recovery
and an edit, then group mismatch, no world agreement, lost authority, a changed
actual epoch provider, guild removal, reentry and callback-context mutation. All
reject before native submission, preserve prior serialized settings and drain
the original owner. These are composition tests, not live transition acceptance.

Remaining: bind the fresh native reader into the real startup lifecycle, validate
same-process world/session transitions and safe recovery/cutover with both streams.
No priority journal or writer was enabled by these changes. The existing checked
limits-only trial remains unchanged.

Final verification: all169 Lua scripts pass. Review also caught a unit fixture
forwarding the alias incorrectly and failing before its intended injection. The
fixture now forwards it correctly and asserts each of30 injected faults actually
executes exactly once. Both targeted composition suites and the full suite passed
after this correction. Evidence fingerprints are recorded in
test-results/priority-world-membership-20261007.json.

### 2026-10-07: fresh reader bridge and coordinated two-stream preparation

Added default-off settings_priority_live_reader.lua, composing the checked guild,
parameter and supplied-world lookup readers with settings_priority_membership.
Each ownership request takes fresh paired observations, checks context before and
after, and caches no positive membership or engine wrapper. Failure, missing,
foreign, changing or reentrant observations revoke the adapter. Its providers
remain trusted synchronous game-thread code. The bridge tests use explicit
scalar engine-reader fixtures, not new native marshalling evidence.

Review of the current live launcher found two blockers to simply adding another
writer: the global settings gate permits one holder, and the lifecycle accepts
one owner. Added settings_startup_gate_group.lua and an optional captured gate
facade to settings_startup (existing default behavior preserved). A child's
release now marks that child's recovery complete; the shared fence remains held
until both children are ready and a coordinated commit succeeds. Failure is
terminal, child proof checks fail, and cleanup cannot release the global fence.

Added settings_combined_owner.lua, registering both original placeholders before
native creation. Retirement fences both streams and revokes every proof before
retiring any child. Drain attempts each original child once, even if the other
fails or throws. Unknown outcomes retain references; aggregate cleanup is verified
only when both registered owners confirm closed and no uncertainty remains.

New integration tests compose two actual Startup coordinators, Store, Caps, gate
group and combined owner with simulated native IO/engine proofs. Limits becoming
active first does not admit edits in either stream. Both ready permit edits.
Priority coverage/activation failure prevents admission, and both original owners
still get independent cleanup attempts. Repeated cleanup does not retry native
actions; failures keep the global fence. These are offline coordination tests,
not live two-stream acceptance.

No source was deployed in this preparation. The checked limits-only launcher and
journals remain installed. Priority async is still disabled. Remaining work:
compose per-stream native handles/backends, migration/coverage and proof revocation
in the real launcher, then checked live combined recovery/edit/drain and same-
process transition tests. Do not duplicate the limits launcher or expose a stream
before coordinated admission.

Performance gate: the current live-reader bridge intentionally retains the
checked diagnostic global parameter enumeration. It repeats two scans per key;
Store can verify every saved key on each edit. This is NOT acceptable as the
production edit path and was not deployed. Replace that search with fresh guild
native identity traversal and direct supplied-world resolution before activation;
keep the same identity/group/context/freshness checks. No measured speed claim.

Offline verification: all173 Lua regression scripts pass;53 production modules
compile and structural checks pass. Game closed, all legacy recovery files match
the verified backup, and installed production hashes are unchanged (remote.txt
only differs from the prior install receipt due to normal Quit). Fingerprints:
test-results/priority-coordination-20261007.json and corresponding regression log.

Review follow-up: commit rechecks both readiness callbacks before release, with a
regression where consulting priorities invalidates limits readiness. The fence
stays held. Readiness providers are trusted synchronous reads; lifecycle changes
must also fence/revoke, which remains a real-launcher integration gate. All173
regressions passed again after this correction.

### 2026-10-07 — direct priority ownership reader, offline verification

Replaced the preparatory live reader's per-key global parameter enumerations
with supplied-world lookups using the original guild `HandleId`. Each successful
ownership check now performs two fresh guild passes and four direct lookups;
these are fixture call counts, not measured runtime costs. The parameter reader
still validates identity, address and group. No positive result is cached.

The guild reader now validates all eight GUID words before formatting or native
visitation. Only the requested key invokes the visitor. Independent review found
that a same-count slot replacement could evade a single read's final address/count
checks; the reader now reacquires the checked chain and array after visitation,
checks bounds before indexing, and compares the fresh slot identity to its prior
scalar key without dereferencing the old native struct.

Verification: 174 Lua 5.4 regression scripts pass; 53 production modules compile;
structural checks pass (existing panel local-count warning remains). New actual-module
integration tests cover zero global scans, four direct calls, missing/wrong/foreign
results, malformed identities, world/address changes, duplicate entries and failure
after a successful visitor. A poisoned-old-identity regression confirms that the
post-visitor check uses the newly acquired slot. Fixtures explicitly model engine
calls; their userdata shells do not establish UE4SS marshalling or lifetime safety.
Evidence: `test-results/priority-direct-reader-20261007.json` and associated logs.

Not deployed. Priority async remains disabled. Before integrating the two live
writers, run a checked read-only native probe that specifically forwards guild
`HandleId`: the earlier world probe forwarded parameter `IndividualId` instead.
Then verify coordinated startup, interrupted recovery, transitions and draining
with both streams. The installed limits journal remains the current local trial;
this source-only change does not replace or roll it back.

### 2026-10-07 — guild HandleId direct route passes native read-only test

Installed a distinct, consumed-trigger `PWPPriorityDirectRead` diagnostic after
runtime/backup/source and focused regression checks. It exercises the actual
`settings_priority_live_reader` and its Guild/Parameters/World/Membership helpers,
using fresh Pair + LocalAuthority reads around observations. Newly bundled
Store/Datafile/SettingsGate function provenance is pinned to the diagnostic folder.
No writer, migration or native save owner is constructed by this probe.

Process 8972 loaded Palpagos Islands using the documented AHK launch-select flow.
All 15 saved priority identities were accepted in both outer observations of each
of three samples; every sample was complete and stable, with zero unknown keys.
This specifically exercises original native guild `HandleId` forwarding, which the
older parameter-owned-ID probe did not. The checked code path makes 120 direct
world lookups per sample (360 total); this is a code-derived call count, not a
measured duration or a general native-lifetime guarantee. Positive results are
never cached or reused as permission to save.

Normal Quit at 14:30:46 completed: existing limits writer accepted=committed=0,
generation=3, joined=true, cleaned=true, cleanup_verified=true, owner_retained=false.
Both limits journal record hashes match their pretest values. All legacy recovery
files are unchanged; production file hashes differ only in the explicitly submitted
`remote.txt` Quit command. Game is closed and the probe trigger is DISABLED.

Evidence: `test-results/direct-8750ba17faab4e1fa7e1d02d1bd2ef39/`
contains install/source hashes, captured log, strict analysis, exit log and post-run
record. Full regression suite: 174 scripts pass, 53 production Lua modules compile;
all six diagnostic analyzer tests pass. Fixture tests also reject changed/not-ready/
foreign authorization contexts and extra analyzer key rows.

Remaining: integrate the two prepared startup coordinators into a checked live
launcher; preserve the existing limits journal; validate simultaneous priority and
limits recovery/admission, edited values including X, partial-start failure, world
transition and original-owner shutdown. Priority async is STILL DISABLED in the
production mod. This read-only success does not satisfy those writer release gates.

### 2026-10-07 — combined async writers pass real edit, Quit and restart

Implemented `experiments/settings_live_combined.lua`, composing the shared startup
admission gate, combined owner, two startup coordinators, lifecycle, native backend
and fresh priority ownership reader. Shared admission stays closed until both
streams are recovered and authorized. Original owners/proofs are registered before
binding; any ownership rejection fences both streams synchronously, while cleanup
runs after the callback unwinds. Limits must recover the existing journal and may
never re-import stale legacy text. Store now receives the same role/session epoch
as Caps from main. Public/default async activation remains off.

Independent review and actual-module regressions found and closed a missing-limits
remigration path and a same-stack cross-stream admission gap. The checked installer
records durable activation intent, backs up prior code/launch/journals, pins source
and runtime hashes, stages a versioned native DLL/dependency tree, verifies again
before arming, and replaces the launcher last. It does not overwrite journal data.
175 Lua 5.4 regression scripts pass, 53 production modules compile; structural
checks pass with the existing panel local-count warning. Native rebuild receipts
also pass compilation/link, real filesystem/recovery and worker shutdown checks.

Installed the checked LOCAL combined trial under nonce
`combined-fff51655a6a04fb285bbdd8e88c5684e`. At 14:50:50 both streams became active:
limits recovered generation 3, priorities migrated verified legacy data into
journal generation 1. Through the actual stand, Verdash Transporting changed
1 -> 2 -> X; the limit command changed Stone 35000 -> 35001. Checksum/scope/length
validation plus the real Lua typed codec proved these were the only decoded
changes, preserving all other 41 priority rows and both limit rules.

Normal Quit at 14:57:19: limits accepted=committed=1 (generation 4), priorities
accepted=committed=3 (generation 3, includes initialization). Both native owners
reported joined/cleaned, lifecycle cleanup_verified=true, owner_retained=false.

Restart via the documented AHK launch-select flow, then select Palpagos Islands:
both recovered at 14:58:47 with initialization=false, limits generation 4 and
priorities generation 3. The reopened stand visibly retained X, and the live limit
command reported Stone 35001. Thus this checks loaded state as well as disk bytes.

Restored Verdash Transporting to 1 and Stone to 35000 through ordinary edit paths.
Both final typed states exactly match their pre-edit snapshots. Normal Quit at
14:59:59: limits accepted=committed=1, priorities accepted=committed=2, both at
generation 5, joined/cleaned with verified lifecycle cleanup. All eight legacy
recovery paths remain unchanged. No WARN/ERROR in the two archived test windows.
Game is closed; the checked combined launcher remains installed. Do not switch
back to the old limits-only launcher or treat legacy priority text as current.

Evidence: `test-results/combined-startup-install-decd3863212b/`: durable install
intent, source manifests/backups, run1/run2-complete.log, checksum-verified record
snapshots with actual-codec decoded.json, and live-verification.json. Original
native build receipt/DLL retained in combined-native-before-20261007.

Limits of this result: normal startup, edited X/numeric persistence and normal
process shutdown now have native evidence for BOTH writers. It does not establish
save latency/frame-time improvement, interruption/power-loss recovery, concurrent
world/role transitions or multiplayer acceptance. Next gate is a same-process
world transition: fence both streams and drain their original owners, refuse
stale callbacks/edits, and do not silently rearm in the next world. Controlled
failure/interruption and multiplayer cases remain release requirements.

Independent evidence review agrees with this bounded verdict. There were two
sessions and ONE intervening recovery restart, not two restart recoveries; final
generation 5 has been checksum/typed-verified after exit but has not yet been
loaded again. run1-complete.log includes the next startup prefix, so use each full
trial nonce to delimit sessions. The UI X observation is the operator's screenshot
evidence; the independent reviewer verified journal/log evidence only.

### 2026-10-07 — native same-process world round trip passes fencing

Evidence: `test-results/combined-transition-20261007/{before.json,complete.log,verification.json}`.
The checked combined build ran in PID 3896 throughout Palpagos Islands -> title ->
existing PWP Async Test 2026-10-04 -> title -> Palpagos Islands. No code or launcher
changes were made. Initial startup recovered BOTH restored generation-5 journals
with initialization=false; combined READY at 15:04:32. This additionally closes
the previous note that final generation 5 had not yet been recovered on boot.

At the first normal Return to Title (15:05:22), load_pre fenced both streams and
completed original-owner cleanup: cleanup_verified=true, owner_retained=false,
joined/cleaned both, accepted=committed=0, generation=5. Exactly one lifecycle
cleanup and two native_exit records occurred across the entire round trip and
final normal Quit at 15:09:45. Later ClientRestart callbacks reported closed
without rebinding or replaying native draining. Sessions 2 and 3 stayed unavailable;
no subsequent async READY, startup, migration or activation appeared.

An actual `pwp limit Mining Stone 35001` was refused in the test world (15:06:42)
and again in the original world (15:08:55). In the reopened original stand,
right-click and direct X attempts left Verdash Transporting visibly at 1. All four
journal files retain their exact pretest hashes, and all eight legacy recovery
paths retain their bytes/absence. No WARN/ERROR in the captured test window.
The game exited normally; combined trial remains installed and will recover on
its next process startup.

Scope: this proves the conservative one-world-per-process policy in native
singleplayer transitions, including return to the SAME map/name. No outstanding
accepted writes were present at transition, so pending-write draining during
travel still needs a controlled test. It does not prove multiplayer role changes,
interrupted publication/power-loss behavior or performance. UI input observations
are not per-command acceptance receipts.

New frontend gap: after transition the stand still shows ordinary priorities and
looks editable while both settings writers are fenced. Input attempts do not
visibly explain the refusal. Storage protection passed; frontend acceptance did
not. Before broad async enablement, expose an explicit blocked/restart-required
state (distinct from recoverable loading), and prevent misleading editable
presentation. The current development launcher intentionally does not rearm after
travel; do not remove that safety rule merely to hide this message.

### 2026-10-07 — stand lock explanation implemented

SettingsGate now exposes a presentation-only state: ready, recovering or
restart_required. Only the current owner token may mark restart-required; it
neither releases admission nor changes ownership. The combined startup group's
terminal fence marks this state, including after normal world travel. UI footer
and cell tooltips distinguish temporary loading from a terminal lock; capable
cells show ?, receivers are disabled at refresh, and input paths reject while
locked (including previously queued direct/click/controller intents).

175 Lua regression scripts pass and all 53 modules compile; structural checks
pass. Actual UI integration regression covers live gate changes, footer/tooltips,
unknown glyphs, queued edits rejected and ordinary rendering after valid release.
Independent review passed. Compatible gate, UI and versioned group files installed
together with preimage backups and checked source/runtime/native/legacy/journal
hashes. Evidence: test-results/settings-lock-live-20261007 and settings-lock-*.log.
Native DLL, launcher and journals unchanged. Native visual acceptance pending.

Scope: this is the LOCAL stand gate. It does not yet transmit a server's terminal
lock to remote clients or explain the lock in every production-limits surface.
The storage fence is immediate; existing visuals change at the next maintenance
refresh. It does not add automatic rearm after travel.

Native visual acceptance completed at 15:28-15:29: after normal Return to Title
and reloading the same world, capable cells showed ? and the footer visibly read
"Settings locked after a session change or save failure. Restart the game to edit
priorities and limits." Right-click and direct X retained the unavailable state.
Both original native writers had already joined/cleaned at 15:26:36 with no
accepted writes, generation 5. No reactivation occurred. Normal Quit completed;
process absence checked. All four journal hashes and eight legacy recovery paths
remain unchanged. Evidence complete.log and verification.json appended in the
settings-lock-live-20261007 directory. Temporary loading wording is fixture-tested;
this live run specifically validates the terminal restart-required presentation.
Pending-write travel, interrupted publication and remote-client presentation
remain separate gates.

### 2026-10-07 — deterministic pending-travel regression

The combined-launcher Lua integration fixture now establishes accepted greater
than committed in BOTH streams before invoking the actual registered LoadMapPre
callback. Its latest priority edit is X. World readiness and ownership are removed
and the session epoch changes before callback execution. Cleanup must retain the
original endpoints, fence admission immediately, revoke all proofs, retire both
streams before draining either, and reject edits attempted inside cleanup.
Engine/helper/roster discovery counters must remain unchanged during cleanup,
including failed discovery attempts swallowed by a pcall.

Both original endpoints drain exactly once and preserve their latest payload.
A lost limits drain reply must retain BOTH child owners and must not claim verified
cleanup. Subsequent load/init/restart hooks and queued polls cannot replay calls or
rebind. The focused regression passes; the full Lua suite passes 175 scripts and
compiles 53 production modules. An inert-travel-callback mutant fails the new
assertions. Independent review identified the discovery-counter and child-owner
assertion gaps; both were strengthened. Logs: test-results/pending-travel-lua.log
and pending-travel-mutant.log.

This fixture uses real Lua composition and lifecycle code but mocked native
publication. It does NOT establish outstanding native writes during UE travel.
Actual game travel recorded above still had zero outstanding writes. A native
worker regression is checked separately below. Public/default enablement remains
off; the previously checked local combined trial remains installed. Read-only
post-test comparison confirms all four player journal files and all eight legacy
paths unchanged (test-results/pending-travel-protected.json).

Native counterpart also passes: `check_link.py` mode `two-stream-pending` seeds
two isolated journals, reopens EXISTING-state owners, and parks both real worker
threads before their updates. Both have accepted=3/committed=0. Both admissions
are retired and late submissions rejected before either drain. A test-only hook
INSIDE the real drain/join path checks 3/0 for the identified original worker;
only that observation releases its worker. This removes the earlier test race
where release could precede entry into drain. No sleep-based timing assumption
is used, and no minimum blocking duration is claimed.

Each stream publishes its coalesced latest update, drains/cleans its original
owner, and reopens through a fresh owner. Exact payload bytes and generations
are checked; actual Lua codecs additionally validate recovery and X decoding to
false. Worker Lua-call count remains zero. Reply shapes are validated before C++
indexing. Full native bridge checker and all 13 standalone writer cases pass.
The added observer is compiled only under PWP_DRAINING_WRITER_TESTING, with no
production behavior change. Receipt source hashes were independently matched to
current files. Durable evidence: test-results/pending-travel-native-20261007
(receipt.json and entry-two-stream-pending.log); prior build receipts/DLLs retained
under experiments/native-draining-bridge/build/previous-build-*.

Remaining acceptance distinction: the Lua fixture proves lifecycle ordering;
the native executable proves pending original-worker draining on real files.
Their combination does not prove the full UE callback/native integration with
pending writes. Next live test must positively observe pending revisions at
the travel boundary with a bounded test-only barrier, preserve settings/backups,
and recover exact latest values after normal shutdown/restart. Merely racing a
normal fast save, or repeating idle travel, is insufficient. No new DLL or test
barrier was installed in this step.

### 2026-10-07 — pending writes across actual singleplayer travel: passed

Built a separate DEV-only DLL with PWP_LIVE_PENDING_GATE_DEV_ONLY. Only the two
compiled target scopes with valid existing journal pairs qualify. Each original
worker's first update parks before the publication lane; its own real drain/join
releases it independently. The condition-variable wait has a 60-second fallback
(not a bound on filesystem IO or total drain). No Lua/engine calls occur on the
worker. A fixed evidence file records park/join/release with scope, thread and
accepted/committed counters. Normal builds omit the hold. Isolated actual-entry
tests cover join release and accelerated timeout; source/runtime/root/import/
export/artifact fingerprints passed. Receipt: experiments/native-draining-bridge/
build/live-pending-37613f6315f3/receipt.json.

The DLL-only installer validates the existing combined installation plus the
three-file lock-UI update, backs up all four journal records, preserves the normal
DLL and launcher, and changes only the launcher's DLL path. Restoration preserves
current journals and supports interruption using its durable intent receipt.
Ten installer tests and three evidence-checker tests pass. Installer never invokes
the game; checked AHK/Computer Use performs normal launches and travel.

Attempt 1 is explicitly NOT pending-travel acceptance: both holds reached their
60-second fallback before load_pre at 16:11:24. The two intended edits (Verdash
Transporting 1 to X, Stone 35000 to 35001) completed at generation 6, recovered
after normal restart, and no unrelated settings changed. Retain timeout evidence,
do not count this as a passing pending test.

Attempt 2 used a checked `--return-title-only` variant of the existing AHK macro
to avoid spending the hold window on separate screenshot round trips. It sends
the existing normal stand-close/menu/Return-to-Title sequence and stops without
quitting/relaunching. Both streams were visibly recorded parked before travel.
At load_pre 16:16:30, the original limits writer entered join at accepted=1 /
committed=0; priorities entered at 2/0. Both were still parked, timeout=false.
The initial focus click queued priority 5, followed by direct 1, which exercises
latest-value preservation during the hold. Both workers released from their own
joins, not the timeout. Original cleanup completed exactly once: limits 1/1,
generation 7; priorities 2/2, generation 8; both joined/cleaned, no retained owner.
Both park timestamps precede the load_pre log second; both joins occur within
that second. There are no WARN/ERROR lines in the attempt-2 window.

After normal Quit at 16:17:16, the installer restored the original checked normal
DLL launcher. Actual Lua-codec decoding of the latest journal generations matches
ALL original typed settings exactly; no backup bytes were copied over journals.
A third process recovered limits generation 7 and priorities generation 8,
initialization=false, with both streams active and READY at 16:19:56. The reopened
stand shows Verdash Transporting 1; read-only `pwp limit` at 16:20:44 reports Stone
35000 and Wood30000. The process module list identifies the original combined-stage
DLL. All four journal hashes remain unchanged across this final startup/readback;
all eight legacy recovery paths remain unchanged. Normal restart has no WARN/ERROR.

Durable evidence: test-results/pending-travel-live-5f54e7a161b1 (installation intent,
preimages, attempt1-timeout.tsv/log, attempt2.tsv/log, typed-restoration.json,
restored-launch.json, normal-restart.log and acceptance.json). Typed snapshots:
test-results/combined-startup-install-decd3863212b/pending-timeout-20261007 and
pending-travel-restored-20261007. Independent review confirmed native hold/join
ordering, matching original launcher/DLL, and unchanged final journal hashes.

Scope: local singleplayer, known storage/guild, normal Return to Title followed
by orderly process restart. This closes the pending-write travel gate for that
case. It does not establish crash/power-loss durability, multiplayer role changes,
remote-client lock presentation, general automatic rearm after travel, or frame
performance. Local combined trial remains enabled; public/default async remains
off. No commit, publication or Workshop/Nexus upload performed.

### 2026-10-07 — disposable native writer interruption: passed

Added `native/save_core/draining_crash_test.cpp` and
`tools/test_draining_crash.py`. The test builds actual DrainingWriter, backend,
journal and filesystem code into disposable executables. No production logic,
game installation or player journals changed. Only owned helper processes are
terminated; no game process is terminated.

The 36-case matrix covers eight boundaries for each stream both alone and after
the other stream has committed (32 cases), plus four simultaneous-pending cases
at after_backup/after_publish for each stream. In the latter, both original
writers have accepted=1/committed=0 at interruption, and the second worker is held
before the publication lane. A flushed nonce/point/stream/PID/thread marker plus
exit91 proves the intended boundary was actually reached. Fresh-process recovery
acquires fresh owners without approving writes or replaying lost RAM tails.

Independent Python framing/SHA256 checks verify complete scopes, generations and
payloads against native recovery. Actual Lua Store/Caps serializers and typed
codecs validate X and OFF in every valid slot and complete orphan record. Exact
canonical pairs and expected stage/backup artifacts are checked, including the
inactive slot. Read-only recovery must preserve every surviving file byte for
byte. Before publication the old generation2 is selected; after publication the
new generation3 is selected despite the interrupted writer not acknowledging it.
The other pending stream stays at generation2. Previously committed other-stream
updates remain generation3: this is deliberately not two-stream atomicity.

Two executable negative controls (inert termination and missing hook) are
rejected. Six oracle mutations are rejected: older candidate, swapped streams,
promotion of staging data, replay of the lost tail, disappearance of the other
slot, and checksum corruption. Initial harness runs exposed a Windows CRLF
comparison error and incomplete test assertions; those runs are retained and do
not count as acceptance. No persistence defect was demonstrated by those failures.

Passing evidence: `test-results/draining-crash-9e1d6506aa30/receipt.json` with 36
cases, four both-pending cases, two negative controls, six oracle mutants, stable
source hashes, binary hashes and retained per-case artifacts/logs. Main separately
verified all current source hashes, all 36 boundary markers and complete retained
directory hashes. Existing journal suite also passed 32 tests, zero skips/errors/
failures: `test-results/save-native-journal-20261007T160514853157Z/receipt.json`.

Scope: controlled interruption of the real native writer in disposable Windows
processes. This closes that isolated recovery gate; it does not establish physical
power-loss durability, an actual game-crash integration result, multiplayer role
transitions, general same-process rearm or frame-time performance. Local combined
async remains enabled under its existing checked launcher; public/default remains
off. No commit or publication.

Independent final review found no blocking false-pass or concurrency issue,
confirmed both earlier test gaps closed, and matched recorded source/binary/header
hashes. The six oracle mutants test the checking logic; they are not six rebuilt
native implementation mutants.

### 2026-10-07 — session isolation and remote lock candidate: offline passed

Added clean and lost-drain host-to-client-to-host cases to the actual combined
launcher regression. Real Session epochs change despite the same map name;
queued actions/guards expire, roles become undecided before client selection,
remote caps remain separate from local data, and returning to authority clears
the remote view. Both original owners drain exactly once. No new bind, accepted
write, activation or legacy IO occurs after the terminal fence. Lost replies
retain both owners. This fixture drives main's ordering; it does not execute an
actual engine ClientRestart or native network handshake.

Review found a real presentation/protocol gap: a fenced host could publish its
retained settings as a current successful snapshot. Net now suppresses both
snapshot streams and edit/ACK handling while fenced, including reentry during
message construction/native send. Confirmed peers receive session-bound L lock
messages. Client validates server/client/guild identities, invalidates both
streams and queued edits, clears remote rules at the main composition boundary,
and rejects later snapshots/ACKs for that locked session. A recovering lock uses
bounded fresh-handshake backoff; both snapshots must complete again. A terminal
restart lock does not automatically retry and cannot be downgraded by a delayed
recovering message. Schema 3 is required on both ends; old schemas are rejected.
The PWP_V2 envelope spelling remains framing, not the negotiated schema version.

Priority footer/tooltips and Production Limits explain whether the server is
loading or the host must restart. Local terminal locks and explicit scheduler
refusals now say restart rather than incorrectly promising recovery in progress.
The new local status regression failed before that correction and passes after.
Queued direct/controller edits remain blocked on receiving remote lock state.

Validation: all 53 modules compile with Lua5.4, all176 regression scripts pass,
and structural checks pass (existing panel194-local warning remains). New
network regression covers wrong/stale identity, midstream fencing, stale ACKs,
ACK construction reentry, schema mismatch and recovering-only retries. Main's
real receiver/composition regression confirms remote caps are cleared without
modifying local saved data. UI integration has67 passing cases. Independent
review found no remaining blocker in these changes and independently exercised
fencing inside native send. Evidence: test-results/session-lock-20261007/receipt.json
and test-results/session-lock-full-suite.log.

Important limit: server fence alone does not proactively notify idle clients.
Clients learn the lock on their next authenticated edit, snapshot attempt or
handshake. No broadcast/polling mechanism was added. An offline passing result
is not live multiplayer acceptance. No files were deployed this step; the game
still has its previous checked schema/build. Next: checked coordinated client/
server deployment and actual transition/reconnect test, preserving existing
journal and legacy backups. Public/default async remains off; the existing local
combined trial remains unchanged. No commit or publication.

### 2026-10-08 — coordinated install and admitted-world transition verified

The preceding offline-only deployment note is superseded by the checked Oct 7
installation: all 53 server Lua files were downloaded back and matched the
candidate; the server restarted at 20:08:37. Local installation receipt:
`test-results/session-lock-install-9b33e1f70608/installed.json`. Server evidence:
`test-results/server-schema3-20261007/`. Server native async remains disabled.
The fresh client negotiated schema 3 and the expected RAM guild. That handshake
alone did NOT prove editing: later logs exposed a fresh-client trial timeout.

Oct 8 live test used process 13368 throughout singleplayer -> title -> RAM ->
title -> the original singleplayer world. Both streams recovered generations
7/8 and the stand visibly displayed saved numbers and X. At 12:03:08 both native
owners joined and cleaned successfully on load_pre. RAM then synchronized as a
client with schema 3; its stand displayed the local restart-required fence.
A clicked cell stayed unavailable. On returning to singleplayer, session 4 was
authority/settings-unavailable and the visible fence remained. There were exactly
two stream starts, two native exits and one combined activation. No rearm occurred.
The game quit normally at 12:06:57. All four journal hashes and all eight legacy
paths were unchanged. This run made no admitted priority/limit edits and does not
test pending-write travel (covered separately), server async or crash recovery.

Evidence: `test-results/session-transition-live-20261008/receipt.json`, `live.log`,
`client-lock.png`, `returned-authority-lock.png`. Public/default async stays off.

New blocker: the experimental launcher holds its gate while waiting for local
authority even when starting directly as a confirmed client. Sync can be ready
while both setters refuse edits, followed by a 600-second readiness timeout.
The Oct 7 timeout admitted no owners and left journals unchanged. A never-admitted
client needs a terminal opt-out that allows network edits only in that client
session and re-fences before any subsequent role reset. Admitted/partial/uncertain
owners must retain the current no-rearm policy. Status commands reporting saved
and sync-ready must not be interpreted as proof that the edit gate is open.

The fresh-client regression failed before the fix. The combined launcher now
terminally opts out only when both modules are decided clients in the current
positive epoch, both network submit functions exist, and no admission/child/native
ownership exists. The gate group releases only its own pristine token and cannot
create children or commit afterward. Transition/exit refences before role reset.
Unknown/authority readiness still times out; admitted and uncertain owners cannot
opt out. Main independently reran all176 regressions and structural checks after
the change, with no failures (existing panel194-local warning). These are offline
results until the new experimental closure is installed and tested as a client.

Follow-up live result: installed the checked experimental closure using
`tools/install_client_optout_trial.py`; receipt is
`test-results/client-optout-install-711131d75a2d/installed.json`. All 36 staged
hashes match. Only the two experimental Lua files changed; no server or production
Scripts changes were needed. Independent review found no installer blocker.

Fresh process24640 used the documented server macro successfully. At12:12:12 the
launcher explicitly opted out in client epoch2 without starting either native
writer. Schema3/RAM synchronization completed. Vixy's first enabled work priority
was changed1->2->1 with direct keys, then1->2->1 with right/left mouse input.
Each completed edit cleared its pending marker; the tooltip reported confirmation
by server. The final visible value was restored to1. This verifies the live edit
path, not an independently downloaded server-file durability/restart check.

The same process then returned to singleplayer. At12:16:23 the opt-out was
terminally fenced before the new world-role state; at12:16:27 session3 was local
authority/settings-unavailable. The stand visibly required a restart. No native
startup or rearm occurred. The game was quit normally after recording this result.
All four local journal files and eight legacy paths remained unchanged. Client
timeout behavior beyond600s was tested with a fake clock, not a ten-minute live
soak. Production-limit edits and a fresh authority boot of this follow-up closure
remain separate live checks. Public/default and dedicated-server async remain off.

## 2026-10-08: fresh authority and production-limit journal recovery

Evidence: `test-results/authority-limit-live-20261008/` (`baseline.json`, original four records, `changed-decoded.json`, `restored-decoded.json`, `live.log`, `receipt.json`, `restored-panel.png`). Checked closure: `client-optout-install-711131d75a2d/installed.json`; no new deployment or production-code edits in this test.

Three normal fresh-process singleplayer launches of Palpagos Islands passed combined admission. First readiness 13:15:20 recovered limits generation 7 and priorities 8. Original rules: Stone 35000, Wood 30000. At 13:16:06 the existing `pwp limit Mining Stone 35001` command reported asynchronous pending; independent binary SHA/header/payload checks confirmed generation 8. Quit 13:16:25 reported accepted=1/committed=1 and both owners joined/closed with verified cleanup.

Second readiness 13:17:54 recovered limits generation 8; the live command readback at 13:18:21 showed Stone 35001. Restoration at 13:18:34 committed Stone 35000 as generation 9. The panel visibly showed Saved and both original limits; entering the Stone editor then Escape cancelled without changing the rule. Quit 13:19:17 confirmed one accepted/committed limits write, no priorities writes and clean cleanup.

Third readiness 13:20:44 recovered limits generation 9 and priorities 8. Readback 13:21:07 showed Stone 35000/Wood 30000; normal quit joined both workers with zero additional writes. Game process closure verified. All four journal checksums validated. The authoritative limits payload exactly matches the original generation-7 payload; generation/checksum advance is intentional. Both priorities records are byte-identical and all eight legacy paths remain unchanged. The older limits B slot legitimately retains the test generation-8 value 35001. No WARN/ERROR in the bounded log.

Independent agent review confirmed the one-byte effective limit change, second-process recovery and exact restoration. The old B/gen6 already contained 35001, so acceptance compares the edited record against the previously authoritative A/gen7, not merely B-before versus B-after.

Scope: confirms command-entered authority limit save, clean quit and restart recovery on the latest client-opt-out closure. It does not establish UI confirmation/commit behavior, multiplayer limit edits/server-file durability, crash/power-loss behavior, actual producer output or performance. Public/default async and dedicated-server native async remain OFF. Next live gate: dedicated-client limits editing with preserved/restored server state and independent persistence evidence; retain the other release gates above.

## 2026-10-08: multiplayer limit rejection and empty-panel fixes

Evidence: `test-results/client-limit-live-20261008/`: downloaded server configuration, local hash baseline, before/after live logs and receipts, screenshots, exact five-module patch, compiler/regression output and deploy log. RAM had no caps.txt (also no tmp/pending/bak variants) and downloaded `config.lua` has `work_caps={}`. No verified producer adapter is registered. Therefore successful legacy-limit editing cannot be exercised on its existing state; no synthetic rule was seeded and no server restart/code/settings upload occurred.

Client process42604 joined through the documented AHK and verified schema3/guild. `pwp limit Mining Stone 35001` at16:45:56 was rejected and created no server limit file. It exposed two defects: the specific refusal reason was reduced to generic `rejected`, and global status stayed rejected, making a confirmed empty ruleset display "Limits unavailable". Screenshot additionally showed the empty-state text above the panel. Client opt-out started no native workers; normal quit16:47:12 preserved all local journals and eight legacy paths.

Fixes in caps/main/net propagate only allowlisted refusal codes, retain confirmed snapshot readiness after rejection, preserve incomplete snapshot uncertainty, other pending edits and applied-unsaved warnings. panel_status maps reasons into readable messages. panel.lua puts empty text into the existing Head row. Schema3 unchanged. Agent demonstrated failing regressions before changes and main independently passed all177 regression scripts, Lua5.4 compilation of53modules and structural checks (existing194-local warning remains). New `test_net_limit_rejection.lua` covers actual Caps refusal/no IO, safe wire reasons, duplicate acknowledgements, subsequent edit, incomplete snapshots, concurrent pending edit and both stream save-failure states. Existing integration/render/reliability tests extended.

Checked local deployment changed exactly caps.lua, main.lua, net.lua, panel.lua, panel_status.lua relative to the previous installed schema3 code. Backup: `D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS/Mods/PalWorkPriority/backups/deploy-20261008-165209-4075a67b67b74ad7a589431edac29512`. `installed-code-after.json` is the current53-module hash manifest; the earlier install receipt no longer describes production Scripts. The36-file experimental stage, nativeDLL/launcher, journals and legacy remained unchanged.

Retest client5676 joined RAM at16:53:36. Repeating the rejected request16:53:55 against the UNCHANGED older schema3 server left synchronization ready at16:54:18. Screenshot `rejected-after.png` confirms "Synced with server", "The server rejected this change; confirmed settings are unchanged", and "No production limits configured" inside the panel. Client storage totals appropriately remain unavailable. Normal quit16:54:43; zero native starts and all local journal/legacy hashes unchanged. Fresh GPortal directory listing still showed no caps file and unchanged config/priorities timestamps. This is live proof for generic old-server rejection and layout, not live proof for the new detailed server code or a successful server limit write. New code-specific reason propagation is regression-tested only until checked server deployment/retest. Public/default and dedicated-server native async remain OFF.

Remaining: checked server update for detailed refusal reasons; successful multiplayer limit persistence needs an appropriate supported/legacy-rule test fixture and independent server-disk/restart evidence. Do not relabel the rejection test as that acceptance gate. No commits or publishing performed.

## 2026-10-08: checked RAM deployment and detailed refusal acceptance

Evidence: `test-results/server-rejection-20261008/` candidate manifest/archive,
server-install-receipt.json, live-offset.json, live.log, live-receipt.json and
detailed-rejection.png. GPortal download endpoint was blocked by Chrome; no
bypass used. Uploaded archive extracted separately; all five changed modules
were read through the visible editor and compared by SHA256, accounting for
editor CRLF normalization. Active folder preserved as
`Scripts-before-rejection-20261008`; staged Scripts copied into the mod root.
Installed transport contents matched staging, and directory listed 53 modules.
This is not a downloaded full installed 53-module hash receipt.

Normal restart with zero players: boot19:58:47, authority/settings available
19:58:52. Actual server runtime reports UE4SS Git ba2efd55. Existing scratch
V1/V3 scripts refused invalid run tokens; dedicated native async remains off.
Boot also shows two BPModLoaderMod PalWorkPriority actor loads at19:58:50;
retain as an installation/asset-lifecycle investigation, not a proven cause.

Documented AHK launched client44720; verified RAM/schema3/expected guild and
opened the stand20:01:01. Unsupported `pwp limit Mining Stone 35001` queued
20:01:21. Status20:01:28 stayed ready; screenshot confirms specific unsupported
producer explanation, Synced with server, and No production limits configured
inside the panel. Independent agent inspected screenshot and logs: raw reason
code is not logged, so detailed rejection evidence is visual, readiness evidence
is both visual and logged. Initial snapshot_apply_failed20:00:34 recovered to
ready20:00:41; investigate separately rather than claiming an error-free session.

Normal quit20:01:52 completed cleanup without admission/attachment/native worker
starts. All four journal hashes and eight local legacy paths unchanged. GPortal
post-test root still has no caps file or variants. Server priorities were rewritten
at restart, generation89->90; comparison through editor with retained .bak proves
identical non-comment rows and identical payload checksum7e4eefdc. Do not claim
server priorities were byte-for-byte unchanged. Server remains running, client
closed. No commit or publication.

Detailed refusal gate is now closed. Successful multiplayer limit persistence is
still open: use a separate disposable local dedicated-world fixture with a clearly
labelled legacy rule and synchronous writer, verified runtime loading, client edit,
independent server-file delta, normal server restart/recovery and restoration.
The earlier local server fixture failed UE4SS loading; it is not ready acceptance
evidence. Do not seed synthetic rules into RAM or enable headless native async to
substitute for that fixture. Public/default and dedicated native async remain OFF.

## 2026-10-09: isolated-server preflight and graceful test control

The local dedicated installation remains stopped; RAM and the installed client
were not changed this turn. `test-results/server-fixture-20261009/preflight.json`
records the restored local runtime hash,34native-mod directories, no active
Workshop package entries and disabled REST. These current settings prevent a
useful fixture launch; they do NOT explain the earlier failed trial, whose
archived config explicitly activated UE4SSExperimentalPW with a dedicated rule.
The cause of that runtime-load failure remains unproved.

Removed force termination from `tools/server.py stop`. New server_control uses
the official local REST shutdown endpoint only when already configured, checks
listener ownership plus selected process identity, refuses proxies/redirects,
and waits for process exit without kill fallback. Start refuses known-missing
shutdown configuration. No REST/password/firewall settings are changed by these
tools. Ownership sampling is not an atomic socket-to-PID binding. Native graceful
shutdown still needs live acceptance; an HTTP200 or observed exit alone is not
settings-durability evidence. Tests inject foreign listeners, PID replacement,
post-request enumeration failure, timeout and transport failures. A no-force
regression fails against historical HEAD's force-stop implementation.

Independent snapshot investigation found no justified production fix:
snapshot_apply_failed can mean callback refusal/exception or commit rejection;
the local gate does not block remote snapshot replacement. Existing retry
recovered;53modules compile and13targeted Lua regressions plus6in-memory ordering
checks passed. The log lacks the specific failing branch. Capture bounded
diagnostic details on reproduction rather than guessing a role-race fix.

Remaining fixture work: preserve local world/runtime/config, isolate the minimal
runtime and Lua mod package, establish a safe configured normal-shutdown route,
prove actual UE4SS loading, then perform a legacy-rule client edit and independent
server-disk/restart recovery. No successful multiplayer save gate claimed here.
Broad Python discovery encountered an existing tools/tests module-name collision
for test_native_save_journal; targeted suites are the verified result, not a
whole-Python-suite pass. Public/default and headless native async remain OFF.

Final independent review hardened configuration parsing against commented fields,
wrong sections, duplicate settings, quoted field-like text, nested tuples and
empty unrelated values. Main reran41server/control tests and23stress tests, all
passed; Python compile and touched tracked-file diff checks passed. Saved logs:
`test-results/server-fixture-20261009/server-tests.log` and `stress-tests.log`.
Read-only preflight of the real INI now correctly refuses disabled REST. No live
shutdown/API request, credential/config change or game/server launch occurred.

### October 9 live fixture follow-up (supersedes preflight-only state above)

Original local Mods, Saved and LogicMods were preserved by rename under
PalServer/PWPTestBackups/fixture-20261009 before fixture activation. RAM was
untouched. The first launch bound REST only to127.0.0.1:18212 but returned401
with effective AdminPassword empty despite the generated fixture INI. UE4SS
was not loaded; no save acceptance was attempted.

A single CTRL_C_EVENT requested exit after confirming that only the target
server and helper shared its console, no unattended launch flag, and the
local UE5.1 interactive first-signal handler requests engine exit. Both
processes exited. No repeat signal, CTRL_BREAK, CTRL_CLOSE or force kill used.
This establishes observed exit, not persistence correctness.

Preserving the copied selected world's WorldOption.sav under a fixture-only
name and relaunching made authenticated REST info return200 with the expected
fixture server name/version1.0.5.102999. This controlled change identifies the
copied world options as the admin-configuration conflict in this fixture.
The new server.py stop then completed through REST with both processes gone.
Runtime deployment still failed; explicit-workshopdir trial is next.

Independent helper patch now checks every listener address, port and owner,
requires explicit127.0.0.1, and rejects wildcard/LAN/IPv6-only destinations.
Main reran32control+14server unit tests successfully. Runtime/source-loading
and successful multiplayer save/recovery gates remain open. Async remains OFF.

Fixture closed: explicit-workshopdir also did not produce ManagedMods or load
UE4SS. A second REST normal shutdown succeeded. Original local Mods, Saved and
LogicMods restored; failed fixture retained under the backup tested-fixture
subdirectory. activation.json records restoration; live-result.json records
both shutdowns and the unresolved runtime-loader gate. No forced termination,
RAM changes, public enablement or multiplayer durability claim.

Independent loader review: fixture matches the official documented package
layout, activation names and server rules; shipping binary contains loader
paths. PalModSettings.ini is constructed dynamically, so its absence as a
complete binary string is not evidence that the loader is absent. Missing
ManagedMods manifests places this failure before successful deployment, not
at UE4SS initialization. Actual resolved Mods root, config migration/filtering
and initialization gates remain hypotheses. Next investigation should capture
the loader's actual config/filesystem path before another package change.
Final validation:46server/control+23stress tests pass, Python compile passes,
and touched tracked-file diff check has no whitespace errors.

## October 9: manual fixture and multiplayer limit recovery

Static review supports the launcher-root Mods/PalModSettings.ini location.
No dedicated-server skip was found inside traced StartupModule, but its actual
invocation is unproved. Kernel-File ETW was denied admin access; no permissions
changed. Missing manifests alone do not prove UE4SS initialization failure.

Manual dwmapi loading from the already archived official2281fa31 release worked;
Workshop loading was disabled in the fixture to prevent double loading. Runtime
SHA25621b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8.
All53Lua sources match the repo. Game/server1.0.5.102999; mod0.5.0-rc1.
Boot20:00:06; authority ready20:00:10. Headless stress correctly FAILED on
unverified assignments despite completed invocation and2camps. With a connected
client,5command-bound normal passes completed in11.55s. No frame-time claim.

Client ready20:03:15 saw inherited legacy Mining/Stone35000. Client command
20:03:29 changed it through normal network routing to35001. Server recorded
player change and wrote guild-scoped caps generation1, checksum42022037.
Client confirmed ready35001 at20:03:48. Normal client quit20:04:13 and REST
server shutdown completed. Reboot20:04:29, ready20:04:33; reconnect status
20:05:21 recovered35001. Panel20:05:30 visibly showed35,001 and Synced with
server. Storage and limit state remained Unavailable: no stock/production or
item-specific-limit acceptance is claimed.

Server caps SHA2569da4beb1572b7fbcf8246e8a830e134f284609f1a9344d739136d91f2bb62204
unchanged across restart. Client legacy priority/limit hashes unchanged. Both
client sessions opted out without native writer admission/attachment. This
accepts synchronous dedicated persistence, NOT dedicated asynchronous saving.
Final client quit20:05:53, REST shutdown, original local folders restored;
manual loader additions retained under backup/tested-fixture and removed from
active paths. RAM unchanged. No commit or publication.

Evidence in test-results/server-loader-20261009: acceptance.json (main's summary,
not an automated validator), server-priority.log, client-session.log, both caps
copies, client-save-isolation.json, failed headless stress.json, passed
stress-with-client.json, recovered-limit.png, activation.json and manual.json.

Closed: one-guild legacy edit, synchronous save, normal restart, client snapshot
and UI recovery. Still open: Workshop deployment, empty-server assignment
verification, multiple clients/guilds, storage/producer behavior, dedicated
native async prerequisites, and the other public-release gates.

Independent review accepted the narrow synchronous legacy-save/restart/client
recovery gate. Reviewer recalculated checksum42022037 over219payload bytes,
confirmed generation1 and identical caps copies, inspected the recovered UI,
and verified all3current client legacy hashes against the pre-edit snapshot.
Five connected-client completion receipts match. Reviewer explicitly excluded
crash/power-loss durability, async, Workshop, priorities-edit persistence and
actual ceiling enforcement. Normal exits/restoration are main-observed process
and filesystem evidence, not inferred from mod logs. Main's final process check
found no Palworld/PalServer process; active manual DLL/runtime paths absent.

## October 9 empty-server diagnostic follow-up

Read-only assignment census originally reported an incomplete scan because
UE4SS FindAllOf returns nil when no instances exist. A regression failed before
the diagnostic fix and passed afterward. After a normal fixture restart, the
live census at20:15:42 reported14Pals,0records,0failures,complete=true. Every
direct Pal actor remained unavailable and each assignment stayed unknown. This
fix changes diagnostic accuracy only; it does not authorize scheduling against
missing assignment evidence or close empty-server acceptance.

The independent storage census matched production totals before the restart.
Client storage is a separate missing transport path, now under implementation.
All177Lua suites passed after the census fix. Whole Python discovery now passes
414tests (333passed,81native-dependent skips), independently rerun. Steam-library
path discovery resolves the actual D: installation. The disposable server was
stopped normally and original Mods/Saved/LogicMods restored; manual runtime
and proxy archived out of active paths. Evidence: test-results/server-assignment-20261009.

See [current consolidated gates](release-gates-2026-10-09.md); native async
release status has not changed.

## October9 dedicated identity observation

The isolated manual-runtime server returned a coherent current-world chain,
manager ownership, loaded-world=true and an absolute engine Saved root matching
the configured fixture. Eleven one-second samples agreed; the one-shot observer
then cancelled its timer successfully. No writer DLL or storage grant was used.
The configured world was selected from GameUserSettings, never directory order.
Both empty-server worker directors were WaitForLoadingAround; Pal actor evidence
remained unavailable. Normal shutdown and full fixture-folder restoration passed.
See `test-results/server-identity-20261009/acceptance.json` and raw identity.log.
This advances the read-only prerequisite only: integration, recovery, lifecycle,
remote acknowledgement and actual async dedicated writes remain unaccepted.

## Parked cutover tooling (2026-10-04..11)

Merged on 2026-10-20 from seven notes (native-file and native-handoff of
2026-10-04; dedicated-clock-probe, installation-fence, native-rollback,
settings-cutover-fixture and settings-export of 2026-10-11). None of this runs
in 0.5.0 except the startup fence in `Scripts/main.lua`. The tools stay in the
repo because optional gate G2b would need them. The staged write path that
replaced the v1 destination leases is in
[staged-reservation-recovery-2026-10-11.md](staged-reservation-recovery-2026-10-11.md)
and its native startup run in
[staged-recovery-native-2026-10-11.md](staged-recovery-native-2026-10-11.md).

### Native background file publication (2026-10-04)

Code: `experiments/native-file-probe/` (`entry.cpp`, `probe.cpp`, `driver.lua`,
`check_link.py`, `verify_readback.py`, `build/receipt.json`); acceptance
`tools/accept_native_file_probe.py`. Evidence:
`test-results/native-file-live-20261004/`.

- The primitive is **first publication: it refuses an existing destination.**
  The fixed scratch root is compiled in; Lua cannot choose a destination.
  Input is validated hex copied into owned native bytes before IO.
- Live (PID 42708, world-ready 11:41:16 UTC): 11:42:07 published 262,144 bytes
  (256 KiB) in **17.6866 ms** native inclusive time on worker thread 25676
  (game/completion thread 35196). 11:42:22 a different 35-byte payload was
  **refused with Windows error 183** (already exists) in 30.6263 ms. External
  whole-byte readback after each step: SHA256 `2312394b...a415e9` unchanged.
- DLL SHA256 `7b6b2b23...2aae44`, runtime `21b691a6...ef92b8`. Review fixed a
  directory-handle leak when vector allocation throws (16 native initialization
  regressions pass).
- Open: successive generations and recovery, ownership across duplicate
  loads/reloads, queued/in-flight retirement, storage/session binding, and
  acknowledgements only after validated persistence. A timed-out callback cannot
  cancel an OS write; no power-loss or shutdown-latency bound exists.

### Native background handoff (2026-10-04)

Code: `experiments/native-lua-handoff-probe/` (`entry.cpp`, `driver.lua`,
`warm.lua`, `README.md`, `warm-receipt.json`); acceptance
`tools/accept_native_handoff_warm.py`. UE4SS `ExecuteAsync` runs a native
copy/checksum, completion is queued to the game thread; passing needs correct
data, different thread identities and a game-thread heartbeat strictly inside
the native interval.

- **Timer trap:** the first trial (`handoff-20261004T105421Z`) failed
  "delay too short" with a strict 200 ms gate measured by GetTickCount64 around
  Sleep(200). Microsoft documents 10-16 ms resolution for both. The log had no
  raw timestamps, so the cause is not proven, but it stays a failed trial.
  Measure elapsed time with QPC.
- V2 with QPC (10 MHz, integer microseconds, the full 200,000 µs still required,
  overlap must clear both edges by more than 3 µs), before world load:
  200,268 µs, 4 game-thread beats inside, tightest margin 6,292 µs, checksum
  2382238981 over 256 KiB (matches Python).
- Warm (after world-ready 11:24:14 UTC), three trials at 11:25:05/15/25:
  201,190 / 200,674 / 200,596 µs, **7 / 7 / 6 game-thread beats** inside about
  200 ms of native work, worker 43944 vs game thread 34948.
- Evidence: `test-results/native-lua-handoff-live-20261004/`,
  `test-results/native-lua-handoff-warm-20261004/`.

### Dedicated clock-only probe (2026-10-11)

Code: `experiments/dedicated_parameter_clock.lua` (calls
`GetAccurateRealTime` on `Default__GameplayStatics`),
`experiments/dedicated_clock_probe.lua`, `experiments/dedicated_clock_entry.lua`,
`experiments/dedicated-clock-probe/main.lua`; tools
`tools/install_dedicated_clock_probe.py` (read-only preflight by default, arms
`enabled.txt` last), `tools/prepare_dedicated_clock_fixture.py`,
`tools/accept_dedicated_clock_probe.py`; tests
`tests/test_dedicated_clock_probe.lua`, `tests/test_dedicated_parameter_clock.lua`.
(The source note was not valid UTF-8; it was read bytewise for this merge.)

- **Out-parameter trap:** pinned UE4SS 2281fa31 `LuaUObject.cpp:193` captures
  scalar out-parameter references at Lua stack slot 1 and does not consume the
  argument, so **consecutive scalar out-params all land in argument 1**. Pass
  one fresh table twice and read `Seconds` and `PartialSeconds` from it. A
  pinned-binding regression fails if the adapter goes back to separate tables.
- Three disposable dedicated boots (no production mod, normal REST shutdown,
  original-hash restoration each time; the launched image is
  `PalServer-Win64-Shipping-Cmd.exe`):
  1. `dedicated-clock-native-20261011` (nonce a09ea44f...): clock_unavailable.
  2. `dedicated-clock-binding-20261011` (4aecd52a...): Seconds integer,
     PartialSeconds nil, failure at stage `fraction`.
  3. `dedicated-clock-shared-20261011` (0383ef29...): **passed on the third
     boot**: 8 samples × 34 reads, all 7 between-sample intervals and all 8
     within-sample spans advanced, timer cancelled. Spans about 0.162-0.218 ms.
- Not validated: elapsed semantics and total callback cost. They need an
  independent reference such as QPC; `os.clock` is not a fallback.
  `server.py start` readiness cannot be reused (it waits for `PWP_READY`).
  Installer constants point at the restored third trial; a new run needs fresh
  backup and receipt paths.

### Startup fence and interrupted cutover fixture (2026-10-11)

**Live in the shipping code:** `Scripts/main.lua` opens `.settings-cutover`
before loading `priorities.txt`/`caps.txt` or inspecting
`async-trial/launch.lua`. If the marker exists, or the open fails with anything
other than "not found", it acquires `settings_gate`, requires a restart and logs
an error. It never reads, executes or removes the marker. Regression:
`tests/test_main_integration.lua`, "cutover fence precedes settings recovery and
launcher inspection". `tools/deploy.ps1` also refuses to deploy while the marker
or trial launcher/receipt exists.

`tools/settings_cutover_fixture.py` works only on a verified review bundle in
its own `mkdtemp` directory (no game-root argument). Forward: stage and verify
the marker, replace all four recovery paths of both streams with checked new
generations, verify, retire the two copied trial markers, remove the marker
LAST. Resume accepts only original or intended exact bytes. Its **rollback
mode** (plan-bound rollback intent that outlives completion, restores eight
legacy and two trial entries, fence removed last) has run only on bundle copies and the
disposable native fixture, never on a real install: the 2026-10-11 switch back to the shipping path needed no cutover
([DECISIONS](DECISIONS.md), Test installation).

- Trap caught in review: an automatic `TemporaryDirectory` finalizer could
  bypass the explicit cleanup refusal if the root was replaced; now `mkdtemp`
  plus identity-checked cleanup.
- 42 interruption boundaries, three fresh-process recoveries; 211 Lua scripts,
  55 modules. Evidence: `test-results/cutover-recovery-20261011-*.log`
  (`-python.log` is the pre-fix baseline, `-final-python.log` the acceptance),
  `test-results/cutover-real-bundle-copy-20261011.json`,
  `test-results/cutover-rollback-20261011/`.

### Native rollback (2026-10-11)

Tools: `tools/settings_cutover_lock.py` (share-mode-zero Windows lock, no PID
guessing or stale-lock stealing), `tools/prepare_cutover_native_fixture.py`,
`tools/run_cutover_rollback_native.py`. Evidence:
`test-results/rollback-native-20261011/`.

- Rollback interrupted right after replacing `caps.txt`: the first boot (nonce
  2e1e0ca5...) reported **restart-required**/unavailable, zero settings opens,
  bytes unchanged. A fresh Python process **resumed and restored the
  originals** (eight legacy and two trial paths, including absence; marker
  last). The second boot (ee15c050...) was ready/saved with the original
  priority 3/X and Stone=100.
- This fixture was **replacement-based**. G2b still needs a new rollback test
  of the staged write path; this evidence must not be reused for it.
- The lock excludes cooperating migration processes only, not every writer.

### Installation fence and pins (2026-10-11)

Tools: `tools/settings_installation_binding.py`,
`tools/settings_installation_fence.py` (read-only preflight by default,
`--rehearse`, `--recover`), `tools/settings_inventory_pins.py`. Evidence:
`test-results/installation-fence-rehearsal-ee617305.../` (marker only) and
`-0d44ee40.../` (with pins).

- Marker-only rehearsal on the real D: client: a competing process was refused
  the lock with sharing error 32. With pins: all 4,152 protected mod files plus
  UE4SS.dll held, 8 of 8 write/delete requests refused (error 32), binding
  digest `70c1fcb6...ef15d17` unchanged.
- Only three root paths are excluded from the inventory: `priority.log`,
  `.settings-cutover` and the empty `.settings-cutover.lock`.
- **Limit:** the cooperative lock and the pins exclude only cooperating writers
  and existing files. Steam updates and `tools/deploy.ps1` do not take the lock,
  and new names are not excluded (existing-file exclusion, not namespace
  exclusion).

### Export bundle (2026-10-11)

Code: `experiments/settings_export_reconcile.lua`,
`tools/settings_export_bundle.py`; `tools/settings_migration_backup.py`
`game_closed` now covers the whole Palworld/PalServer process family including
`PalServer-Win64-Shipping-Cmd`.

- Bundle `test-results/export-review-only-20261011-e5a32f93/bundle`:
  **41 priority rows and 2 limit rows**, from **journal generations 8 and 11**;
  the legacy files held the same 41/2. This is the bundle the 2026-10-11 switch
  back was checked against.
- Trap: the `.body` candidates must not be copied over `priorities.txt` or
  `caps.txt`, because existing `.pending`, `.tmp` or `.bak` generations may
  still win recovery. Membership claims came only from journal-listed keys.
