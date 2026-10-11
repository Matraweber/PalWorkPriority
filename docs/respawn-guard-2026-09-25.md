# Respawn ownership guard — September 25, 2026

Review of ClientRestart found a concrete unknown-owner defect: when a local
controller exists but reading the hook context throws, `same` remained nil and
the callback reset the local session. Two unreadable names could also compare
equal. A foreign or unidentified event could therefore discard queued edits and
clear writer roles on a listen host.

The guard now requires two nonempty string names and positive equality within
the current callback. No controller wrapper is stored across callbacks. The
existing no-local-controller branch is unchanged; this is not a new identity
or world-transition detector.

Regression evidence in tests/test_main_integration.lua:

- The old implementation failed on a throwing context: it advanced the session.
- Foreign, throwing, nil-owner, nil-name and empty-name observations preserve
  the session, writers and queued local action, including both names absent.
- A positively identified local event advances the session, invalidates old
  queued work, clears writer decisions and retains recurring work.
- The clock fixture now matches real clock.reset: recurring entries survive,
  deferred work is cleared. Its former removal of timers was a fixture defect.

All 49 Lua modules compiled, all 67 regression scripts passed, and the structural
checker passed (panel remains at 194 top-level locals). Independent review
found no blocker and independently passed the integration test.

## Native evidence and limits

Read-only perf/status at 01:37:52 reports a 17829-second window, one
`hook: complete spawn` call, healthy heartbeat, local authority, saved settings,
and complete cached storage data. Timing is OFF: these are counts, not measured
durations. The emergency respawn from September 24 produced no second world-key
marker. Do not call that test proof of ClientRestart/session invalidation.

The character remains at the five-Pal base near its Palbox. Brief movement inputs
did not establish a usable stand interaction; post-respawn stand reopening and
death while editing are still unverified. Do not run the stand-facing restart
macro from this position. No native respawn was repeated in this follow-up.

This guard needs a restart to load. Native callback identity/dispatch, interrupted
editing across an actual respawn, and populated multiplayer remain release gates.

Checked deployment completed at 01:38:29, with previous code/configuration in
`backups/deploy-20260925-013829-d9c00833ca3843d7af5f600105518a2a` under the
installed mod. The running game has not restarted onto this change.

Subsequent native acceptance at 02:58–03:00: normal AHK quit/relaunch replaced
PID2964 with PID31424. The new process logged world-key resolution at02:59:40
and PWP_READY session=1 role=authority at02:59:44. All nine stand rows and their
numbers returned visibly. This verifies initial local session admission with the
guard loaded, not an emergency-respawn hook on an already-running world.
