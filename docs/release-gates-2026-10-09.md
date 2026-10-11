# Remaining release gates â€” October 9, 2026

Candidate: unpublished 0.5.0-rc1. This is the current checklist, not a claim
that every older unchecked item remains unfixed. Historical reports retain
their original evidence. Public/default and dedicated native async are OFF;
the checked local combined async trial is an exception. The user authorized
implementation and testing of the whole remaining list.

## Evidence added today

- Local manual-runtime dedicated fixture: authenticated legacy Stone limit edit
  35,000 â†’ 35,001, synchronous server persistence, normal client/server shutdown
  and restart, and client panel readback passed. Client legacy files unchanged.
  See `test-results/server-loader-20261009/` and the latest section of
  [async acceptance](async-enablement-2026-10-04.md). This does not establish
  native async, priorities persistence, actual production, or Workshop loading.
- Empty-server diagnostic regression fixed: UE4SS's documented nil result from
  FindAllOf means no instances, not an enumeration failure. Before-fix Lua
  regression failed; after-fix Lua and native census pass. All 14 Pal actors
  remain unavailable and their assignments remain unknown. No idle/manual
  inference was added. Archive: `test-results/server-assignment-20261009/`.
- Independent storage census matched production counts in that fixture.
  Client storage remains unavailable because no stock transport existed;
  bounded, scoped transport is implemented. First live base-1 count matched the
  server (27,867 Stone). Final instrumented tests passed base2 (5,498),
  expiry selector clicks and close/reopen renewal. Initial apparent selection
  reversion was not reproduced or assigned a speculative cause.
  See `test-results/server-storage-20261009/`; not a completed gate.
- All 183 Lua regression scripts passed for the final live storage candidate.
  Later source-only producer guards bring the passing suite to186. Python discovery is repaired:
  `python -B tools/test_python.py` independently ran 422 tests, 341 passed and
  81 native-dependent skips. Skips are not native acceptance.
- Steam-library discovery now finds the actual D: client installation; explicit
  overrides and ambiguous/missing installations have regression coverage.
- All three disposable server fixtures stopped normally and originals were restored.
  The temporary schema4 client was restored to its exact pre-test Scripts/Info.
  RAM was untouched by these trials.

## 1. Settings and asynchronous persistence

- [ ] Ordinary installation, upgrade, rollback and removal of the async backend,
  beyond the checked development launcher.
- [ ] Dedicated active-storage identity, ownership, recovery and lifecycle before
  enabling dedicated native writes.
- [ ] Remote client behavior while the authority recovers, drains, fails or
  requires restart; durable acknowledgement must track the correct generation.
- [x] Local panel-entered async limit commit, restart/readback and original-value restoration. Remote async acknowledgement remains a separate open gate.
- [ ] Matched write-latency/frame-time trials with profiling off/on.
- [ ] Actual game-crash integration and recovery. Disposable native-process
  crash cases passed; those are not game-crash or physical power-loss evidence.
- [ ] Document restart-required behavior after travel; auto-rearm is not supported.
- [ ] Remaining numeric/default-reset reports, migration/reinstall/recovery and
  safe removal with confirmed permission restoration.
- [ ] Dedicated priority edit/save/restart acceptance (limit acceptance passed).

## 2. Scheduling and production behavior

- [ ] Empty-server assignment evidence: current native actors are absent. Do not
  turn this into an idle/manual=false assumption merely to pass stress tests.
- [ ] Actual targets/activity/output for Pupperai, Flambella, Incineram,
  displaced/sleeping/waking Grizzbolt, cooling, generation, fishing, research,
  recyclers, synthesizers, ranching and fixed assignments.
- [ ] Reproduce all-work-stops and one-miner reports with applied permissions,
  available jobs, actual workers and output, rather than fence logs alone.
- [ ] Staffing/manual/occupied-seat/unknown-worker cases; balanced versus strict
  modes; idle reconciliation under real game transitions.
- [ ] Safe item-specific producer adapter: stone capped while ore continues,
  consumption resumes stone, multiple rules/producers and measured in-flight
  overshoot. Unsupported producers must remain explicitly unsupported.
- [ ] Actual legacy work-type limit enforcement and accurate UI explanation.
- [ ] Verified client storage transport, shared/guild storage deduplication,
  selected-base scope, unavailable/expired stock presentation.

## 3. Multiplayer and lifecycle

- [ ] Two clients, two owners and two guilds; concurrent edits, delayed/lost or
  incomplete messages, reconnect and incompatible versions.
- [ ] Deliberate unmodded vanilla edits distinguished from the mod's own writes
  using verified sender evidence.
- [ ] Explain/reproduce transient snapshot_apply_failed recovery.
- [ ] Missing interaction prompt after joining: pause workaround is not a fix.
- [ ] Listen-host, respawn and hostâ†’clientâ†’host transitions on the same map.

## 4. Frontend and controls

- [ ] Remaining reported crashes, duplicates and stuck UI; death while editing,
  bed/missing/duplicate pak, tree replacement and repeated hide/reopen.
- [ ] Rules at 0/1/13/14/26/27 entries; multiple picker pages; long text; amount
  editor/pagination positioning without moving the preferred panel position.
- [ ] 16:9, 16:10, Steam Deck resolution, ultrawide and UI scaling.
- [ ] Physical controller navigation and held/released inputs; right double-click,
  rapid focus changes and mixed direct-key/mouse input.
- [ ] Network feedback, blank backdrop, modded catalogue/Search/Add crash and
  clear explanation of unsupported/legacy limits.

## 5. Performance and compatibility

- [ ] Full server scans/edit/sync-flush costs and first-open/search/fill/edit spikes.
- [ ] Repeated matched independent frame-time captures: mod absent/present,
  profiling off/on, cold/aged sessions, base/field/dungeon and each UI surface.
  Count-only rows, overlapping inclusive timings, tick cadence and no log errors
  cannot establish stutter-free operation.
- [ ] Loaded game/runtime/mod fingerprints on each acceptance run.

## 6. Installation and release

- [ ] Built-in Workshop local-server loader remains unresolved; manual runtime
  loading works. Do not equate the two routes.
- [ ] Explain/remove duplicate PalWorkPriority asset actors observed on RAM.
- [ ] Clean Workshop/manual packages, supported Vortex route, pak mounting,
  duplicate-install protection and matching source/asset contracts and hashes.
- [x] Refresh the comment census: all70Steam comments,17Nexus comments and2Nexus
  bugs read in logged-in Chrome October9. [Current delta](comment-update-2026-10-09.md)
  preserves report-to-finding links; this does not close reported defects.
- [ ] Update installation/testing/removal documentation, changelog and grouped
  replies. Posting/publishing follows release acceptance, not test completion alone.
- [ ] Optional high-quality-stand restriction and Pal-produced material support.
- [ ] Optional independent priority/limit components; controls hints and
  consistent wraparound; assess UI-edit coalescing without relying on close.

## Current work

Storage transport has explicit guild/session/request binding, complete bounded
snapshots, source-cache age, expiry and bounded sends. Local readback passed for
both bases, physical selection while counts expired, and close/reopen renewal.
Count expiry preserves selector metadata but never stale totals. Four-packet
batches reduced five-packet replies from five transmitter censuses to two.
Independent review caught and closed a pre-send guild-revocation gap. Final
source hashes and limits of acceptance are in
`test-results/server-storage-20261009/acceptance.json`.

The initial apparent Base1 reversion was not reproduced in instrumented tests;
it is not declared explained. Multi-guild/shared-storage and independent
frame-time acceptance remain open. No public-server/package change was made.

Priority cycling wraps through 1–5/X in both directions, with Lua regression
coverage; native mixed-input validation remains. Client diagnostics now label
local configuration and withhold unconfirmed server scheduling policy.

Source-only producer guards prevent registration from advertising undeliverable
item-rule creation, reject mismatched work/output, and capture validated adapter
fields against later mutation. No native producer adapter has been enabled.


## Dedicated identity observation, 21:03

A read-only one-shot observer completed 11 stable samples on the isolated manual
server runtime. Current world/state/instance agreed, the save manager belonged
to that instance, loaded-world was true, and the engine returned the exact
absolute Saved root and configured world directory. Timer cancellation returned
true. All samples explicitly retained verified=false and storage_grant=false.
No native writer was loaded. Normal REST shutdown and original-folder
restoration completed. Evidence: `test-results/server-identity-20261009/`.

Both empty-server camp directors reported WaitForLoadingAround with player
tracking false. Four leaving-assignment records were observed, but all 14 Pal
actors were unavailable. This narrows the lifecycle explanation; it does not
close empty-server assignment or actual-worker acceptance. The full suite now
passes 187 Lua scripts. Whole Python discovery passes 432 tests: 351 passed,
81 native-dependent skips. Skips remain unaccepted native gates.
Dedicated async identity integration, ownership, recovery and lifecycle remain
open. This single read-only boot is not permission to enable native writes.


A second normal boot retested the reviewed collector after adding final loaded-
world and world-owner rechecks. It again completed 11 coherent samples and
cancelled successfully; normal shutdown/restoration passed. First-run artifacts
have a `first-` prefix, final identity.log and fingerprints cover the corrected
collector. Ordered rechecks are not an atomic engine snapshot. The dedicated
world-bound guild/Pal membership proof remains separate from local-player proof.


Read-only headless guild prototype added under experiments (not production):
GetGroupManager(world), exact GuildMap key/GetId agreement and a bounded repeated
roster read. Default-off; no authority/storage grant. Native accessibility and
ownership are unproved. The whole Lua suite currently passes188 scripts.

Frame-capture investigation found that the September23 wrapper omitted exit,
process-identity and CSV completion checks. Its generic privilege warning also
appears in successful captures; it is not the established root cause. A new
pinned-recorder wrapper is under independent review. Its offline validator has
accepted two prior60-second captures (8,286/9,545 rows), but no new live frame
acceptance is claimed yet.


## Independent capture smoke result, 21:16

Reviewed `tools/capture_frames.py` completed a title-screen10-second capture with
2,392 raw rows /2,391 anchored intervals,9.9690861s coverage, exit0, unchanged
game PID/creation time and matching validated/final CSV hashes. Archive:
`test-results/frame-captures/459a78a931184728bc5137c15345ed4f/`.
The game then exited normally through its menu. This validates the capture
pipeline only, not mod performance or the cause of September's missing output.
1,793 rows were marked Dropped; Present cadence must not be called displayed FPS.
No permissions changed. Matched gameplay/stand/panel and profiling comparisons
remain open. The wrapper/analyzer regression set passes44 tests.


## Headless guild route, third isolated boot

The explicitly queried fixture guild returned a complete16-ID roster through
GetGroupManager(current world) and its exact GuildMap entry in11 native samples.
World/manager/context checks passed; all grants remained false. The observer
finished with successful timer cancellation. Normal server shutdown and original
folder restoration passed. `test-results/server-identity-20261009/guild-*`
contains receipts, code/runtime hashes, raw output and narrow acceptance notes.
This establishes route accessibility for one fixture guild, not cross-guild
safety, actual Pal activity, recovered-priority coverage or async admission.


## Frontend recovery batch and native smoke

Fixed and independently reviewed three reproduced failure paths: unreadable
containers causing duplicate rows; forgotten input restoration after a transient
failure; cancelled editors remaining visible after a failed hide. Recovery is
bounded and checks current generation/ownership. The editor teardown reentrancy
regression is covered.193 Lua scripts pass;452 Python tests pass discovery
(371 passed,81 skipped). Panel remains at194 top-level locals.

Native singleplayer candidate: rules opened, Stone editor opened and Escape
cancelled, panel closed, vanilla Options/Inventory remained interactive, rules
reopened. Both pre-existing local async streams exited cleanly with no accepted
or committed edits (limits generation9, priorities8). Normal quit and exact
client Scripts restoration passed. Failure injection was offline, not native.
A clipped per-row Legacy group label was observed and remains under inspection.
Quick synthetic Alt+F1/V inputs did not establish shortcut/stand acceptance.
See `test-results/frontend-recovery-20261009/`.

The independent settled-rules capture is valid but performance FAILS acceptance:
1,372 raw rows over9.97195s, p99 Present interval84.28ms, worst122.09ms,
42 intervals above50ms. It is one unmatched scene with no aligned mod-event
trace; neither cause nor improvement is established.951 rows were dropped;
these statistics are Present cadence, not displayed FPS. Large remaining spikes
must be investigated before release. Capture09fb66ce97bc4c53a737da548a0eb715.


## Persistence cost isolated, 21:47

The reviewed opt-in instrumentation measured 8,908 forced GameplayStatics
resolutions taking 8,259ms in a 29-second rules-open observation window.
Priorities/limits maintenance averaged39.42/38.94ms; the separate combined
poll averaged77.42ms. These inclusive regions overlap and must not be summed.
The raw-QPC rules capture reproduced42 Present intervals above50ms in9.95s,
p99 84.54ms and maximum123.69ms. The closed-panel capture had18 above50ms
in9.97s, maximum125.46ms. External anchors and event traces are archived for
independent correlation. Profiling was on; no optimization acceptance yet.

A bounded legacy-label geometry fix passed offline regressions and native
visual inspection at the current1280x720 viewport. It retains the existing
panel position/editor geometry; other resolutions remain open. All194 Lua
regression scripts pass. The optional raw-QPC capture extension passed54
focused capture/analyzer tests and independent review.

Native streams recovered generations9/8 and exited normally at21:47:19,
accepted=0/committed=0, both cleaned/joined true. Original Scripts and trial
launcher were restored with exact hashes; journal contents retained. Evidence:
`test-results/persistence-cost-20261009/`. The measured persistence lookup
expense is the immediate optimization target, without weakening proof checks.

This lookup finding belongs to the explicitly enabled local async development
trial. Public0.4.1 did not ship this trial, so it does not by itself explain
public Workshop/Nexus stutter reports. Those need their own matched evidence.

Independent raw-QPC/Lua correlation associates all42 rules-open and all18
closed-panel >50ms Present intervals with persistence maintenance or the
combined poll. This holds for the tested affine clock maps and +/-2ms endpoint
sensitivity, with no trace drops/expiry. Association is not an intervention
result; the next build reduces lookups while retaining complete proofs.
Reproducible analysis: `test-results/persistence-cost-20261009/correlate_captures.py`
and `correlation-results.txt`.


## Scoped proof optimization and actual panel-save finding, 21:55

One fresh GameplayStatics CDO is now explicitly scoped to an authorization
operation and cleared on every exit/reentry/revocation. Both ordered snapshots
and all identity/authority checks remain. Default providers are unchanged.
Seven focused suites and independent mutation checks passed before the native
trial. Source changes remain in experiments; public/default async is still OFF.

Native rules-open: forced lookups4,998 versus9,996 Pair.read calls, exactly one
lookup/two snapshots per proof. Maintenance means23.25/22.33ms, combined poll
45.61ms. In the corresponding short capture, p99 fell84.54→52.25ms and maximum
123.69→76.29ms; >50ms counts42→23. Closed capture p99 was7.34ms but worst116.83ms
with14 intervals>50ms. Profiling-on single pairs, evolving world activity/time,
and remaining spikes prevent full performance acceptance or a universal saving
claim. Evidence: `test-results/persistence-scope-20261009/`.

A real mouse/type/Confirm edit35000→35001 exposed a panel contract bug: caps
returned accepted-but-pending and the editor falsely reported failure/unchanged.
After cancelling that stale draft the panel showed35001 Saved. Normal exit
at21:55:31 confirmed one accepted/committed limit write at generation10, both
streams cleaned/joined; priorities stayed generation8. This is backend commit
evidence, not frontend acceptance. The pending-result UI fix and restart/readback
are underway; the original35000 must be restored through the normal UI afterward.
Original Scripts and launcher are restored, with the committed journal retained.


## Pending-save UI native acceptance, 22:05

The reviewed candidate recovered limits generation10/priorities8 after a full
restart. The panel visibly showed Stone35,001 Saved. A physical editor change
back to the original35,000 closed the editor on Confirm and visibly displayed
Saving... / Saving change..., then Saved with35,000. No false failure remained.
Normal quit at22:05:31 recorded one accepted/committed limits write, generation11,
and priorities unchanged at8; both native streams cleaned/joined true. Original
Scripts and launcher were restored with exact hashes and journals retained.
Evidence: `test-results/panel-async-save-20261009/`. All197 Lua regression scripts
passed before deployment. This closes the narrow local panel commit/readback
gate, not remote durability acknowledgements, installation or crash recovery.

Full Python discovery after the raw-QPC additions ran462 tests:381 passed,81 native-dependent skips. Log: `test-results/panel-async-save-20261009/python-suite.log`. Skips remain unaccepted native gates.


## Interruption recovery and next checks — October 11

Verified the October9 final temporary client installation was restored: every
original Scripts hash and the trial launcher match the saved baseline. No game
or local server process was running at resumption. The restored Stone35,000
value survived the subsequent restart (limits generation11, priorities8).

The duplicate-priority-flush fix passed200 Lua scripts before its native test.
The real Main/UI/store regression failed before with two flushes and passes
after with one. A one-use callback-scoped receipt skips only an unchanged,
successful prior flush; standalone, pending/error, new edits and session changes
retain required maintenance. Native rules proof counts are equal for both
streams (2,312 each), versus the prior extra priority polls. Maintenance still
averages about23.7ms priorities/22.7ms limits; combined polling45.9ms.

October9 raw-QPC captures under `test-results/persistence-flush-20261009/`:
rules1,579 intervals,9.9589s coverage,p9952.45ms,max92.79ms,27>50ms/0>100ms;
closed2,001 intervals,9.9591s,p998.06ms,max53.07ms,10>50ms/0>100ms. These single
profiling-on windows and changing world activity do not establish release
performance acceptance. The narrower duplicate-work fix is confirmed; spikes
remain. Normal quit22:14:20 recorded accepted0/committed0, generations11/8, both
cleaned/joined true. Original Scripts/launcher restored exactly; journals kept.

Next async network foundation: attachment-bound receipt queries and a bounded
pending-edit ledger. No network integration or dedicated enablement yet.
Dedicated parameter observer wiring is offline only pending independent review
and a separate native accurate-clock binding check.


## Async acknowledgement foundations — October 11

Implemented internal attachment-bound receipt queries in settings_writer, caps
and store. A receipt query cannot turn memory acceptance into durable success,
use a replaced/detached writer, or bypass normal module publication/notification.
The current durable body and covered revision are returned explicitly; a newer
snapshot may supersede an older request's value. Attachment allocation uses one
scalar Lua-registry counter across module reloads, never wraps, and retains no
engine objects. These receipts are trusted internal values, not wire credentials
or persistent cross-VM identities.

A pure experimental pending-edit ledger reserves capacity before mutation,
allows one active request per peer/stream and128 globally, prevents duplicate
replay and marks timeout unknown. Completion requires trusted durability proof
and completed guarded snapshot delivery; the ledger itself proves neither.
No net/main integration, remote ACK delivery, native enablement or deployment
was performed. The next step is wiring both halves with durable snapshot gating
and exact-revision ACK replay, then end-to-end integration regressions.

All204 Lua regression scripts pass and54 modules compile. The writer fault
mutation that labels in-memory acceptance saved is caught. Tests cover receipt
replay across module reload, malformed/exhausted allocation, callback reentry,
closing/failing writes, stale session/owner and changed module snapshots.
Evidence: `test-results/async-receipts-full-20261011.log`.

Dedicated parameter wiring now has offline independent review PASS with7focused
Lua suites and14installer tests. It resolves the accurate-clock CDO once per
callback and releases it on all exits; no os.clock fallback. Native marshalling,
elapsed advancement and cost still need a separate clock-only trial BEFORE
parameter sampling. Exact files/review: `test-results/dedicated-parameter-wiring-20261011/`.

Independent capture analysis is now archived in
`test-results/persistence-flush-20261009/independent-analysis.txt`. It confirms
22 duplicate priority polls removed in the rules window: stand-refresh inclusive
mean23.091ms to0.136ms, while the remaining maintenance/combined polls still
align with >50ms Present intervals. This is a narrow measured saving, not global
stutter-free acceptance. Original installation restoration was verified by Main
from filesystem hashes, not inferred from an agent/user statement.


## Stable edit acknowledgement replay — October 11

Fixed net.lua so a duplicate request replays the original result and original
P/R snapshot revisions. Previously send_ack read the peer's latest revisions,
which could associate an old result with unrelated later publications. The
revision pair is now copied immediately after the handler returns, before the
post-handler authority check or FName conversion can dispatch nested callbacks.
Peer/session/settings fences remain required on every send, including retries.
No protocol/schema change or async enablement is involved.

The new regression fails on the old implementation. Tests cover successful,
rejected and applied-but-unsaved results; later publications; reentry during
authority validation and FName conversion; and a lost initial ACK. Duplicate
requests invoke the mutator once. All204 Lua regression scripts and54 module
compilations pass; structural checks pass. Independent review PASS killed both
late-capture and current-revision-replay mutants. Evidence:
`test-results/network-ack-replay-20261011.log` and
`test-results/network-ack-replay-structural-20261011.log`.

This is a prerequisite for remote async completion, not completion itself.
Main still needs to preserve `(false, 'pending', receipt)` from store/caps;
currently those branches collapse pending into rejection. It must reserve a
ledger slot BEFORE calling apply_set/apply_clear, not after obtaining a receipt.
Caps returns pending directly; store's async apply returns pending before the
existing synchronous flush branch. Hello/resync and all broadcast routes need
the same durable-publication guard, so pending memory cannot become confirmed
state by a different route. Runtime guild aliases must be authenticated and
mapped to the canonical receipt guild; the experimental ledger's canonical GUID
validation is not a replacement for net's sender/guild authorization.

Deferred work must retain only plain data, reacquire and re-prove the recipient,
query the original attachment, prove the exact serialized snapshot still matches,
finish guarded snapshot transmission, then cache/send its exact revision ACK.
A lost/uncertain write or timeout is unknown, never a definite rejection or an
automatic replay. Do not add an unconditional extra persistence poll per UI beat:
the duplicate-flush native measurements already demonstrated that cost.

No deployment or native testing was performed for this ACK change. Public and
dedicated async remain OFF. The game and local dedicated server were stopped at
the start of this continuation; existing installed files and journals unchanged.


## Clock-only preparation and composition checks — October 11

Added a separate default-off clock-only probe and offline fault tests. It invokes
no world, guild, Pal, parameter or writer route. At most eight callback attempts,
34 clock reads per callback and fixed arithmetic work; callback-local clock CDO
is released before emitting observations. Frozen/frame-only values cannot qualify
as observed advancement. Resolver and total callback costs remain unknown; spans
use the clock being tested and explicitly leave elapsed_validated=false. Native
clock binding and independent elapsed/cost acceptance are still outstanding.
No installer change, installation or native run was made. Invocation/limits:
`docs/dedicated-clock-probe-2026-10-11.md`; frozen files:
`test-results/dedicated-clock-probe-20261011/fingerprints.json`.

A new composition regression joins actual caps/store, writer, settings_session,
barrier and pending ledger with fake backend completion. Both streams cover
canonical/runtime guild mapping, duplicate admission, storage completion before
normal module publication, timeout followed by durable completion, role changes,
and uncertain completion. It explicitly models the publication barrier; it is
NOT a net/main integration or real snapshot-delivery acceptance test.

Final full Lua run:206 scripts pass,54 modules compile. Log:
`test-results/continuation-20261011-final-lua.log`. Narrow ACK replay and clock-only probe independent reviews are PASS. The latter
also passed registration-failure and synchronous-reentry probes; native binding,
independent elapsed validation, callback cost and harness acceptance remain open.


## In-flight reply ordering and uncertain handlers — October 11

A new before-fix regression reproduced a second ACK ordering bug: a duplicate
arriving synchronously during its first handler received stale_request before
the original result. Net now reserves that peer before mutation and holds the
reservation through result caching, including error logging and post-handler
authority checks. The first independent review caught an early-release gap;
a second regression now covers that boundary too. Uncached requests during the
callback abstain without mutation or high-water advancement; cached completed
results remain replayable with their frozen revision pair. The reservation is
cleared by identity on completion or invalidated-context exits. Existing
command_context invalidation/authorization behavior is deliberately retained.

Another before-fix regression reproduced a handler changing state then throwing:
net falsely sent rejection. Thrown outcomes now retain a bounded unknown record,
send no success or rejection ACK, and cannot reapply the mutator on an exact
retry. The real client protocol times out and requests fresh full state. A later
snapshot updates visible state without inventing an edit acknowledgement.

Fault coverage includes duplicate/malformed/other-ID reentry, authority and
logging callbacks, role loss, session/peer replacement, completed result replay,
and cleanup without clearing a replacement reservation. Full206 Lua regressions
and54 module compilations pass; structural checks pass. Evidence:
`test-results/network-reservation-20261011-lua.log`,
`test-results/network-reservation-20261011-structural.log`, and frozen hashes in
`test-results/network-reservation-20261011/fingerprints.json`.

These changes fix the existing synchronous receive path and are prerequisites
for asynchronous completion. They do NOT integrate the experimental pending-edit
ledger, preserve Main's pending receipts yet, or send remote durable async ACKs.
No deployment/native tests performed; public/dedicated async remains OFF.


The next independent fault review found diagnostic cleanup could itself throw:
a handler error object's __tostring, a failing log sink, or the post-handler
authority probe could strand peer.inflight. Error formatting/logging is now
protected; a throwing authority probe records unknown only for an unchanged
plain peer/session identity. Identity-checked cleanup runs before returning,
without a false ACK. Three additional regressions fail before and pass after;
unknown retries do not reapply, and the next distinct edit is not blocked.
Cached earlier results remain exactly replayable while another edit runs.
Full206 Lua regressions/54 compilations and structural checks passed again after
these changes. Updated fingerprints replace the earlier intermediate candidate.

Final independent review PASS for this reservation/unknown-outcome patch; four
net suites plus54 compilations passed independently. Review archived at
`test-results/network-reservation-20261011/review.txt`. No native acceptance.


## Pending result propagation — October 11

Main now preserves false/state/attachment receipt for remote async priority
set/clear and limit set/clear. Pending returns before another flush, direct
snapshot broadcast or scheduler pass. The previous priority path discarded the
receipt/reason; pending limit removal also broadcast memory through its generic
failure path. A real Main composition regression fails before and passes after
for all four commands (mutator completion mocked; composition root real).

Net treats false/pending as an unknown bounded request record with reason pending,
not a final rejection or success. Exact duplicates do not reapply; the existing
client timeout/resync path remains the fallback. Real server/client protocol
fixtures cover both streams: no final ACK, old confirmed view retained and
ack_timeout after the deadline. No extra poll, timer, unbounded pending queue or
receipt object retention was introduced.

IMPORTANT: this is conservative result propagation, NOT deferred-success delivery.
Net does not yet retain/use the attachment receipt or complete a pending ledger
entry. Success still needs current attachment durability, guarded exact snapshot
publication, authenticated canonical guild mapping and lifecycle invalidation.
Hello/resync/broadcast durable-publication guarding remains open. Therefore this
fallback does not make remote async safe to enable. Public/dedicated async remain
OFF; no deployment or native test was performed.

All206 Lua regressions/54 compilations and structural checks pass. Evidence:
`test-results/network-pending-result-20261011-lua.log`,
`test-results/network-pending-result-20261011-structural.log`, fingerprints under
`test-results/network-pending-result-20261011/`.


Independent narrow pending-result review PASS. Reviewer saw one transient Main
initialization failure (measurement.bind received a boolean module); isolated and
subsequent standard-runner reruns passed. Main froze Scripts/tests source and
repeated the same three suites five times: all passed, source hashes unchanged.
Cause/which module were not established; concurrent source editing during review
is possible, not proven. No production guard was added to hide the error. Evidence
and exact caveat: `test-results/network-pending-result-20261011/review.txt` and
`frozen-reruns.log`. This is routing acceptance only, not remote async completion.


## Deferred remote completion and publication guards — October 11

Supersedes the previous source-only pending-result limitation, not the native
release gates above. Deferred completion is now integrated behind explicit
`net.enable_deferred(true)` before negotiation; no public configuration or Main
startup enables it. Session changes turn it off again. Dedicated/public async
remain OFF. No client or server install, restart, or journal mutation occurred.

- Store/caps publication predicates require current bytes to match the private
  snapshot committed by normal maintenance. IO completion alone is insufficient.
  Hello, resync, broadcast and edit snapshots share this guard. Legacy synchronous
  transport keeps its explicit applied-but-unsaved behavior.
- The bounded pending ledger reserves before mutation and accepts only a valid
  attachment receipt with the activated canonical owner. Duplicate/ambiguous
  requests cannot replay a mutation. Plain metadata only is retained.
- One completion job per one-second beat reacquires the recipient and rechecks
  session, authority, guild, receipt request revision and exact durable body.
  A complete guarded snapshot precedes success ACK; replay pins that original
  revision. Incomplete sends retry within the original eight-second deadline.
  Expiry means unknown outcome, never rollback or automatic resubmission.
- Publication reentry during native conversion/send cannot commit a stale peer
  revision. Configuration defaults also participate in the proof: live content,
  replacement of work_caps, and every configure generation are checked against
  the actual config used to build rows. Defaults are not claimed journal-backed.
- Pure publication checks add no native persistence polling. Their serialization
  and repeated ownership checks still need measured native cost acceptance.

Validation: all209 Lua regression scripts pass;55 production modules compile
with Lua5.4; structural checks pass (existing panel194-local warning). Independent
production review and real-persistence transport composition review pass.
The composition uses actual Main adapter source and real persistence modules;
engine roster/RPC and backend completion are mocked. It proves both-stream
maintenance-before-publication, full snapshot-before-ACK, duplicates, timeout,
role/body changes, uncertain IO and send retry. B/E conversion tests mutate real
config defaults and forbid completion/revision/ACK. A negative-control mutation
removing defaults consistency checks fails the new regression as expected.

Evidence: `test-results/network-deferred-20261011-lua.log`, structural and mutation
logs alongside it, and `test-results/network-deferred-20261011/` hashes/review.
An initial integration-fixture revision failed while still under construction;
final frozen full suite passes. Callback declarations and a shadowed local name
were corrected for the structural checker without weakening it.

Still open: native registry/receipt integration, lifecycle and reconnect matrix,
real delayed/failed delivery, concurrent-owner load and eight-second queue expiry,
matched frame-time cost, and dedicated ownership/recovery prerequisites. The128
entry bound does not promise128 timely completions at one job per second. Keep
remote async off until the reviewed native fixture establishes those properties.


## Native clock prerequisite — October 11

Built/reviewed the separate clock-only one-shot harness, installer, strict log
acceptor and fresh resumable fixture preparation/restoration. Full210 Lua scripts
and55 modules pass;32 focused Python installer/acceptor/fixture tests pass.
Independent review additionally exercised72 interrupted rename/restoration cases.
A parser bug accepting cumulative start intervals >=60seconds was corrected.

Ran TWO real isolated dedicated boots. Both canceled after their first callback
with clock_unavailable; the second diagnosis established an integer Seconds
output but missing named PartialSeconds. This is failed clock qualification,
not measured zero time. No parameter sampling, writer or async enablement ran.
Both servers exited normally; all originals restored with exact recorded hashes.
See [clock evidence](dedicated-clock-probe-2026-10-11.md) and the two native evidence
folders. Next prerequisite: explain the pinned runtime's fractional out-parameter
binding, then rerun a bounded reviewed clock trial. Other release gates stay open.


The third clock boot resolves the preceding binding blocker: pinned UE4SS places
consecutive scalar outputs in the first table. Passing one fresh output table
twice preserves strict named-field validation and passes8 native samples,7
between-sample advances and8 synchronous advances. Timer cancellation, normal
shutdown, original-hash restoration and installed-source equality pass.
Evidence: `test-results/dedicated-clock-shared-20261011/`. Independent elapsed/
total callback cost, dedicated parameter membership/lifecycle, native IO and
remote async acceptance remain OPEN. No async flag or release package changed.


## Release package asset and collected-byte acceptance — October 11

Corrected a release-blocking mismatch: repository LogicMods contained the old
5,400-byte 0.4.1 pak, although current Lua requires StandInput contract 2 as well
as WorkRules input contract 3. Replaced the repository payload with the existing
12,040-byte combined candidate, SHA-256
`4eddf38bcf859ec27df2424aa9bda2ea9ded735e56ab7178b5c97d0b10bf4a9d`.
Verified all six constituent source hashes against the September 24 package
provenance and confirmed exact equality with the installed client pak. No game
installation or runtime state changed in this step.

`docs/asset-contract.json` schema 2 now binds those exact bytes to both required
widget identities/contract versions. The release builder rejects stale/missing
contracts, a different asset even with a correct CLI hash, and missing/ambiguous
default configuration. It embeds the reviewed contract in both manifests,
compiles the collected Lua bytes under final package filenames, and compares
both manifest and payload after validation. Contract fields are reviewed
expectations, not binary introspection or current native acceptance.

Fourteen release regressions pass, including an isolated clean Git snapshot of
all 55 current Lua modules. That test builds and extracts both distributions,
loads fresh configuration using real Lua 5.4 and real temporary files, and checks
that existing numeric/X root settings take precedence. Only the disposable
fixture receives a commit; the user's working tree remains unchanged by that
operation. The first test draft used the display label Kindling instead of the
configuration enum EmitFlame; validation rejected it and the fixture was fixed.
No actual release was committed, published or installed.

Still open: current-candidate native UI/installation/performance acceptance;
all other standing behavior and multiplayer gates; and async qualification.
An existing async-trial/launch.lua or remote.txt survives a merge install.
Exclusion from a fresh ZIP is not deactivation of a previous trial. Trial-to-release
migration must recover/preserve journal-backed settings before removing its
launcher; do not silently delete or bypass it. The clean-source release guard
continues to reject the current uncommitted tree.

Independent frozen-source review: PASS, no blocking payload findings. Full offline
Python suite: 502 tests, 421 passed and 81 native tests explicitly skipped. Evidence:
`test-results/release-package-20261011-python.log`. Expected mocked server-control
failure messages in this log are negative tests, not real server starts or stops.


## Orphaned async trial recovery fence — October 11

Fixed startup falling back to legacy settings when async-trial/launch.lua is
missing but the installer's async-trial/receipt.lua remains. A present receipt,
unknown read result, or thrown probe now holds the shared settings gate with
restart-required presentation. Receipt content is never executed. Both legacy
flushes and scheduler admission remain blocked. Missing launcher AND positively
missing receipt still permits an ordinary clean installation.

Real main-composition regression covers receipt presence, denied open, thrown
open, failed close, and the clean-install control. All 210 Lua regression scripts,
55-module compilation, structural check, and 14 release/package tests pass.
Removing the new guard in memory causes the new regression to fail. Evidence:
`test-results/orphan-trial-20261011-lua.log` and
`test-results/orphan-trial-20261011-package.log`.

Limitations: this is a protective fence, not a rollback/export implementation.
Deleting both launcher and receipt cannot establish that external journals are
absent or older; this guard cannot detect that situation. Preserve the entire
trial tree and journals. No native installation/restart or settings migration
was performed. Controlled journal-to-legacy export and upgrade acceptance remain
open, alongside the standing async qualification and release gates.


## Read-only journal export proposal — October 11

Added tools/settings_journal_export.py. It captures both A/B pairs with bounded,
identity-checked repeated reads, validates native record framing/SHA-256/scope,
and invokes the actual Lua 5.4 typed codec and canonical serializers for EVERY
present generation. The export policy is intentionally stricter than runtime
recovery: any damaged/foreign/unsupported present peer blocks export rather than
falling back to an older record. Equal-generation differing payloads also block.
Each stream must have a valid record; explicit missing peers are allowed.

A closed-process read-only run against the current local trial journals selected
priorities generation 8/B (2,918 canonical bytes) and limits generation 11/A
(262 bytes). Source entries, identities, hashes and canonical bodies are retained
in test-results/journal-export-readonly-20261011.json. Pre/post process absence
and repeated source equality passed. These observations are not an exclusive
writer lock or current-world ownership proof. No source file was changed.

Eight regressions cover newest selection, explicit absence vs omitted paths,
invalid present peers/checksums/inner scope, X preservation, equal-generation
conflict, read errors and unstable capture. This is an export PROPOSAL only:
replacement_allowed, live_scope_verified and cross_stream_transaction_verified
are always false. The bodies are scoped candidates, not complete legacy files.
Legacy rows outside this scope, deletion/Pal membership, runtime guild aliases,
backups and atomic two-stream cutover still require explicit reconciliation.
No launcher was removed and no rollback/async-release acceptance is claimed.


## Reconciliation and complete offline bundle — October 11

Completed the larger read-only export preparation block and full tests. See
[export evidence and remaining cutover requirements](settings-export-2026-10-11.md).
Actual unchanged local files produced a verified review-only bundle: 41 priority
rows, two limits, generations 8/11. Membership comes only from journal-listed
keys and remains explicitly unverified; no replacement grant or live cutover.

Fixed the shared offline guard missing PalServer-Win64-Shipping-Cmd by recognizing
the whole client/server process families. Independent review caught disjoint
canonical/runtime alias groups in reconciliation; both are now rejected even
with no overlapping item rows. 211 Lua scripts and 55 compiled modules pass;
525 Python tests complete with 444 passes and 81 native skips. Structural checks,
three negative controls and both independent reviews pass. No gameplay/deployment
or native settings writes occurred. Safe two-stream cutover, ownership/deletion
coverage, interrupted-restart recovery and native acceptance remain open.


## Interrupted cutover fixture and startup fence — October 11

Added the production .settings-cutover startup fence before settings recovery or
trial inspection, plus a disposable-only two-stream filesystem transaction.
Recovery replaces all eight legacy paths with checked new generations; copied
trial markers retire only after complete verification; the fence is removed last.
42 injected boundaries, partial writes, uncertain replacements and three fresh
Python subprocess recoveries pass. A temporary copy of the actual review bundle
also completes without following live source paths or modifying game files.

Independent review found unsafe automatic temporary cleanup; replaced it with
explicit identity/path-checked cleanup and verified that refused cleanup cannot
later delete a replaced root through garbage collection. Final review passes.
211 Lua scripts/55 compiled modules and structural checks pass. Final Python:
535 total, 454 passed, 81 native skips. See
[full scope and evidence](settings-cutover-fixture-2026-10-11.md).

This is NOT an installed/native cutover or public async enablement. Target guard
installation, verified current/historical scope coverage, stopped-writer ownership,
real interrupted-restart/rollback acceptance and broader release gates remain open.


## Deployment recovery protection and installed guard — October 11

The ordinary deploy.ps1 previously allowed replacement or -Remove while an
async launcher, orphan receipt, or interrupted-cutover marker existed. Added
positive-absence checks before mutation and again after compilation/before
activation preparation. Existing marker directories also refuse. Independent
review found that DirectoryNotFound could conceal an async-trial regular-file
ancestor; ancestor type validation now rejects that case too. Access/unknown
errors refuse. Checks are sampled, not an exclusive lock against another writer.

14 real PowerShell fixture tests pass, covering all three marker paths as files
and directories, deploy/remove, invalid ancestors, and marker creation during
both compiler calls. The new regression failed against the original installer.
Independent final review passes. Evidence: deploy-recovery-20261011-before.log
and deploy-recovery-20261011-python.log in test-results.

Installed-source audit found 16 changed/missing repository modules. Full current
main.lua ALONE is incompatible: installed modules lack flush-receipt, storage
transport and deferred publication APIs. Do not use the ordinary installer to
bypass the new guard or manually delete trial markers.

A minimal backport changes ONLY the startup guard block on the installed main
baseline. All 53 captured installed modules compile; 13 focused composition
cases pass. The unpatched baseline fails the actual new fence assertions.
These use memory filesystem/native mocks, not native acceptance. Two independent
reviews agreed on baseline compatibility. See
 test-results/startup-guard-backport-20261011/.

Installed the reviewed guard-only main while game/server process families were
absent. Exact original code, active stage, bridge DLL, legacy files, journals,
launcher and receipt were backed up before a single atomic main replacement.
All other 98 protected files and the complete eight-path legacy snapshot remained
unchanged. Evidence:
 test-results/startup-guard-install-20261011-d7ef2d56/installed.json.
Installed main SHA256:
2117d62226d9e7f72dc6ab7504565d3dcf18a09852f50358a9c40f06e4d78132.

No game was launched, no journal/setting cutover occurred, and the existing
checked local trial remains armed. Public/default and dedicated async stay off.
This install is intentionally NOT the full repository candidate. Native startup
acceptance, current/historical ownership coverage, cutover and full release gates
remain outstanding. The backport runner's postcheck is bound to the pre-install
baseline; after this install use its captured fixture evidence, not that stale
live-baseline equality check as a new compatibility verdict.

Final full Python suite: 538 tests, 457 passed, 81 native skips (162.436s). Native skips remain unverified, not passes.


## Native installed startup guard acceptance — October 11

Ran three local client launches against the installed guard-only backport
(main SHA2117d622...), game1.0.5.102999. Evidence directory:
`test-results/startup-guard-native-20261011/`.

1. Normal existing-world recovery: expected storage/guild, limits generation11
   and priorities generation8, initialization=false, both saved/available.
   Normal quit verified both native owners drained/joined/cleaned. Four journal
   files and all eight legacy recovery entries remained byte-identical.
2. Own diagnostic .settings-cutover marker, title-screen startup: expected fence
   error, settings unavailable, no trial armed/started. Normal quit; unchanged
   journals/legacy verified. Removed ONLY the exact diagnostic marker after
   stopped-process checks. This was not an interrupted real cutover.
3. Normal restart afterward: both streams recovered again in the same scope,
   followed by normal verified quit. Scripts/runtime/launcher/receipt and all
   settings bytes still unchanged. No native process remains running.

The first scheduler stress run FAILED/unverified (five assignments/current
workers lacked evidence). Preserved as passes.json; never converted to a pass.
On the third launch, an early census found14 unavailable actors; after loading,
all14 direct readers resolved, with four reserved jobs. This supports transient
loading as a hypothesis, not a proved explanation of the first run's five
unknowns. A NEW stress run after settled evidence completed13/13 command-bound
live passes in30.703s with the unchanged acceptance criteria. Reserved jobs do
not prove occupied/completed work. The independent observer agreed on the
narrow recovery/cleanup verdict and on preserving the initial failure.

No priorities/limits were edited, and no new commits were admitted by either
journal writer (accepted=committed=0 on both normal exits). Native marker presence
refusal is now exercised; unreadable-marker faults remain offline-only. No
native file-read tracing, actual interrupted two-stream cutover, game-crash or
power-loss acceptance, stand visual/input acceptance, production output evidence,
or frame-time capture is claimed. Public/default and dedicated async remain OFF.


## Native synthetic interrupted-cutover recovery — October 11

Evidence: `test-results/cutover-native-20261011/`. The isolated dedicated
fixture used the pinned manual UE4SS runtime and 55 production Lua modules,
with scheduling disabled/dry-run and no native writer DLL. All settings were
synthetic and stored in an owned temporary directory; the real client trial,
journals and legacy settings were not targets of this experiment.

- Interrupted the disposable transaction after replacing `caps.txt`, leaving
  mixed generations behind the checked `.settings-cutover` marker. A fresh
  native boot executed the production entry through a synchronous observer.
  It reported restart-required, both settings unavailable, and zero opens of
  the eight exact settings paths and two exact trial paths. All eleven snapshot
  entries remained identical after normal REST shutdown.
- Resumed the persisted checked plan in a fresh Python process while the server
  was stopped. All eight recovery files matched the desired envelopes; both
  synthetic trial files were retired afterward and the marker removed last.
- A second accepted fresh native boot read the recovered files: gate ready,
  both states saved, eight settings opens and two missing-trial probes. Both
  serialized bodies matched independent expectations, including an X edit,
  unrelated preserved X, a guild OFF override and unrelated wildcard limit.
  All eight files stayed exact after normal REST shutdown.
- Restored the original dedicated server installation and Saved directory.
  The fixture restoration receipt verifies exact original hashes. No game or
  server process remained. The observed fixture is archived, not deleted.

The first fenced boot exposed a missing terminal newline in the observer; its
concatenated record is retained as `fenced-first-framing.log`, not accepted.
The observer and regression were corrected, then the fenced boot repeated.
The strict parser requires a complete nonce/phase-bound record and exact bodies;
its eight test methods include malformed/truncated/duplicated records, failed
states, invalid counts, zero-read recovery and snapshot mismatch controls.
`acceptance.json` records both accepted observations with source-log hashes.
Parser results explicitly do not confer ownership, activation or replacement
permission; interruption and restoration evidence are separate fixture records.

Scope: one deliberate interruption boundary (`after-replace:caps.txt`) on a
synthetic two-stream cutover. Open counts cover exact paths only during the
synchronous production entry, not subsequent callbacks or OS-level tracing.
This is not a game crash, physical power loss, live-settings migration, native
async writer test, production-output test or performance measurement. Remaining
live ownership/deletion coverage, ordinary installation/rollback and other
release gates stay open. Public/default and dedicated async remain OFF.

Final Lua validation: 212 regression scripts passed; 55 production modules
compiled. Final Python suite: 546 tests, 465 passed, 81 native-dependent skips, zero
failures (155.287s). Skips are not native acceptance. Independent review passed
the native observations, source-log hashes, restoration evidence and scope
limitations. The original malformed native record was separately confirmed
rejected by the strict parser. No public release or default async enablement.


## Export coverage inventory and rollback boundary — October 11

Added `tools/settings_export_coverage.py`: a read-only audit of a verified export
bundle. It uses the actual Lua recovery selector and typed decoders, includes
both retained priority-journal slots, distinguishes claimed target/foreign and
unclaimed keys, and reports exact added/removed/changed row counts. X is a value,
not absence. The report is bound to the verified manifest and candidate hashes;
changed artifacts or manifests during the audit fail. Source paths in captured
metadata are never followed. All ownership/deletion/activation grants remain false.

Actual reviewed bundle: 15 shared Pal keys; no legacy-only, journal-only or
older-peer-only keys; zero priority rows added/removed/changed in the proposed
candidate. Claims still originate from journal keys and remain unverified.
Retained A/B slots are not complete history. The installed eight legacy paths,
four journal files and both trial entries still matched the captured bundle on
fresh repeated offline reads. Sampled process absence is not an exclusive lock.
Evidence: `test-results/export-coverage-20261011/{coverage,freshness}.json`.

The independent review confirmed a key limitation: the existing paired native
membership reader can confirm a current target-guild member, but cannot classify
an absent key as transferred/deleted/unloaded. It permanently revokes its adapter
on a rejected lookup; a per-key observation therefore needs fresh readers and
must preserve unresolved outcomes rather than infer deletion.

Rollback must not blindly restore a pre-trial snapshot: that can discard newer
journal edits. Rearming an old trial after legacy edits can also discard those
newer legacy settings. A simple inverse transaction requires exact unchanged
cutover-state checks; otherwise preserve both histories behind the startup fence
and reconcile newest durable states, including all eight legacy recovery files.
No live rollback operation or default async enablement is added here.


Added `experiments/settings_export_membership_observer.lua`, a pure one-shot
observer bound to a manifest SHA-256 and a sorted unique union of at most 256
native Pal keys. It brackets each fresh reader factory and lookup with exact
session/authority-context reads, detects retained-argument mutation and reentry,
and downgrades prior confirmations if the sample becomes invalid. One rejected
membership adapter does not poison subsequent independent readers. Outcomes are
`current_target_confirmed`, `unresolved`, or `not_examined`; `complete` means all
keys were attempted under stable context, not that every key was confirmed.
Providers must still be wired to fresh native readers; this module performs no
engine discovery, IO, installation, writer activation or deletion itself.

Prepared `test-results/export-coverage-20261011/membership-request.json` bound to
the actual reviewed manifest and exact 15-key union for a future read-only native
run. This is a request, not an observation. Prior native ownership runs are not
reused as current evidence. No game or server was launched in this work block.

Independent collector review passed, including four extra adversarial in-memory
cases. The regression exercises the real membership adapter's terminal-rejection
behavior and a negative control that removes late-context revocation and makes
the test fail. All 213 Lua regression scripts and 55 production compilations pass.
The coverage audit's 10 focused Python tests pass. Full Python: 556 total, 475 passed, 81 native-dependent skips, zero failures
(160.230s). Skips do not establish native acceptance. Hash-bound validation:
`test-results/export-coverage-20261011/validation.json`.


## Bundle-bound native membership observation — October 11

Implemented the isolated one-shot `experiments/export-membership-live/main.lua`,
strict analyzer, and checked installer. The runner uses the proven Pair/local
Authority route and a fresh paired direct reader for each requested Pal. It
waits for the requested world, binds a complete scalar native context, takes
three samples, then stops; late identity changes and callback errors terminate
the run. The analyzer requires the exact nonce, manifest, scope, alias, ordered
key set, stable native identities, all three samples and a complete done record.
An unresolved lookup is not a deletion or ownership grant.

Pre-native review found an installer failure-after-enable edge case. Fixed
cleanup of the exact installer-owned enable/arm files; all eight installer
regressions pass, including a write that succeeds then raises. An initial
mutation-test assertion also blocked preflight; corrected and repeated before
installation. The runner passed independent review and its simulated output
passed the actual strict analyzer. No failing preflight installed a probe.

Native evidence directory:
`test-results/export-membership-b27c6af221b74ec6b33b479653db6f61/`.
Game 1.0.5.102999, pinned UE4SS runtime, existing checked local trial unchanged.
Launched normally, loaded Palpagos Islands, and observed all15 expected Pal keys
as current-target-confirmed in all three samples. Zero unresolved, stable world
and native identity fields, 50 complete log records. Independent analysis agreed.
Native log SHA256:
`9bf4b36989138ea999a40f3a2a77fc60671b8fe581d56fbe6853172353d5814e`.

Returned to title and quit normally. Existing limits/priorities owners reported
joined/cleaned, accepted=committed=0, generations11/8. Exact production hashes,
all eight legacy paths, four journals and both trial entries matched the original
bundle afterward. The one-shot probe was disarmed and moved outside Mods into
`UE4SS/PWPDiagnosticArchive/`; no original probe or player file was deleted.
The archive-parent absence initially stopped archival before any move; created
and checked the owned parent, repeated all checks, and completed the move.

This closes the current-membership observation for this exact bundle/key union
at this run. It is not durable historical ownership/deletion coverage, exclusive
writer ownership, live migration, rollback, crash recovery or performance proof.
No settings were edited and default/public/dedicated async remain OFF. The next
cutover requirements are stopped-writer exclusivity, a reviewed rollback that
preserves newer edits, and native acceptance of the actual coordinated change.

Final validation for this block: 214 Lua regression scripts passed, 55 production
modules compiled; 575 Python tests, 494 passed, 81 native-dependent skips, zero
failures (177.007s). Independent post-run review matched 4,152 protected files
and the exact settings snapshots. Skipped native tests remain unverified.


## Rollback recovery — October 11

Implemented a disposable-only rollback in `tools/settings_cutover_fixture.py`.
It admits only an exact completed cutover, persists a separate plan-bound intent,
refuses stale forward resume after rollback, preserves unknown/newer edits by
refusing mutation, and restores originally absent paths to absence. All eight
legacy recovery paths restore before either trial entry; the startup fence is
removed last after exact verification.

Independent code review passed with no blocking findings. The implementation
agent's 12 rollback regressions pass, covering 38 fault boundaries, partial
staging, uncertain replacements/deletions, newer edits and four fresh-process
recoveries. Its 10 existing forward tests also pass. An in-memory admission
bypass makes all six admission subcases fail, so the admission regression is
not satisfied by an inert or unrestricted rollback. Raw agent test output was
not saved as a separate file; that provenance is explicit in review.json.

Main separately tested a disposable copy of the actual bundle, interrupted
after restoring caps.txt, then recovered in a fresh Python process. All ten
original entries matched exactly, including five originally missing files.
The temporary copy was cleaned only after verification. Readback of the live
installation still matched all eight legacy entries, four journals and both
trial entries. No game files were written and no game was launched.

The broader Python complement passed: 565 tests, 484 passed, 81 native-dependent
skips, zero failures (92.615s). The separately run forward/rollback suites cover
the two excluded modules; they are not omitted acceptance coverage.
Evidence: `test-results/cutover-rollback-20261011/`.

This closes disposable exception/process rollback recovery, not native rollback,
power-loss durability or exclusive writer ownership. Default/public/dedicated
async remain OFF. The next gate is a reviewed installation-bound writer fence
and native acceptance of coordinated forward/rollback recovery; process absence
and exact-byte checks alone are not exclusive ownership.

Main final focused run also passed: 22 tests, zero failures (359.033s).
Combined with the disjoint Python complement: 587 tests, 506 passed, 81 native
skips, zero failures. Source hashes and counts: `test-results/cutover-rollback-20261011/validation.json`.


## OS transaction lock and native rollback — October 11

Added the share-zero Windows transaction lock and directory/ancestor pins to
all three disposable migration/recovery entry points. Eight real Windows tests
pass; independent review found no remaining blocker. Cooperating migration
processes are excluded. Unrelated writers are not covered by the lock.

The isolated native rollback trial also passes: interrupted mixed recovery
files produce restart-required with zero settings/trial reads; fresh-process
rollback followed by a second native boot loads exact original priority/limit
bodies (eight settings reads, two missing-trial checks). Both normal shutdowns
retain exact bytes. Server restoration hashes match, independently verified.
Real client legacy files, journals and trial files remain unchanged.

Evidence and limitations: `docs/native-rollback-2026-10-11.md` and
`test-results/rollback-native-20261011/`. Synthetic original launchers are absent;
this is not native async-writer crash/power-loss proof or a real client cutover.
Public/default/dedicated async remain OFF. Installation-bound stopped-writer
orchestration, freshness and the applicable real-trial migration gates remain.

Final disjoint regression totals: 600 tests, 519 passed, 81 native-dependent
skips, zero failures. This includes 570 complementary Python tests, 22
forward/rollback tests and eight real Windows lock tests; the complementary
run explicitly excludes the other three modules. Native boots are separate
evidence, not counted as additional unittest cases. Five native-orchestration
gate tests are included in the complementary run. Counts/provenance are in
`test-results/rollback-native-20261011/validation.json`.


## Fixed installation binding and marker-only rehearsal — October 11

Bound the actual client installation to the pinned guard/runtime, reviewed
4,152-file inventory, bundle, membership observation and all settings/journal/
trial states. Review caught and corrected initial dependency tampering being
accepted as a fresh baseline. The new 23 regressions pass.

An actual marker-only rehearsal passed, including a second process refused by
the held installation lock (Windows sharing error 32), exact marker removal,
and unchanged payload readback. No game launched, settings changed or launcher
retired. Empty persistent lock artifact remains. Evidence and boundaries:
`docs/installation-fence-2026-10-11.md` and
`test-results/installation-fence-rehearsal-ee617305021f456681bde48f571f9aa2/`.

This closes binding and marker lifecycle rehearsal on the real installation,
not data cutover. Third-party deployment/code-write races still need protection
before replacement; the cooperative lock is not a universal file-write barrier.
Historical membership/actual trial migration gates remain separate. Public async
is still OFF and the checked local trial is unchanged.

Independent post-rehearsal review passed: one full binding recheck confirmed
all 4,152 protected files plus the exact settings/journal/trial states, absent
marker, empty regular lock file, and matching intent/completion evidence.
No contradictions found; this remains a marker-only result.

## Existing-file exclusion rehearsal — October 11 follow-up

Added and tested Windows read handles denying writes/deletes on the reviewed
existing mod inventory and runtime throughout the marker-only cycle. All 23
focused regressions pass. The actual installation rehearsal passed: eight
nonmutating write/delete access requests from a separate process were refused
with sharing error 32; full post-run binding matches all 4,152 protected mod
files, runtime and legacy/journal/trial states. Marker removed; game/server
remain stopped; player data and local trial unchanged.

This closes competing writes to those existing held objects during rehearsal.
It does not reserve absent paths, prevent all new children, pin every external
dependency, or authorize payload replacement. New-child drift is explicitly
tested to fail the final check and retain the startup fence. A real payload
transaction still needs safe handling of writable and absent destinations;
historical membership does not supply a fresh ownership/deletion grant.
Public async remains OFF. Evidence and limits:
`docs/installation-fence-2026-10-11.md` and
`test-results/installation-fence-rehearsal-0d44ee402a6b4f6291bf1c5c2583cd70/`.

## Writable destinations and missing-file reservations — October 11

Implemented a disposable-only same-handle writer with exclusive CREATE_NEW for
missing destinations. All eight recovery paths are held before payload writes;
newer edits are checked against immutable originals. Review found and fixed a
baseline-adoption race, with a regression and a failing negative control.
Sixteen focused tests pass. The actual review-bundle copy experiment reserved
five missing files, verified eight candidates and refused all sixteen competing
write/delete operations. All fourteen real legacy/journal/trial entries stayed
unchanged. No installed payload was written and no game was launched.

The copy retains its startup fence and trial files. This is not atomic multi-file
activation or automatic crash recovery. A crash between name reservation and
receipt publication remains an explicit recovery-design gate; the prior native
rollback test does not establish durability of this new write path. Public async
remains OFF. Evidence and failure-accounting:
`docs/destination-leases-2026-10-11.md`.

## Staged missing-destination recovery — October 11 follow-up

Closed the tested publication-before-progress gap using identity receipts
flushed before a no-replace, same-handle rename. Explicit disposable recovery
handles both prepared empty scratch and already-published known objects, while
refusing replacements, unknown bytes and incomplete receipts. Twenty-nine focused
tests pass, including separate-process interruption/recovery and a failing
identity-check negative control. Review-triggered plan/trial admission races
were fixed and tested.

Both before/after-publication scenarios also passed on fresh copies of the actual
review bundle. All eight candidates verified with the same reserved identity;
all fourteen actual source entries were unchanged. No game launched, installed
settings written, trial retired or public async enabled. Native acceptance of
this new recovery path and actual cutover sequencing remain open.
See `docs/staged-reservation-recovery-2026-10-11.md` and
`test-results/staged-recovery-20261011-f36683d29456407aaef569fc5f77f882/`.

## Native staged-reservation recovery — October 11 follow-up

Two isolated synthetic dedicated-server boots now verify the new path: the
publication-before-progress interruption reads no settings/trial files, then
explicit recovery loads exact X/OFF candidates while preserving unrelated rows.
Both normal shutdowns preserve all tracked bytes. The original server is restored
with matching hashes, and all fourteen actual client entries remain unchanged.
Twelve runner regressions, eight parser tests and the Lua observer regression
pass; all 55 production Lua modules compile. Four controls against the actual
native record reject old values, a stale nonce and failed entry.

This closes native candidate recovery acceptance only. New-path rollback,
live installation sequencing, trial retirement and fresh ownership/session
evidence remain open. No power-loss or general process-exclusion claim is made.
Public/default and dedicated async remain OFF. Evidence and exact limits:
`docs/staged-recovery-native-2026-10-11.md` and
`test-results/staged-recovery-native-20261011/`.
