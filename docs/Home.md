---
date: 2026-10-20
tags: [records]
status: current
---
# Pal Work Priority: home

Related: [DECISIONS](DECISIONS.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md) · [LESSONS](LESSONS.md) · [testing](testing.md)

The project's notes as one Obsidian vault (open this `docs/` folder as a vault).
Every note has properties (`date`, `tags`, `status`: current, evidence, history)
and a Related line. Superseded notes were merged into these and deleted on
2026-10-20 ([vault-cleanup](vault-cleanup-2026-10-20.md)); git history keeps them.

## Start here

- [RELEASE-0.5.0](RELEASE-0.5.0.md): what ships and which gates are still open
- [DECISIONS](DECISIONS.md): what was decided and rejected, with evidence links
- [LESSONS](LESSONS.md): mistakes already paid for (read before engine work)
- [testing](testing.md): how to test and what counts as evidence

## Latest

- [Vault cleanup, 2026-10-20](vault-cleanup-2026-10-20.md) · 2026-10-20
- [Reliability candidate testing](testing.md) · 2026-10-20
- [G5: performance, 2026-10-19](g5-performance-2026-10-19.md) · 2026-10-20
- [G3: Search/Add crash with Cosmetic Outfits, 2026-10-20](g3-search-crash-2026-10-20.md) · 2026-10-20
- [G1 upgrade from 0.4.1 through the Workshop route, 2026-10-20](g1-workshop-2026-10-20.md) · 2026-10-20
- [0.5.0 release scope](RELEASE-0.5.0.md) · 2026-10-20
- [Lessons: mistakes this project already paid for](LESSONS.md) · 2026-10-20
- [Decision log](DECISIONS.md) · 2026-10-20
- [G6: old client and new server disagree politely, 2026-10-19](g6-version-mismatch-2026-10-19.md) · 2026-10-19
- [G6: guild isolation on rc1, 2026-10-19](g6-guild-isolation-2026-10-19.md) · 2026-10-19
- ["Everything stops" / "only one miner": reproduced, two causes, 2026-10-16/17](g4-scheduling-2026-10-17-miners.md) · 2026-10-17
- [G3: no second or stuck panel, 2026-10-17](g3-panel-2026-10-17.md) · 2026-10-17

## Release and reports

- [Work log, 2026-10-09 to 2026-10-11](work-log-2026-10-09-to-11.md) (history)
- [Remaining release gates - October 9, 2026](release-gates-2026-10-09.md)
- [0.5.0-rc1 reply drafts — not posted](release-replies-0.5.0-draft.md)

## Scheduling and limits

- ["Everything stops" / "only one miner": reproduced, two causes, 2026-10-16/17](g4-scheduling-2026-10-17-miners.md)
- [Coolers: same silent-station gap as generators, fixed, 2026-10-16](g4-scheduling-2026-10-16-coolers.md)
- [Continuous stations: generators count as demand, 2026-10-14](g4-scheduling-2026-10-14-stations.md)
- [G4: do Pals do what the stand says? 2026-10-12](g4-scheduling-2026-10-12.md)
- [Assignment reader investigation — September 25, 2026](assignment-reader-2026-09-25.md)
- [Base storage scope: September 13](storage-scope-2026-09-13.md)
- [Storage scheduling and dropped loot — September 13](storage-prefetch-2026-09-13.md)

## Performance

- [G5: performance, 2026-10-19](g5-performance-2026-10-19.md)
- [Stand edit latency: root-cause investigation, September 29](edit-latency-root-cause-2026-09-29.md)
- [PalPriority reference comparison and conditional transport lookup](palpriority-comparison-2026-09-26.md)
- [Blueprint lazy-icon experiment — 2026-09-14](icon-prototype-2026-09-14.md)
- [Frame correlation and physically absent-mod comparison, September 13](frame-correlation-2026-09-13.md)

## Stand and panel

- [G3: no second or stuck panel, 2026-10-17](g3-panel-2026-10-17.md)
- [G3: layout at every list size, 2026-10-17](g3-layout-2026-10-17.md)
- [G3: Escape, photo mode, death while editing, 2026-10-17](g3-escape-photo-death-2026-10-17.md)
- [Event-targeted stand mouse input — September 24, 2026](stand-pointer-2026-09-24.md)
- [Stand rebind and discovery safety — September 24, 2026](stand-lifecycle-2026-09-24.md)
- [Native stand keyboard input — September 24, 2026](stand-keyboard-2026-09-24.md)
- [Native stand reconstruction boundary — September 24, 2026](stand-close-events-2026-09-24.md)
- [Widget contract and pak build](widget-spec.md)
- [Native panel cursor correction — September 23](panel-cursor-2026-09-23.md)
- [Focused amount-editor Escape — September 23, 2026](editor-escape-2026-09-23.md)
- [Viewport and icon investigation — September 13, 2026](viewport-and-icon-retest-2026-09-13.md)

## Multiplayer and network

- [G1 upgrade from 0.4.1 through the Workshop route, 2026-10-20](g1-workshop-2026-10-20.md)
- [G6: old client and new server disagree politely, 2026-10-19](g6-version-mismatch-2026-10-19.md)
- [G6: guild isolation on rc1, 2026-10-19](g6-guild-isolation-2026-10-19.md)
- [G1 upgrade from 0.4.1, 2026-10-11](upgrade-041-2026-10-11.md)
- [Transmitter-first broadcast discovery — September 29](transmitter-first-2026-09-29.md)
- [Broadcast lifetime safety — September 29](push-lifetime-2026-09-29.md)

## Saving

- [G1 restart persistence: code review against the reports, 2026-10-11](restart-persistence-2026-10-11.md)
- [Save flush/close investigation — September 29](save-flush-2026-09-29.md)
- [Other mods: persistence comparison — September 29](reference-persistence-2026-09-29.md)

## Async saving (optional, G2b)

- [Staged reservation recovery — October 11](staged-reservation-recovery-2026-10-11.md)
- [Native staged-reservation recovery acceptance — October 11](staged-recovery-native-2026-10-11.md)
- [Dedicated async: next evidence gates — October 9, 2026](dedicated-async-next-gates-2026-10-09.md)
- [Asynchronous saving enablement — October 4, 2026](async-enablement-2026-10-04.md)
- [Positive absence and first initialization review](save-initialization-review-2026-10-04.md)
- [World-scoped identity across host/client transition — October 4, 2026](async-save-world-transition-2026-10-04.md)
- [Async saving: SDK access and alternative entry route](async-save-route-research-2026-10-04.md)
- [Async save: routes tried and rejected (Blueprint trial, 2026-09-29 to 2026-10-04)](async-save-history.md) (history)
- [Save-session controller — October 3, 2026](async-save-session-2026-10-03.md)

## Crashes and research

- [G3: Search/Add crash with Cosmetic Outfits, 2026-10-20](g3-search-crash-2026-10-20.md)
- [Search-crash sidecar — September 15, 2026](search-crash-2026-09-15.md)
- [The recurring crash](the-crash.md)
- [Research: the crash is a known UE4SS class, and the cure ships in our build](research-ue4ss-crash.md)

## Testing and tooling

- [PresentMon capture procedure and evidence boundaries](frame-capture-procedure-2026-10-09.md)
- [Public report census (comment ledger)](comment-ledger-2026-09-11.md)

## Outside the vault (repo files, open on GitHub or in an editor)

- [README](../README.md), [CHANGELOG](../CHANGELOG.md) (ships in the release archive)
- [AGENTS](../AGENTS.md) and [CLAUDE](../CLAUDE.md): rules for coding agents
- Async experiment READMEs next to their code: `experiments/*/README.md`,
  `experiments/save_*.md`, `native/save_core/*.md`
- `docs/asset-contract.json`: read by tools/release.py, keep its path
