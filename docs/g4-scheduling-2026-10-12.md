---
date: 2026-10-12
tags: [scheduling, testing]
status: evidence
---
# G4: do Pals do what the stand says? 2026-10-12

Related: [g4-scheduling-2026-10-14-stations](g4-scheduling-2026-10-14-stations.md) · [g4-scheduling-2026-10-17-miners](g4-scheduling-2026-10-17-miners.md) · [assignment-reader-2026-09-25](assignment-reader-2026-09-25.md)

Gate: [RELEASE-0.5.0.md](RELEASE-0.5.0.md) G4. Singleplayer, local client on the
branch build. Observation tool: `!pwp assignments`, the read-only census of each
Pal's native work assignment (state, fixed, suitability of the current job),
which Codex matched against the in-game Current Task on 2026-09-26. Work values:
2 Watering, 3 Planting, 6 Gathering, 7 Lumbering, 8 Mining, 12 Transporting.
Settings were snapshotted first (`test-results/g4-20261012/*-before.txt`) and
are back to identical rows afterwards.

## Setup

At load the base was nearly idle (wanted: Watering 2, Farming 1) and both legacy
limits were met (Wood 43,818 / 30,000, Stone 42,547 / 35,000), which switches
Lumbering and Mining off. To create competing demand the two limits were raised
to 900,000 for the test and set back to 30,000 / 35,000 afterwards.

## Priority 1 beats priority 5 (swap control)

Subject: Mammorest in base 1 (`BOSS_GrassMammoth`, key 6E1B8171...), able to
mine and log. Planting has no row and defaults to 1. Census every ~22 s.

| Phase | Setting | Samples (current job) |
|---|---|---|
| A, 10:01-10:05 | Mining 1, Lumbering 5 | Lumbering 1 (first sample, job begun before the change), Mining 3, Planting 2, idle 4 |
| B, 10:06-10:12 | Mining 5, Lumbering 1 | idle 7, Planting 2, Lumbering 5, **Mining 0** |

Fence line in phase B: `BOSS_GrassMammoth -> Lumbering`. Swapping the two values
on the same Pal in the same base flipped which of the two jobs it took; the
priority-5 job was never taken after the first sample of each phase. Idle
samples coincide with no matching demand (phase B's demand was Transporting
116, which a Mammorest cannot do). Output: Wood +365, Stone +257 over both
phases, not attributable to one Pal (others log and mine too).

**Verdict: PASS for job choice.** The done-when's "8 of 10 observations" is not
met literally because of idle stretches with no demand; among working samples
the priority-1 job (or the equal-priority Planting default) was taken every
time after the switch. Per-Pal output was not isolated.

## Staffing limit (max 3 per work type, spread mode)

Ten census samples, counted per base and work type, 10:16-10:20 (limits lifted,
so Mining and Lumbering had demand). Maximum observed: 3 (Mining in base 1 at
10:17:43, Transporting in base 2). Never above 3. **PASS** (bound reached under
demand). Not established: that four or more eligible Pals were free at those
moments.

An earlier run accidentally ran under a maximum of 4: `!pwp cap` cycles the
setting rather than showing it (see LESSONS). `!pwp reload` restored 3 from
config; the setting is in memory only and was never written to disk.

## Empty dedicated server

Server log while nobody was connected (2026-10-11 21:19, RAM on rc1):
`1 camp(s), 9 pal(s), 0 work(s) in 0 type(s), 0 permission request(s) sent,
1 idle camp(s) reconciled`. The game runs no base work without a player, as
measured in August, so there are no assignments to verify. **Closed as not
applicable**; the scheduler makes no assumption to cover it.

## Still open in G4 (as of 2026-10-12)

> Update 2026-10-20: all closed since. Incineram passed 2026-10-14 (below),
> Grizzbolt sleep/wake 2026-10-14 ([stations](g4-scheduling-2026-10-14-stations.md)),
> "everything stops" was reproduced and fixed 2026-10-17
> ([miners](g4-scheduling-2026-10-17-miners.md)).

- August repro cases under live demand: Incineram Handiwork over Kindling (needs
  queued crafting), Grizzbolt after being moved, sleep and wake. Today's census
  showed Grizzbolt fixed on its generator (`fixed=true suitability=4`).
- "Everything stops" / "only one miner" reproduction.

Tooling added: `!pwp setprio <palkey> <work> clear` removes a row through
`store.clear`, so a test can put the file back exactly.

## Incineram: Handiwork 1 over Kindling 2 (Glave's report), 2026-10-14

Sampler: `tools/sample_assignments.py` (census every ~17 s, prints each working
Pal's job and the latest demand line). Raw rows:
`test-results/g4-20261012/incineram-samples.txt`. To make Incineram the deciding
Pal, the user set Arsox Kindling X and Penking/Anubis Handiwork X, and the agent
set the Pal Recruiter's Handiwork X. All were restored afterwards; all 41 rows
match the 2026-10-12 snapshot again.

**First attempt, Pal Sphere Workbench queue: no Handiwork job existed.** The
game announced Handiwork once (at queue time) and never again. With the mod
switched off (`!pwp off`, vanilla permissions, 3 minutes) no Pal took Handiwork
either: the game was not offering that workbench's job to Pals. Not a mod
fault, but worth knowing when reproducing reports: a Sphere Workbench queue is
not a usable Handiwork test.

**Second attempt, ordinary workbench queue, 20:25-20:29:**

| Demand line had Handiwork | Incineram's job |
|---|---|
| yes (20:25:50, 20:26:08, 20:27:53, 20:28:11, 20:28:46, 20:29:03) | Handiwork every time it was working |
| no (20:26:43, 20:27:00) | Kindling (correct, nothing at the workbench) |

Fences in the same window: `Baphomet -> Handiwork` (15 passes) or
`Handiwork, Kindling` (27, when seats allowed both). Incineram was never on
Kindling while Handiwork work was announced. **Verdict: PASS.**

Earlier "mismatch" scare, recorded so it is not re-derived: a first look
compared fence lines from 19:48-19:50 with job samples from 19:51-19:56. In
the sample window Incineram was unfenced (no Handiwork demand), so Kindling was
correct. Compare intent and observation from the same pass window only.

Still open: Grizzbolt after being moved, sleep/wake; "everything stops" /
"only one miner".
