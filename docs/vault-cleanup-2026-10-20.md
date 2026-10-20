---
date: 2026-10-20
tags: [records, release]
status: done
---
# Vault cleanup, 2026-10-20

Related: [DECISIONS](DECISIONS.md) · [Home](Home.md)

## Result (carried out 2026-10-20, user approved the list)

- 78 files deleted (73 notes, 5 evidence JSONs of deleted notes); 53 notes
  remain, each with properties and a Related line, listed in [Home](Home.md).
- New: [async-save-history](async-save-history.md) (the rejected Blueprint
  routes), [work-log-2026-10-09-to-11](work-log-2026-10-09-to-11.md) (split
  out of release-gates unchanged), moved
  [save-initialization-review-2026-10-04](save-initialization-review-2026-10-04.md).
- Facts from deleted notes went into DECISIONS (new "Multiplayer and network"
  section, UI and input, rejected lists, the cutover fence, locked legacy
  limits, stand refresh justified), LESSONS, testing, widget-spec,
  comment-ledger (one census with F01-F87), g5 History and the merged notes.
- Every link to a deleted file was repointed (README, CHANGELOG, AGENTS,
  native/save_core/README, a ui.lua comment); a scan finds 0 broken links.
- Corrections found on the way: the stand skip was the rejected dirty-flag
  gating (dropped, LESSONS); the remote panel reply is confirmed since
  2026-09-23; testing.md's assignment reader note was stale.

## The plan as approved

The user asked to make docs/ a Palworld Obsidian vault, put every note in it,
make the notes fit together, and remove notes our later decisions made stale
(user's choices 2026-10-20: the vault stays in the repo; stale notes are merged,
then deleted, git history keeps them; the list is shown before deleting).
Four read-only agents classified all 122 notes plus the markdown outside docs/.

## What stays where

- **The vault is `docs/`.** Every note gets properties (`date`, `tags`,
  `status`) and a `Related:` line; `Home.md` is the entry page (Latest, then
  topics). Links stay plain markdown links so GitHub renders them too.
- **Stays at the repo root** (tools and stores read them there): README.md,
  CHANGELOG.md (ships in the release archive), AGENTS.md, CLAUDE.md. Home.md
  links them.
- **Stays next to its code**: the READMEs and module contracts under
  `experiments/` and `native/save_core/` (installers, tests and headers point
  at them). Home.md lists them. Moved into the vault:
  `experiments/save-initialization-review-20261004.md` (a dated review), now
  [save-initialization-review-2026-10-04](save-initialization-review-2026-10-04.md).
- **Stays at its exact path**: `docs/asset-contract.json` (tools/release.py
  reads it; its text names widget-spec.md and stand-keyboard-2026-09-24.md).

## Kept (current, or evidence a current decision or open gate rests on): 49

Core: DECISIONS, LESSONS, RELEASE-0.5.0, testing, widget-spec,
release-gates-2026-10-09 (cut to its §1-6 backlog), release-replies-0.5.0-draft,
comment-ledger-2026-09-11, frame-capture-procedure-2026-10-09.
Gates: g3-escape-photo-death, g3-layout, g3-panel (2026-10-17), g4-scheduling
x4, g5-performance-2026-10-19, g6-guild-isolation, g6-version-mismatch,
restart-persistence-2026-10-11, upgrade-041-2026-10-11,
search-crash-2026-09-15 (open G3 gate).
Engine and design evidence: the-crash, research-ue4ss-crash,
assignment-reader-2026-09-25, palpriority-comparison-2026-09-26,
reference-persistence-2026-09-29, edit-latency-root-cause-2026-09-29,
transmitter-first-2026-09-29, push-lifetime-2026-09-29, save-flush-2026-09-29,
icon-prototype-2026-09-14, editor-escape-2026-09-23, panel-cursor-2026-09-23,
frame-correlation-2026-09-13, viewport-and-icon-retest-2026-09-13,
storage-scope-2026-09-13, storage-prefetch-2026-09-13,
stand-pointer/-lifecycle/-keyboard/-close-events (2026-09-24; CHANGELOG links
three of them).
Optional async (G2b may still ship it): async-enablement-2026-10-04,
async-save-route-research-2026-10-04, async-save-world-transition-2026-10-04,
async-save-session-2026-10-03, staged-reservation-recovery-2026-10-11,
staged-recovery-native-2026-10-11, dedicated-async-next-gates-2026-10-09,
save-initialization-review-2026-10-04 (moved in).

## Merged into a kept note, then deleted: 16

| Deleted | Goes into |
|---|---|
| comment-update-2026-09-15, -09-23, -10-09 | comment-ledger-2026-09-11 (one census) |
| edit-broadcast-2026-09-29, edit-context-2026-09-29 | edit-latency-root-cause-2026-09-29 |
| push-phases-2026-09-29, stand-push-discovery-2026-09-29 | transmitter-first-2026-09-29 |
| save-phases-2026-09-29 | save-flush-2026-09-29 |
| async-save-scratch-2026-09-29, async-save-transport-2026-10-03 | async-save-session-2026-10-03 |
| async-save-transition-2026-10-03, async-save-world-identity-2026-10-03, async-save-world-reverse-2026-10-04 | async-save-world-transition-2026-10-04 |
| destination-leases-2026-10-11 | staged-reservation-recovery-2026-10-11 |
| overlay-plan | widget-spec (pak build toolchain section) |
| server-restart-2026-09-25 | testing (server macro section) |

## Superseded, facts kept elsewhere, then deleted: 57

Their still-useful facts (measurements, rejected approaches, traps) move into
the named target before the file goes.

- **Async Blueprint trial history (12)** → new `async-save-history` note (the
  rejected routes with their numbers): async-save-authority, -destination,
  -events, -events-warm, -identity, -idle, -lifetime, -mailbox, -process, -ram,
  -scoped, -warm.
- **Parked async cutover tooling (7)** → async-enablement (background section):
  dedicated-clock-probe, installation-fence, native-rollback,
  settings-cutover-fixture, settings-export (2026-10-11), native-file,
  native-handoff (2026-10-04). The live `.settings-cutover` startup fence in
  main.lua gets a DECISIONS entry.
- **September performance (17)** → g5-performance "History" section, rejected
  ideas → DECISIONS: deep-performance-retest, performance-bundle,
  performance-bundle-retest, performance-investigation, remaining-stutter,
  stand-cost-retest, stand-name-retest, stand-tree-phases,
  roster-read-retest, scheduler-read-reuse (2026-09-13), jump-restart,
  roster-native-retest, stand-retest, stand-input-retest (2026-09-12),
  stand-capture-2026-09-11, performance-2026-09-15,
  panel-storage-refresh-2026-09-15.
- **Closed UI and input bugs (15)** → DECISIONS "UI and input", LESSONS,
  testing: edit-reflow, rule-reveal, remove-conflict, panel-partial-tree,
  pal-activity, respawn-guard (2026-09-25), panel-handoff, photo-editor-followup,
  respawn, frontend-followup (2026-09-24), monitor-retest, offline-reliability,
  restart-input-investigation (2026-09-23), panel-cancel-2026-09-15,
  native-escape-2026-09-16.
- **Old ledgers and plans (6)** → RELEASE, comment-ledger, DECISIONS:
  reliability-2026-09-11 (finding IDs F01-F24 → comment-ledger),
  report-status-2026-09-13, open-issues-2026-09-23, audit-2026-08-26,
  multiplayer-plan, reference-ui-comparison-2026-09-13, and the evidence JSONs
  of deleted notes (implementation-, native-smoke- 2026-09-11,
  roster-native- 2026-09-12, stand-capture- 2026-09-11, stand-retest-
  2026-09-12).

Two open items found only in old notes move to release-gates §3/§4 instead of
being lost: hovering a priority cell leaves vanilla's right-hand Pal detail on
the previous Pal (pal-activity); edits by two owners at once have only a client
check, no server compare-and-set (photo-editor-followup, remove-conflict).

## Stale lines inside kept notes (fixed in the same pass)

- RELEASE G5 "Starting point" still quotes September numbers; the matched
  baseline of 2026-10-19 replaces it. "camp FindAllOf needs a decision" is
  decided. G3 gets the missing link to search-crash-2026-09-15; Deferred links
  dedicated-async-next-gates.
- DECISIONS: the 10-14..10-17 station entries sit under "Test installation"
  (move to "Scheduling and limits"); the 0.5 rule "new legacy limits are
  locked" exists only in LESSONS and code (add it); the 10-03 GameState entry
  gets its merged evidence; the targeted-widget entry (09-13) gets its evidence
  link.
- **Conflict found:** DECISIONS 2026-08-27 rejects "dirty-flag refresh gating
  (reintroduces the repaint bug that bit three times)". The stand "skip when
  nothing changed" the user chose to investigate on 2026-10-19 is that idea; it
  was proposed without reading the rejected list. Needs the user's call.
- LESSONS: panel.lua local count (198 then, 194 now).
- testing.md: "Current evidence" and the restart-helper pointer name September
  notes; repoint, add the server macro and PresentMon permission facts.
- g4-scheduling-2026-10-12 "still open" list, g4-...-14-stations title
  ("RETRACTED"), g3-escape-photo-death "not covered", g6-version-mismatch "not
  yet verified": each later passed in the same file; mark them.
- README/CHANGELOG links to deleted notes are repointed (README: release-gates,
  comment-update, reliability; CHANGELOG: performance-bundle, reliability).
