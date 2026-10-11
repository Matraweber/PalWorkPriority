# Offline reliability fixes - September 23

Later live continuation: [monitor migration and native retest](monitor-retest-2026-09-23.md). The original offline work below did not run the game; the later authorized test did. Native panel cancellation and automated hit-testing still have open findings.

Source remains unpublished 0.5.0-rc1. The user paused native tests; this work changes repository source/tests only. No deployment, restart, game interaction, remote trigger or frame capture was performed. Previous native results do not test these changes.

## Timed-out multiplayer edits

A priority or production-limit edit could time out, correctly show connecting, then become ready after an unrelated full snapshot. The affected stream still held old data, allowing another edit against stale state. On timeout the client now invalidates the affected stream and requires its full snapshot; an unrelated stream or late acknowledgement cannot restore readiness. Existing identity, guild and sender checks are unchanged.

`tests/test_net_commit_errors.lua` covers priorities and limits, with and without acknowledgements, unrelated full snapshots, late acknowledgements/deltas, edit refusal while uncertain, and recovery on the affected full snapshot. The regression was independently reproduced against the pre-fix logic in an isolated Lua runtime without replacing any source/game files (`test-results/net-timeout-before-20260923.txt`). This is simulated packet behavior, not a populated-server test.

## Explicit control requests and panel opening

The development channel previously converted desired open/close states to deferred toggles and logged completion before execution. It now holds one session-bound desired state and executes it on the existing game-thread drain. Repeated open requests do not close the panel. Combined open/screen requests are applied together; a screen change cannot disappear behind an opening-generation change. An explicit matching-state request invalidates older queued UI input, and repeated closes retry failed native cleanup. Only the completed state is reported; failure to open or detach is reported as failure. Console dispatch no longer claims successful execution when its adapter throws/returns false, and pending commands from another session are cancelled.

The panel's synchronous control entry point is for an already-running game-thread callback; it does not establish permission to call native widgets from arbitrary threads. Normal UI actions keep their existing game-thread queue. Failed or throwing overlay creation now closes the local panel state and invalidates abandoned edits rather than leaving a phantom open panel.

`tests/test_remote_control.lua` uses the real panel/remote Lua modules with synthetic file reads, engine objects and queued callbacks. It covers startup replay prevention, duplicate/opposing desired states, session changes, creation failure, retry, detach failure, invalid/combined mode requests, native Cancel precedence, console failure, incomplete-close retry and older queued toggles. The old completion log fails before correction (`test-results/remote-control-before-20260923.txt`). A second pre-fix assertion reproduced the phantom-panel state on a thrown creation error. Independent review found the retry/older-toggle defects; their before-fix failures are recorded in `remote-retry-before-20260923.txt` and `remote-queued-toggle-before-20260923.txt`.

## Verification and limits

All 44 modules compile under Lua 5.4; all 59 Lua regression scripts and 120 Python fixture tests pass, and the structural checker passes. Offline compile/regression/checker receipts are under `test-results/offline-reliability-*-20260923.txt`. Native keyboard focus, action consumption, widget lifetime and frame timing are unverified by these tests. September 16's [action-router candidate](native-escape-2026-09-16.md) remains pending native acceptance and has not been promoted into `docs/asset-contract.json`.

Next live checks: fresh fingerprints and checked install/restart, native cancellation matrix, explicit panel request receipts, then delayed/missing multiplayer acknowledgements with independently observed server state. Scheduling assignment/output, item-specific limits and performance acceptance remain open.
