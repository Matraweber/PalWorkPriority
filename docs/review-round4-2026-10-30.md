---
date: 2026-10-30
tags: [release, testing, records]
status: current
---
# Fourth strict review round, final pre-ship check (2026-10-30)

Related: [review-round3-2026-10-29](review-round3-2026-10-29.md) · [review-ux-crowding-2026-10-29](review-ux-crowding-2026-10-29.md) · [perf-final-2026-10-29](perf-final-2026-10-29.md) · [g7-final-build-2026-10-30](g7-final-build-2026-10-30.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md)

The user asked for every reviewer to go over every aspect before shipping, performance
included. The twelve reviewers judged exactly what would ship: tag v0.5.0 (1e945db) and
the archives in `build/release-0.5.0`. An open P1 caps a score at 5. **Nothing is fixed
yet; the user picks.**

## Scoreboard

| Reviewer | R1 | R2 | R3 | R4 | Verdict |
| --- | --- | --- | --- | --- | --- |
| Panel bugs | 4 | 6 | 5 | 8 | ship |
| Tooling | 6 | 5 | 7 | 7 | ship (press Cancel on any upload error) |
| Performance | 6 | 7 | 7 | 7 | ship |
| Engine safety | 6 | 6 | 7 | 7 | ship after fixes |
| Multiplayer | 4 | 5 | 6 | 7 | ship after fixes |
| Scheduler logic | 4 | 5 | 7 | 7 | ship after fixes (wording) |
| Newcomer UX | 4 | 5 | 5 | 6 | ship; store page lines first |
| Accessibility | 4 | 7 | 7 | 6 | ship after fixes |
| Onboarding | 4 | 6 | 5 | 6 | ship after fixes (text) |
| Release truth | 4 | 4 | 6 | 5 | ship after fixes |
| Persistence | 5 | 5 | 6 | 5 | ship after fixes |
| Test coverage | 4 | 5 | 6 | 5 | ship after fixes |

Confirmed: archives, stage and tag are byte-identical; no server IP or secret in any of
575 commits or in the archives; no regression in panel, tooling, performance,
scheduler, multiplayer or persistence from the fixes since round 3.

## P1

1. **"Stone Pits keep producing" is false** when no Mining is wanted any more (a
   stone-only base stops its pit too). Panel help line, picker detail, CHANGELOG and the
   change note say it; the README is right. Release truth.
2. **The "config.lua rejected" notice shows once per session**, then the mod is paused
   without a word; a test pins this. Test coverage, engine safety.
3. **A fresh install loses its vanilla baseline** if the first launch never loads the
   player's own world (quit at the title, join a server first, crash on load): the next
   launch switches on every job that was unticked in the game. Persistence.

## P2 (merged)

**Code**
- A rejected `config.lua` on a dedicated server looks like a working mod to every client
  (regression from the round-3 rejection change). Engine safety.
- 0.4.1 leniency is per entry, not per value inside `pal_overrides` and `work_caps`. Test
  coverage.
- The server's "a join resets the controller back-off" probably never runs
  (`ClientRestart` is a client RPC); reset it on a confirmed Hello, cap 30 s. Test
  coverage.
- Changing guild while connected leaves the Limits panel stuck. Multiplayer.
- The server keeps old peers until an edit; at 128 new players are refused (can wait).
  Multiplayer.
- A line 0.4.1 skipped now refuses a whole data file; a refused `priorities.txt` shows
  1s and fails clicks silently. Persistence.
- The picker selection tint fails contrast (3.6-4.1:1, regression from the crowding
  fix); the pointer row and the keyboard row look selected at once. Accessibility.
- 12 pt tile labels on Steam Deck; the stand's "!" reason is mouse-only (both can wait).
  Accessibility.
- Picker guesses jobs from item names (Leather/Horn/Bone under Farming, non-rocks as
  Mining items). Newcomer UX.
- Hover follow can redraw up to 30 times a second (no frame capture); multi-base server
  pass never measured. Performance.
- `workshop-upload.ps1` leaves the note window open after a failure; the server macro
  presses Escape blind. Tooling.

**Texts**
- Two contradicting messages on a server without the mod; per-base wording; overshoot
  above a limit never explained; NVIDIA Alt+F1; upgrade notice too long; "Lowest work
  level" option help is wrong. Newcomer UX, scheduler.
- CHANGELOG: performance "checked on the final build", 33 ms frames attributed, empty
  server stations "work", automated-only list, "every route", README evidence links.
  Release truth.
- GitHub's default branch is still 0.4.1, so "docs on GitHub" lands on the old README.
  Release truth (user's call).
- Store page and INSTALL.txt: GitHub link, a right-click (not left-click) first test,
  NVIDIA, the missing-log case, a first-minute paragraph, "one copy" as step 0, server
  paths for self-hosted Windows servers, Vortex steps; a ready-made server zip.
  Onboarding.

The P3 lists are in each reviewer's report and are not repeated here.

## Outcome

The user picked all of it (P1, the code P2s that reach players, the text and store
page P2s, and the P3s). Seven fix agents worked in parallel. The merge and the retest
in game are in [retest-r4-2026-10-30](retest-r4-2026-10-30.md), along with three more
fixes it found (ore ids, Sandwich, and the stand saying the mod is paused). Decisions
are in [DECISIONS](DECISIONS.md) under 2026-10-30.
