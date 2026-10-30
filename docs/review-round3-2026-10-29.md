---
date: 2026-10-29
tags: [release, testing, records]
status: history
---
# Third strict review round after the round-2 fixes (2026-10-29)

Related: [review-round2-2026-10-29](review-round2-2026-10-29.md) · [retest-r2-2026-10-29](retest-r2-2026-10-29.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md) · [DECISIONS](DECISIONS.md)

The same twelve reviewers (`~/.claude/agents/palworld-*.md`) reviewed HEAD a7b81af
under the same rules. An open P1 caps a score at 5, and two or more cap it at 4.
All 243 Lua tests and luacheck passed for every reviewer. **Nothing is fixed yet.
The user picks.**

## Scoreboard

| Reviewer | Round 1 | Round 2 | Round 3 | Verdict |
| --- | --- | --- | --- | --- |
| Accessibility | 4 | 7 | 7 | ship after fixes |
| Scheduler logic | 4 | 5 | 7 | ship after fixes |
| Engine safety | 6 | 6 | 7 | ship after fixes |
| Performance | 6 | 7 | 7 | ship after fixes |
| Tooling | 6 | 5 | 7 | ship after fixes |
| Release truth | 4 | 4 | 6 | ship after fixes |
| Multiplayer | 4 | 5 | 6 | ship after fixes |
| Persistence | 5 | 5 | 6 | ship after fixes |
| Test coverage | 4 | 5 | 6 | ship after fixes |
| Newcomer UX | 4 | 5 | 5 | ship after fixes |
| Onboarding | 4 | 6 | 5 | ship after fixes |
| Panel bugs | 4 | 6 | 5 | ship after fixes |

Every round-2 P1 is confirmed closed (respawn, host verdicts, search Enter, 0.4.1
config, first-click notice, upload guards, release texts). The three new P1s come
from round-2 wording and from routes earlier rounds did not walk.

## New P1s

1. **The keyboard footer says "Enter types", but Enter raises the limit one step and
   saves it.** `panel.lua:3488`. DECISIONS 2026-10-21 kept Enter as one step up, so
   only the text is wrong. Found by: panel bugs.
2. **A fresh dedicated-server install by zip never loads.** README:51 uploads only
   `Scripts`, so `enabled.txt` never reaches a new server and UE4SS skips the mod. The
   step-3 check still passes. Not checked: whether GPortal lists new folders in
   `mods.txt` by itself (then P2). Found by: onboarding.
3. **Per-base scope with two or more bases opens on an unnamed "Base 1 of 2"**, sorted
   by id, and seeds new limits from that base's stock. Fix: open on the player's or
   stand's base and label it "This base". Found by: newcomer UX.

## P2s (merged)

**Network and server**

- **A limit edit by anyone wipes every other open client panel.** A full R snapshot goes
  to every peer and each runs `limits_changed()`. Rows flicker to "No count yet" and all
  K panels request at once, about K × 50 ms of server time. Fix: reset only when the rows
  differ. Found by: performance, engine safety, multiplayer.
- **Join messages exceed the server budget (2 per 60 s).** Three senders (ui ask,
  `net.poll`, the 18 s one-shot). This is the "ignoring repeated announcements" warning
  from the retest. A reconnect or respawn within the minute stays "connecting" for up to
  60 s. Found by: multiplayer, test coverage.
- **A refused missing-pal ask is never retried.** Found by: multiplayer.
- **A busy server (save stall up to 2.5 s) drops the next count request**, so the row
  waits about 10 s. Fix: keep the newest early request and serve it after 1 s. Found by:
  test coverage.
- **`!pwp limit` on a client only works with the panel open.** Found by: test coverage.

**Scheduler and persistence**

- **An unreadable base guild releases all held rocks** for that recheck. Found by:
  scheduler.
- **0.4.1 leniency ends at the first edit of an unrelated key**, and the untouched value
  then stops the mod. Fix: lenient per key where the value equals the backup's. Found by:
  engine safety, persistence.
- **An older `.bak` wins over a valid gen-0 file** written by 0.4.1 or a hand edit, so
  those edits are lost. Found by: persistence.
- **Two hand edits in a row break saving for good** (`.rejected.<gen>` name collision),
  and the mod refuses every pass. Found by: persistence.

**Panel and stand**

- **The Click / Enter / Y wording reads a controller flag that is frozen while the panel
  is open**, and pad paths stamp "keys". Found by: panel bugs.
- **Accessibility:** no focus shown on "change base"; static "Click" lines remain; the
  legend lacks arrows and Enter; search is mouse-only; save errors at 12 pt; "Medicine
  Production" may overflow the job column. Found by: accessibility.
- **Newcomer texts:** "Rocks stopped" does not say Stone Pits keep producing; the legend
  does not say everything starts at 1; picker help says "Click" on a pad; the success
  notice says "Click the number"; the options note says "host" for dedicated servers.
  Found by: newcomer UX.

**Onboarding and release texts**

- **Version mismatch advice** tells Workshop players to install the server's version.
  Say "ask the host to update the server". Found by: onboarding.
- **A rejected `config.lua` makes the mod vanish without a word.** Add a Troubleshooting
  step, ideally an in-game message. Found by: onboarding, release truth.
- **No sign a fresh install works**, and upgrade notices appear only in the panel. Found
  by: onboarding.
- **No 0.5.0 store page text** and no gate for it; the Vortex "Update/Replace" path loses
  config edits. Found by: onboarding.
- **The change note still drops the panel section** (the greedy fill skips the largest
  section). Found by: release truth.
- **`restore` help and the `config.lua` `enabled` comment contradict "X stays off".**
  Found by: release truth.
- **The "only automated tests" list** misses BOM, 0.4.1 values and the respawn reset;
  the README states the G7 rerun as done; RELEASE-0.5.0 has stale gate text. Found by:
  release truth, onboarding.
- **Unexplained join warnings** ("could not be typed", "repeated announcements");
  `!pwp discover` is not in the README table. Found by: onboarding, scheduler.

**Tooling and process**

- **`release.py` packages disk bytes, not the tag's.** 12 tracked Lua files on disk have
  CRLF while git holds LF, and `git status` shows nothing. Fix: package from git, or
  refuse on a mismatch. At least renormalise the checkout before the rebuild. Found by:
  tooling.
- **G7 can pass on an old archive**: the Workshop route has no hash check and deletes
  before it opens the zip. Found by: tooling.
- **`wipe` can delete the dev install** without a backup. Found by: tooling.
- **The rebuild needs the old `build/release-0.5.0` moved aside**, and the force-push must
  come before `prepare`. Found by: release truth.

**Evidence still missing**

- A `pwp perf` on the final build (host, two bases, Mining limits, panel open 30 s).
- The in-game cases tested only in Lua: a server without the mod or with 0.4.1, a missing
  pak, a second UE4SS, and a respawn that really runs the `ClientRestart` reset.

**Secret scan:** the GPortal IP is in none of the 510 commits, tags or tracked files. It
exists only in gitignored local logs.

The P3 lists are in each reviewer's report and are not repeated here.
