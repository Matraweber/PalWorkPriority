---
date: 2026-10-29
tags: [release, testing, records]
status: current
---
# Second strict review round after the audit fixes (2026-10-29)

Related: [review-2026-10-28](review-2026-10-28.md) · [retest-2026-10-29](retest-2026-10-29.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md) · [DECISIONS](DECISIONS.md)

The same twelve reviewers (`~/.claude/agents/palworld-*.md`) reviewed HEAD 45e8145
again under the same rules. An open P1 caps a score at 5, and two or more cap it at 4.
Each reviewer judged the result, not the effort. **Nothing is fixed yet. The user
picks.**

## Scoreboard

| Reviewer | Round 1 | Round 2 | Verdict |
| --- | --- | --- | --- |
| Accessibility | 4 | 7 | ship after fixes |
| Performance | 6 | 7 | ship after fixes |
| Onboarding | 4 | 6 | ship after fixes |
| Engine safety | 6 | 6 | ship after fixes |
| Panel bugs | 4 | 6 | ship after fixes |
| Newcomer UX | 4 | 5 | ship after fixes |
| Scheduler logic | 4 | 5 | ship after fixes |
| Multiplayer | 4 | 5 | ship after fixes |
| Persistence | 5 | 5 | ship after fixes |
| Test coverage | 4 | 5 | ship after fixes |
| Tooling | 6 | 5 | ship after fixes |
| Release truth | 4 | 4 | ship after fixes |

All round-1 P1s are closed. The new P1s mostly sit where the fixes met real game behaviour
that the tests faked (focus timing, respawn, host versus client).

## New P1s (merged across reviewers)

1. **A respawn forgets which rocks are held.** The `ClientRestart` reset calls
   `item_sources.forget()` in the same world, so rocks stay off until a reload, even
   after off, restore or removing the limit. This affects singleplayer and hosts.
   Found by: scheduler (P1) and engine (P2-1).
2. **Host group rows show "No count yet" for good with two or more bases** in camp
   scope, which is the default. `panel_status.verdict` on the host still uses the
   pre-schema-5 path. Found by: multiplayer.
3. **Enter in the search box can still create a limit.** Enter clears the text box's
   focus before the queued key handler runs, so `RB.typing()` is false. The test fakes
   focus. The retest's "Enter went to Show all" was this bug. Found by: test coverage
   (P1) and panel (P2-1). The engine reviewer adds that `RB.typing` asks a widget kept
   from an earlier frame.
4. **A 0.4.1 `config.lua` with values 0.4.1 tolerated stops 0.5.0.** Examples: interval
   3, a cap of 0, a key named by its label, a fractional priority, a limit of 0. Found
   by: persistence.
5. **False first-click notice when the job already has a group limit.** It says "stops
   all <job>" where it should say "joins the limits". Found by: UX.
6. **`upload` does not check the stage against the tag, archive hash and live
   version.** After a retag, a skipped or ignored `prepare` would publish the old build.
   Found by: tooling.
7. **Release texts.**
   - "Every fix below was tested in the game" is not true.
   - The missing-pak sentences in the CHANGELOG and README are false.
   - The G7 install runs ("final build") were made on the old tag's archives.

   Found by: release truth.

## P2s (merged)

**Code**

- **Double-click** creates a limit or removes one. Fix: a minimum delay between arm and
  confirm.
- **Picker tiles re-sort under the pointer** on every pass. The cache key holds the
  stock table's identity.
- **Host "Rocks stopped" ignores base and guild.** `item_stopped` looks at every camp.
- **Mining at bases.**
  - A base with no Mining source loses Mining.
  - A partial read cannot prove "wanted".
  - Skipped entries still count as a complete read.
- **Held rocks stay off while settings cannot be saved.** `restore` returns before
  `release_rocks`.
- **A client shows a stale verdict** for up to about 10 s after a limit edit.
- **A 0.4.1 server:** the "base-game stand" fallback is false there, because the old
  scheduler rewrites the flags. The stand should be read-only for `incompatible`.
- **Config files.**
  - A UTF-8 BOM in `config.lua` stops the mod.
  - The DarnMenu shared-index write is not failure-safe.
  - The reset notice only lives in memory for one session.
- **`stations.classes` grows without bound.**
- **Keyboard and pad wording.** It says "Click again" and "Click Sure?". The keyboard
  arrows are never hinted.
- **The two-line job cell** is too cramped (8 px glyphs, 0 px gap). The fix is one line.
- **UX.**
  - The "Off" help is untrue: X jobs stay off.
  - "Others below" is never explained.
  - The uncounted picker caption leads to a dead end.
  - Equal numbers and "1 wraps to X" are missing from the legend. A first left click on
    a fresh install sets X.
  - A newer client is told to update.
  - The stand grid shows through the panel.

**Docs, onboarding and release truth**

- The extract target trap (a subfolder).
- Troubleshooting steps 1 and 4.
- Keeping config edits when updating with Vortex.
- Server prerequisites: UE4SS, Windows only, the upload step, which log.
- A wrong `config.lua` comment.
- The README evidence link.
- The `config.migration.bak` row.
- "After about a minute" for the stand fallback.
- No RELEASE gate yet for the audit fixes.
- The change note drops the panel section.

**Tooling and process**

- `release.py` default output path.
- `g7_install_matrix.py`: the `assert` guard, and `restore` deletes before it checks.
- The moved tag must be force-pushed. That needs the user's OK.
- Rerun G7 (manual, Workshop, 0.4.1 upgrade) on the new archives.
- Five onboarding checks in game: a server without the mod, the missing pak, a second
  UE4SS, a clean Workshop install, and a Workshop upgrade from 0.4.1.
- A group-limit row on the server.
- A `pwp perf` reading with the panel open.

The P3 lists are in each reviewer's report and are not repeated here.
