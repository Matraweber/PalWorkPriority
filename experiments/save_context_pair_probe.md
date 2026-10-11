# Same-callback context-pair diagnostic

Standalone experiment; no installed/live driver changes, discovery, authorization, file IO, scheduling or activation.

## Actual collector contracts

| Collector | Route and checks | What it does not establish |
| --- | --- | --- |
| `save_headless_identity_probe.read(engine, get_state, get_instance)` | `engine.GameInstance` → injected GameplayStatics `GetGameState(instance)`; checks `GetGameInstance(state)`, `state:GetLevel().OwningWorld`, world's instance and state; re-reads engine instance/current state. Returns world/state/instance addresses on contextual agreement. | Its “headless” name does not require a dedicated server or prove the supplied engine is active. No viewport comparison, manager ownership or active-storage proof. |
| `save_world_identity_probe.read(engine)` | `engine.GameViewport.World.GameState`; reads map name, directory, role and dedicated flag. | No world/state/instance addresses or ownership fence. Matching names and fields alone cannot associate it with the headless state. |
| `save_identity_probe.read(engine)` | `engine.GameViewport.World.OwningGameInstance.SaveGameManager`; checks manager outer and re-reads the current world/instance/manager chain. Returns those three addresses only on agreement. | No GameState address. Selection and loaded flags are diagnostic observations, not storage proof. |
| `save_active_provider` evidence contract | Requires contextual headless state with valid world/state/instance integer addresses; Identity world/instance addresses must match. It separately checks fresh lifecycle epoch, authority, guild, local-host role, selection, loaded state and an external active-storage verifier. | These conditions cannot be supplied by renaming or promoting the simpler World output. A candidate still is not authorization. |

## New standalone API

`Pair.read(engine, get_state, get_instance)` composes the three unchanged readers. Caller supplies one freshly resolved GameEngine and read-only GameplayStatics callables and executes the entire call synchronously on the game thread. There are no injected fake reader results or cached wrappers in the implementation.

The sequence is: capture viewport-chain scalar addresses → Headless.read → World.read → Identity.read → recapture viewport-chain addresses. The independent bracket covers world, GameState, instance, manager and engine-root instance. All addresses must be positive Lua integers, stable across the bracket and consistent with the applicable collector outputs. World names, directories, roles and dedicated flags must agree between the applicable readers; required fields must be readable and valid. The successful path calls Headless once (two current-state queries and one state-owner query), World once and Identity once (one manager-owner query).

Output is a flat table containing **only bounded scalar values**. `status='context_agrees'` and `agrees=true` mean these observed routes agree within this callback. Success includes `world`, `directory`, `role`, `dedicated`, world/state/instance/manager addresses, and prefixed `identity_*` selection/autosave/loaded observations. Every result has `verified=false`, `active=false`, `storage_grant=false`; there is no ready flag, scope, key, epoch or authority assertion. It is deliberately not the active provider's nested evidence envelope.

Missing required context, unreadable getters/addresses, rejected ownership, changed chains or conflicting route fields return `agrees=false`, a fixed reason, and **no combined addresses, directory or world name**. Exceptions are reduced to a fixed status; raw engine error strings and wrappers never escape. The probe keeps no history between reads.

Selection and loaded data are separate from contextual ownership. Known new-world `selected=nil, loaded_world=false`, unreadable loaded state, or a client's stale local selection cannot grant readiness; they also do not by themselves falsify a successfully checked object chain. They remain explicitly prefixed diagnostics. Consumers must never use `agrees` as an authorization result. Roles 0–3 and dedicated true/false are compared as reported, not converted to host authority.

This bracket is not an atomic engine snapshot, an engine-discovery guarantee or a substitute for lifecycle epochs. An unobserved change-and-return between reads, pointer reuse, asynchronous ordering and supported travel routes still require live evidence and lifecycle coverage. This local viewport comparison intentionally cannot establish agreement when a dedicated/headless process has no viewport. No native call can be preempted by this synchronous probe.

## Offline validation

`tests/test_save_context_pair_probe.lua` uses full strict engine-wrapper mocks with the **actual three collectors**, not injected scalar successes. It covers matching routes, new-world absence of selection, reload/client flags, same-name foreign roots, native-address wrapper aliases, invalid/missing/throwing context, wrong manager/state ownership, root/world/state/instance/manager changes, field/name mismatches, fresh outputs, and wrapper garbage collection. Forbidden-access, write, enumeration and stringification assertions stay enabled.

Command: `python tools/test_lua.py tests/test_save_context_pair_probe.lua tests/test_save_headless_identity_probe.lua tests/test_save_world_identity_probe.lua tests/test_save_identity_probe.lua tests/test_save_active_provider.lua tests/test_save_authorization.lua`

Integration with a future optional lifecycle-driver sample is deferred. The current installed-driver source and its five-file fingerprint manifest remain unchanged.
