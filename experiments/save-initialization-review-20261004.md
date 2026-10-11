# Positive absence and first initialization review

The tested root mapping is accepted as observed correlation. No trustworthy
positive-absence and first-initialization provider was identified in the
audited exposed APIs. Do not turn Engine null, a false existence result, an
empty directory listing, or Lua errno 2 into permission to initialize settings.
This review adds no runtime provider, production integration, install or game
calls. The companion tests use disposable files in separate Python processes.

## Evidence and API boundaries

`test-results/save-root-live-20261004/acceptance.json` correlates the reported
`C:/Users/matra/AppData/Local/Pal/Saved/` root, existing physical synthetic B
slot, SHA-256 and fresh native 262144-byte recovery. The receipt explicitly
records no new write, no active-storage verification and no positive absence.

Local primary Engine sources are under
`D:/Program Files (x86)/Epic Games/UE_5.1/Engine/`:

- `Source/Runtime/Engine/Public/SaveGameSystem.h:119` maps negative FileSize to
  DoesNotExist. Its generic slot path at line 165 is ProjectSavedDir followed
  by `SaveGames/<slot>.sav`; it is not the account/world Level.sav path.
- `Source/Runtime/Core/Private/Windows/WindowsPlatformFile.cpp:1013` collapses
  metadata-query failure or a directory into FileSize -1. At line 1279,
  non-append OpenWrite uses CREATE_ALWAYS, not CREATE_NEW.
- `Source/Runtime/Engine/Private/GameplayStatics.cpp:2435` onward returns false
  or null for failed loads; null also covers unsuccessful deserialization.
- `Source/Runtime/Engine/Private/Kismet/BlueprintPathsLibrary.cpp:314` exposes
  boolean FileExists and DirectoryExists, without operation-scoped OS errors
  or a retained directory/file handle. GetProjectSavedDirectory reports a path;
  it does not lock that path or select an active world.
- `Plugins/BlueprintFileUtils/Source/BlueprintFileUtils/Private/BlueprintFileUtilsBPLibrary.cpp`
  exposes boolean copy/move wrappers, if that optional plugin is present.
  Shipping availability has not been established here. Copy with replace=false
  is not sufficient: `Source/Runtime/Core/Private/HAL/FileManagerGeneric.cpp:147`
  first checks existence, then calls platform CopyFile without a no-replace
  argument. `Source/Runtime/Core/Private/GenericPlatform/GenericPlatformFile.cpp:752`
  opens the destination for normal writing. A concurrent creator can win the
  gap and have its file overwritten.
- Windows MoveFile uses MoveFileW (`WindowsPlatformFile.cpp:1042`). A no-replace
  move of a completed staged file is a possible per-file publication building
  block, not a complete provider. The Blueprint result discards the error,
  generic Move may create directories/retry, the plugin is unverified, and it
  supplies neither active binding nor exclusion across A and B. It must not be
  mistaken for a transaction merely because one destination is not replaced.

The archived binding source
`test-results/ue4ss-installed-ref-LuaMod-20260913.cpp` is the repository's
installed-revision reference, identified in
`docs/edit-latency-root-cause-2026-09-29.md`. Its IterateGameDirectories binding
at line 2639 traverses the game tree and uses skip_permission_denied at line
2698. Neither its listing nor its internal filesystem calls provide a retained,
error-preserving initialization transaction to Lua. No such exported helper
was found in this binding source or installed UEHelpers. This is a bounded API
audit, not proof that every possible installed extension lacks additional APIs;
the source-to-current-DLL correspondence was not independently reconstructed.

Existing `tests/test_lua_file_errors.py` demonstrates that Windows Lua 5.4
maps missing leaf and missing parent to the same errno 2. A successful root
check before or after that call cannot make two separate operations atomic.
An FFI DLL, arbitrary memory function call, external PowerShell helper or
package.loadlib shim would introduce a new native mechanism, not establish an
already supported UE4SS capability. None was loaded or invoked in the game.

## New disposable Windows tests

Run `python -m unittest discover -s tests -p test_save_initialization_windows.py -v`.
All seven tests passed on this machine:

1. OPEN_EXISTING distinguishes absent leaf (2) from absent parent (3).
2. An empty file opens successfully; CREATE_NEW refuses it with error 80.
3. A share-denied read returns 32 and leaves the file intact.
4. Write access to a read-only file returns 5 and leaves bytes intact. This is
   attribute-based write denial, not an ACL-denied read test.
5. After missing-leaf observation, a different process creates the file.
   CREATE_NEW refuses it and preserves the external bytes.
6. The same interleaving with CREATE_ALWAYS truncates the external bytes.
7. Holding a directory handle without delete sharing and an exclusive handle
   to newly created A still allows a different process to create B. Neither
   handle reserves the entire absent A/B namespace.

These tests demonstrate the OS boundary and the race, not a shipping provider,
atomic publication, crash durability, ACL traversal denial, reparse safety or
native registry integration. A fresh root string, before/after stat checks,
sentinel file, named mutex or cooperative lock file does not exclude a writer
that ignores that convention.

## Required native contract for V7

Handoff for Fermat: an Engine Blueprint registry/coordinator alone cannot close
this gate. Do not label a V7 load-null outcome missing. The required addition
is a typed native filesystem operation with these semantics, plus a separately
trusted active-storage binding. This document specifies requirements; it does
not assert that an existing implementation satisfies them.

`ObserveSlot(binding, reservation, slot)` must:

- Accept an opaque current binding to process incarnation, world epoch,
  authoritative storage, guild, stream, canonical root and native holder/ticket.
  A Lua table echoing these values is not binding provenance. Active identity
  cannot come from SelectedWorldSaveDirectoryName alone; it remains a separate
  upstream gate even after filesystem mapping is accepted.
- Validate fixed slot grammar and actual root/directory identity with native
  handles. Prevent ancestor/reparse substitution; string normalization alone
  is insufficient. Refuse unresolved mapping, unsupported roots and missing
  parents. A new installation needing a root must use a separate guarded setup
  operation, not silently create parents during an absence check.
- Capture GetLastError immediately from the exact failed OPEN_EXISTING call.
  Only missing leaf in the verified namespace can be an absence observation.
  Preserve missing parent, access/sharing denial and other failures distinctly,
  returning unreadable for recovery. Successful open means present, including
  zero bytes. Read/decode/schema failures do not retroactively mean absent.
- Retain typed scalar results and operation identity until matching consumption.
  An absence observation is not a reusable capability to create later.

`InitializeIfVirgin(binding, reservation, initialRecord)` must combine admission,
exclusion, classification and publication rather than accept an old missing
boolean. It must reject revocation/retirement and serialize the commit boundary
against epoch changes in native state; worker code must not retain Unreal
wrappers. Serialize a bounded immutable record, preserve existing data, check
write/flush/close results, and publish a complete record without replacing an
intervening file. Conflict, unreadable, revoked, failure/uncertain and initialized
must remain distinct. Completion is retained under the exact reservation;
timeout or Lua reload cannot release uncertain ownership.

CREATE_NEW is a necessary possible building block for exclusive creation, but
creating an empty final file and then calling SaveGameToSlot is NOT this
operation. Releasing the handle opens another race; keeping it blocks Engine
reopening; a crash may leave an empty file that must never count as absent.

The current A/B recovery policy initializes only when both slots are absent.
Per-file CREATE_NEW cannot make that pair-wide fact atomic against writers that
do not participate in the registry. Cooperating mod instances need shared
scope-wide serialization; cloud synchronization and manual file changes need
conflict detection and preservation rather than an assumption of cooperation.
A single authoritative atomic initialization/commit object is a viable design
alternative, with corresponding reader and migration semantics. A directory
handle or named mutex alone does not make the existing pair check atomic.
The user's broad implementation authorization includes these technical design
choices; this review imposes no additional approval requirement. This particular
review did not implement them. Protection against arbitrary malicious writers
is not a prerequisite: prioritize prevention of accidental overwrite, preserve
unexpected files, and fail closed on detected or unresolved conflicts.

## Remaining acceptance work

There is no safely shippable provider with the audited APIs alone. Adding a pure
Lua classifier with trusted=true/root_verified=true inputs would only move the
unproven assumptions into booleans, so no such provider was added.

Native work must prove precise OS errors, ACL-denied reads, shared-handle
conflicts, competing-process creates, root/ancestor/reparse replacement,
cross-slot races, interrupted partial publication, flush/close failure and
retirement during pending IO. It must then demonstrate the actual shipped
binding and registry together, not just an editor fixture. Existing foreign,
oversized, unknown-schema and unreadable records must preserve data and prohibit
default initialization. Root mapping remains observed correlation for the
recorded build/configuration; active storage, power-loss durability and
production migration remain independent gates.
