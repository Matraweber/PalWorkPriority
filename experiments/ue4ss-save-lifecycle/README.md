# Lifecycle diagnostic driver (isolated; not deployed)

Prepared for manual installation and the next normal restart. No production Scripts, priorities, caps, native journal, save settings or game controls are modified. The only writes made by this driver are its own arm file and diagnostic log.

Use these files in the isolated mod root, preserving the paths below. The four dependencies come from the repository's top-level `experiments/` directory; they are not duplicated here.

| Mod-relative destination | Repository source |
| --- | --- |
| `Scripts/main.lua` | `experiments/ue4ss-save-lifecycle/Scripts/main.lua` |
| `experiments/save_lifecycle_epoch.lua` | `experiments/save_lifecycle_epoch.lua` |
| `experiments/save_lifecycle_epoch_observer.lua` | `experiments/save_lifecycle_epoch_observer.lua` |
| `experiments/save_world_identity_probe.lua` | `experiments/save_world_identity_probe.lua` |
| `experiments/save_identity_probe.lua` | `experiments/save_identity_probe.lua` |

`SHA256SUMS.txt` fingerprints these five files using their mod-relative destinations. No enabled marker, run file, deployment or game restart has been performed here.

For one-shot activation, the mod root's `run.txt` must contain `PWP_LIFECYCLE <unique-nonce>` followed by an optional newline. The nonce is 1–64 ASCII letters, digits or hyphens. Missing, disabled, malformed, oversized and extra-command input does nothing. Valid input is replaced with `DISABLED` and closed successfully before any dependencies, hooks or timer are initialized. There is only one installation attempt per Lua environment, including a failed partial installation. Rearming is intended for a later normal restart, not hot reload.

Output appends to `<mod root>/lifecycle.log`, with UTC timestamp, nonce and sequence on every line. Hook messages report lifecycle order and epoch without inspecting hook arguments. A one-second game-thread timer uses the **same World.read(engine) + Identity.read(engine) queries as the distinct-world driver**. It logs initial context and changes only, including world names, directory/selection/autosave status, role, loaded flag, ownership status and the Identity probe's current-chain world/instance/manager addresses. Only the last formatted string is retained; no engine wrappers or sample-history table are retained. Hooks perform no world queries. Samples are correlated observations, not atomic lifecycle snapshots or storage proof. New-world selected=nil and loaded=false do not imply a false role.

Every log line states `verified=false storage_grant=false`. The observer has no admission API and no call to epoch authorization. All four engine callbacks return nil, including stop/error paths, so LoadMap is never overridden.

The run stops at 30 minutes on the next timer or hook callback, or after 1,800 timer callbacks even if wall time stalls. A backward clock, callback failure, logging failure or line exhaustion also stops it. The limit is 4,096 line attempts **per armed run**, including a reserved terminal line; the existing log is never truncated. Each message is capped at 8,192 bytes. Stop first makes callbacks inert, then attempts timer cancellation and records whether cancellation succeeded. Retained hooks cannot be unregistered through these APIs; they return nil without further work after stop. If scheduling throws after retaining a callback without returning a handle, it cannot be physically cancelled, but the callback is inert. Failed cancellation is reported rather than called successful. A stalled game thread cannot execute a deadline or cancellation until it runs again.

## Offline checks (2026-10-04)

- Actual driver entry point: **48 fixtures passed**, loading the real observer, epoch and property-probe modules. Covered actual arm parsing/no-arm/error paths, consume-before-register, repeat loads, four missing/throwing/false registrars, explicit nil hook returns, unchanged/changed samples, new B and reloaded B, owner mismatch, wrapper garbage collection, timer/setup/log/query/clock errors, late handle cancellation, cancellation failure, 30-minute timeout, tick bound and line bound.
- Epoch and Identity regressions passed.
- Explicit Lua 5.4 compilation passed for main, its four dependencies and both lifecycle tests (7 files). The standard test runner also compiled 51 production modules read-only with zero syntax failures.
- Follow-up fixture repair: `test_save_world_identity_probe.lua` and the older World/Identity driver tests lacked the current collector's `GetAddress`/`GetOuter` methods. Their mocks now explicitly implement those methods; strict forbidden-access assertions remain intact. The World-probe regression also checks 26 invalid owner/address/chain cases, asserting that all three context addresses stay absent even when selected/loaded observations remain available. All 10 relevant World, Identity, headless, provider, authorization and lifecycle regression scripts pass. Collector and driver source behavior is unchanged.

Target command: `python tools/test_lua.py tests/test_save_lifecycle_driver.lua tests/test_save_lifecycle_epoch.lua tests/test_save_identity_probe.lua`

Mocks do not prove hook availability/order, native cancellation success or coverage of every travel mode. Live callback correlation awaits the user's manual installation and normal restart.

User-reported live context: B's normal reload now has selected+loaded=true and passed phase 3, confirming its difference from first-entry new-world gameplay. Original A returned ready, phase 5 completed at **13:42:58 UTC**, and stand numbers were verified at **13:44 UTC** on 2026-10-04. These are user observations, not results from this uninstalled driver.
