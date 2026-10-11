# Current open issues â€” September 23, 2026

Current consolidated checklist: [October 9 release gates](release-gates-2026-10-09.md).
The entries below are chronological evidence, not the current completion checklist.


Consolidated after the 22:24 editor-cancellation retest. Candidate: unpublished 0.5.0-rc1. This supersedes historical wording about still-open defects where newer native evidence exists; it does not erase the historical test records. Public-report coverage is the September 23 Steam delta and September 15 Nexus review, not a fresh online census.

## Frontend â€” next dedicated workstream

October3 [authority identity observations](async-save-authority-2026-10-03.md):
two local-host boots separated by one normal restart exposed the same selected
save-directory ID, matching one account/world Level.sav path, with fresh gameplay
authority and loaded-world=true. Autosave-name stayed empty. The selected ID also
appeared on Title before load, so it alone cannot authorize storage. Fresh-process
RAM return exposed empty fields, stand restored, controls off and production
hashes unchanged. Startup-session authority was excluded from evidence after
independent review. Same-process switching and dedicated-server identity remain
unverified; production async saving remains gated.

October3 [save identity/recovery boundary](async-save-identity-2026-10-03.md):
read-only client probe completed through RAM join; both candidate identity
properties remained empty in Splash/Login/Title/MainWorld5. No identity was
promoted to verified. New isolated copied-read classifier refuses nil/ambiguous
existence as absence; queue regression proves defaults cannot be written after
that failure. 91 Lua suites pass. Diagnostic off, stand restored, production
hashes unchanged. Authoritative save-directory verification and positive absence
evidence remain required; no production async integration or performance claim.

October3 [scoped native save/handover](async-save-scoped-2026-10-03.md): V6
canonical world/guild/stream binding and monotonic owner epochs pass native
scope-matrix, restart/readback and reentry tests. 88 Lua suites pass, including
30 driver fault cases. Separate local live trial passes exact 64KiB native IO,
retirement while Busy, drained handover, stale request/ack refusal and retained
result across RAM join. Timer cancelled, controls disabled, production hashes
unchanged. Native singleton enforcement, real storage identity, read-error
classification and production migration/acknowledgements remain open. See report
for narrower GC-interleaving coverage limits; no new frame-time claim.

October3 [native save ownership/mailbox](async-save-mailbox-2026-10-03.md): V5
fixed-slot coordinator binds one immutable owner, reserves/copies requests before
return, retains terminal results and checks exact idempotent acknowledgements.
Native build/reload/restart/cook pass, including completion-callback reentry and
pending teardown/GC. Independent review prompted atomic admission and two stronger
test assertions; 87 Lua suites pass. Local isolated live trial passes exact64KiB,
native guards and unconsumed-result travel/ack through RAM join; diagnostic off,
stand restored and production hashes unchanged. Native global uniqueness,
dynamic scope binding, safe owner turnover and production integration remain open.

October3 [async-save lifetime gate](async-save-lifetime-2026-10-03.md): separate
V4 rooted coordinator built and locally installed, exact 64KiB native write/read
passed in Palworld and survived into the RAM gameplay world after normal restart.
Native fixtures also pass pending-world-teardown and readback-GC checks. Two
UE4SS API mismatches and an overly broad travel assertion were caught and fixed;
86 Lua suites pass. Diagnostic disabled, timer cancelled, production hashes
unchanged. This resolves the bounded lifetime experiment only: native scoped
ownership/retained completion mailbox, real recovery faults, migration and durable
network acknowledgements still block production async integration.

October3 [scoped save transport](async-save-transport-2026-10-03.md): exact
world/guild/stream slot separation, full completion identities, retained mailbox
acknowledgement and foreign-record refusal implemented outside production.
85 Lua suites pass against a reference backend; native implementation still
requires ownership surviving world teardown and a retained terminal mailbox.
Inline-completion receipt retagging caught by review is fixed and regression-tested.
No installation or real-settings migration was performed.

October3 [save-session controller](async-save-session-2026-10-03.md) implemented
behind an isolated development gate: accepted/durable revisions, coalesced
completion ranges, timeout ownership, retired-session draining and shared backend
lease.84 Lua suites pass; five compiled unsafe mutants rejected, including both
reentrancy defects caught by independent review. No production
Scripts or deployment changed. Native scoped storage/migration and network
generation ACK integration still gate real settings and an in-game retest.

October2 [populated V3 warm/recovery trial](async-save-events-warm-2026-10-02.md):
24 exact distinct records through64KiB,24 completion hooks; final23/24 recovered
after restart. Both scratch controls verified DISABLED; client restored at stand;
production writer unchanged. Five-minute capture51,343presents, displayed max38.1ms,
none>50ms, but no matched control/server-clock alignment. Async storage tail1.505s
remains;24 dispatch lookups553ms total. Queue ownership, truthful durable states,
real IO faults and production integration remain gates. Independent review agrees.

October2 [V3 completion-event prototype](async-save-events-2026-10-01.md):
FTP recovered; three FAILURE boots completed (three hooks each), then exact
generation-1/32-byte READFAIL passed after controlled restart. Completion uses
copied event data with no polling bridge lookup. Both V2/V3 controls read back
DISABLED; production writer hash unchanged. All83 offline suites pass; independent
review confirms narrow one-slot/null-input/restart coverage only. No frame-time
or production-integration claim. Real IO faults, interrupted writes, uncertain
operation ownership, queue integration/migration/ACKs and populated V3 acceptance
remain open. The prior provider-access blocker is resolved.

October1 follow-up [idle lookup reduction](async-save-idle-2026-10-01.md): idle
harness lookups removed; unique24-record WARM protocol and explicit READWARM.
All81 regression scripts pass, including12 simulated interruption/failure cases.
Native24/24 records verified; final23/24 recovered after restart; disabled again,
client restored. Lookup time7999->1255ms across trial (-84.3% descriptive),49
resolutions=24 requests+25polls. New completion outlier703ms remains; client capture
has no interval above50ms but scene/display cadence differs, so no FPS gain claim.
Production writer unchanged. Native fault injection and cheap completion delivery
still gate real integration; this optimizes the experiment, not released saves.

October1 [warm async-save native trial](async-save-warm-2026-10-01.md): FTP bypassed
broken web listing; checked scratch driver/metrics deployed. Three paired rounds
completed 24 exact synthetic readbacks, then A7/B8 survived a controlled restart.
Both WARM timers cancelled; flag verified DISABLED; client returned to stand.
Independent PresentMon capture: 49,979 presents, p99 7.9962ms, max28.967ms;
displayed intervals max33.3658ms, none above50ms. No phase clock alignment or
universal stutter-free claim. Engine completion median68.801ms, max204.240ms;
harness lookup overhead ~24ms/callback remains substantial. Production writer
hash unchanged. Fault/interruption tests, cheaper completion observation, distinct
operation identities, queue integration/migration/durable ACKs remain open.
All80 offline Lua suites passed before deployment. One reconnect announcement
throttle warning observed; full limitations and raw evidence linked above.

September29 [V2 async save/read RAM trial](async-save-ram-2026-09-29.md): separate
driver/pak installed and hash-verified; eight synthetic writes read back exactly,
then both final A/B records recovered after another server restart. Trial disabled
and both timers stopped; production writer unchanged. All79 Lua suites pass.
Enqueue printed0–1ms at unmeasured clock resolution, but one asynchronous completion
took1123.722ms. No frame evidence or stutter-fix claim. Warm/populated tests,
storage faults, queue integration, safe migration and durable ACK handling remain.

September29 [save flush/close diagnostic](save-flush-2026-09-29.md), installed and
native-tested after restart: eight edits reproduced 1197/2237ms stalls during
explicit buffered flush; subsequent close stayed below timing resolution.
Six ordinary saves averaged4.5ms. This narrows the blocking phase, not the
OS/hosting cause, and is not a fix. Backups and checked saves remain intact;
77 suites pass. Original priority restored, profiler off20:01:48. No async writer
has been installed; thread-safety and truthful durable acknowledgements are gates.

September29 implemented [transmitter-first broadcast discovery](transmitter-first-2026-09-29.md):
77 regression scripts/51 compiled modules pass;290 new discovery cases with fail-before
scan evidence. Source/client/server hashes match. Native four-edit test eliminated all
four component scans; delta110→83.5ms mean (~24% lower). Ordinary edits274–280ms,
but one738ms edit contained478ms in file close. Overall mean392ms; intermittent save
stall remains open. Priorities restored, profiler off19:49:02. Multi-peer native and
frame-time acceptance remain open; no stutter-free claim.

September29 root-cause investigation: [edit latency and upstream research](edit-latency-root-cause-2026-09-29.md)
accounts for the approximately303ms changed-edit callback through repeated discovery,
two complete roster reads, checked saving and immediate scheduling. The steady
changed path has roughly11 searches; the children route still searches for a
controller on RAM. Independent review recommends transmitter-first recipient
discovery with exact-peer matching and one lazy fallback as the next bounded
optimization, targeting one25.5ms scan. Subsequently implemented and measured above.
The69ms file-close event remains an operation-level observation, not a host diagnosis.
Server callback latency and client frame stutter remain separate acceptance gates.

September29 deeper edit-path review: removed a second sender-guild lookup using
invocation-bound plain data and fixed stale acknowledgements after session/peer
replacement. Independent review cleared the final change; all73 suites pass.
Installed after GPortal recovered: four native edits confirmed; four deltas,
no full broadcasts. Three edits304-308ms versus earlier441-444ms, but one577ms
edit included278ms in saving. Original priorities restored; close/reopen passed.
Profiling off. The2456ms outlier remains unexplained; no stutter-free claim.
[Scope, safety checks and remaining gates](edit-context-2026-09-29.md).

September29 follow-up: checked per-operation save timings installed and tested
after a full macro restart. Four saves4-5ms; edit hooks274-282ms in a night/idle
scene. No save spike reproduced; backups and verification remain intact.
All74 suites pass. [Detailed evidence and next target](save-phases-2026-09-29.md).

September29 next live window: stand delta111ms mean splits into roster58.75ms,
component scan26.5ms and transmitter discovery25.5ms. Encoding/send below
observable precision. Four edits278-351ms; a73ms save included69ms closing
the temporary file. This locates one slow operation, not its underlying cause.
Original priority restored, profiling off,75 suites pass. No new speedup claim.
[Measured phases and safe next-change constraints](push-phases-2026-09-29.md).

September29 safety prerequisite: broadcast invalidation regression failed before
the fix. Session/peer/nonce/authority/nested-push guards now stop stale sends and
revision commits, including native preparation boundaries. All76 suites pass;
installed hashes match and native1→2→1 smoke passed. Delta110ms mean remains:
duplicate roster optimization is deferred, not claimed fixed. Profiling off.
[Regression and live evidence](push-lifetime-2026-09-29.md).

September25 multiplayer roster observation reproduced stale native Pal details
when hovering modded priority cells. Hovering untouched battle checkboxes
selected the correct Pal without edits. Both full roster passes and the
confirmed missing assignment-reader blocker are recorded in
[Pal activity evidence](pal-activity-2026-09-25.md). All nine assignments were
unverified and the server sent zero permission requests during the sampled
passes; plausible native activity is not priority-scheduler acceptance.

September25 removal confirmation now binds current value/guild, rejects stale
queued values and clears on close/navigation. All70 suites pass.
[Evidence and remaining concurrency limits](remove-conflict-2026-09-25.md).

September25 editor reflow: removed/off-page rules could leave an editor over a
different row. Current-page layout ownership and immediate draft cancellation
now cover this, while preserving still-visible moved drafts. All69 suites pass;
[evidence and scope](edit-reflow-2026-09-25.md).

September25: fixed existing-item navigation opening the wrong Rules page and
selecting an unrelated amount. Multi-page27-rule regression, newer navigation,
guild-change cancellation and all68 suites pass; native Stone selection passes
with unchanged settings. [Evidence and remaining native matrix](rule-reveal-2026-09-25.md).

| Priority | Issue | Current evidence / required work |
|---|---|---|
| P1 gate | Remaining native input acceptance | September24 mouse and number/Enter routes now capture event-time targets. Native arrows have one owner; mixed mouse/number/controller mutations share FIFO ordering. 59 stand regressions pass. Initial live 5/X/1, single-step Right, focused Enter, modifier/panel isolation and Escape checks pass with settings payload restored. Physical held keys/controllers, right double-click, rapid focus/row recycling and populated multiplayer remain open. See [keyboard evidence](stand-keyboard-2026-09-24.md) and [mouse evidence](stand-pointer-2026-09-24.md). |
| P1 | Original Escape crashes, stuck/duplicate panels and photo-mode backdrop | Reported; specific causes not all reproduced. Latest amount-cancel/close path passes locally. Still test photo mode, bed, respawn, pause/inventory/map handoff, missing/duplicate pak and replaced widget trees. |
| P1 backend | Item-specific creation remains unavailable | September24 candidate now labels capabilities before selection and distinguishes legacy editing; initial native browsing/refusal/preserved-amount checks pass. No native producer adapter was added. See the separate producer-control release gate below. |
| P1 | Search/Add crash with modded catalogue | Nexus bug 1133489 remains unreproduced. Filtered indexing reduces exposure; it does not prove the crash fixed or implicate Cosmetic Outfits. Need crash context, exact versions and triggering operation/item. |
| P1 gate | Layout, pagination and rendering lifecycle | Earlier parent/cache fixes have simulated coverage and small native smoke tests. Rules 0/1/13/14/26/27, multi-page picker, long names/status, editor positioning and hidden/reused controls still need a full visual matrix. Test 16:9, 16:10, Deck, ultrawide and UI scale while retaining preferred position. |
| P1 gate | Edit feedback and responsiveness | Verify visible saving, pending, rejected, unavailable and incompatible states in real delayed/failing multiplayer. Measure click-to-visible response and first-open/search/page spikes. A briefly blank backdrop before redraw was observed after reopening; duration/impact unmeasured. |
| P1 gate | Held-key and controller/Deck input | Compiled held-key tests and Lua controller tests pass; actual repeat/release routing after editor collapse and physical B/D-pad/Steam Input remain unaccepted. Verify focus, cancel precedence and no input leaking underneath. |
| P2 | Clarity, readability and maintainability | Audit affordances, selected versus pending priority appearance, storage/base scope, legacy whole-work behavior, balanced versus strict mode, truncation and readable help. Panel remains 5652 lines and 194 top-level locals; continue separating layout/input/editing as touched, without a wholesale rewrite. These are review targets, not newly proved defects. |

## Core behavior and release blockers

September29: [priority-edit broadcast duplication](edit-broadcast-2026-09-29.md)
confirmed natively: 441-444ms callbacks include a ~108ms full broadcast inside
save, followed by a109ms delta. Scoped one-owner notification fix passes73
regression scripts and independent review; deployed files read back correctly.
After-fix native edit/restore/reopen smoke passed; timing retrieval is blocked
by GPortal management errors. The earlier2456ms
outlier did not repeat and remains unexplained. Normal server passes remain
about66ms; there is no stutter-free acceptance.

September26 follow-up: [PalPriority comparison and conditional transport](palpriority-comparison-2026-09-26.md)
implemented and native-tested on RAM. Six passes needed only one component
lookup (the single pass sending two changes). Mean66.2ms; unchanged passes
62.4ms; changed pass85ms. Authority/camp walks still dominate. No frame-time
or stutter-free claim; the prior85.6ms sample remains historical evidence.

September26 RAM timing: five full passes averaged85.6ms (89ms worst).
Camp enumeration, authority resolution and owned-component resolution each
averaged25.4ms; new assignment reads cost5ms across45 reads. These measured
server lookup spikes remain open, not covered by old stutter-free claims.
See [integration and timing evidence](assignment-reader-2026-09-25.md).

September25: a [read-only assignment census](assignment-reader-2026-09-25.md)
now exposes native job identity, camp, fixed flag and work state for acceptance.
September26 follow-up: the direct callback-local reader matched all nine native
census records (including ranching and a fixed furnace Leave reservation) and
is now wired on RAM. All72 suites pass. Missing actors remain unknown; new
candidate/fallback permissions require explicit non-manual evidence. Full
priority/output/staffing acceptance remains open; see the linked evidence.

September25: post-respawn stand reopening now observed with all nine rows and
priority numbers. A separate incomplete-panel-tree defect is fixed with failing
before/passing after regressions: unreadable advertised children/names cannot be
accepted as absent widgets or leave an active draft. See [tree evidence](panel-partial-tree-2026-09-25.md).
Death while editing and actual respawn-event invalidation remain open.

September24 [native emergency respawn](respawn-2026-09-24.md) passed with panels
closed beforehand: local authority remained correct, Production Limits and its
editor reopened, Escape/input recovered, settings stayed unchanged. Death while
editing, multiplayer respawn and post-respawn stand reopening remain untested.

September24 [photo/editor follow-up](photo-editor-followup-2026-09-24.md): no
dormant mod backdrop appeared in native photo mode after panel closure, including
HUD hide/restore. A separate reproduced stale-draft overwrite is corrected with
changed/deleted-rule regressions; all67 scripts pass. This does not provide
server-side concurrent-write protection. Respawn and the full layout matrix
remain open.

September24 [native handoff checks](panel-handoff-2026-09-24.md) passed whole-panel
Close with an unfinished amount draft, stand/map focus restoration and subsequent
pause/inventory access. Saved settings stayed unchanged. Photo mode, bed,
respawn and other lifecycle paths remain open; no blanket crash-free claim.

The subsequent [native reconstruction guard](stand-close-events-2026-09-24.md)
uses the runtime's actual UUserWidget Construct/Destruct overrides, not the
inapplicable Pal/CommonUI hierarchy from the older modding kit. All65 stand
checks pass. Two same-process Escape/V reopen cycles advanced native event
counts 0â†’1â†’2 and restored visible priorities; settings remained unchanged.
Pure hide/show without construction or row rebinding remains unverified.

September24 lifecycle follow-up: same-Pal rebinds now cancel stale queued
input, and ambiguous/unreadable menu discovery refuses edits while remaining
retryable. All 62 stand checks and 66 regression scripts pass; independent
review passed. The final AHK restart, single-step navigation, mouse/direct-number
edits and Production Limits close-to-stand handoff passed natively; settings
payloads were restored/preserved. Bindless hide/reopen detection and physical controller/native
duplicate-menu acceptance remain open. See [lifecycle evidence](stand-lifecycle-2026-09-24.md).

| Priority | Issue | Current evidence / required work |
|---|---|---|
| P1 | Scheduling behavior acceptance | September26 native assignment reader now wired on RAM after nine-Pal direct/census agreement. Fixed assignments and unreadable workers have regression coverage; live passes now issue permission updates. Test distinct priorities, actual targets/output, occupied seats, manual conflicts, idle reconciliation and staffing limits across transitions. Allowed permissions do not establish activity/output. |
| P1 | Item-specific production control missing | No verified producer adapters. Legacy rules still govern whole work types. Stone capped while ore continues, consumption/resumption, multiple producers, fixed workers and in-flight overshoot remain undelivered/unaccepted. |
| P1 | Reported worker behavior | Reproduce Pupperai, Flambella, Incineram, Grizzbolt displacement/sleep/wake, cooling, fishing, research, recyclers, synthesizers and ranch/fixed work. Include the new all-work-stops/one-miner report with exact settings and actual output. |
| P1 | Numeric settings resets and upgrade preservation | X serialization and checked persistence are corrected in the candidate; repeated local settings hashes survive. New numeric/default-on-login reports remain unexplained. Test real edits plus restart/reconnect, Workshop/manual update, reinstall, migration and interrupted-save recovery. |
| P1 | Multiplayer and unmodded edits | Protocol/session/timeout simulations pass. Populated listen/dedicated, two guilds/owners, rejected/delayed edits, incomplete snapshots, reconnect/version mismatch and hostâ†’clientâ†’host need native acceptance. Intentional vanilla edits need verified sender/input evidence; do not infer human intent from changed bits. |
| P1 | Storage scope and guild/shared chests | Sampled base totals match independent censuses. Guild/shared storage, no double counting, base/ownership transitions and client visibility remain unaccepted. Unknown data must stay unavailable. |
| P1 gate | Remaining performance and frame evidence | September 23 complete scheduler mean20.571/worst23 ms; stand mean11.427/worst17 ms, roster nested inside it. These are callback costs, not frame percentiles. Latest independent capture produced no usable data. Repair capture, match scenes/builds/cohorts and optimize correlated spikes; no stutter-free claim. |
| P1 gate | Packaging and compatibility | Installed WorkRules-contract3/StandInput-contract2 test pak differs from baseline release asset. Do not publish baseline Lua/new-contract mismatch or promote before remaining acceptance. Test clean Workshop/manual installs, upgrade/removal, duplicate installation, exact supported runtime and Vortex route. Some tooling still defaults to the obsolete C-drive installation. |
| P2 | Documentation and public follow-through | Consolidate historical status contradictions, keep current acceptance/build fingerprints clear, package both channels from one staging process and prepare accurate replies after gates pass. No current-candidate fixes have been published. |
| Deferred | Convenience requests | High-quality-stand-only option and requested Pal-produced materials. Catalogue entries alone cannot deliver safe per-output controls. |

## What is no longer the same open bug

The focused amount editor now cancels with one Escape, returns owned focus to the panel, and the next Escape closes only Production Limits. Mouse Cancel, Backspace, reopening and Alt+F1 passed the final full restart. Cursor capture was corrected in the preceding native run. Cleanup failures gained regressions. All 59 Lua scripts pass and all three settings files remained byte-identical. These narrow successes do not certify all UI lifecycle/crash/controller scenarios.

September24 follow-up: the picker now distinguishes availability before selection.
Fixed notice rows passed native checks on both screens. A newly reproduced pager
creation-order defect is also repaired: native item hosts now remain ordered through
partial fill, full/final pages and shrinking back to storage items. All 66 regression
scripts pass; the three settings files remain unchanged. The 347-second browsing
sample still has a 37ms panel-refresh peak and 24ms scheduler peak (inclusive
callback measurements, not independent frame times). Catalogue counts settling
during browsing remain part of the search audit.
The native stand mouse-event probe did not establish an event-time target route;
that initial probe did not fix queued stand targeting. A subsequent generated
per-cell receiver now repairs the mouse route with native evidence. The later
[keyboard follow-up](stand-keyboard-2026-09-24.md) replaces raw numeric targeting
and records its own native acceptance. The earlier run also did not reproduce the
earlier injected Alt+F1 success. See [current follow-up evidence](frontend-followup-2026-09-24.md)
for the final native layout check and current test counts.

## Recommended order

October3 async-save isolation follow-up: a native same-process singleplayer ->
Title -> RAM join retains the old local save ID on the client, despite its
loaded-world flag becoming false. Current production correctly reports client
and ready synchronization; the experimental probe remains unverified and never
binds storage. Require current-session authority/readiness before future async
storage selection. All 92 Lua regressions pass; production Lua unchanged by this
test. A second native run now covers RAM client -> Title -> local host in one
process; ID appears before loaded readiness. The experimental controller now
requires fresh authorization and suppresses stale recovery/ACK delivery while
draining accepted data. All92 suites pass. Native evidence-provider integration,
dedicated-server identity and different-save discrimination remain open. See
[transition evidence](async-save-transition-2026-10-03.md).

The experimental authorization composer now requires fresh matching context,
candidate and active-storage proof, with a final session recheck. All93 Lua
scripts pass, including zero-IO client refusals. This is a tested composition
boundary, not a completed native proof provider or production integration. See
[save-session evidence](async-save-session-2026-10-03.md).

Active-destination investigation: the SDK's loaded world object has no declared
directory GUID. A passive save-completion callback is a candidate route, not yet
observed firing natively. Its checked local driver registered successfully but
timed out after300seconds with no callback, despite a Level.sav metadata change.
The driver cancelled cleanly; production unchanged, diagnostic disabled. All95
suites pass after a diagnostic-sink shutdown fix. No storage proof obtained. See
[destination investigation](async-save-destination-2026-10-03.md).

Paired follow-up: all96 suites pass and independent pre-install review passed.
The live PreInternal destination hook remained silent; the autosave notification
hook produced four successful events30seconds apart. Seven-minute timeout and
timer cancellation passed; production unchanged and probe disabled. This proves
notification visibility only, not storage identity.

Process-map follow-up: all98 suites and independent Lua review pass. Exact
runtime2281fa31 map API was source-checked before isolated installation.
Four-minute native trial completed234samples, all empty, despite advancing
Level.sav metadata. Timer cancelled, probe disabled and production unchanged.
No destination identity obtained; empty polling does not disprove transient
entries. Do not repeat this probe without new source evidence. See
[process-map evidence](async-save-process-2026-10-03.md). Active-storage proof
and world/session correlation remain open before asynchronous persistence
can replace the existing production writer.

World-scoped identity follow-up: independent review found
PalGameStateInGame.WorldSaveDirectoryName. A checked property-only trial observed
the matching local directory only after MainWorld5 loaded; it remained
unavailable on Title despite a populated selection. Role3/dedicated=false,
43samples, clean cancellation, unchanged production and disabled arm. All100
suites pass. This is a stronger candidate, not a completed storage-proof provider.
Next test host/client transitions and distinct existing saves. See
[world-scoped identity evidence](async-save-world-identity-2026-10-03.md).

October4 host→client follow-up completed in one process: GameState directory
changed from local31141... to serverfa6a... while selected-ID retained31141....
Title and initial unavailable client GameState were correctly excluded; stable
role1/dedicated=true/loaded=false client observed,155samples, timer cancelled.
All101 suites and independent re-review pass after correcting incomplete-test
timeout wording. Production unchanged and probe disabled. See
[world identity transition](async-save-world-transition-2026-10-04.md).
October4 reverse client→Title→local test also completed in one process
(PID31528): serverfa6a... changed to local31141..., with populated selection on
Title correctly insufficient. Stable host observed after142 samples; production
status independently confirmed local authority and saved priorities/limits.
All102 suites pass, production unchanged, diagnostic disarmed. Stand reopen was
not visually verified in this reverse trial (macro attempt did not open it;
large Pal obstructed view). See [reverse evidence](async-save-world-reverse-2026-10-04.md).
Different-save/headless checks and actual storage authorization remain; these
observations still deliberately grant no asynchronous write authorization.

September25 respawn follow-up: fixed an unknown-owner ClientRestart callback
resetting the local session. Regression fails before/passes after; all67 suites
and independent review pass. Native emergency respawn did not establish a second
ClientRestart event (one session-wide call in the later diagnostic), so actual
respawn invalidation, interrupted editing and post-respawn stand reopening remain
open. See [guard evidence](respawn-guard-2026-09-25.md).

1. Frontend input ownership and event-time targeting; a reproducible interaction matrix accompanies each change.
2. Layout/pagination/editor/search states, honest capability presentation and controller/focus behavior.
3. Native assignment reader and actual scheduling/staffing tests, then verified item-specific producer control.
4. Persistence/upgrade and populated multiplayer/storage acceptance, correlated performance tests.
5. Clean packages, compatibility acceptance and accurate release communication.

Sources: [current report status](report-status-2026-09-13.md), [reliability gates](reliability-2026-09-11.md), [latest native Escape evidence](editor-escape-2026-09-23.md), [queued-click reproduction](restart-input-investigation-2026-09-23.md), [latest Steam reports](comment-update-2026-09-23.md), [Nexus/Deck reports](comment-update-2026-09-15.md).

## September25 live dedicated-server acceptance delta

Separate server restart macro now passes two complete client restart/rejoin/stand-open cycles; singleplayer macro unchanged. Native priority1â†’2â†’X, server-file X persistence, X after client restart, and restoration to1 all verified. See [macro and multiplayer evidence](server-restart-2026-09-25.md).

Still open: dedicated-server process restart, two clients/guilds, rejected/delayed edits, and native assignment evidence. Current server reports unverified assignments; correct grid/saved settings do not prove scheduling behavior. Post-join missing interaction prompts recover after opening/closing vanilla pause; macro includes this workaround, but cause remains unisolated.
