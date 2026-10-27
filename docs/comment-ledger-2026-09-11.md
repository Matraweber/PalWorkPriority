---
date: 2026-10-27
tags: [reports]
status: current
---
# Public report census (comment ledger)

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [release-replies-0.5.0-draft](release-replies-0.5.0-draft.md) · [search-crash-2026-09-15](search-crash-2026-09-15.md)

The one census of public Steam and Nexus reports for Pal Work Priority. It
started as the 2026-09-11 audit and now also holds the later deltas (2026-09-13,
-09-15, -09-23, -10-09) and the finding IDs F01-F24 that the reply drafts key
on. Gate status lives in [RELEASE-0.5.0.md](RELEASE-0.5.0.md); how to test is in
[testing.md](testing.md); reply drafts are in
[release-replies-0.5.0-draft.md](release-replies-0.5.0-draft.md).

**Status 2026-10-21** (open reports against the [0.5.0 gates](RELEASE-0.5.0.md)):
G1 settings: restart persistence PASS 2026-10-11 (Two Bob Games, johndujo and
the earlier reset reports; like's X diagnosis D1), 0.4.1 upgrade PASS on both
routes (Workshop 2026-10-20).
G3 frontend: second/stuck panel PASS (Extramrdo, Okami_sama Sep 18 10:32,
Calas Typhon, Drokz077), layout PASS (Hall9002), Escape/photo/death PASS
(Gim1i; the original crash was never reproduced), Search/Add crash with item
mods fixed 2026-10-20 (DarkWyrmReaper B1, NoMo/Omoface 88/B3,
[g3-search-crash-2026-10-20](g3-search-crash-2026-10-20.md)); **open:** the
Pal bed + photo mode grey box (Zekrom144, Roin 89): PASS on rc1 2026-10-21. G4 scheduling:
priority 1 over 5 PASS (HelpImStupid0), Incineram PASS (Glave), generators
fixed 10-14 (CosmicWarbear, DSFddaaaa), coolers fixed 10-16 (poiman,
GammaEuviex, srvtsonn), "only one miner / everything stops" fixed 2026-10-17
(Okami_sama, SolidRhoé). G5 performance closed 2026-10-20, best effort (Plz, Ashura, luller,
UltraJohn, Siberfox99). G6 multiplayer PASS on one machine (dedicated-server questions).
G7 open: replies (incl. Ceo of Toes D2), Vortex (Saber57Draxus); install
checks done 2026-10-21. Deferred to
0.5.x/0.6: item-specific limits (SolidRhoé, BIG DADDY, Mithandil de Melkin),
Steam Deck and controller (TheJoe, Erbse, tigerpow100), two-client tests,
independent priority/limit mods (wikidnumb), high-quality stand
(NoNickNeeded), deferred scheduling after UI close (Material Defender).
Old reports rerun 2026-10-27 ([g4-old-reports-2026-10-27](g4-old-reports-2026-10-27.md)):
KhanKeal's Pupperai PASS, Flambella covered by a planning test; Rey's Lamball
reproduced and fixed (ranches never counted as work). Second round the same
day with a lab, a pond and a caught Flambelle: poiman's fishing pools
reproduced and fixed (the pond's job was untyped and silent), Samurai9400's
research not reproduced (typed by subject; silent, now counted), KhanKeal's
Flambella reproduced while the pond was invisible. No reply posted.

## Census totals

| Date | Steam | Nexus | Added | Source |
| --- | ---: | ---: | --- | --- |
| 2026-09-11 | 52 | 13 | the audited 65 entries below | full read, both sites |
| 2026-09-13 | 53 | (13, not re-read) | one author progress update | direct public fetch; Chrome did not attach, Nexus answered HTTP 403 |
| 2026-09-15 | 56 | 15 + 1 bug | 6 comments, 1 bug (71 + 1) | logged-in Chrome, delta only |
| 2026-09-23 | 62 | (not re-read) | 6 Steam comments | logged-in Chrome, Steam delta only |
| 2026-10-09 | 70 | 17 + 2 bugs | 8 Steam, 2 Nexus, 1 bug | logged-in Chrome, every page of both sites and both bugs expanded |
| 2026-10-21 | **73 + 1 discussion (2 posts)** | **17 + 3 bugs** | 3 Steam, 1 Steam discussion, 1 Nexus bug | built-in browser, signed out; newest Steam page, the discussion, Nexus posts and bugs |

The 2026-10-09 census counted 87 comments plus 2 bug reports; the 2026-10-21
delta (rows 88-90, B3, D1-D2) brings it to **90 comments, 3 bug reports and
one Steam discussion with 2 posts**.
Nexus still showed 0.4.1 (updated August 28) then. The deltas were read in the
browser because the web cache held fewer, older posts. No reply, moderation or
publication was done by any census. Public reports name no loaded package hash,
so none of them is evidence against an unpublished candidate unless it is
reproduced with its identity recorded.

## How to read the rows

Entries include author replies, requests, withdrawn reports and nested replies,
so 87 entries are not 87 defects. Dates are as displayed; relative timestamps
were normalized to dates, not invented times. Authors are public display names.
Paraphrases are short and do not reproduce comments.

Status (as of the 2026-09-11 audit): **A** = matching defect path identified in
code or visual evidence, native cause pending; **R** = symptom reported,
reproduction pending; **Q** = request; **C** = context, reply, praise or
withdrawal. One entry with several symptoms needs several tests. Numeric resets
must not all be attributed to the proven X serialization defect.

## Finding IDs F01-F24

Moved here from the 2026-09-11 reliability ledger. The IDs are stable; every
row below and every reply draft keys on them. The last column is the
2026-09-11 state; the current state is the matching gate in
[RELEASE-0.5.0.md](RELEASE-0.5.0.md). F22-F24 are internal findings, not public
comments.

| ID / priority | Finding and evidence | Implementation area | Native gate / status (2026-09-11) |
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

## Steam, audited 2026-09-11 (52 entries)

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

## Nexus, audited 2026-09-11 (13 entries)

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

## Later entries, 2026-09-13 to 2026-10-09 (66-87, B1-B2)

Numbered after the audited 65. Each delta read only the new entries and the
boundary entry, not every older comment again; the 2026-10-09 census reread
everything. The gate column is the current [RELEASE-0.5.0](RELEASE-0.5.0.md)
gate or Deferred.

| # | Source / ID | Displayed date | Author | Report | Finding | Disposition when read | 0.5.0 gate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 66 | [Steam 569297137117173393](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_569297137117173393) | 2026-09-12 22:27 | Matraweber | Author says repairs are underway. | F20 | Context, not defect evidence. The only new ID in the 2026-09-13 fetch (53 Steam). | G7 |
| 67 | [Steam 569297443349502462](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_569297443349502462) | 2026-09-15 (7 h before read) | poiman | Icelyn ignores cooling 1 for priority-5 work; fishing pools ignored despite Handiwork 1. | F11 | Separate cooling and fishing cases; permissions or UI numbers do not show the job chosen. | G4 (coolers fixed 2026-10-16; fishing not tested) |
| 68 | [Steam 569297443349488654](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_569297443349488654) | 2026-09-15 (12 h before read) | Erbse | Steam Deck needed mapped left/right clicks; asks about controller support. | F18 | Native Deck focus/navigation test; desktop keyboard success is not enough. | Deferred (Deck) |
| 69 | [Steam 569297443349364937](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_569297443349364937) | 2026-09-13 20:21 | tigerpow100 | Cannot change priorities on Steam Deck. | F18 | Same input gate, not a separate confirmed cause. | Deferred (Deck) |
| 70 | [Nexus post 175442289](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-09-12 10:35 | DreamFun | X alone resets after loading; other priorities persist. | F01 | Strongly matches the 0.4.1 X serialization defect. | G1 |
| 71 | [Nexus post 175615590](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-09-15 07:29 | DSFddaaaa | Asks for Transport default 5; cooking, crafting and generation get interrupted. | F11/F18 | Keep the approved checked=1/unchecked=X default; investigate the scheduling instead. | G4 (generators fixed 2026-10-14) |
| B1 | [Nexus bug 1133489](https://www.nexusmods.com/palworld/mods/5376?tab=bugs) "Crash To Desktop" | 2026-09-14 | DarkWyrmReaper | Add item / search all items aborts to desktop; suspects the newly added Cosmetic Outfits mod 5049. | F16/F17 | Compatibility reproduction; the interaction is a hypothesis. Still no replies on 2026-10-09. See [search-crash-2026-09-15](search-crash-2026-09-15.md). | **G3, open** |
| 72 | [Steam comments](https://steamcommunity.com/sharedfiles/filedetails/comments/3786408856) | 2026-09-21 04:09 | Danodan | Clunky behaviour causes more frustration than benefit. | F18 | General usability, not a distinct cause. Prioritise mouse/keyboard workflows and measured latency. | G3/G5 |
| 73 | Steam | 2026-09-20 19:49 | Erbse | Work settings do not survive restart; unsure when it began. | F01-F03 | Persistence blocker; values unspecified, so not assumed to be X only. | G1 |
| 74 | Steam | 2026-09-19 10:10 | like | Priorities reset to defaults every login; otherwise fine. | F01-F03 | Same persistence gate, reproduced separately from X-only reports. | G1 |
| 75 | Steam | 2026-09-19 09:44 | Mithandil de Melkin | Wants Flame Organs, Venom Glands and Pal-specific materials such as Gummos Leaf in limits. | F07 | Catalogue request plus producer-control gate; a visible item is not a safe output control. | Deferred (item-specific limits, Pal-produced materials) |
| 76 | Steam | 2026-09-18 11:20 | Okami_sama | Adding tasks in the panel stopped other work across the base; mining allowed only one Pal. | F07/F09 | Reproduce with exact rules, mode, worker cap and assignments. | **G4, fixed 2026-10-17** ([evidence](g4-scheduling-2026-10-17-miners.md)) |
| 77 | Steam | 2026-09-18 10:32 | Okami_sama | Open panel cannot be closed except by restarting the game. | F04/F06 | Corroborates the stuck-panel reports. | G3 (PASS 2026-10-17) |
| 78 | [Steam 591816835949675692](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_591816835949675692) | 2026-09-29 | Material Defender | Rationale for running scheduling once after closing a UI. | F15/F16 | Performance suggestion, not proof that repeated passes crash. | Deferred (scheduling after UI close) |
| 79 | [Steam 591816835949675621](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_591816835949675621) | 2026-09-29 | Material Defender | Apply deferred scheduling to stand edits too. | F13/F15 | Judge against latency, disconnects and UI teardown; never depend on a close event to persist edits. | Deferred |
| 80 | [Steam 591816596100673992](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_591816596100673992) | 2026-09-28 | Material Defender | Wants 1 <-> X cycling wraparound. | F18 | Six-state cycling implemented with regression coverage; mixed-input/controller acceptance open. | done in rc1 (DECISIONS 2026-09-11) |
| 81 | [Steam 591816596100673837](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_591816596100673837) | 2026-09-28 | Material Defender | Keep chat commands immediate, coalesce UI changes. | F15 | Same scheduling/latency gate. | Deferred |
| 82 | [Steam 591816596100673758](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_591816596100673758) | 2026-09-28 | Material Defender | A changed flag and one pass at panel close. | F15 | Check the existing deferred/coalesced paths before adding a scheduler trigger. | Deferred |
| 83 | [Steam 591816596100670438](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_591816596100670438) | 2026-09-28 | Extramrdo | Wants a left/right-click reminder. | F18 | Discoverability follow-up. | Deferred (mouse/pad legend) |
| 84 | [Steam 591816596100670402](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_591816596100670402) | 2026-09-28 | Extramrdo | Wants Alt-F1/F2/F3 hints and a priority-order explanation; stuck panel blocks menus; Alt-F1 opens a second panel. | F04/F06/F18 | The candidate legend is source evidence only; duplicate/lifecycle reproduction is a gate. | G3 (PASS 2026-10-17) |
| 85 | [Steam 591816302688012535](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_591816302688012535) | 2026-09-23 | Two Bob Games | Transport X returns to 1 after restart; priorities seem ignored until edited again. | F01-F03 | Separate serialization/recovery from applying at startup; both must pass. | G1 (PASS 2026-10-11) |
| 86 | [Nexus 176018241](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-09-22 | wikidnumb | Wants priorities and production limits as independent components. | F21 | Optional design work; avoid conflicting double installs. | Deferred |
| 87 | [Nexus 175824555](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | 2026-09-19 | HelpImStupid0 | Transport 5 still dominates primary work 1. | F09/F11 | Needs actual assignment/output; fence membership is not enough. | G4 (PASS 2026-10-12) |
| B2 | [Nexus bug](https://www.nexusmods.com/palworld/mods/5376?tab=bugs) "Priority list not saving" | 2026-09-18 | johndujo | Previous selections disappear on reload. | F01-F03 | Values unspecified, not assumed X only. Persistence/startup gate. | G1 (PASS 2026-10-11) |

## Later entries, 2026-10-09 to 2026-10-21 (88-90, B3, D1-D2)

| # | Source / ID | Displayed date | Author | Report | Finding | Disposition when read | 0.5.0 gate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 88 | [Steam 590691913363940543](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_590691913363940543) | 2026-10-09 22:38 | NoMo | Typed "ingot" into the item search with item mods installed: UI laggy, then crash to desktop. UE4SS log tail on pastebin ends at "picking an item" (0.4.1). | F05 | Same report as B3. Same class as B1: naming an item ID that is not a table row aborts the game; fixed in 172eccf, 5 rounds with Cosmetic Outfits passed ([g3-search-crash-2026-10-20](g3-search-crash-2026-10-20.md)). | G3 (fixed 2026-10-20) |
| 89 | [Steam 570426530135681694](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_570426530135681694) | 2026-10-19 14:02 | Roin | Sleep in a Pal bed, photo mode, exit: a big grey rectangle blocks clicks and quitting (only this mod and UE4SS). | F06 | Repeats Zekrom144 (row 2). Cause on 0.4.1: the panel shell sat collapsed on the viewport from world load, and leaving photo mode makes viewport widgets visible again. rc1 attaches only while open and detaches on close (overlay.lua `hide`). The Pal bed route is still untested live ([g3-escape-photo-death-2026-10-17](g3-escape-photo-death-2026-10-17.md) "Not covered"). | G3 (PASS 2026-10-21) |
| 90 | [Steam 570426530135681758](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_570426530135681758) | 2026-10-19 14:03 | Extramrdo | Workaround for 89: Alt+F1 open and close removes the rectangle. | F06 | Fits the cause above (closing re-collapses the shell). | with 89 |
| B3 | [Nexus bug 1147959](https://www.nexusmods.com/palworld/mods/5376?tab=bugs) "Crash To Desktop" | 2026-10-10 05:33 | Omoface | Same text and pastebin as row 88. | F05 | Duplicate of 88. | G3 (fixed 2026-10-20) |
| D1 | [Steam discussion 586187435308941852](https://steamcommunity.com/workshop/filedetails/discussion/3786408856/586187435308941852/) | 2026-10-02 14:58 | like | "Setting a Pal to X does not save, fix included": `store.lua` `M.save` turns `false` into `nil` (`math.tointeger(false)`), so X rows are dropped; posts a one-line patch and asks for better drop warnings and logging in `M.load`. | F01 | Correct diagnosis of the 0.4.1 X loss; rc1 fixed it independently (G1). Credit them in the changelog/reply. | G1 (PASS 2026-10-11) |
| D2 | same thread | 2026-10-17 01:57 | Ceo of Toes | Asks whether the patch is needed on the client too or only on the dedicated server. | F01/F17 | For 0.4.1: saving happens on the server, so the server copy matters; for 0.5.0 server and every player need 0.5.0. Reply draft. | G7 reply |

The 2026-09-23 and 2026-10-09 deltas named no finding IDs; those of rows 72-87 were assigned in the 2026-10-20 merge.

Notes from the deltas:

- 2026-09-15: the game showed **1.0.5.102999**, newer than the 1.0.4.102642 of
  the earlier tests; earlier timing and acceptance did not carry over.
  [Cosmetic Outfits](https://www.nexusmods.com/palworld/mods/5049) adds
  craftable NPC outfits for the Antique Wardrobe; it was not installed or
  tested during the read.
- 2026-09-23: the raw accessibility excerpt of the six entries is
  `test-results/steam-comment-delta-20260923.txt` (local). Dates are the page's
  CEST timestamps; the comment IDs were not recorded for that delta.
- 2026-09-13: raw response and receipt in
  `test-results/current-steam-public-20260913.html` and
  `public-refresh-20260913.json` (local).

## Linked evidence and its limits

- [Hall9002's screenshot](https://ibb.co/pvTLHFpV) was viewed during the audit: 2560×1600, 16 rules, pager overlapping list rows/amount controls. It corroborates the layout symptom; it does not identify every faulty cache/parent transition.
- [Plz's collection](https://steamcommunity.com/sharedfiles/filedetails/?id=3790433214) contained 34 mods in the audit, including transport/stacking/feeding/stutter, ranch/schema and UI/graphics modifications. Treat it as a compatibility cohort after a minimal baseline. Membership proves no conflict or culprit.
- [NoAhQ's linked video](https://vimeo.com/1222120759) was recorded as a link; playback was not part of the audit. The user report still requires a native reproduction.
- [PalPriority reference](https://www.nexusmods.com/palworld/mods/3830) provides context for comparisons and earlier investigations, not proof of this candidate's behavior.
- [UE4SS dependency](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587) identifies the intended distribution. Its advertised September revision differs from the August test log; actual loaded compatibility remains unaccepted.

## Consolidation and reply tracking

The evidence column is the 2026-09-11 position; current results are the gates
named in the status line at the top.

| Report group | Findings | Evidence position on 2026-09-11 | Reply draft |
| --- | --- | --- | --- |
| Lost X / numeric settings / update | F01–F03, F12 | X regression fails actual baseline/passes candidate in isolation; numeric resets, fixed-assignment loss and native migration require distinct tests | Settings and recovery |
| Escape, stuck/duplicate/grey panels | F04–F06 | Handoff/cache paths identified; native crash and photo/duplicate causes unproved | Panel and input |
| Priority, research, cooling, ranching, generation | F08–F11, F18 | Idle/unknown-scope baseline failures confirmed; assignment_reader nil; actual work/output matrix pending | Scheduling and assignments |
| Stone/ore, overshoot, synthesizers, guild storage | F07/F19; internal F22 | Legacy semantics and inherited-clear OFF masks implemented; regression added; no accepted native item-specific adapter | Production and storage |
| Blank/slow client UI and reverting vanilla edits | F12–F14/F18 | Snapshot/render/edit paths identified; two-guild and mixed-client tests pending | Multiplayer and controls |
| Stutter and logging | F15/F16/F20 | Earlier timing gaps confirmed; matched current-runtime frame evidence missing | Performance |
| Install/runtime/key discovery | F17/F20 | Correct Alt+F1 instruction and intended dependency documented; clean routes/current runtime/Vortex unaccepted | Installation |
| High-quality stand restriction | F21 | Optional request intentionally deferred | Optional access restriction |

Reply drafts are in [release-replies-0.5.0-draft.md](release-replies-0.5.0-draft.md)
and are rewritten against the final build under gate G7. **Posting status: none
posted.** Update a group only after attaching evidence; do not imply that every
comment in a group shares a cause or is resolved together.
