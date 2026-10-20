---
date: 2026-09-29
tags: [performance, network]
status: evidence
---
# Stand edit latency: root-cause investigation, September 29

Related: [transmitter-first-2026-09-29](transmitter-first-2026-09-29.md) · [push-lifetime-2026-09-29](push-lifetime-2026-09-29.md)

Read-only runtime investigation. No new deployment, settings change, game input,
or performance improvement is claimed. Candidate remains unpublished 0.5.0-rc1.
This combines current code, the saved RAM measurements, reference-mod review,
and primary upstream documentation/source. It does not replace native acceptance.

## What the measurements establish

The latest RAM window (19:03:37–19:04:20, one client/guild, nine Pals) contains
two edits, 300 and 306 ms inside the server receive hook. These are server
callback durations, not client frame times or complete click-to-confirm latency.

| Disjoint portion of an edit | Observed mean / attribution |
|---|---:|
| Initial checks and remaining handler overhead | About 50 ms residual |
| Complete edit roster validation | 55.5 ms |
| Save and deferred notification | 4.5 ms |
| Stand delta, including its own discovery and roster | 110 ms |
| Immediate scheduler pass | 83 ms on each edit |
| Whole hook | 303 ms |

The residual contains sender-guild discovery and the command's fresh authority
probe. Its exact internal split was not separately measured. The code routes
both through searches, consistent with their roughly 25 ms observed counterparts.
Do not add the authority/camp/component rows again to these parent regions.

Inside the 110 ms delta, roster rebuilding is 58.5 ms, component discovery
25.5 ms, transmitter discovery 25.5 ms, and guild proof 0.5 ms. Those phases
explain essentially the entire duration. Encoding and send have timed samples
below the observed 1 ms clock step; zero displayed is not zero cost or zero
network latency. Four earlier deltas averaged 111 ms, supporting repeatability
of this bottleneck across the two small windows.

## Why one changed number does so much work

1. `net.receive_command` discovers transmitters to prove the sender's guild.
2. `main.on_command` freshly proves authority.
3. `stand_rows` freshly proves authority again, enumerates camps, and reads all
   scoped Pals/capabilities to validate the requested Pal.
4. The edit is saved with recovery and verification.
5. `push_stand(nil, key)` broadcasts: `each_peer` separately discovers components
   and transmitters; `stand_rows` repeats authority/camp/roster reads. Only after
   constructing that roster does `push_pals` filter to the requested Pal.
6. `run_pass("priority change")` immediately reconciles all loaded camps. It
   repeats fresh authority/camp reads and resolves a write component if needed.
7. The edit acknowledgement follows the handler's return.

The single-client steady changed-pass path therefore has roughly eleven
searches: one inbound transmitter search, four authority searches, three camp
enumerations, two broadcast discovery searches, and one player-controller
search for the scheduler's write route. Cold class lookups, fallbacks and
different branches can add or remove work; this is not a universal fixed count.
At about 25 ms each, this explains most of the approximately 300 ms callback.

The children route is not scan-free on a dedicated server:
`owned_network_component` first calls `player_controller`, which falls back to
`FindFirstOf("PalPlayerController")` without a local viewport. The latest log
has two `api: pc walk` and two `api: owned comp via children` counts, alongside
49 ms measured across two complete owned-component resolutions. A route counter
alone had previously hidden this upstream cost.

The client also deliberately coalesces edits for 100 ms (`net.lua`, COALESCE),
polled on the 100 ms UI beat. Queued input, this deadline, network transit,
server work, acknowledgement and repaint are separate parts of perceived delay.
Coalescing protects rapid edits; removing it blindly increases server work.

## Why discovery is expensive even with nine Pals

UE4SS documents FindAllOf as traversing the entire global object array. The
matching result count is not the amount searched. The exact local runtime
banner is v3.0.1 Beta #0, Git SHA 2281fa31, MSVC Shipping. Its pinned Lua binding
delegates FindAllOf/FindFirstOf to UObjectGlobals and then wraps the results.
The Pal loop is downstream of that search and cannot make the search cheaper.

The exact 25 ms is a measurement on RAM, not a constant mandated by UE4SS.
Object population, per-object checks, CPU/memory performance and host scheduling
can affect it. No host CPU trace or global-array census isolates their shares.
Older 9–12 ms comments and local singleplayer timings do not price this server.

Important limits of the upstream search:
- The local client settings have bUseUObjectArrayCache=false. The RAM server's
  current settings/runtime fingerprint were not re-read during this research;
  the client file does not prove the server configuration.
- The pinned binding is available, but its UEPseudo submodule revision
  1cb4c98746f03dfcbf2f0394b59dfec0c9f83a04 was not publicly retrievable (404).
  Thus the exact native implementation/cache interaction was not audited here.
- Upstream changed cache defaults in PR747; current main has further settings.
  Neither establishes that toggling this installation's cache is safe or faster.
- FindFirstOf can terminate on a rare object if it occurs early. The old code
  comments saying this is possible *only* for common classes are too absolute.
  Its poor observed price here, not that assertion, supports the diagnosis.
- StaticFindObject/FindObjects names alone do not prove a cheaper algorithm.
  Prior local measurements already rejected blind name-lookup substitutions.

## The save spike is a separate source of variability

Four earlier edits included one 73 ms save with 69 ms spent in temporary-file
close. The latest two saves were 4 and 5 ms. Standard Lua regular-file close
calls C fclose; Microsoft documents flushing associated buffers during close.
Thus buffered write/close work can legitimately appear in the close bucket.
The writer does not request explicit physical-disk synchronization.

Storage contention, host scheduling and filesystem/filter activity are plausible
causes, not diagnoses. No OS trace identifies one. The 69 ms event does not
explain the older 278 ms save or 2456 ms handler without matching evidence.
Moving flush elsewhere might only move the same wait. Removing checked close,
backup rotation or verification would sacrifice settings safety, not solve it.

Microsoft's CRT clock measures elapsed time rather than pure CPU time, with
CLOCKS_PER_SEC=1000. Standard Lua os.clock delegates to clock. The local MSVC
banner and observed 1 ms step are consistent with this; the server build still
needs its own fingerprint. A timed region can include waiting/preemption and
is never an independent presentation/frame measurement.

## Ranked changes justified by this investigation

1. **Prototype transmitter-first broadcast discovery.** Enumerate transmitters
   once, obtain each candidate BaseCamp component with the existing typed
   GetComponentByClass pattern, and retain live owner/guild/peer/session checks.
   This targets the separate component scan (~25.5 ms per broadcast) without
   reusing roster data. Keep an explicitly measured fallback for incomplete
   resolution. Match the exact negotiated component name, not guild alone;
   GetComponentByClass may not return that component when multiple candidates
   exist. Perform at most one lazy fallback enumeration for unresolved peers,
   reusing the fresh transmitter map. Native multi-owner/guild behavior and all lifetime boundaries
   must pass before replacing the existing route. This is a proposal, not an
   already-proven saving or implemented patch. Independent read-only review
   confirmed this route is feasible in the current code and identified no
   requirement to discover components first. It reduces the successful steady
   edit path from eleven to ten searches; approximately 110→85 ms delta and
   303→278 ms callback are estimates before added lookup overhead, not results.
2. **Replace the headless authority lookup with a verified current-world route.**
   Four checks per edit make this potentially valuable. The present fast world
   route depends on GameViewport, which a dedicated server lacks. A fresh
   callback context/world utility route is worth a narrow typed probe; no
   timestamp hint, stored GameMode wrapper, or missing-data-as-false shortcut.
3. **Reduce full-roster work for a single-Pal operation.** A targeted fresh
   membership/capability reader can avoid unrelated Pal rank reads, but keeps
   camp/authority cost unless their access routes improve. Reusing a plain
   validated row across save/native callbacks additionally requires proven
   invalidation for session, guild, membership, capability and effective-value
   changes. Epoch checks alone are insufficient. Keep this deferred until that
   contract is established; do not claim the entire 58.5 ms as recoverable.
4. **Consider session-bound scheduler batching after accepted edits.** The
   immediate 83 ms pass extends each edit callback and acknowledgement path.
   Coalescing reconciliation could reduce repeated passes during bursts, but
   merely delaying one pass does not reduce its frame cost. Preserve ordering,
   X reconciliation, pending-write safety and accurate acceptance semantics.
5. **Investigate slow saves with matched host evidence.** Retain operation
   timings; correlate a reproduced event with host file/CPU tracing where
   available. Local Process Monitor cannot diagnose an inaccessible remote
   host. An async writer needs immutable generations and truthful unsaved state,
   not engine calls moved to an arbitrary background thread.

The downloaded PalPriority July26 sources use changed-state guards and skip
converged camps, but also retain native wrappers across callbacks. Our render
guards and lazy write-route resolution already apply the transferable parts.
Those sources are not equivalent-workload RAM benchmarks and their lifetime
assumptions are not a safe shortcut. See the September26 comparison.

## Verification needed to close the claim

Measure one candidate at a time with installed hashes, equivalent edits and
restoration, exact scan counts, and complete callback/individual phase timings.
Require fail-before/pass-after regression evidence for the removed lookup and
all cancellation/fallback paths. Include multiple recipients, another guild,
reconnect/replaced peers and missing/incomplete resolution.

Separately capture client frames and click-to-ack latency. The current server
data explains synchronization delay and server work, not every visible client
stutter. September13 mod-absent recordings still had large spikes; newer
paired recordings are required to attribute remaining frontend symptoms.

## 2026-09-29 (15:41-15:56): duplicate edit broadcast removed

Merged from edit-broadcast-2026-09-29 (deleted 2026-10-20, git history keeps it).

Before the fix (RAM, 122 s profile from 15:41:50, instrument-only main): two
priority edits took 441 and 444 ms in the incoming hook. Each made a full
save-callback broadcast (about 108 ms) and then an explicit one-Pal delta
(109 ms), so about 108 ms per edit was duplicate work. Roster validation
averaged 55.5 ms.

Fix: the store tracks whether a pending notification covers one Pal or
several, keeps that scope across save failures and detaches it before
callbacks. The network handler defers the notification and sends exactly one
broadcast per edit: a delta when the commit touched only that Pal, one full
snapshot when the flush also committed other Pals. A clean no-op clear still
sends a fresh snapshot; a failed save keeps the `applied_unsaved` reply and
the delta attempt. A successful save is not proof of delivery. The new tests
failed before and pass after (73 scripts). The 16:32 profile below confirms
four deltas for four edits and no full broadcast.

Side observation, not caused by this patch: after both same-process
reconnects the vanilla Escape menu had to be opened and closed once before the
stand's interaction prompt appeared.

## 2026-09-29 (16:27-16:33): sender reuse and stale-ACK guard

Merged from edit-context-2026-09-29 (deleted 2026-10-20, git history keeps it).

The transport already resolves the sender's guild to authenticate a request;
main repeated that transmitter lookup. Now the transport hands main an opaque
token for the same synchronous handler only. It holds plain data, never engine
wrappers, and is checked for identity, session epoch, server nonce, peer
identity, the peer's session/guild fields and sender name; reentry, session
reset and handler exit invalidate it. Main's fresh authority, full roster
authorization and recipient checks stay. One fewer sender lookup per edit,
verified in tests; no milliseconds are claimed (not timed separately).

**Stale-ACK guard.** A regression reproduced a real defect: a handler could
replace its session or peer while authority stayed true, and the transport
then recorded and sent an acknowledgement for the superseded request. The
return path now checks the captured epoch, nonce, peer identity and the
peer's session/guild fields before recording or sending any acknowledgement.
The regression failed before the fix.

Considered and not adopted (not justified by the measurements): sharing native
camp reads across validation, save and broadcast (widens object lifetime), and
stopping roster validation at the target Pal (risks skipping unknown
ownership, partial rosters and duplicate identities).

Native retest on RAM, 109 s profile ending 16:32:03, four edits (Vixy
Gathering 1->2->1 twice):

| Inclusive region | Samples | Mean | Worst |
|---|---:|---:|---:|
| Incoming network hook | 4 | 373.25 ms | 577 ms |
| Stand delta | 4 | 108 ms | 110 ms |
| Save (notification deferred) | 4 | 73 ms | 278 ms |
| Roster validation | 4 | 55.5 ms | 57 ms |
| Complete scheduler pass | 13 | 71.5 ms | 88 ms |

Edits took 577, 304, 304 and 308 ms. The 577 ms edit contained the 278 ms
save (the other three saves totalled 14 ms); that spike is followed in
[save-flush-2026-09-29.md](save-flush-2026-09-29.md). The ordinary edit path of
about 304 ms remained.

## Sources and preserved evidence

- [Microsoft CRT fclose semantics](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/fclose-fcloseall?view=msvc-170)
- [Microsoft CRT clock semantics](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/clock?view=msvc-170)
- [Lua regular-file implementation](https://www.lua.org/source/5.4/liolib.c.html)
- [Lua clock implementation](https://www.lua.org/source/5.4/loslib.c.html)
- [UE4SS FindAllOf documentation](https://docs.ue4ss.com/dev/lua-api/global-functions/findallof.html)
- [Exact client-revision Lua bindings](https://github.com/UE4SS-RE/RE-UE4SS/blob/2281fa311e417b1dfddedbcd49972d764fddb244/UE4SS/src/Mod/LuaMod.cpp)
- [Upstream cache-default change](https://github.com/UE4SS-RE/RE-UE4SS/pull/747)
- [StaticFindObject contract](https://docs.ue4ss.com/lua-api/global-functions/staticfindobject.html)
- [Construction notification contract](https://docs.ue4ss.com/lua-api/global-functions/notifyonnewobject.html) (construction is not complete lifetime/membership invalidation)

Local primary evidence: `.tmp/assignment-census/server-push-lifetime.log`,
`server-push-phases.log`; research source copies and commit/tree metadata in
`.tmp/assignment-census/ue4ss-research/`. Source inspection covers main.lua,
net.lua, palapi.lua, datafile.lua, measurement.lua and perf.lua. Historical
frame evidence is documented in `frame-correlation-2026-09-13.md`.
