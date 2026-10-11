# Dedicated identity observation

Diagnostic only: no writer DLL, save operations, production integration or
storage authorization. All outputs have `verified=false`, `active=false`, and
`storage_grant=false`. A matching root or context does not change this.

The installer is restricted to the manual runtime at
`C:/Program Files (x86)/Steam/steamapps/common/PalServer/Pal/Binaries/Win64/ue4ss`,
runtime SHA256 `21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8`,
and the active disposable `server-identity-20261009` fixture receipts. Both client
and server must be stopped. It reads only the configured `DedicatedServerName`
from GameUserSettings.ini, then checks that exact world's Level.sav exists.
It never enumerates saves to choose a world, copies the INI, or emits credentials.

Review commands (not executed as part of implementation):

```powershell
python -B tools/install_dedicated_identity_observer.py --runtime-root 'C:/Program Files (x86)/Steam/steamapps/common/PalServer/Pal/Binaries/Win64/ue4ss'
# After review, same command plus --install stages and arms; never launches.
```

The isolated mod is `PWPDedicatedIdentityObserver`. Installation is one-shot:
existing package/receipt refuses overwrite. Partial failures leave the package
disabled; investigate rather than automatically retrying or deleting evidence.
Only Lua/config files are copied. `enabled.txt` is created last. The runtime
consumes `Scripts/run.txt` before scheduling and writes only its `identity.log`.

Each sample resolves wrappers afresh on the game thread. Actual headless reads
bracket manager ownership and Saved-root observation. The dedicated wrapper then
rechecks state ownership, state-to-level-to-world identity, world ownership,
manager ownership/identity and the loaded flag before publishing. These ordered
reads are not an atomic engine snapshot or protection against unobserved ABA.
The runner uses a 1-second
interval, at most 60 samples/60 wall seconds, and stops after 10 seconds of stable
observations. A callback over 100ms ends sampling after return; native calls cannot
be preempted. Cancellation failure is recorded and callbacks remain inert.

`project_saved` is the bounded raw engine string. Relative paths, including
`../../../Pal/Saved`, remain `relative_unresolved`. No tool/launcher working
directory is used to resolve them. `expected_root_matches` is a text comparison
for supported absolute paths only, never canonical filesystem/storage proof.
Addresses are ephemeral observations, never persistent identities. No viewport
or local selected-save fallback is read.

Acceptance requires process-bound installation/source hashes, the matching
configured directory, dedicated role/context and manager observations, bounded
sample/cancellation evidence, and preserved fixture/restoration receipts.
This does not prove active-storage binding, guild/Pal ownership, native writer
exclusion, recovery, lifecycle safety or permission to enable async writes.

Offline validation:

```powershell
python -B -m unittest tests.test_dedicated_identity_installer -v
python tools/test_lua.py tests/test_dedicated_identity.lua tests/test_save_headless_identity_probe.lua
```

Installer tests use temporary trees with mocked process checks, never the real
runtime. Existing headless probe source is reused unchanged.
