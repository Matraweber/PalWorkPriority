---
date: 2026-10-09
tags: [release]
status: current
---
# Remaining release gates - October 9, 2026

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [work-log-2026-10-09-to-11](work-log-2026-10-09-to-11.md) · [dedicated-async-next-gates-2026-10-09](dedicated-async-next-gates-2026-10-09.md)

> Status 2026-10-20: the current ship list is [RELEASE-0.5.0](RELEASE-0.5.0.md)
> (since 2026-10-11). This note is the wider backlog behind it: sections 1-6
> keep the items RELEASE does not cover, most of them deferred past 0.5.0.

Candidate: unpublished 0.5.0-rc1. This is the current checklist, not a claim
that every older unchecked item remains unfixed. Historical reports retain
their original evidence. Public/default and dedicated native async are OFF;
the checked local combined async trial is an exception. The user authorized
implementation and testing of the whole remaining list.

## Evidence added today

- Local manual-runtime dedicated fixture: authenticated legacy Stone limit edit
  35,000 → 35,001, synchronous server persistence, normal client/server shutdown
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
- [ ] Listen-host, respawn and host→client→host transitions on the same map.
- [ ] Two owners editing at once: stale-draft and removal guards compare only
  the client's observed snapshot; no server compare-and-set, so unseen
  concurrent updates and same-value delete/recreate go undetected.

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
- [ ] Hovering priority cells leaves vanilla's right-hand Pal detail on the
  previous Pal (name/portrait did not refresh it; an untouched battle checkbox
  does). Seen 2026-09-25 on RAM; cause unproven.

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
  bugs read in logged-in Chrome October9. [Current delta](comment-ledger-2026-09-11.md)
  preserves report-to-finding links; this does not close reported defects.
- [ ] Update installation/testing/removal documentation, changelog and grouped
  replies. Posting/publishing follows release acceptance, not test completion alone.
- [ ] Optional high-quality-stand restriction and Pal-produced material support.
- [ ] Optional independent priority/limit components; controls hints and
  consistent wraparound; assess UI-edit coalescing without relying on close.

## Work log

The running log of October 9-11 (dedicated identity observer, capture smoke,
frontend recovery, persistence cost, async acknowledgement, cutover fence,
rollback and reservation recovery, release package acceptance) moved to
[work-log-2026-10-09-to-11](work-log-2026-10-09-to-11.md).
