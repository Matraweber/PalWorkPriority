# 0.5.0-rc1 reliability and release ledger

Audit date: **2026-09-11**. Target: **0.5.0-rc1 reliability candidate, unpublished**. Baseline reviewed: clean 0.4.1 at `aa66480`. The uncommitted candidate's tested files and completed automated checks are recorded in the [implementation evidence](implementation-evidence-2026-09-11.json).

This ledger records the approved scope and what must be demonstrated before release. [All 65 comments](comment-ledger-2026-09-11.md), [test protocol](testing.md), [README](../README.md) and [reply drafts](release-replies-0.5.0-draft.md) are companion documents. No comment has been posted and no release is authorized by an unchecked row.

**Earlier native retest — September 13, 14:48 candidate:** the [viewport, typed stand and icon report](viewport-and-icon-retest-2026-09-13.md) verifies the restarted 40-module generation. Rules refresh averages 1.956 ms versus 13.841 ms before the viewport change; complete stand refresh averages 11.6–11.9 ms versus about 20.7 ms before typed discovery. All 184 measured stand lookups used the typed route; reopening and two icon pages plus warm return passed the observed visual checks. Three one-minute clips still show 61–64 intervals above 16.67 ms and three above 33.33 ms each, including profiling off. First catalogue construction still takes about 51 ms; assignments and storage remain unverified. All 47 Lua regressions pass. Profiling and recorders are off; broader native/release gates remain open. Earlier evidence below is historical and retains its original limitations.

## Assessment and evidence limits

**Latest storage/performance retest, September 13 17:20:** [storage scheduling and dropped-loot report](storage-prefetch-2026-09-13.md), PID 40108. Complete stock now survives the observed no-base dropped-item case; two native positive-base comparisons match all quantities/counts. The separately queued storage refresh lowers full callback maxima **41→23 ms** in both off/on pairs. Four independent frame captures do not establish a broad stutter improvement; long frames persist. All 42 modules compile and 53 regressions pass. Background refresh on, profiling/recorders off. This supersedes prior scope counts but closes none of the untested output, shared-storage, multiplayer or overall frame-time gates.

**Latest storage retest, September 13 16:20:** [base-stock scope report](storage-scope-2026-09-13.md), PID 16836. The 549–550 zero-GUID entries are known world-loot classes with no assigned base; the authority-only, exact-class exception removes those false failures while retaining conservative unknown storage. Two successive native comparison runs match all 29 scoped item totals and holder counts against an independent census, and the visible two-base totals reconcile. All 41 modules compile and 52 Lua regressions pass. This supersedes earlier unresolved-loot counts only: scans still cost 21–23 ms, and shared guild chests, controlled ownership/quantity transitions, actual assignments/output, multiplayer and frame-time acceptance remain open. Profiling is off.

**Latest installed retest, September 13 15:42 candidate:** [remaining-stutter report](remaining-stutter-2026-09-13.md), final PID 42972. Separate background redraws, bounded search preparation, streaming stand traversal and the removed click-age gate pass 50 Lua regressions (40 compiled modules). The tested mouse controls and stand reopening work. Cold catalogue draw is 32–36 ms versus 54 ms previously; the matching stand-grid improvement is small (10.8–11.1 to 10.6–10.7 ms). New recordings, including the final revision with profiling off, still show recurring long frames. Scheduler costs, actual assignment evidence and storage scope remain open. See [report status](report-status-2026-09-13.md) for published-versus-local limitations. This supersedes the 14:48 summary above; profiling and recorders are off.

**September 13 follow-up:** [Deeper performance investigation](performance-investigation-2026-09-13.md) links the observed 1.07/10.7-second long-frame patterns to the corresponding callback cadences without claiming exact frame causality. The checked candidate narrows row-owned priority traversal, adds painting subregion timings, scopes storage demand by effective limits, and bounds incomplete-read retries while preserving unknown evidence. All 39 modules compile and 35 Lua regression scripts pass. Native gains require the subsequent checked installation/restart record; existing frame captures still show pauses.

**12:39 installation:** four Lua modules are staged with all 39 installed/source and backup hashes verified. Independent review is closed after targeted duplicate-bar and empty-guild retry regressions were fixed. Runtime, pak and user configuration are unchanged; profiling/recorders are off. PID 29584 still runs the prior generation, so restart verification and repeated native timings remain the next gate. [Installation details and evidence](performance-investigation-2026-09-13.md#checked-installation--1239).

The audit read 52 Steam comments across six pages and 13 Nexus comments/replies across two pages, including the linked UI screenshot and stutter reporter's collection. Public releases reviewed remained dated August 28. Sources: [Steam comments](https://steamcommunity.com/sharedfiles/filedetails/comments/3786408856) and [Nexus posts](https://www.nexusmods.com/palworld/mods/5376?tab=posts).

0.4.1 has confirmed persistence and control-flow defects. Some reported native symptoms have plausible paths in the code but no established engine-level cause. “Code-confirmed” below does not mean every report with similar wording has that cause.

Earlier performance conclusions exceeded the measurements: count-only counters printed zero milliseconds; complete scheduler cost was missing; nested timings overlapped; stress could succeed without completed passes. Tick cadence, fence membership, echoes and silence in error logs do not prove smooth frames, actual work or output.

The historical UE4SS log names `c838a8ac`. The [intended dependency distribution](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587) advertised `2281fa31`, updated September 3. **Current game/runtime compatibility is unaccepted.** Record actual loaded identities and hashes; August evidence cannot substitute.

## Pre-install identity snapshot — not a native test

The initial read-only fingerprint evidence identified **client installed mod 0.4.1**, **server installed mod 0.4.0**, and **source 0.5.0-rc1**. Neither game nor server process was running at that observation. **Loaded runtime is unknown**; log identities are historical and unbound to a current process. The later local test installation is recorded below; these earlier observations are preserved as history.

Local evidence: [fingerprint-client.json](../test-results/fingerprint-client.json) and [fingerprint-server.json](../test-results/fingerprint-server.json). These files live in ignored `test-results/`; they are local evidence, not release payload or tracked source. Preserve/hash them when assembling an acceptance record.

[Fingerprint tool](../tools/fingerprint.py) and [frame analyzer](../tools/analyze_frames.py) are read-only. Their CLI/help schemas and fixture behavior were tested; see [fingerprint tests](../tests/test_fingerprint.py) and [frame analysis tests](../tests/test_analyze_frames.py). A mapped process-module path, if observed later, is not a loaded-memory hash: the tool hashes the on-disk file. There were **no actual independent frame captures at this initial snapshot**; later native records below supersede that evidence gap.

## Local client test installation — 2026-09-11, 20:53 Europe/Berlin

The user authorized installation and assisted testing. Before replacement, all 103 files matched the implementation evidence; 39 Lua modules compiled, all 32 Lua regression scripts (including 26 stand cases) and 102 Python tests passed again, and the structural check passed. The installed legacy configuration was accepted by the candidate validator. No game or server process was running during backup, deployment or verification.

Pre-migration backup: `C:\Users\matra\Desktop\PalWorkPriority-test-backups\20260911-205237`. Its manifest records 371 copied files and verified SHA-256 values, including all local SaveGames, saved configuration, the prior client mod, shared mod settings, runtime/configuration and the installed pak. The historical UE4SS log was also copied with a separate hash record. Keep the world, old mod and old settings together for rollback; never replace a running world's files or load new-schema settings with old code.

The reviewed deployment tool installed **0.5.0-rc1** into the existing client mod directory. All 39 installed Lua files and Info.json match source. The existing pak matches the candidate contract and was left in place. The legacy config was copied byte-for-byte to the durable mod-root config.lua; 335 protected save/config/runtime/asset/installation-record files were verified unchanged. Auto reload remains disabled. The developer channel is prepared for the next full startup with no queued command. Other mods, runtime binaries, Workshop content and the dedicated server were not changed.

Local receipts: [backup](../test-results/client-backup-2026-09-11.json), [installation](../test-results/client-install-2026-09-11.json), [pre-install fingerprint](../test-results/preinstall-client-2026-09-11.json). These ignored artifacts are not release payload. **Native acceptance remains pending:** no candidate game launch, loaded-runtime verification, native save round-trip, frame capture or completed pass was observed in this installation step. Verify the candidate again after launch because an external mod updater could replace files.

Start with world readiness, authority, settings and complete-pass evidence; then UI and actual job/output checks; then persistence restart, matched performance captures and disposable dedicated-server tests. Failure injection and stress belong on a disposable save copy. Native item-specific producers and manual-assignment readers remain unavailable and cannot be marked passed by this installation.

## Startup attempts and isolation — 2026-09-11, 21:18–21:27 Europe/Berlin

The first user launch applied pending official-loader updates. ManagedMods recorded PalWorkPriority 0.4.0 before launch; Workshop contained 0.4.1. The loader recopied 0.4.1 over 14 changed candidate modules at 21:18:30, and the startup banner confirmed 0.4.1. UE4SS also updated to **2281fa31**. This attempt does not test the candidate. The [official loader documentation](https://github.com/pocketpairjp/PalworldModUploader/blob/main/PalworldModUploader/docs/en/04-Tech.md) confirms version-change reinstall and DebugMode's every-launch reinstall behavior. Both managed/cache versions subsequently matched 0.4.1 with DebugMode false.

After preserving the failed-start logs, the candidate was recompiled, redeployed and verified again. All 39 source/install Lua hashes, Info.json and pak matched; all 240 backed-up world-save files and priorities/caps remained unchanged. A direct launcher request did not produce a new runtime log; the subsequent Steam launch loaded 0.5.0-rc1 at 21:23:34, confirming that the pending update no longer overwrote the candidate. It then crashed before world entry.

An independent read-only crash review mapped **both** the 21:18 and 21:23 fault instructions to `MapCollectablesNative/dlls/main.dll + 0x1232F`, reading `0x1C0`, with matching stack hashes. This identifies the faulting module, not the underlying bug or complete initiating interaction. The candidate was not loaded in the first crash. PalSchema signature errors and the last Blueprint-loader messages are not established causes.

For a controlled isolation, only MapCollectablesNative's activation marker was renamed from `enabled.txt` to `enabled.txt.pwp-test-disabled-20260911`. DLL/settings are intact; no map-mod source was changed. It had been starting through that marker despite not appearing in ActiveModList. Restore that marker only with the game stopped and when deliberately testing/reinstating the crashing combination. The temporarily disabled state remains in effect for this test installation.

The isolated Steam launch at 21:25:15 stayed alive through the 21:27:40 observation, loaded candidate 0.5.0-rc1 and mapped the intended UE4SS.dll. The runtime's **on-disk** SHA-256 is `21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8`; no loaded-memory hash is claimed. Status communication succeeded. The frontend emitted PWP_READY with session 0, so that marker alone did **not** establish a loaded gameplay world. A request-bound dry probe correctly returned `status=aborted`, `camps=0`, `dry=true`, `pending=0` while enumeration was unavailable. It is not a completed gameplay pass.

Local artifacts: [startup result](../test-results/startup-result-2026-09-11.json), [live-process fingerprint](../test-results/isolated-start-client-2026-09-11.json), [reinstallation](../test-results/client-reinstall-2026-09-11.json), [map-mod isolation](../test-results/map-mod-isolation-2026-09-11.json). Failed-run logs are preserved below the pre-test backup root. **World entry, actual scheduling, restart persistence, UI behavior, multiplayer and frame-time acceptance remain pending.** Existing PalSchema signature errors remain recorded as compatibility limitations; surviving startup does not establish their harmlessness.

## Loaded-world smoke results — 2026-09-11, 21:27–21:35 Europe/Berlin

World entry occurred at 21:27:49, session 1, followed by authority/settings readiness. Status observed two camps and 14 Pals, priorities/limits saved, and live demand pulses. Screenshot identifies **game 1.0.4.102642**, 1920×1080. These are useful native observations on UE4SS 2281fa31, not release acceptance.

**Gameplay gate remains blocked.** All 14 assignments and manual-assignment states were unverified; storage was unverified with configured legacy caps. The scheduler preserved observed permissions and deferred automatic allocation (explicit X reconciliation remains possible). The seven reported unverified staffing conflicts are excess preserved permission reservations, not seven proven occupied jobs. Zero permission requests in these passes cannot establish successful priority or limit enforcement.

Three cumulative profiler snapshots at 45, 132 and 199 seconds contained 4, 13 and **19 total** scheduler samples respectively; do not add these overlapping counts. In the final window, complete scheduler time was 744 ms total, **39.158 ms mean / 43 ms worst**. Storage was 372 ms total, 19.579 ms mean / 22 ms worst; camp enumeration was 190 ms total, 10 ms mean / 11 ms worst. Child timings overlap the complete pass. These numbers measure the current deferral path, not the future fully functioning scheduler. Clock resolution remained unmeasured; zero durations are not free operations. Profiling was switched off at 21:32:49.

At this 21:35 observation, independent frame capture was **BLOCKED**; the later authorized elevation and successful captures are recorded below. The installed NVIDIA helper produced no data. The official portable PresentMon 2.5.1 executable, verified against published SHA-256 `9bec3083069f58f911e6a512f4806db51a27bd096103087bc1d05ef54c80a191`, exited 6 with trace-session access denied: administrative privilege or Performance Log Users membership is required. No privilege/group changes were made, no CSV was produced, and no frame-rate or stutter verdict is supported. The temporary binary is in ignored test-results, outside the game and release payload.

The two-rule Production Limits page was opened and closed programmatically. Screenshot00324 shows Wood 30,000 and Stone 35,000, both labeled legacy groups, with storage `?` and limit state `Unavailable`; Screenshot00325 confirms no panel/backdrop after closing. This does not cover Escape, vanilla menu handoff, controller input, many-row pagination, restarts or visual agreement at other resolutions. Immediate remote open/close log messages reported the old state before queued work ran; subsequent panel-state and screenshots were used as evidence instead. That diagnostic wording remains a follow-up.

**A further test false positive was found and fixed in source.** The old request-bound completion predicate could accept the observed unverified pass because camps/Pals/pass ID advanced with no ordinary errors. Scripts/main.lua now emits `status=unverified` for assignment/storage evidence gaps, `status=incomplete` for deferred/pending/expired/withdrawal work, and records invocation completion separately. The existing harness rejects both statuses. Evidenced zero-write passes can still complete; dry runs remain explicitly dry. The independent agent reports 13 before-fix failing case reports, including this live-shaped case and each individual flag; the coordinator's full after-fix run passed all 39-module compilation, 32 Lua scripts (including 26 stand cases), 102 Python tests, structural and whitespace checks.

Only Scripts/main.lua and tests/test_main_integration.lua changed after the measured build. **This receipt fix is not deployed or hot-loaded.** The live game retains the original candidate and all results above apply to its original hashes. [Native smoke evidence](native-smoke-evidence-2026-09-11.json) records the new source fingerprint, the installed old-main hash, test output hashes and native limitations. Local detailed receipts and screenshots are listed in [native-smoke-result-2026-09-11.json](../test-results/native-smoke-result-2026-09-11.json). No successful gameplay stress or native priority/limit result is claimed.

## Monitoring Stand and independent frames — 2026-09-11, 21:58–22:09

**Native UI and performance gates failed.** With the stand open, screenshots show vanilla checkboxes and the mod legend. Every timed refresh reported unavailable cells (88/88). The diagnostic encountered a removed `cells_under` function, after writing a partial tree containing nine rows and 117 cells. The generic `_C` container assumption rejects native text-leaf shapes; source correction and a checked restart are required.

After the user explicitly approved Windows elevation, three process-filtered PresentMon captures succeeded, each 60 seconds: profiling off/on/off. Full recordings contained 63/60/62 application Present intervals above 33.33 ms. The common 45-second interiors contained 46/45/47. Stand refresh averaged 39.318 ms (worst54); complete scheduler42.222 ms (worst44), with unknown assignment/storage deferral still active. The recurring frame pattern is real; exact event causality and mod-absent overhead remain unverified. No stutter-free claim is supported.

[Detailed stand report](stand-capture-2026-09-11.md) records raw/full/interior statistics, unchanged installed identities, source differences, scene drift, frame-generation caveats and artifact hashes. Profiling is off, recorder processes exited, and the game was left running. No game code was replaced during capture.

The stand source correction is now validated: explicit native text-leaf handling, preserved CheckBox-content traversal, bounded refusal details and the repaired dump. Full checks passed: 39 Lua 5.4 modules, 32 Lua scripts including 29 stand cases, 102 Python tests, structural checks. [Stand capture evidence](stand-capture-evidence-2026-09-11.json) records the newer source fingerprint. This supersedes the earlier source manifest for the four stand patch files; all native captures still apply to the original installed build. Nothing was deployed; native painting and performance acceptance remain open.

## Status vocabulary

- **CODE-CONFIRMED:** a defect/path was identified in the reviewed source; native symptom causality may still be unproved.
- **REPORTED:** a user described the symptom; reproduction is pending.
- **SIMULATED:** an isolated regression passed for its modeled contract in this task's run. Attach its source fingerprint and raw result; this status does not certify native behavior.
- **PENDING:** work or evidence remains. A test file or implemented branch alone is not a passing result.
- **BLOCKED:** specify the missing native API, environment or observation; keep the gate open.
- **ACCEPTED:** the specified earlier failure and candidate pass have reviewed evidence on recorded builds.

**Release acceptance remains PENDING.** The records below describe this task's executed isolated tests and read-only artifact checks. Engine boundaries are mocked unless stated otherwise. Recorded file/output hashes identify the tested integration; simulated results never substitute for native acceptance.

## Implementation and test evidence snapshot

**The complete 0.5.0-rc1 automated suite passes**, including explicit-false rendering, sticky save-failure states and the final server/stress safeguards. The evidence table below records counts and limits. Native implementation and acceptance gates remain open.

| Evidence | Latest result | Boundary |
| --- | --- | --- |
| Real Lua compilation | **39 modules compile in Lua 5.4** | Syntax only; no native acceptance |
| Lua regressions | **32 scripts all pass**, including **26 stand integration cases** within those scripts | Actual Lua/UI source with simulated engine contracts; explicit-false-return fix included |
| Structural checker | **PASS; panel 194 top-level locals** | Supplements real compilation and regressions |
| Python regressions | **102 tests pass**, including **16 server and 23 stress tests** | Process-control calls are mocked; no native launch, stop or compatibility acceptance |
| X baseline comparison | [test_x_roundtrip.lua](../tests/test_x_roundtrip.lua): git-show aa66480 store rerun with in-memory filesystem fails exactly “X disappeared after save/load”; candidate passes; [baseline-x.json](../test-results/baseline-x.json) | SIMULATED before/after; native restart/reinstall still pending |
| Scheduler/demand baseline comparison | Actual git-show aa66480 sources rerun in this task; both exact expected errors matched; candidate scheduler/demand suites pass | [baseline-regressions.json](../test-results/baseline-regressions.json) includes source/test SHA-256; native job/output gate remains pending |
| Configuration | Root migration/backup, precedence and validation before migration/reload/override application implemented and tested | Reject whole malformed/nonfinite config while retaining prior accepted settings; 1–5/X meaning unchanged |
| Archive config mapping | Source Scripts/config.lua packaged as Scripts/default_config.lua | Protects manual merge; cannot recover old config if Workshop deletes Scripts before first migration; pre-update backup required |
| Checked persistence | Live/.tmp/.pending/.bak validation and protection of recovered temporary data | Isolated fault/recovery evidence; not protection against every crash or power loss |
| Inherited limits | Guild-local OFF masks persist clearing shared/config ceilings; [round-trip/isolation tests](../tests/test_caps_inherited.lua) pass | No change to other guilds in model; native multi-guild gate open |
| Carried pak | Hash/plain-index validation **PASS, v11, 5,400 bytes** | Full hash/path recorded below; not mounting/widget/runtime acceptance |
| Server/stress helper | Exact installation/process identity, checked lifecycle results, final health/error drain and actual dry-mode validation implemented | **SIMULATED PASS** — regressions fail before and pass after; full Python suite passes; no native acceptance |
| Latest source integration | Roster/stand_rows distinguish empty from unavailable; partial off-list remains unknown; current Role 2 overrides stale GameMode evidence; nil item ID makes stock unavailable; restoration requires confirmed readback and policy changes preserve pending writes | SIMULATED in completed 39/32/26 code/UI run; no native assignment/authority/storage result |
| Read-only diagnostics | Fingerprint and frame-analysis tools added; help/schema fixture tests exercised | Installed versions are not loaded identities; no actual independent frame capture |
| Native capabilities missing | No verified output adapter; scheduler.assignment_reader remains nil | Item-specific controls unavailable; manual/occupied-job evidence unknown, not absent |
| Native evidence missing | Current runtime, clean installation, actual assignment/output, multiplayer, input/lifetime and independent frame capture | All corresponding release acceptance remains PENDING |

**Configuration upgrade caveat:** renaming packaged defaults prevents a manual merge from overwriting legacy editable Scripts/config.lua. It does not preserve a file that a Workshop updater deletes before the first migration. Require a pre-update backup and test the actual updater route; do not promise automatic preservation for every installation.

**Final automated record:** [implementation-evidence-2026-09-11.json](implementation-evidence-2026-09-11.json) contains SHA-256 identities for **103 tested files**, raw output hashes, exact baseline failures, pak integrity, installed observations and the remaining native work. Tested file-set SHA-256: `152bf19aa644c4064e9a886fd9f22c761a8b3081aa18987bd77f7f20ce27d84c`. Its scope includes runtime code, tools, tests, metadata and pak contract; prose documents and generated outputs are excluded. The file set and all recorded test-output hashes were rechecked after integration.

## Actual baseline regressions

This task reran the actual modules extracted with `git show aa66480`, using isolated mocked boundaries (in-memory filesystem for store). [baseline-regressions.json](../test-results/baseline-regressions.json) records each source SHA-256, test SHA-256, expected failure, observed traceback and `matched: true`. All three matched; candidate suites pass.

| Baseline module / test | Exact matched failure |
| --- | --- |
| store / test_x_roundtrip.lua | `X disappeared after save/load` |
| scheduler / test_scheduler.lua | `idle X edits and obsolete restrictions must reconcile` |
| demand / test_demand.lua | `unknown camp must not contribute demand to arbitrary bases` |

The earlier [baseline-x.json](../test-results/baseline-x.json) remains local evidence. The combined record is embedded in the checked implementation artifact. These are actual earlier-source before/after regressions, not native restart, assignment or output tests.

## Run artifacts and pak identity

Raw UTF-8 output from the completed integrated run is retained locally:
[Lua](../test-results/final-lua.txt), [structural](../test-results/final-structural.txt) and [diff check](../test-results/final-diff.txt).
[Python](../test-results/final-python.txt) records all **102 passing tests**, including the final tool corrections. These outputs are ignored local artifacts; their hashes and test/source identities are retained in the checked implementation-evidence JSON.

Pak: [LogicMods/PalWorkPriority.pak](../LogicMods/PalWorkPriority.pak), **v11, 5,400 bytes**. SHA-256:

```text
f266971e7c4ffea00039fd892de7b47cbaeecca959ba8cb36f546caff522e310
```

Hash and plain-index validation passed. This is artifact integrity, not native mounting/widget compatibility.

## Test-tool safeguards verified in simulation

- Server selection now uses exact installation paths, including the dedicated server's `-Cmd` image. Stops recheck PID, executable path and start time; another installation is never an authorized target.
- Already-running/unverified readiness and unsuccessful stops return failure.
- Stress verifies final liveness and drains errors after its last sample. Foreign installations and launchers cannot prove target liveness.
- Stress validates and records actual dry state; a normal request that stayed dry cannot pass as a normal execution.

The new regressions failed on the previous helpers and pass after correction. All 39 focused server/stress cases and the full 102-test Python suite pass. All process calls were mocked. No game/server process was launched or stopped by this task; live Windows behavior remains a native gate.

## Actual CLI regression evidence

Four cases added to the existing [test_main_integration.lua](../tests/test_main_integration.lua) execute the real main command handlers with mocked engine/transport/storage boundaries. **All four failed before the fixes and pass afterward.** They are included in the passing code/UI suite and recorded tested file set.

| Regression before | Candidate behavior / asserted result |
| --- | --- |
| Fractional limit silently rounded | Reject fractional input rather than changing it into a different whole-number limit |
| Queued client limit reported as set | Report pending/queued state; do not claim a server-confirmed set |
| Failed clear reported as absent | Surface failure; do not misreport a failed clear as an already-absent rule |
| Unknown or unscoped stock displayed as 0 | Display unavailable stock/scope rather than a measured zero |

`show_limits` also labels legacy group semantics and names the current guild/base from verified `panel_status` evidence. It uses that evidence rather than making blind rescans; absent scope stays unavailable. This is source/isolated-test evidence, not proof of actual in-game storage or server acknowledgements.

## Behavior contract

1. Fresh, positively identified installations preserve vanilla choices: checked→1, unchecked→X. Existing mod priorities survive upgrades. Do not derive original choices from flags already modified by an older mod.
2. Keep 1 highest, 5 lowest, X disabled. Explain this in the interface; do not reverse stored values.
3. Preserve existing balanced (`spread`) or strict (`fill`) mode settings. Balanced intentionally spreads staffing before filling higher-priority work with extra workers.
4. Respect manual assignments; make conflicts with X or limits explicit.
5. New limits are item-specific only through verified producer controls. Existing group rules retain their behavior under an explicit legacy label; no silent migration of meaning.
6. Preserve the user's preferred panel position; fix layout within it.
7. Missing authority, identity, storage, work state or sync information means unknown, never an inferred permission or success.
8. Do not cache collectable engine wrappers across callbacks. Matching instance names are not lifetime proof, and `IsValid()` on a stale wrapper can itself crash.

## Findings and planned changes

Each finding ID is stable and referenced by the comment ledger. The final column is the native release gate; PENDING there does not mean the code is unimplemented. Implemented, passing isolated groups are checked as SIMULATED below and recorded separately in the evidence register.

| ID / priority | Finding and evidence | Implementation area | Native gate / status |
| --- | --- | --- | --- |
| F01 P1 | X becomes nil during 0.4.1 serialization; directly explains loss of X rows. Other numeric resets are not fully explained. CODE-CONFIRMED | Explicit false handling, real Lua round-trips and unrelated-edit regression in store | PERSIST — X regression SIMULATED before/after; native PENDING |
| F02 P1 | Writers ignore normal write/close failure and remove the old live file before replacement. CODE-CONFIRMED | Checked open/write/close/readback; recoverable generations; bounded dirty retries; accurate save/error state | PERSIST — PENDING |
| F03 P1 | Editable config lives in replaced Scripts; transient Pal keys and unknown prior state risk incorrect migration | Root config, backed-up migration, durable identity validation; preserve data on update/reinstall | CONFIG — PENDING |
| F04 P1 | Close permits vanilla handoff, later watchdog forces GameOnly. CODE-CONFIRMED; exact Escape crash cause unproved | Explicit lifecycle and game-thread actions, idempotent close/cancel, generation invalidation, focus ownership | UI — PENDING |
| F05 P1 | Visibility caches survive hiding; widget reuse does not reparent. Nexus screenshot shows overlapping rules pager | Successful-write-only caches, parent/anchor repair, pagination/edit containers, current-tree resolution | UI — PENDING |
| F06 P1 | Photo-mode grey box and duplicate/stuck panel REPORTED; native cause unproved | Single owned attachment, closed panel detached, safe reconstruction/teardown, duplicate-load detection | UI — PENDING |
| F07 P1 | Thresholds gate whole suitability after all configured items reach limits. CODE-CONFIRMED | Label/preserve legacy groups; verified per-output adapter, unsupported creation refused, measured overshoot | PRODUCER — PENDING |
| F08 P1 | Idle camp returns before permission reconciliation. CODE-CONFIRMED | Apply X edits and release stale restrictions even without demand/caps | SCHED — PENDING |
| F09 P1 | Held workers/fallback permissions bypass staffing accounting; ranking is not consistently across candidates. CODE-CONFIRMED | Count occupied seats, cap all permission paths, rank candidates with stable ties; separate mode semantics | SCHED — PENDING |
| F10 P1 | Initial unknown camp/type can remain unrepaired; unknown scope can reach all camps; holds use type-level proxies | Repair records, quarantine unknown scope; ready/occupied/completed/unknown state; assignment-specific retention | SCHED — PENDING |
| F11 P1 | Manual, research, recycler, cooling/ranching and specialist failures REPORTED; allowed permission alone does not prove work | Verify native assignment/output; respect fixed work; expose conflicts; verify producer/work mappings | SCHED/PRODUCER — PENDING |
| F12 P1 | Remote ceilings share local durable storage and survive role reset; world-name/session ambiguity. CODE-CONFIRMED | Separate snapshots, session/guild/camp scope, undecided writers at transition, session-bound evidence/callbacks | SESSION — PENDING |
| F13 P1 | Non-throwing skipped cells count as painted; rapid clicks use old confirmed values; snapshot completion/version validation insufficient | Rendered/skipped/failed outcomes, rebind invalidation, pending edits/coalescing/ack, negotiated revisioned snapshots | SYNC/UI — PENDING |
| F14 P1 | Multiple-owner/guild routing and unmodded clients' edits need actual verification; reported vanilla undo loop | Preserve authorization, prove write owner/scope, distinguish external vanilla edits from own writes | AUTH/SYNC — PENDING |
| F15 P1 gate | Missing full timings, fake zero rows, nested sums and inert stress success invalidate earlier broad claims | Complete bounded profiling, measured clocks/windows, inclusive labels, both sinks; request-bound completed-pass harness | PERF/STRESS — PENDING |
| F16 P1 gate | Continued one-second/periodic stutter REPORTED; collection does not establish another mod as cause | Matched absent/present and profiler off/on frame captures; cold/aged scenes; optimize proven spikes; local viewport gates | PERF — PENDING |
| F17 P1 gate | Current runtime, clean installs, pak contract and Vortex route unverified; Alt+F2 was misleading panel instruction | Fingerprints, dual deterministic package, Alt+F1 docs, exact dependency, one installation; Vortex only after acceptance | PACKAGE — PENDING |
| F18 P2 | Stand direct entry/controller requests; priority-order and balanced-mode confusion | Explain 1–5/X and modes; direct keys and controller focus/navigation without removing clicks | INPUT — PENDING |
| F19 P1 | Guild-chest request and ambiguous broader stock scope; missing data may appear as zero | Visible camp/guild scope, shared storage counted once, known/unavailable stock states | STORAGE — PENDING |
| F20 P2 | Chat output unclear, UE4SS lines concatenate, sink failures hidden; developer docs contradict evidence | Output to priority.log explained; newline framing and sink failures; replace unsupported claims; aggregate recurring errors | LOG/DOCS — PENDING |
| F21 deferred | Optional high-quality-stand restriction requested | Keep current access; evaluate only after reliability gates. No implementation in this release scope yet | OPTIONAL — DEFERRED |
| F22 P1 follow-up | Clearing a guild override exposed shared/configuration ceilings while reporting success. CODE-CONFIRMED during implementation | Guild-local OFF masks and scope/round-trip regression: SIMULATED PASS | Native multi-guild/restart PENDING |
| F23 P1 follow-up | Actual main CLI rounded fractions, called queued limits set, called failed clear absent, and displayed unknown/unscoped stock as 0 | Four real-main-code regression cases fail before/pass after; verified panel_status scope and legacy labels | SIMULATED before/after; native CLI/sync/storage PENDING |
| F24 P1 test gate | Final read-only audit found unsafe server wildcard stop, unchecked lifecycle success, missing final stress drain and ignored dry=true marker | Exact process ownership, checked lifecycle, final health drain and actual-mode checks | SIMULATED PASS — 39 focused / 102 full Python tests; native PENDING |

## Implementation checklist versus native acceptance

A checked **SIMULATED** row means implemented source behavior passed the cited isolated regression group in the final integrated run. It does not close a native gate. Exact test-output and source-file hashes are in the implementation evidence. All 102 Python tests, including the added server/stress safeguards, pass.

### A. Player settings

- [x] **SIMULATED — priorities and checked persistence:** 1–5/X, unrelated edits, durable identity, failures, retries and generation recovery. [X](../tests/test_x_roundtrip.lua), [persistence](../tests/test_persistence.lua), [datafile integration](../tests/test_datafile_integration.lua). Native save-error visibility/restart/update still pending.
- [x] **SIMULATED — configuration:** migration with backup, root precedence, whole-config rejection of malformed/nonfinite values before migration/reload/overrides, prior accepted settings retained. [Configuration](../tests/test_configuration.lua), [main integration](../tests/test_main_integration.lua). Priority semantics unchanged.
- [x] **SIMULATED — inherited clearing and snapshot isolation:** guild-local OFF masks survive round-trip without changing other guilds; remote snapshots do not write local durable caps. [Inherited caps](../tests/test_caps_inherited.lua), [caps isolation](../tests/test_caps_isolation.lua).
- [x] **DOCUMENTED — forward candidate schema:** downgrade needs compatible pre-upgrade backups, not current new-schema files. Already-discarded X requires a surviving earlier copy.
- [ ] **NATIVE — upgrade/reinstall/restart:** prove preservation on each installation route. Workshop may remove legacy Scripts before migration; a pre-update backup is required.

### B. UI lifecycle, layout and editing

- [x] **SIMULATED — actual UI code integration:** 26 passing stand cases in [UI integration](../tests/test_ui_integration.lua), plus [overlay lifecycle](../tests/test_overlay_lifecycle.lua), [overlay adapter](../tests/test_overlay_native_adapter.lua), [panel runtime](../tests/test_panel_runtime.lua), [panel render](../tests/test_panel_render.lua), [cell rendering](../tests/test_ui_render.lua).
- [x] **SIMULATED — modeled lifecycle contracts:** idempotent close/cancel, handoff ownership, current-tree/generation handling, rendering outcomes, cache invalidation and layout/editor behavior covered by those fixtures. This does not certify collectable-object lifetime in Unreal.
- [x] **IMPLEMENTED / COMPILED — responsibilities split:** panel structural count now 194 top-level locals; preferred position retained as the acceptance target.
- [ ] **NATIVE — UI matrix:** Escape while editing, repeated close/open, photo mode/bed, pause/inventory/map focus, duplicate/missing pak, respawn, same-name reconstruction, rules 0/1/13/14/26/27, picker pages, all resolutions/scales and devices.

### C. Scheduling, production and storage

- [x] **SIMULATED — scheduling:** idle reconciliation, repaired/quarantined demand, capacity and stable candidate allocation. [Scheduler](../tests/test_scheduler.lua), [plan](../tests/test_scheduler_plan.lua), [demand](../tests/test_demand.lua). Baseline idle/unknown-scope failures confirmed separately.
- [x] **SIMULATED — permission readback:** distinguish observed changes from pending mod writes; unknown reads do not invent confirmation. Observations no longer rewrite saved priorities as X or 1: the September 12 rapid-click test exposed that assumption as unsafe. [Permission tracking](../tests/test_scheduler_permissions.lua), [rapid-click correction](stand-input-retest-2026-09-12.md).
- [ ] **NATIVE / UNAVAILABLE — intentional vanilla edits:** an observed checkbox bit does not identify a human action or its sender. Automatic adoption of unmodded clients' checkbox changes requires a verified input/sender adapter; the removed inference must not be presented as multiplayer support.
- [x] **SIMULATED — producer contract:** unsupported creation refused; existing legacy rules editable; output-admission model tested. [Producers](../tests/test_producers.lua), [caps isolation](../tests/test_caps_isolation.lua), [inherited caps](../tests/test_caps_inherited.lua).
- [x] **SIMULATED — storage scope and availability:** shared backing containers deduplicated and unreadable scope/quantity retained as unknown. [Storage reader](../tests/test_storage_reader.lua), [scheduler storage](../tests/test_scheduler_storage.lua).
- [ ] **NATIVE / UNAVAILABLE — assignment reader:** scheduler.assignment_reader is nil. Manual and actual occupied-job identity remain unknown; safe native reader and assignment-specific retention verification are missing.
- [ ] **NATIVE / UNAVAILABLE — producer adapter:** no verified item-specific output control. Stone stopping while ore continues, consumption/resumption, synthesizers, multiple producers and bounded in-flight output are not delivered by the interface.
- [ ] **NATIVE — behavior/storage:** Pupperai, Flambella, Incineram, Grizzbolt displaced/sleep/wake, research, cooling, recycler/ranch/fixed work; actual activity/output, guild chest coverage and visible selected scope.

### D. Multiplayer and controls

- [x] **SIMULATED — session/authority:** undecided writers during transitions, isolated role state and generation-bound work. [Session](../tests/test_session.lua), [authority](../tests/test_authority.lua), [main integration](../tests/test_main_integration.lua), [caps isolation](../tests/test_caps_isolation.lua).
- [x] **SIMULATED — protocol/edit handling:** snapshot revision/completion, negotiation and modeled acknowledgement/pending-edit paths. [Protocol snapshots](../tests/test_protocol_snapshots.lua), [network reliability](../tests/test_net_reliability.lua).
- [x] **SIMULATED — stand inputs/rendering:** direct 1–5/X and navigation dispatch plus explicit draw outcomes. [Stand input](../tests/test_stand_input.lua), [UI rendering](../tests/test_ui_render.lua), [UI integration](../tests/test_ui_integration.lua).
- [ ] **NATIVE — multiplayer/input matrix:** solo/listen/dedicated, multiple owners/two guilds, unmodded edits, delayed/rejected edits, incomplete snapshots, incompatible versions, reconnect and host→client→host same map. Verify visible states and controller/keyboard focus.

- [x] **IMPLEMENTED — latest conservative readers:** distinguish empty roster from unavailable data, preserve partial off-list unknowns, prefer current client Role 2 over stale GameMode evidence, treat nil item IDs as unavailable stock, confirm restore by readback and preserve pending writes across policy edits. Covered by the completed code/UI isolated run; native gates unchanged.

- [x] **SIMULATED — F23 actual CLI before/after:** four cases in [main integration](../tests/test_main_integration.lua) fail before/pass after: fractional input, queued-client status, clear failure and unknown/unscoped stock. Legacy labels/current guild/base use verified panel_status evidence without blind rescans. Code/UI full run and Python safeguard rerun pass; the final manifest is recorded.

### E. Measurement and tools

- [x] **SIMULATED — profiler/log contracts:** explicit unmeasured counts, timed sample/window/resolution, inclusive nesting, bounded statistics and sink behavior. [Perf](../tests/test_perf.lua), [perf/log](../tests/test_perf_log.lua).
- [x] **SIMULATED — composition boundaries:** headless UI gating and request-bound completed/aborted pass behavior. [Main integration](../tests/test_main_integration.lua).
- [x] **SIMULATED — F24 stress/server tools:** exact-process selection/stop identity, checked lifecycle results, final liveness/error drain and actual dry-state validation. [Stress](../tests/test_stress.py), [server helper](../tests/test_server.py). Before/after regressions and expanded full rerun pass; actual process control remains untested.
- [x] **SIMULATED — diagnostic tooling:** read-only fingerprint/frame analyzer help, input schemas and fixtures tested. [Fingerprint](../tests/test_fingerprint.py), [frame analyzer](../tests/test_analyze_frames.py). Installed client/server snapshots collected; no live process or independent frames observed.
- [ ] **NATIVE — complete cost and frame capture:** root/phase spans and both logging sinks correlated with independent frames; repeated absent/present and profiler off/on, base/field/dungeon, cold/aged, closed UI/stand/rules/picker.
- [ ] **NATIVE — optimize proven spikes only:** declare budget, review worst events; no unsupported stutter-free or zero-cost claim.

### F. Packaging and follow-through

- [x] **SIMULATED — package/deploy contracts:** default_config mapping, manifests/exclusions and archive/deploy guards. [Release](../tests/test_release.py), [release/deploy](../tests/test_release_deploy.py); final full Python suite passes. No release archive was made. The later client test deployment is recorded above and does not establish native installation acceptance.
- [x] **ARTIFACT — carried pak:** hash/plain-index validation passed, v11/5,400 bytes; full hash/path recorded in the artifact section.
- [x] **DOCUMENTED — 65-comment traceability:** each public ID maps to findings/gates; grouped replies remain drafts. Alt+F1, priority.log, runtime limitations, legacy semantics and backup requirements are explicit.
- [ ] **NATIVE — actual clean installations:** Workshop/manual/update/removal, one loaded mod and mounted compatible pak; Vortex remains uncertified. Verify actual loaded fingerprints.
- [ ] **RELEASE — all applicable native gates:** no upload or posting from these simulated results. Optional high-quality-stand restriction remains deferred.

**No native item adapter or assignment reader is implied by any checked row.** The implementation and simulated tests are useful completed work; the corresponding unavailable native features and release gates remain open.

## Acceptance boundary

All checked SIMULATED groups above are completed implementation/model work, not native acceptance. The evidence snapshot holds automated results and artifact identity; unchecked NATIVE rows are the release gates. No producer control, manual-assignment reader, loaded-runtime proof or independent frame capture is supplied by passing isolated tests. Separate native observations and frame captures above supply limited evidence and expose remaining failures.

## Corrections to historical interpretation

- A route counter with no duration bracket cannot establish zero milliseconds or a >99.9% saving. Earlier memo/pulse observations prove route frequency only.
- Parent and child timing totals overlap. Pad drive/down/controller rows cannot be added as independent work.
- A ten-second cadence does not detect a 30–150 ms hitch; no errors do not prove no native risk.
- Retaining Generating Electricity in a fence does not prove generation continued or a displaced Pal returned. Handiwork permission does not prove bench activity.
- The August empty-field test kept two camps loaded; the no-camp abort branch was not exercised. Do not generalize it to all maps/server states.
- Existing save replacement was not crash-proof. A recoverable generation system still cannot promise every failure costs nothing.
- Ctrl+R and automatic UE4SS reload invalidated earlier assumptions and can affect other mods. Acceptance uses controlled full restarts.
- The comments' mod collection is a compatibility cohort, not evidence blaming another mod.

## Follow-through

### September 13 — performance bundle native restart and input test

[Measured restart results](performance-bundle-retest-2026-09-13.md): PID 9460 matches all 39 staged modules. Two idle windows reduce stand mean 24.0→20.8 ms and heartbeat worst 70–74→42–45 ms; label discovery falls 3.3–3.5→0.56–0.71 ms per grid. Three clean one-minute frame captures still retain a roughly one-second long-frame pattern; the first includes an unexplained 160 ms outlier. User confirms reopened numbers and ordered rapid/direct input; 47 drain slices still average 24.7 ms. Panel follow-up exposes remaining 12.4 ms host resolution and 101 ms maximum complete refresh. No all-stutter or release acceptance. Final snapshot: 75 ticks, 18 edits, zero mod errors; profiler off, panel closed, installed files unchanged. Storage/assignments remain unverified. Next measured targets and the misleading unavailable-stock “0 items” label are recorded in the report.

### September 13 — bundled performance fixes installed at 13:29

[Whole-mod inventory, changes and limits](performance-bundle-2026-09-13.md). Eight checked modules now separate expensive background callbacks, budget FIFO input/icon work, preserve current-tree label lookup with scalar hints, avoid unnecessary storage class reads, reuse local-controller evidence within callbacks and clear texture scopes after failed refreshes. Independent review found and reproduced three coordinator regressions; all are corrected. Final gates: 39 compiled Lua modules, 41 Lua regression scripts, 102 Python unittest cases, structural checking with the existing 194-local panel warning. All 39 installed/backup modules and 88 checked source/test hashes are verified. Runtime, pak and user configuration are unchanged; no hot reload. PID 34308 still runs the previous generation. Full restart/native measurements are required. Menu/camp sweeps, individual native-call spikes, multiplayer performance and broader release gates remain open; this is not an all-stutter-fixed claim.

### September 13 scoped-lookup restart

[Native performance retest](deep-performance-retest-2026-09-13.md) verifies PID 34308 and all 39 checked module hashes. All 117 cells remain discoverable; roster visits 909→639, roster mean 10.7→6.9 ms, complete stand refresh 27.2→24.0 ms. Incomplete storage scans occur on eight of 24 timed passes rather than every pass; uncertainty is preserved. Scheduler mean is 27–29 ms, but 45–47 ms peaks remain. Clean PresentMon recordings still show approximately one hitch per second, with worst intervals 74–77 ms including profiling off. Independent review confirms the bounded gains, not stutter-free acceptance. No native assignment/storage/output adapter or multiplayer acceptance is implied. Current-build reopen/input feedback remains pending; profiling is off and recorders have exited.

### September 12 native stand retest

[Full retest, source correction and evidence](stand-retest-2026-09-12.md). The installed text-leaf patch still leaves the grid unavailable: the completed diagnostic identified an unrelated input-prompt subtree, not a budget exhaustion (1990/4000 visits). Three unelevated frame recordings now work with the persistent Windows permission and show 56/57/56 Present intervals above 33.33 ms per minute. The complete stand refresh averages 37.474 ms. No stutter-free or functioning-scheduler acceptance follows from these readings.

A new source-only resolver restricts discovery to the current menu's unique named roster, with separate owner/roster completeness checks and no private-tree traversal during owner discovery. Three new failures reproduce before the patch; all 32 Lua regression scripts (33 stand cases), 39-module compilation and structural checks pass afterward. Independent review is closed after two corrections. Installation/restart/native painting and recapture are pending. The reference PalPriority downloads do not provide the missing manual-assignment, storage or producer adapters. Native release gates above remain open.

**19:12 update:** per the user's clarified workflow, the checked resolver is now installed, with automatic reload disabled and measurements finished. The old session exited before the final process check. All 39 modules/Info.json and the preserved previous generation were hash-verified. Full restart, actual loaded-version verification, painting and recapture remain pending; see the retest report's staging receipt. Future Lua staging may use this workflow after the same checks.

**19:23 native update:** [Restart retest](roster-native-retest-2026-09-12.md) verifies the new resolver in PID 32480, with all staged hashes matching. Nine rows show 33 priorities; all 117 scoped widgets are found (77 owner/909 roster visits). The user and a fresh screenshot confirm numbers after one close/reopen into a different menu instance. Three captures still show 54/52/54 intervals above 33.33 ms per minute. Complete stand refresh mean is 28.530 ms (previous broken session 37.474); scheduler mean 42.667 ms. This closes the observed grid-blocker reproduction and one reopen only. Remaining performance work begins with subregion timings; assignment/storage/output and broader lifecycle/multiplayer gates remain open.

**20:05 background check:** the same session has 274 automatic ticks from 19:16:45 to 20:05:22. Every one reports all 14 assignments unverified and storage unverified; total permission requests sent by these ticks is zero. No WARN/ERROR appears in the session's mod log. This explicitly confirms the automatic-allocation deferral remains active; a running loop and visible priorities must not be described as working scheduling or limits. [Data snapshot](../test-results/background-health-20260912.json).

The user's fresh-default question was verified against the actual configuration/store code using an isolated in-memory filesystem: positively fresh checked work becomes 1, unchecked becomes X, unrelated edits and save/load preserve both, and an existing root config follows upgrade behavior rather than resetting. The shipped legacy table is mixed 1–5, not uniformly 3. The three existing configuration/persistence/scheduler regression scripts and this focused check pass; native clean-install acceptance remains pending. [Focused check](../test-results/check-fresh-defaults-20260912.lua), [results](../test-results/check-fresh-defaults-20260912.txt). No player settings were changed.

**Stand input follow-up:** the user accepted fresh priority 1 and reported hovered number-key brackets plus laggy mouse cycling. The screenshot confirms the former; source and independent review identify the one-second queue-drain gate as a separate input-delay cause. The [input correction and retest record](stand-input-retest-2026-09-12.md) documents matching pointer-directed glyphs, 100 ms queue processing, client coalescing, one roster enumeration per action and affected-cell repaint. Three UI regressions fail before; all 32 regression scripts (39 stand cases), 39-module compilation and structural checks pass after. The checked correction was installed at 20:21 and hash-verified with a verified backup; next-restart native acceptance remains required. The 252-second pre-change sample still measures 28.818 ms stand refreshes and 42.708 ms scheduler passes, with no edit pass in that window. It cannot establish click latency or stutter elimination.

**22:29 rapid-click correction:** the restarted input build measured 27 input drains at mean 29.185 ms during the user's faster-click reproduction, with two native-bit adoptions logged. A failing regression demonstrates that the scheduler could overwrite numeric choices as X or 1. Adoption is removed; observed bits now update readback history only. A verified adapter for intentional unmodded-client checkbox edits remains unavailable. Fresh tree-name class reuse, one-controller-per-pad-sample reads with cancellation, deferred unused storage scans and existing-scan diagnostics are included. The final 39-module/33-script gate and independent review pass. Six changed Lua modules were installed with verified source/backup hashes; next restart and native speedup/click acceptance remain pending. Details and artifacts are in the linked retest record. Recurring camp enumeration/storage spikes and the broader release blockers remain open.

**22:31–22:51 follow-up:** the [restarted-build retest](jump-restart-2026-09-12.md) verifies all 39 installed hashes in PID 6192. Pad drive falls from 0.299 ms/call to 0.139–0.150; complete stand refresh remains approximately 30.2 ms and scheduler approximately 44 ms. Three 60-second captures record 56/57/56 intervals above 33.333 ms and approximately 82 ms worst frames, including with profiling off. No priority edit occurred in the saved session, so the jumping symptom remains unverified. Storage diagnostics identify 532 unknown-scope outcomes, without distinguishing empty IDs from failed reads. A further checked two-module patch removes exact childless-widget probes and preserves detailed GUID failure reasons from existing reads; it does not exclude unknown storage. All 33 regression scripts and independent review pass. Installed with verified backup at 22:51:40, pending the next full restart and native measurement.

**22:05 restart update:** PID 12896 started at 22:00:27 after the input-fix staging; all 39 hashes match, the new input-drain counter is present, and screenshots show the complete stand with plain `1`. The 128-second profile contains no queued-input samples or edit passes, so live click-response acceptance awaits the user sequence/feedback. Stand refresh mean remains 28.858 ms and scheduler mean 44.333 ms. Independent one-minute capture has 53 Present intervals over 33.333 ms, six over 50 ms and worst 86.324 ms; recurring stutter remains. Local authority is reported, but assignments/storage still lack verification. Profiling is off and the recorder has exited. [Evidence and independent review limits](stand-input-retest-2026-09-12.md).

Keep F21 and remaining convenience requests after blockers. Prepare comment replies from accepted evidence, not implementation intent. Before publishing, replace the candidate changelog with exact verified behavior and limitations, record release manifests and fingerprints, and link the evidence. If a required gate remains pending, the outcome is an unreleased candidate with an explicit remaining-work list.

**September 13, 18:00 frame-correlation update:** [Aligned recordings and absent-mod comparison](frame-correlation-2026-09-13.md) establish recurring moderate pauses associated with complete scheduler/camp and storage scans. Two absent clips still contain large 44-57 ms intervals; restored profiling-off clips retain 10/11 intervals over 16.67 ms per minute versus 2/2 absent. This is not a causal mean-FPS result: world activity and day/night progressed. Exact player settings/payload were backed up and restored; native authority/storage status and visible priorities were checked. All 43 modules compile and 54 Lua regressions pass; 18 focused Python regressions and the corrected structural checker pass. Profiling/recorders off; no release. Actual assignments, output control, multiplayer and lifecycle gates remain open.
