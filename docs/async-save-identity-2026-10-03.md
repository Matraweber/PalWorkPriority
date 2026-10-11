# Save identity and recovery boundary — October 3, 2026

Production persistence is unchanged. These are isolated experiments.

## Read classification

`experiments/save_read.lua` accepts a copied, schema-labelled snapshot. Unknown
schema, failed field reads, null loads and foreign scope are unreadable. Only
bounded scalar fields are copied. Malformed same-scope records are invalid;
checksum content remains checked by the queue. There is deliberately no missing
classification from V6's boolean/native-null outcomes.

The Lua integration regression feeds a failed native read to the recovery queue
and proves submitting fresh defaults remains prohibited, with zero writes.
This does not implement a real native classifier or prove access-denied behavior
on the installed runtime. The helper is not yet connected to the V6 backend.

The local UE 5.1 engine source explains the constraint: GameplayStatics returns
false when the save system is absent; FGenericSaveGameSystem maps negative
FileSize to DoesNotExist. Windows FileSize collapses failed metadata queries to
-1, without preserving why they failed. A failed existence check therefore
cannot authorize replacement. This source evidence does not identify the actual
Palworld platform save implementation without further runtime verification.

## Identity probe

`experiments/save_identity_probe.lua` reads fresh viewport/world/game-instance
and save-manager properties within each callback. The SDK declares
SelectedWorldSaveDirectoryName, AutoSaveWorldDefaultName and
bIsLoadedWorldSaveData. The kit C++ implementations are stubs, so getters are
not invoked and their runtime semantics are not assumed.

The probe distinguishes unavailable, read_failed, empty, malformed, zero GUID
and format-valid candidates. Matching candidates are still verified=false;
there is no writable storage/key/ready output. Raw malformed values, user-facing
world names, passwords and whole-object dumps are not logged.

The one-shot driver disarms before scheduling, records changed observations,
waits ten seconds in the exact RAM gameplay world and cancels itself. A title
or intermediate login world cannot complete the trial. Timeout also cancels.
All 91 Lua regression scripts pass, including driver failure/timeout/cancellation
and native-read refusal tests. Independent review improvements to conversion
and loaded-state failure reporting were applied before installation.

## Live evidence

Completed October 3, 13:06-13:07 Europe/Berlin. Evidence is retained at
`test-results/save-identity-20261003/` (installation hashes, 91-suite test log,
identity log, UE4SS log, restart transcript and acceptance receipt).

Splash, Login, Title and MainWorld5 all reported both candidate strings empty
and loaded-world=false. These were successful reads, not unreadable fields.
No format-valid identity appeared. The observed client route therefore cannot
supply RAM's authoritative save identity; neither host behavior nor an alternate
server route is established by this result.

The driver stayed in MainWorld5 for ten seconds, reported the final observation,
cancelled its timer and remained verified=false. The macro subsequently verified
the RAM guild handshake, and a fresh screenshot showed the stand open with
priority numbers. All four experiment controls are DISABLED. Source/destination
hashes match and all production Lua files match their preinstallation hashes.
The checked local installation contains only the driver and probe, no pak and
no production edits. Client observations cannot establish server storage identity.

## Authority follow-up

[Local-host observations](async-save-authority-2026-10-03.md) now correlate the
selected-directory field with one real save across two host boots and contrast
it with a fresh RAM client boot. Autosave-name is empty even on the host. The
selected field can appear before load on Title. This does not close general
identity verification or same-process transition gates.

## Next gates

The later [same-process transition test](async-save-transition-2026-10-03.md)
confirms that the selected local ID survives joining RAM. Format/directory
checks alone are insufficient; current-session authority/readiness is required.

Verify authoritative host/server identity against the actual save directory,
repeat across restart and different saves, then host/client/host transitions.
Decide copied-world identity policy. Missing/unreadable recovery needs positive,
trustworthy absence evidence or explicit guarded initialization; never infer it
from a null load. Native singleton enforcement and production migration remain
separate gates. No new frame-time or stutter-elimination claim.
