# Installed-state binding and marker-only rehearsal — October 11

This step connects the tested transaction lock and startup fence to the actual
fixed client installation. It does not perform data cutover, retire the async
launcher, modify journals, or enable async saving for other installations.

`settings_installation_binding.py` reuses the real Lua recovery and membership
analyzers, pins the reviewed bundle, native membership log, installation receipt,
runtime and guard main, and compares the installed protected file inventory with
the reviewed receipt. It also binds current root/file identities and checks both
complete legacy recovery sets, all four journal paths and both trial paths.
Manifest/receipt paths are compared, never followed to choose mutation targets.
Fresh captures are repeated with process checks around them.

Only three exact root paths are excluded from the inventory: `priority.log`,
the explicitly expected `.settings-cutover` marker, and the empty, regular,
single-link `.settings-cutover.lock` artifact. Nested files with those names are
not blanket exclusions. The lock is checked through metadata so a coordinator
can recheck the binding while holding its share-zero handle.

`settings_installation_fence.py` defaults to read-only preflight. Its explicit
`--rehearse` operation takes the fixed installation lock, checks the binding,
persists intent outside the installation, and exclusively creates a unique
startup marker. It checks process absence again **after** creation and verifies
the unchanged binding. Before removal it repeats those checks and requires the
exact marker bytes. It never changes settings or launcher files.

If a process starts before the post-fence check, the operation stops and retains
the marker. A process starting after a correctly installed guard sees the
marker cannot load settings. Explicit `--recover` handles only the exact
marker-only rehearsal intent after process/source checks pass. Unknown, partial
or foreign markers remain untouched. If completion recording fails after marker
removal, evidence is incomplete; recovery does not recreate the marker.

## Limits before actual cutover

The original lock excludes cooperating migration drivers, not arbitrary file writers.
Existing deployment tools and Steam updates do not participate in this lock.
Hash checks detect code changes but do not continuously deny third-party writes
between checks. Actual settings replacement needs that remaining deployment/code
race addressed, along with the applicable fresh session and migration evidence.
The follow-up below adds protection for existing files, but does not exclude
new names or authorize replacement of player data.

The retained native membership observation belongs to its recorded session. It
does not become a fresh authority grant or complete historical deletion coverage
merely because its bytes still verify. All binding replacement, activation and
ownership grants remain false. This marker rehearsal must not be described as
successful live data migration or native async-writer durability acceptance.


## Actual installed rehearsal result

Evidence: `test-results/installation-fence-rehearsal-ee617305021f456681bde48f571f9aa2/`.
The final read-only preflight passed against the pinned inventory. The marker-only
operation then completed on the fixed D: client installation under the OS lock.
A separate Python process attempted the same installation lock during the active
rehearsal and was refused with Windows sharing error 32. No settings operation
ran in that competing process.

All binding checks completed before removal of the exact owned startup marker.
Post-run readback matches all eight legacy entries, four journal entries and both
trial entries. The startup marker is absent. The persistent regular single-link
lock file remains empty by design. Client and server processes are stopped. No
game was launched and no settings/launcher/journal bytes were changed.

The two new test modules pass all 23 regressions (51.522s), including real Win32
installation-lock behavior, pre-capture dependency tampering, process-start
races, foreign/partial markers, changed settings and interrupted completion.
Source hashes and test provenance are saved in validation.json. The earlier
native rollback results remain separate evidence; this run did not repeat them.

Independent post-rehearsal review passed: one full binding recheck confirmed
all 4,152 protected files plus the exact settings/journal/trial states, absent
marker, empty regular lock file, and matching intent/completion evidence.
No contradictions found; this remains a marker-only result.

## Follow-up: existing-file write exclusion

`settings_inventory_pins.py` now opens each reviewed existing file for read with
only read sharing, checks its opened Windows identity and SHA256, and holds the
handle through the rehearsal. Directory and ancestor handles deny deletion and
rename. Writable handles already held by another process cause acquisition to
fail. Handles are non-inheritable; partial acquisition unwinds, and uncertain
release quarantines the remaining handles until process exit.

The fixed installation factory takes the transaction lock, reconstructs the
binding using fixed paths, and acquires these pins for the full reviewed mod
inventory plus UE4SS.dll. The first complete cycle check happens under all pins,
before the marker is changed. Rechecks and exact marker ownership checks remain.
The marker and empty transaction lock are deliberately outside this inventory.

Nine real Win32 pin tests passed (0.322s), plus fourteen marker/integration tests
(10.509s). Coverage includes actual competing writes/deletes/replacements,
pre-existing writers, readonly binding checks, directory rename refusal,
identity/hash mismatch and uncertain cleanup. A new child file deliberately
created under held pins is detected by the final binding recheck, which retains
the startup marker. Recovery refuses until that test-owned child is removed.

This is **existing-file exclusion, not namespace exclusion**. New children,
missing recovery-file names, external journals, other runtime files and other
mods are not all locked by these handles. Full inventory checks detect relevant
drift at their check points; they do not turn the interval after the last check
into an atomic namespace transaction. No ACL changes or blanket deployment
exclusion are claimed. Payload writes would also conflict with this rehearsal's
own pins and require a separately reviewed transaction design.

Windows sharing semantics are documented in
[Microsoft's CreateFileW reference](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew).
Tests establish the specific behavior used here on this machine.

### Protected installed rehearsal result

Evidence: `test-results/installation-fence-rehearsal-0d44ee402a6b4f6291bf1c5c2583cd70/`.
The reviewed script completed with exit 0. A separate Python process requested
write and delete access to four existing files (guard main, store module,
priorities and UE4SS.dll), using OPEN_EXISTING only. All eight requests failed
with Windows sharing error 32. The child never attempted a write, truncate,
rename or delete, including on the hypothetical unexpected-success branch.

All 4,152 protected mod files and the runtime were held and verified. Full
post-run binding reconstruction matched the pre-run digest
`70c1fcb68893a41156cdd2511dee77512c1841a955c8a834b6cbf3c43ef15d17`,
including all legacy recovery, journal and trial entries. The owned marker is
absent and both game families are stopped. No game launched, settings changed
or trial retired. Public/default async remains OFF. Counts, source hashes and
test provenance are in validation.json; raw focused test output is in tool
results rather than a saved text log.
