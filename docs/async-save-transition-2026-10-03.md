# Same-process identity transition probe — October 3, 2026

Separate, read-only experiment; production persistence remains unchanged.
The preceding two-host-boot experiment could not test game-instance state that
survives a return to title. This driver stays active for up to ten minutes,
records a ten-second first MainWorld5 visit, requires an observed Title boundary,
and records a ten-second second MainWorld5 visit before cancelling itself.
Only strings/booleans survive callbacks. The startup arm is consumed first.

This is an observation protocol, not an identity verifier. Host/client roles
must be established independently from the same process's production log and
RAM handshake; repeated map names are insufficient. Unchanged source/installed
hashes, one continuous process lifetime and both runtime session boundaries are
required evidence. The probe never binds a save slot or changes permissions.

## Pre-install checks

All 92 Lua regression scripts pass. The new fixture exercises Title ordering,
single-visit rejection, both dwell resets, disarm failure, timeout at 600 seconds
and cancellation failure. Review found throwing cancellation could trigger a
second shutdown attempt; shutdown is now idempotent and cancellation protected.
Installed only the new driver and unchanged read-only probe after hash checks;
no pak or production module was replaced.

## Evidence

Completed in process 18604, started 19:41:41 local time, with identical process
identity before and after. Evidence: `test-results/save-transition-20261003/`
(`acceptance.json`, process snapshots, installation receipt and captured logs).

| UTC | Observation | Selected local ID | Loaded-world flag |
|---|---|---|---|
| 17:42:32 | First stable singleplayer visit | 31141b9948fe8b9a8b4cc399974dddf1 | true |
| 17:43:29 | Title boundary | same ID | false |
| 17:45:11 | Second stable visit, RAM client | same ID | false |

Production evidence independently establishes positive-session host authority
before Title and client role, ready synchronization and the expected RAM guild
after joining. The driver completed both ten-second dwells and cancelled its
timer successfully. Its startup arm is disabled; production Lua hashes match
the pre-install receipt. No save slot was bound or written by this experiment.

**Finding:** the selected local-save ID survives a same-process join to a remote
server. Format validity and matching an existing local save directory cannot
establish the current storage identity. The future async writer must require
current-session authority/readiness evidence; this probe always returns
`verified=false`. This is an experimental integration hazard, not a demonstrated
production persistence regression.

Independent review confirmed the evidence and added the same-instance
host -> Title -> client regression to `tests/test_save_identity_probe.lua`.
The selected ID stays constant while loaded changes true -> false -> false;
no stage may expose verified identity, storage, key or readiness. After this
addition, all 92 regression scripts pass and 51 production modules compile
under Lua 5.4. The driver also covers throwing cancellation without repeat
shutdown or later callback activity.

## Reverse observation and controller gate

A second run restarted normally into RAM, then returned through Title to the
existing local save without restarting again. Process39980 and its start time
match in the before/after snapshots. Evidence:
`test-results/save-transition-reverse-20261003/`.

| UTC | Observation | Selected ID | Loaded-world flag |
|---|---|---|---|
| 18:39:20 | Stable RAM client | empty | false |
| 18:40:19 | Title after leaving RAM | empty | false |
| 18:40:50 | Local save selected, still Title | local31141... | false |
| 18:41:04 | Stable local gameplay | local31141... | true |

The restart macro verified RAM guild and process identity; production logs
independently show client refusal before leaving and session3 authority/settings
available after returning to singleplayer. The probe completed and cancelled;
all experimental arms are disabled and production source hashes are unchanged.
This establishes the reverse direction for one existing save, not general
storage identity or the new controller's native integration.
Independent review confirmed the direction, same-process identity and role
evidence. Hash/control checks were performed by the main collector against live
files; the reviewer did not independently repeat those filesystem checks.

`experiments/save_session.lua` now requires fresh authorization from its trusted
integration callback at admission and delivery boundaries. Missing/throwing or
non-true evidence denies new work. Lost authority permanently retires the
incarnation, suppresses recovery/ACK delivery, and drains accepted data only to
its original owner. All92 Lua scripts pass; independent code review found only
a missing-callback test setup error, corrected and retested. The actual native
evidence provider remains to be implemented; production does not use this gate.

## Remaining limits

Both directions were observed in separate process runs. One save does not establish
different-save discrimination or copied-world policy. No native dedicated-server
identity has yet been proven. Save-absence classification, migration and native
singleton enforcement remain required before production async integration.
