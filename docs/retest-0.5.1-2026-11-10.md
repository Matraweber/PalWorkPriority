---
date: 2026-11-10
tags: [testing, evidence, release, review]
status: evidence
---
# 0.5.1: in-game tests and review round (2026-11-10)

Related: [DECISIONS](DECISIONS.md) · [LESSONS](LESSONS.md) · [comment-ledger-2026-09-11](comment-ledger-2026-09-11.md) · [perf-final-2026-10-29](perf-final-2026-10-29.md) · [retest-r4-2026-10-30](retest-r4-2026-10-30.md)

The user asked to add the two Nexus requests to the game and test everything
(ledger rows 96 and 97). Branch `dev-0.5.1` from e45ebb6, worktree
`pwp-wt/dev-051`. Local test world (2 bases, 14 Pals, game 1.0.5.102999,
upgraded install, no baseline header). Builds deployed with
`tools/deploy.ps1`; every launch with `restart-stand.ahk --launch`.

## What changed

| Commit | Change |
| --- | --- |
| 9bc0910 | `use_work_priority_for_new_pals` (first design, replaced below) |
| 3b8fd61 | Stand cell tooltip written only when its text changes |
| 5e79018 | Legend backing padding 3 -> 1, lift 163 -> 162 |
| 93f17f5 | Setting reworked: capture stores defaults, one-time conversion, DarnMenu job numbers |
| 992927e | Review fixes (below) |

## In-game results

- **Tooltip:** hovered on Anubis's cell for 11.5 s across a recheck; it stayed
  open (before: closed after 1-2 s, reported by CerbinTalYalas).
- **Legend at 1920x1080 (window, client captured at full resolution):**
  before, last row's border at y 887 and the 30 px legend at 887-916, no gap.
  After, border 887, gap 888-892, legend 893-917 (25 px). HUD weapon-name
  boxes start at y 920 (160 units above the bottom), so the legend clears
  them. English client; the French client of the report was not tested (the
  game takes its language from Steam). The game's "Minimum font size"
  (Medium) did not move the stand.
- **Legend at 1280x720:** border 591, gap 592-596, legend 597-611; the
  weapon name at 614 stays clear.
- **First design of the setting, found broken in game:** with the setting on,
  Pal Recruiter set to 1 1 1 1 showed 3 3 4 4 (every all-equal row was read
  as "not ranked" on every refresh). The 256 unit tests had passed. Reworked
  as the user chose ("convert once").
- **Reworked setting:** toggled in DarnMenu, applied after a restart
  ("DarnMenu options applied, 2 setting(s)"), "Steering 11 of 14" became
  "14 of 14"; jobs with no stored number showed the config numbers
  (Braloha 1/1/5 -> 3/2/5). Pal Recruiter set to 1 1 1 1 stayed so through a
  recheck ("Steering 13 of 14").
- **Menu job number:** Transporting set to 2 on the page, saved as
  `new_pal_priority_Transport = "2"`; after removing Verdash's stored
  Transporting row (a hand edit the mod accepted with its warning), Verdash
  showed 2 there.
- **One-time conversion (staged):** `# baseline=vanilla` added to a copy of
  priorities.txt and Pal Recruiter set to all 1. Launch: "first time on:
  1 Pal(s)", Recruiter saved as 3 3 4 4, `config-ranks.txt` = converted=1,
  and the stand showed "Pal Work Priority: 1 Pal(s) with equal numbers now use
  the default numbers (New Pals use default numbers is on)." Partial rows of
  this upgraded world showed `?` in that staged launch only (a real fresh
  install stores complete rows).
- **Menu page:** new help texts, the subtitle note, X choices and "Chat command
  prefix" (`!pwp`) shown; DarnMenu's own `schemas.lua` loads the shipped page
  and one filled from a changed config.lua (Transport 4, Watering X, prefix
  `!w`, no limit as 0), and rejects a deliberately broken copy.

## Performance (`pwp perf`, UI closed, 216 s; stand open, 82 s)

| Region | 0.5.1 | 0.5.0 (perf-final) |
| --- | --- | --- |
| scheduler pass | 18.9 / 22 ms | 18.1 / 27 ms |
| camp enumeration | 10.0 / 11 ms | 10.4 / 12 ms |
| camp works | 0.98 / 5 ms | 0.74 / 1 ms |
| storage refresh | 25.3 / 27 ms | 22.2 / 23 ms (code unchanged) |
| stand complete refresh (open) | 11.3 / 20 ms | not measured before |
| stand cell refresh | 0.032 ms | not measured before |

Within the 1 ms timer resolution; no 0.5.1 code runs in the storage refresh.
The conversion is a no-op after its first answer each launch.

## Review round

Three read-only agents (persistence, scheduler logic, newcomer UX) on
`e45ebb6..93f17f5`. Confirmed and fixed in 992927e, each with a test that
fails when the bug is put back:

- **P1 (two agents):** the conversion read only stored cells. On upgraded
  installs rows hold only clicked cells, so `{Transport=5, Farming=5}` with
  Handiwork unclicked (shown first) would have become Transporting 1. Now it
  runs only on fresh-install files.
- **P1/P2:** a config.lua X was captured as 1 (already so in 0.5.0, where such
  Pals were left to the game). Now captured as X, setting on or off (user's
  choice), and the conversion makes it X.
- **P2:** off then on converted hand-set equal rows again. Now once ever.
- **P2:** a failed marker write gave up for the session. Now retried every
  30 s.
- **P3:** the conversion ran while the mod was off. Now after that check.
- **UX P1:** the page always showed the shipped values. It now shows
  config.lua's (`darnmenu.schema_text(base)`). Help texts corrected, the
  stand announces the conversion once.

Not acted on, with reasons: a stored number already beats `pal_overrides`
(scheduler P3-2, no change in precedence); DarnMenu saving untouched defaults
(scheduler P3-4) is false, the user file held only changed keys; async
persistence never converts (not shipped).

## Re-review of the fixes (persistence agent, 992927e)

No P1; the claimed fixes held. Four findings, all confirmed and fixed with a
test each (each test fails with its fix taken out):

- **P2-1:** an X saved on a fresh install sticks to each Pal, while the help
  said it could be undone. Texts corrected; `config-x.txt` keeps the last X
  jobs and the stand says once "1 Pal(s) saved while Watering was X still
  have X for it. Change them on the stand." Seen in game (staged: baseline
  header, `x=2`, Pal Recruiter Watering X); the file then read `x=`.
- **P3-1:** `max_pals_per_work_type = false` showed 3 on the page; now 0.
- **P3-2:** page defaults validate but ignored the page's own ranges (600 s);
  now the same `refusal` check as `apply`.
- **P3-3:** a locked marker during a pending retry gave up; now retried.

## Dedicated server (GPortal "RAM", 1 base, 9 Pals, 2026-11-10)

Joined with `restart-server-stand.ahk --launch --any-guild`; each time the
client log showed "synchronization: client; ready" and one edit (Vixy's
Gathering 1 -> 2, then back) was applied by the server ("priority Collection
set to 2 by a player", Vixy fenced to Farming, then left to the game again).

| Client | Server | Joined | Edit applied |
| --- | --- | --- | --- |
| 0.5.1 | 0.5.0 (86a76e4) | 16:29:29 | yes |
| 0.5.1 | 0.5.1 (f5e45ee) | 16:50:51 | yes |
| 0.5.0 (master) | 0.5.1 (f5e45ee) | 17:01:33 | yes, no version warning |

- Server install: `ftp_session.py` install of `pwp-server-scripts-f5e45ee.zip`
  as tag `f5e45ee-c`, "verified: all 60 files read back identical" after six
  dropped transfers were retried. Server log: "Pal Work Priority 0.5.1 loaded",
  `PWP_READY version=0.5.1`. Rollback target for 0.5.0:
  `Scripts-before-f5e45ee-b`.
- Two earlier installs reported "already exists" because two FTP sessions
  served the same queue (the user's `--save-login` run kept running); see
  LESSONS. The server's settings were copied first to
  `D:\PalWorkPriority-backups\server-before-0.5.1-*`.
- Side effect: the server now stores Vixy's Gathering 1 explicitly (it was
  unstored); the value is unchanged.
- The FTP login had to be saved again: GPortal moved the server on
  2026-11-03 (new FTP address), and the kept login timed out.

## Release (2026-11-10)

- master fast-forwarded to 84c8f0b (CHANGELOG dated), tag `v0.5.1`, both
  pushed with `dev-0.5.1`. `tools/release.py --verify-reproducible`: a second
  build gave the same hashes.

| Archive | SHA-256 |
| --- | --- |
| `PalWorkPriority-0.5.1-manual.zip` (Nexus main file) | `607fa8e8f8e89e6a0d5f2e03cc9ea3341265c871b129bb66f58a674f9151396f` |
| `PalWorkPriority-0.5.1-workshop.zip` | `7e20c965f1b0c02439e1003c4b8a9a8a40bd219daef29994069d0f5c50ec0592` |
| `PalWorkPriority-0.5.1-server.zip` (Nexus optional file) | `dda6c9b4d3c9e8a4c0bcb43f2eb89a91ad86317fea0f3b76c53580024bbd253d` |

- **Steam Workshop:** `workshop_upload.py prepare` (67 files, change note
  2439 bytes), `upload`; the user pressed OK at 17:10. The change notes page
  shows "Update: 10 Nov @ 5:10pm" with the 0.5.1 section. `check` still said
  NOT YET right after (Steam had not downloaded the update to this PC);
  run it again before relying on the local copy.
- **Nexus (mod 5376):** "Pal Work Priority 0.5.1" updated the 0.5.0 main file
  in place (primary, 0.5.0 under previous files, not archived), mod version
  0.5.1, six changelog lines. "Dedicated server files 0.5.1" updated the
  optional server file (mod-manager download off).
- **Store pages:** both descriptions changed in place for 0.5.1 (title, the
  new option, updating from 0.5.0, the options page covering config.lua,
  0.5.0 and 0.5.1 playing together; Nexus: Vortex wording without a
  version). Checked on the public pages.
- **Replies (user's request):** Nexus replies to CerbinTalYalas (tooltip and
  legend fixed, the controls line kept, French client not tested) and to
  valdacil (the new option, the one-time conversion on a clean install).
- The GPortal server keeps 0.5.1 (user's decision).

The user's further request: change config.lua in game. Answered by the page
covering it (all settings but `pal_overrides` and the container lists), not
by the mod rewriting config.lua.

Tests: Lua 256 scripts 0 failures, luacheck clean (panel.lua 193 locals),
Python 842 OK (85 skipped).

Test world restored after each run: priorities.txt and .bak from
`D:\PalWorkPriority-backups\before-0.5.1-retest-*`, the DarnMenu user file,
`config-ranks.txt` moved to `D:\PalWorkPriority-backups\after-0.5.1-tests-*`,
GameUserSettings.ini back to 1280x720.
