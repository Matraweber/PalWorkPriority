# Async save lifetime gate — October 3, 2026

The V4 experiment replaces the world-owned Actor with a rooted transient UObject.
It is a local synthetic diagnostic, not the scoped production save backend.
Production settings and the RAM server installation are unchanged.

## Native implementation and proof

`BP_ScratchBridgeV4` lives in the transient package with an explicit root. It
retains its current async action through a reflected property. The generated
graph constructs the action, retains it, binds completion, then activates it.
Completion publishes state and clears the action and world-context references.
The live diagnostic leaves its single root in place until process exit; an
uncertain operation must never permit a replacement coordinator.

Native fixtures deliberately tear down the owning test world/game instance
while work is pending and collect garbage again after save completion starts
readback, before readback completion. Weak references verify the old world and
instance were actually collected and the pending read action survived through
the bridge's reflected reference. A separate synchronous failure verifies that
the completed action reference is cleared even when completion is inline.

Build, verify, fresh asset reload, restart, cook, and package-list checks pass.
Evidence: `test-results/save-scratch-v4/manifest.json`, including source and asset
hashes. Package SHA256:
`a84890b15a5abb3066005e1b78371eeccdee1db1bea2ba7ffe92ae186fcf5e75`.
The package contains the shared record and V4 bridge assets only; no new runtime
DLL. V2/V3 assets and their existing diagnostic slots remain separate.

Two initial implementations were rejected during verification: an exposed proxy
pin depended on temporary editor metadata and failed a fresh asset reload; a
timing-dependent GC checkpoint did not prove readback retention. The final
ordinary Blueprint nodes and deterministic delegate observer replace both.
Failed evidence remains preserved rather than being counted as a pass.

## Live installation protocol

The separate `PWPAsyncSaveLifetimeV4` UE4SS mod consumes its one-shot arm before
scheduling anything. It runs the real Lua session/transport suites in UE4SS
(their native backend is still a fixture), then writes and exactly reads back
a 64 KiB synthetic payload in `PWP_SaveLifetime_v4_B`. It refuses duplicates,
wrong owners, lost roots, mismatched results, and timeout without recreating an
uncertain operation. It then observes a same-process world transition and checks
the retained record and operation state again. No actual priority is edited.

Installation checks all native build hashes, copies and verifies the diagnostic,
and compares every production Lua hash before/after. Receipts and raw logs live
under `test-results/save-lifetime-live-20261003/`.

The first live attempt failed before object construction because the driver
called a nonexistent global `GetEngine`. It disarmed and cancelled its timer
without writing. The corrected driver uses `require('UEHelpers').GetEngine()`;
the mock now exposes that actual module API. All 86 Lua regression scripts pass.
The failed driver/log and checked retry receipt are retained. A second attempt
exposed the one-string `StaticFindObject` overload rejecting a package-only name,
also before construction or IO. The driver now obtains the engine's outer and
requires exactly `Package /Engine/Transient`; a world-owned outer is rejected.
This follows the engine construction in UE5.1 `LaunchEngineLoop.cpp` and the
documented UE4SS `GetOuter` API. Independent source review confirmed this route.

The third attempt (09:22:58 UTC) completed the native 64 KiB write/readback and
survived splash-to-login travel at 09:23:02. That initially satisfied an overly
broad first-world-change check. The driver now requires the observed gameplay
world `MainWorld_5/PL_MainWorld5`; a regression rejects early login completion.
The final gameplay retry passed:

| UTC time | Evidence |
| --- | --- |
| 09:25:22 | One-shot arm consumed in new process 3464 |
| 09:25:23 | Both Lua 5.4 session/transport suites pass inside UE4SS; 65,536-byte native write admitted |
| 09:25:24 | Exact native write/readback and separate read pass; completed action reference cleared |
| 09:26:07 | Root, exact record and terminal ticket survive into `PL_MainWorld5`; timer cancelled |
| 09:26:42 | Server macro verifies expected RAM guild handshake and opens the stand |

Final diagnostic control reads `DISABLED`. Installed driver SHA256:
`11d11892ad324a553a3d92f2d0d462ccecf64cb0863c908565618a705a7ffe98`.
Every production Lua file still matches the original installation receipt.
All 86 final Lua regression scripts pass; 51 production modules compile.
The stand was visually verified open with priority numbers after the final join.
Independent review of the final evidence found no mismatch within this scope.

The production log contains its expected dedicated-client authority warning,
not a local authority failure. UE4SS also reports boot-time ConsoleManagerSingleton
scan ambiguity and a Tick vtable/scan mismatch; these are not silently counted as
a clean runtime-wide log. No diagnostic failure occurs in the final trial.
Raw final logs and `acceptance.json` are in the evidence directory above.

## Scope of the result and next work

Native pending-teardown/GC coverage and live completed-IO travel are different
tests. Neither proves arbitrary process termination, filesystem failure,
production migration, or frame-time improvement. V4 clock fields are deliberately
unmeasured; no `0 ms` performance claim is valid. Expected native null-context
warnings from deliberately destroyed worlds are not a warning-free result.

The next native contract must bind verified storage/guild/stream identity once,
enforce a single owner and monotonic tickets across Lua reloads, and retain a
terminal mailbox until an exact, idempotent consume acknowledgement. V4 alone
does not provide those guarantees and must not be supplied to
`save_transport.lua` as a compatible scoped backend. Missing versus unreadable
storage, migration/backups, larger payloads and truthful network durability ACKs
remain separate acceptance gates before real settings switch to async IO.
