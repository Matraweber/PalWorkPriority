# World-scoped save identity — October 3, 2026

Production persistence is unchanged. This is an isolated observation.

The process-map trial returned234empty samples while the local save changed.
Further identical polling is not useful. Independent source review identified
a stronger candidate: PalGameStateInGame.WorldSaveDirectoryName, a transient
FString replicated through OnRep_WorldSaveDirectoryName. The SDK also registers
DOREPLIFETIME for it. The getter and notification implementations in the kit
are stubs; no setter/load semantics are established from those bodies.

UE5.1 Engine/Classes/Engine/World.h declares GameState as a transient UPROPERTY
on UWorld (line1371 in the installed source). This supports a fresh property
chain engine → viewport → world → GameState without an object-array search.
The field belongs to world state, unlike the retained game-instance selection.
Replication also means a client may legitimately see a server directory ID;
it must never use that observation as permission to write local settings.

experiments/save_world_identity_probe.lua copies only a canonical nonzero GUID,
role0–3, the dedicated-server Boolean and bounded world name. Missing, malformed
and throwing reads remain distinguishable. No native getter other than validity
and name reads is called; no native references survive the callback. Results
are always verified=false, with no storage/key/ready field.

The separate driver logs this observation alongside the existing selected-ID
and loaded-state probe. It disarms before scheduling, reads once a second,
stops after10seconds of stable readable world-directory/role observations or
180seconds/samples, and protects cancellation and failed diagnostic sinks.
An unavailable field cannot produce successful observation completion.
Registration hooks and production changes are unnecessary for this trial.

This does not yet implement verify_storage. Required follow-up evidence includes
distinct local-save discrimination, host/client transitions on the same map,
fresh role/session binding, and dedicated-server access without a local viewport.
A field-name match or candidate agreement alone does not prove load provenance.

Offline validation: all100 regression scripts pass and51 production modules
compile under Lua5.4. Independent review found no blocker in the bounded
reader/driver. Tests include a retained local selection alongside a different
replicated client directory, fresh wrapper replacement, field/sink/timer errors,
world mismatch, stable-observation reset and inert shutdown. These are simulated
transitions, not evidence that the native field has those values on the server.

Checked installation at20:46:04UTC copied exactly three Lua files into the
separate PWPAsyncSaveWorldIdentity diagnostic, checked source/install hashes,
verified unchanged production and armed last. Older probes were disabled.
Live result: process43644, probe armed20:46:54UTC and completed20:47:41UTC
with43samples and successful timer cancellation. Splash/Login/Title GameState
did not yield a directory. At20:47:27 the Title game-instance selection already
contained the local ID but GameState still did not. At20:47:31, loaded MainWorld5
GameState returned31141b9948fe8b9a8b4cc399974dddf1, matching the selected local
save, role3, dedicated=false, with loaded-world=true. Those observations stayed
stable for10seconds. Role3 also appeared on Title: role alone is not readiness.

The normal macro reopened the Monitoring Stand; a fresh screenshot confirmed
priority numbers/X visible. Production independently reported authority and
normal ticks. Capture verified source/install hash agreement, unchanged
production, disabled diagnostic arm and cancelled timer. Evidence is under
test-results/save-world-identity-20261003/ (installation, full log, process,
production/runtime logs, acceptance and100-suite output).

This is the first live world-scoped directory candidate. It is not yet proof
of destination/load semantics, different-save discrimination or replicated
server behavior. Next validate this property through host→Title→client and
back, retaining stale selection as a contrast, then compare a distinct existing
local save where available. Keep production asynchronous persistence disabled
until fresh session/authority/storage binding and the remaining recovery gates
are satisfied. The speculative selection-hook prototype was never installed;
this stronger property route superseded it before testing.
