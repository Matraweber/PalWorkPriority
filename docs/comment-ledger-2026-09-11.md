# Public comment ledger — 2026-09-11

September 15 update: [six new comments and one bug report](comment-update-2026-09-15.md), bringing the historical count to 71 comments plus one bug. The original 65-entry audit below remains unchanged.

**65 entries: 52 Steam comments across six pages, 13 Nexus comments/replies across two pages.** Includes author responses, requests, withdrawn reports and nested replies; 65 entries does not mean 65 distinct defects. This preserves the completed audit, without claiming a new browse or a new reproduction.

Target: **0.5.0-rc1 reliability candidate, unpublished**. Finding IDs map to [the reliability ledger](reliability-2026-09-11.md). Gate definitions and required evidence are in [testing](testing.md). All native acceptance is pending. No entry is marked fixed by this documentation task.

Dates/times are as recorded in the audit. Relative newest timestamps were normalized to dates, not invented exact times. Authors are public display names, not identity conclusions. Paraphrases are brief and do not reproduce full comments.

Status: **A** = matching defect/path identified in code or visual evidence; native causality/full regression remains pending. **R** = symptom reported, reproduction pending. **Q** = request, planned/deferred as indicated. **C** = context, reply, praise or withdrawal; no independent bug asserted. Multiple symptoms in one entry need separate tests. Numeric resets must not all be attributed to the proven X serialization defect.

## Current disposition

The [canonical reliability ledger](reliability-2026-09-11.md) contains implementation status, before/after regressions, counts, hashes and all native gates. Public comments remain unresolved as native reports until their specific acceptance cases pass. F22–F24 are internal follow-up findings, not additional public comments; the total stays **65**. Reply drafts are [here](release-replies-0.5.0-draft.md).

## Steam — 52 entries

Source: [all Steam comments](https://steamcommunity.com/sharedfiles/filedetails/comments/3786408856). Individual links use the public comment ID.

| # | Public ID / source | Recorded date | Author | Paraphrase | Finding | Reproduction / test gate | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | [569297137117056872](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_569297137117056872) | 2026-09-11 | jeje | Still not working; no specific reproduction supplied. | F11/F16 | GENERAL: obtain concrete failure; SCHED/PERF | R |
| 2 | [569297137116983208](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_569297137116983208) | 2026-09-10 | Zekrom144 | Photo mode in a Pal bed leaves a giant grey box until restart. | F06 | UI: bed/photo mode/close/restart | R |
| 3 | [568171134404616876](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_568171134404616876) | 2026-09-10 01:22 | SolidRhoé | Removing the stone cap restores metal mining. | F07 | PRODUCER: stone cap versus ore output | A |
| 4 | [568171134404616830](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_568171134404616830) | 2026-09-10 01:21 | SolidRhoé | Stone limit prevents Rushoar/Mammorest mining metals. | F07 | PRODUCER: independent output controls | A |
| 5 | [568171134404611135](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_568171134404611135) | 2026-09-10 00:09 | KhanKeal | New test still appears to choose priorities randomly. | F09/F11 | SCHED: ready jobs, assignment and output trace | R |
| 6 | [568171134404611112](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_568171134404611112) | 2026-09-10 00:08 | KhanKeal | Flambella with Handiwork 1, Kindling 2, Transporting 3, Ranching 4 stays ranching or appears reversed. | F09/F11/F18 | SCHED: Flambella; balanced/strict comparison | R |
| 7 | [568171134404611086](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_568171134404611086) | 2026-09-10 00:08 | KhanKeal | Pupperai ignores logging 1; all-1 setup also differs from expected farm/food/transport/fire-organ work. | F09/F11 | SCHED: Pupperai and all-1 output trace | R |
| 8 | [583933421007658600](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933421007658600) | 2026-09-08 01:33 | UltraJohn | Stutter every few seconds. | F15/F16 | PERF: matched scenes with external frames | R |
| 9 | [583933421007651709](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933421007651709) | 2026-09-08 00:01 | AstraFulminae | Explains that the author is away, not abandoning the mod. | F20 | DOCS: status communication; no game regression | C |
| 10 | [583933421007650137](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933421007650137) | 2026-09-07 23:40 | Rey | General frustration with bugs. | F11/F20 | GENERAL: connect to specific reproduction | R |
| 11 | [583933421007537011](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933421007537011) | 2026-09-06 21:15 | AstraFulminae | Notes author absence. | F20 | DOCS: release/status communication | C |
| 12 | [583933421007529174](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933421007529174) | 2026-09-06 19:50 | Rey | Reports ongoing bugs and lack of update. | F11/F20 | GENERAL: connect to specific reproduction | R |
| 13 | [583933421007428252](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933421007428252) | 2026-09-05 18:20 | Gim1i | Escape during amount editing crashes; retracts earlier version assumption. | F04 | UI: Escape while editing, native crash evidence | R |
| 14 | [583933421007426843](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933421007426843) | 2026-09-05 18:05 | Gim1i | Priorities reset. | F01/F02/F03 | PERSIST: numeric/X restart and unrelated edits | R |
| 15 | [583933098654411549](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933098654411549) | 2026-09-04 15:27 | coolmunch | Alt+F1 and mod stopped working; suspects September UE4SS update. | F17 | PACKAGE/UI: actual runtime, mounting and input | R |
| 16 | [583933098654349936](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933098654349936) | 2026-09-03 20:00 | Bernie Laplante | Alt+F1 causes FPS drop and prevents interaction except Escape. | F04/F06/F16 | UI/PERF: opening and input ownership with frames | R |
| 17 | [583933098654267714](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933098654267714) | 2026-09-02 22:24 | BIG DADDY | Ore reaches roughly twice its limit while mining continues. | F07/F19 | PRODUCER/STORAGE: groups, counts and in-flight output | R |
| 18 | [583933098654266122](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933098654266122) | 2026-09-02 22:05 | Calas Typhon | Alt+F1 panel gets stuck until restart. | F04/F06 | UI: repeat open/close and vanilla handoff | R |
| 19 | [583933098654257764](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933098654257764) | 2026-09-02 20:18 | Drokz077 | Multiplayer duplicate Rules panels; one persists until forced exit; asks about both-side install. | F06/F17 | UI/PACKAGE: one instance, client/server install | R |
| 20 | [583933098654232901](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933098654232901) | 2026-09-02 14:14 | spleenszuru | Priorities return to defaults after restart. | F01/F02/F03 | PERSIST/CONFIG: all values across restart/update | R |
| 21 | [583933047672432935](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933047672432935) | 2026-09-01 16:55 | Maritisa | Positive feedback and request to reverse priority values. | F18 | INPUT/DOCS: explain 1 highest; preserve saved values | Q |
| 22 | [583933047672426123](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583933047672426123) | 2026-09-01 15:33 | Reudo | Explains smallest-number-first convention used elsewhere. | F18 | DOCS: priority legend | C |
| 23 | [583932755647381077](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932755647381077) | 2026-09-01 08:44 | Han Byeol | Finds value order confusing, though usable. | F18 | INPUT/DOCS: visible priority legend | Q |
| 24 | [583932755647334104](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932755647334104) | 2026-08-31 17:46 | TheJoe | Requests controller navigation on Monitoring Stand. | F18 | INPUT: stand controller, focus and Deck layout | Q |
| 25 | [583932755647312297](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932755647312297) | 2026-08-31 12:25 | MaD | Settings reset on restart. | F01/F02/F03 | PERSIST/CONFIG: distinct numeric and X cases | R |
| 26 | [583932755647282559](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932755647282559) | 2026-08-31 00:31 | Samurai9400 | Research assignment is grey despite correct skill; Palbox roundtrip helps temporarily. | F11 | SCHED: research/fixed assignment and restart | R |
| 27 | [583932755647282394](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932755647282394) | 2026-08-31 00:28 | GammaEuviex | Default transporting disrupts Vanwyrm cooling and Sekhmet handiwork; requests checked→1 and unchecked→X. | F03/F11/F18 | CONFIG/SCHED: genuine fresh baseline and specialist work | Q |
| 28 | [583932755647221955](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932755647221955) | 2026-08-30 10:04 | Drokz077 | Gportal stand grid blank while limits panel works. | F13/F17 | SYNC/UI: server identity, snapshots and row rendering | R |
| 29 | [583932755647192537](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932755647192537) | 2026-08-29 22:40 | Matraweber | Author explains absence over a week and intent to address issues/requests. | F20 | DOCS: update status accurately | C |
| 30 | [583932464793370970](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793370970) | 2026-08-29 02:51 | lainverse | UE4SS print output lacks a newline. | F20 | LOG: distinct framed lines in both sinks | A |
| 31 | [583932464793370119](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793370119) | 2026-08-29 02:35 | lainverse | Sekhmet ignores recycler; ranch X resets; coal synthesizer/wood cap says Waiting while producing; command replies unclear; lines concatenate. | F01/F07/F11/F19/F20 | PERSIST/SCHED/PRODUCER/STORAGE/LOG: separate each symptom | R |
| 32 | [583932464793368834](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793368834) | 2026-08-29 02:12 | ThatFawker | Ranch X resets on server and displaces intended ranchers. | F01/F02/F12 | PERSIST/SESSION: server save and actual ranch occupancy | A |
| 33 | [583932464793335638](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793335638) | 2026-08-28 18:23 | NoAhQ | Requests direct 1–5/X; slow multiplayer clicks; preserve mouse; vanilla clients' edits revert. | F13/F14/F18 | SYNC/INPUT: rapid pending edits and unmodded writes | Q |
| 34 | [583932464793333571](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793333571) | 2026-08-28 17:51 | Rey | Lamball reports insufficient ranch skill. | F11 | SCHED: actual skill/permissions/manual assignment | R |
| 35 | [583932464793333542](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793333542) | 2026-08-28 17:51 | Rey | Cannot assign ranch early-game without a stand. | F03/F11 | CONFIG/SCHED: initial choices and manual assignment | R |
| 36 | [583932464793331761](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793331761) | 2026-08-28 17:22 | NoAhQ | Vanilla edits revert after 5–10 seconds; links video. | F14 | AUTH/SYNC: distinguish vanilla and mod writes | R |
| 37 | [583932464793327823](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793327823) | 2026-08-28 16:21 | NoAhQ | Server works after all-X then priorities; possible old PalPriority conflict suggested. | F13/F14/F17 | SYNC/PACKAGE: minimal baseline; conflict unproved | R |
| 38 | [583932464793289514](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793289514) | 2026-08-28 02:14 | [TLD]Bob77 | Requests guild-chest stock accounting. | F19 | STORAGE: shared container counted once per scope | Q |
| 39 | [583932464793239612](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793239612) | 2026-08-27 12:22 | luller | Reports stutter. | F15/F16 | PERF: full costs and external frame correlation | R |
| 40 | [583932464793238807](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793238807) | 2026-08-27 12:05 | Ashura | Corroborates Plz's stutter report. | F15/F16 | PERF: matched minimal/compatibility scenes | R |
| 41 | [583932464793222422](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793222422) | 2026-08-27 05:31 | Ruse Spark | Disabled checkbox flashes before priority, yet Pals sometimes refuse work. | F11/F13 | UI/SCHED: repaint separately from actual work refusal | R |
| 42 | [583932464793189457](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793189457) | 2026-08-26 20:02 | NoAhQ | Asks about DatHost dedicated support. | F17/F14 | PACKAGE/AUTH: actual dedicated install and edits | Q |
| 43 | [583932464793183873](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793183873) | 2026-08-26 18:49 | CosmicWarbear | Acknowledges author reply. | F11 | SCHED: retain linked generator case; no new symptom | C |
| 44 | [583932464793183238](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793183238) | 2026-08-26 18:42 | Matraweber | Author says generator issue located and fix planned. | F11 | SCHED: historical claim requires output evidence | C |
| 45 | [583932464793179237](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793179237) | 2026-08-26 17:57 | CosmicWarbear | Electric Pals stop and cannot be forced back despite priority 1; mentions ranch/schema mods. | F11/F16 | SCHED: occupied/displaced generator; conflict unproved | R |
| 46 | [583932464793173964](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793173964) | 2026-08-26 16:44 | Matraweber | Author investigating Plz's stutter. | F16 | PERF: historical response, no acceptance evidence | C |
| 47 | [583932464793173898](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793173898) | 2026-08-26 16:43 | Matraweber | Author investigating Glave's priority report. | F11 | SCHED: historical response, no acceptance evidence | C |
| 48 | [583932464793173844](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793173844) | 2026-08-26 16:42 | Gobi Slave | Positive feedback. | F20 | DOCS: acknowledge; no regression requested | C |
| 49 | [583932464793172592](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793172592) | 2026-08-26 16:24 | Plz | Each-second stutter, worse at base; links mod collection. | F15/F16 | PERF: minimal baseline then compatibility cohort | R |
| 50 | [583932464793169598](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793169598) | 2026-08-26 15:34 | Glave | Incineram with Handiwork 1/refining 2 prefers refining. | F09/F11 | SCHED: simultaneous bench/fire demand and output | R |
| 51 | [583932464793166165](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793166165) | 2026-08-26 14:34 | Matraweber | Author announces dedicated-server update. | F17 | PACKAGE/AUTH: historical announcement not current proof | C |
| 52 | [583932464793164785](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_583932464793164785) | 2026-08-26 14:09 | Vik Beilier | Asks about dedicated-server support. | F17/F14 | PACKAGE/AUTH: populated dedicated integration | Q |

## Nexus — 13 entries

Source: [Nexus posts](https://www.nexusmods.com/palworld/mods/5376?tab=posts). IDs identify the exact public posts/replies; the source link opens their thread listing.

| # | Public ID / source | Recorded date | Author | Paraphrase | Finding | Reproduction / test gate | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 53 | [175005468](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-09-05 01:50 | Toomy141 | Requests exact UE4SS distribution link. | F17 | PACKAGE/DOCS: exact distribution and loaded fingerprint | Q |
| 54 | [174899004](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-09-03 07:16 | Hall9002 | Rules second-page pager overlaps amount controls; linked screenshot. | F05 | UI: 13/14/26/27 rows, 16:10 and scaling | A |
| 55 | [174887787](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-09-03 02:02 | srvtsonn | Default hauling takes priority over cooling/grazing. | F03/F11/F18 | CONFIG/SCHED: fresh baseline and specialist behavior | R |
| 56 | [174870843](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-09-02 20:01 | skoomabaptism | Withdraws earlier report with edit. | F20 | DOCS: withdrawn; no remaining reproduction supplied | C |
| 57 | [174818817](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-09-01 21:05 | Saber57Draxus | Vortex install does not work. | F17 | PACKAGE: actual Vortex paths, activation and asset | R |
| 58 | [174842730](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-09-02 07:12 | sandwichmaker3000 | Reply suggests manual install. | F17 | PACKAGE: advice is not proof of Vortex cause | C |
| 59 | [174715896](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-08-31 01:15 | decamhian | Manual install with experimental UE4SS; Alt+F2 does not open anything. | F17/F20 | PACKAGE/DOCS: Alt+F1 panel key; verify install separately | R |
| 60 | [174660384](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-08-30 04:26 | valdacil | Restart loses ranch X choices and fixed assignments. | F01/F02/F11 | PERSIST/SCHED: settings and native fixed work separately | A |
| 61 | [174579909](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-08-28 19:58 | Damokles | Asks if this is a clone of PalPriority, linking mod 3830. | F20 | DOCS: independent implementation and credits | Q |
| 62 | [174634620](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-08-29 19:10 | giorgn | Reply compares mods; slow UI and unmodded-client reverts; values resource caps. | F13/F14/F16 | SYNC/PERF: latency, vanilla edits and output semantics | R |
| 63 | [174562344](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-08-28 13:03 | NoNickNeeded | Requests optional high-quality-stand-only restriction. | F21 | OPTIONAL: deferred until blockers pass | Q |
| 64 | [174525705](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-08-27 19:22 | fardriel | Positive feedback. | F20 | DOCS: no regression requested | C |
| 65 | [174491988](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-08-27 02:52 | Siberfox99 | Roughly twelve-second log/tick hitch; suspects runtime logging because other mods can trigger it. | F15/F16/F20 | PERF/LOG: both sinks and runtime controls; cause unproved | R |

## Linked evidence and its limits

- [Hall9002's screenshot](https://ibb.co/pvTLHFpV) was viewed during the audit: 2560×1600, 16 rules, pager overlapping list rows/amount controls. It corroborates the layout symptom; it does not identify every faulty cache/parent transition.
- [Plz's collection](https://steamcommunity.com/sharedfiles/filedetails/?id=3790433214) contained 34 mods in the audit, including transport/stacking/feeding/stutter, ranch/schema and UI/graphics modifications. Treat it as a compatibility cohort after a minimal baseline. Membership proves no conflict or culprit.
- [NoAhQ's linked video](https://vimeo.com/1222120759) was recorded as a link; playback was not part of the audit. The user report still requires a native reproduction.
- [PalPriority reference](https://www.nexusmods.com/palworld/mods/3830) provides context for comparisons and earlier investigations, not proof of this candidate's behavior.
- [UE4SS dependency](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587) identifies the intended distribution. Its advertised September revision differs from the August test log; actual loaded compatibility remains unaccepted.

## Consolidation and reply tracking

| Report group | Findings | Current reproduction/evidence position | Reply draft |
| --- | --- | --- | --- |
| Lost X / numeric settings / update | F01–F03, F12 | X regression fails actual baseline/passes candidate in isolation; numeric resets, fixed-assignment loss and native migration require distinct tests | Settings and recovery |
| Escape, stuck/duplicate/grey panels | F04–F06 | Handoff/cache paths identified; native crash and photo/duplicate causes unproved | Panel and input |
| Priority, research, cooling, ranching, generation | F08–F11, F18 | Idle/unknown-scope baseline failures confirmed; assignment_reader nil; actual work/output matrix pending | Scheduling and assignments |
| Stone/ore, overshoot, synthesizers, guild storage | F07/F19; internal F22 | Legacy semantics and inherited-clear OFF masks implemented; regression added; no accepted native item-specific adapter | Production and storage |
| Blank/slow client UI and reverting vanilla edits | F12–F14/F18 | Snapshot/render/edit paths identified; two-guild and mixed-client tests pending | Multiplayer and controls |
| Stutter and logging | F15/F16/F20 | Earlier timing gaps confirmed; matched current-runtime frame evidence missing | Performance |
| Install/runtime/key discovery | F17/F20 | Correct Alt+F1 instruction and intended dependency documented; clean routes/current runtime/Vortex unaccepted | Installation |
| High-quality stand restriction | F21 | Optional request intentionally deferred | Optional access restriction |

Reply drafts are in [release-replies-0.5.0-draft.md](release-replies-0.5.0-draft.md). **Posting status: none posted by this implementation task.** Update each group only after attaching evidence; do not imply every comment in a group shares a cause or is resolved together.
