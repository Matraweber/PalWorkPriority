# Controller cancellation and truthful connection status

Local 0.5.0-rc1 candidate; unpublished. These changes do not close the full UI, controller or multiplayer release gates.

## Defects and changes

- The panel's controller Cancel action used `toggle()`, closing the entire panel even while editing a limit. It now uses the same cancel-edit-first action as Escape. A subsequent fresh Cancel closes the panel without saving.
- `pad.drive` dispatched navigation/Confirm before Cancel. Simultaneous Confirm and Cancel could commit a value the player meant to discard. Cancel now takes precedence over all other actions in that sample.
- After cancellation, only buttons actually observed down require proof of release. Held buttons cannot commit, remove, switch tabs, or repeat Cancel against the screen underneath the editor. The release barrier survives a UI reset. Unknown readings of held buttons preserve the barrier; unsupported unrelated buttons do not trap input. Only boolean native readings count as known states.
- The status command previously printed the client's `net.status` for a host too. Confirmed authority now reports `not required; local authority`. Clients retain their actual connection state; undecided roles and stale sessions remain unknown. This is diagnostic wording, not a networking behavior change or proof of healthy downstream clients.

## Automated evidence

Both controller tests failed before the fix (`panel-cancel-before-20260915.txt`). The independent reviewer found successful nil/native non-boolean readings were still converted to release; the added regression failed before that correction (`panel-cancel-review-before-20260915.txt`). After correction, all 44 modules compile under Lua 5.4 and all 58 regression scripts pass. The structural checker passes too. Receipts are under `test-results/panel-cancel-*20260915.*`.

Controller cases include edit cancellation without a write, second-press close, simultaneous Confirm/Cancel/Remove/tab input, long holds, staggered releases, unknown readings, reset during a hold, unsupported keys and fresh actions after release. Stand navigation with no bound Cancel action remains available. These are actual Lua adapter tests, not physical controller or Steam Deck acceptance.

The synchronization tests execute real command dispatch and protocol parsing: authority, incomplete/complete client snapshots, incompatible handshake, reconnection, unknown role and session replacement. The three test groups failed before the diagnostic change and pass afterward.

## Native baseline and outstanding Escape issue

On PID44368, game 1.0.5.102999, opened Production Limits over the Monitoring Stand and opened the existing Wood amount editor (30000). At 23:51:02, Escape cancelled the editor (`editing=no`, panel still open), but also closed the underlying Monitoring Stand. No value was committed. This reproduces the separate key-consumption defect; it is **not fixed by the controller change**. The misleading source comment claiming the raw Escape binding prevented menu overlap has been corrected.

The Lua raw key observer cannot by itself establish that Palworld consumed the key. A future fix needs a verified native input-consumption path, with editor, keyboard, controller and vanilla-menu acceptance; switching blindly to UI-only previously prevented controller/keyboard reads. Do not replace this open gate with an assertion that a non-throwing close is safe.

## Installation and restart

Checked deployment at 23:53:13 retained the preceding code/configuration in `backups/deploy-20260915-235313-28a26f788edb4a378ad03d8dbb202140` beneath the installed mod. All 44 source/install hashes match (`panel-cancel-hashes-20260915.json`).

The existing checked AHK restart ran at 23:54:21, replacing PID44368 with PID48408 (started 23:54:40). The candidate banner appeared at 23:54:46, world key at 23:55:04 and session-1 authority/settings-ready at 23:55:08. The AHK process finished; native inspection showed the Monitoring Stand open with all nine rows and saved numeric/X values. No changes were made to saved priorities or limits by the cancellation test.

At 23:55:29 the real status command reported `synchronization: not required; local authority`, priorities/limits saved, and the panel closed with no edit. Receipt: `test-results/panel-cancel-native-status-20260915.txt`; session excerpt: `panel-cancel-session-20260915.log`. There were no WARN/ERROR/Traceback lines in the checked restart excerpt. Profiling remains off, and no frame recording was made for this change.

This proves the installed build loads and the diagnostic is correct in this singleplayer session. Physical controller/Deck cancellation, populated multiplayer and native key consumption remain unaccepted. The unchanged scheduler still reports 14 unverified assignments and three unverified workers above the staffing limit; this work does not resolve those gameplay evidence gaps.
