# Native multiplayer Pal activity observation — September 25, 2026

Candidate: unpublished 0.5.0-rc1; GPortal RAM world, one base, nine Pals.
Two visual reads of the native Monitoring Stand **Current Task** field,
approximately 22:59–23:01 and 23:02–23:03 local time. No priorities,
assignments, work-mode settings or production queues were changed.

| Pal | First read | Second read |
|---|---|---|
| Vixy | Grazing | Grazing |
| Braloha | Mining | Mining |
| Mammorest | Mining | Idle |
| Vaelet | Grazing | Grazing |
| Flambelle | Refinement | Refinement |
| Scouting Party Survivor | Planting | Planting |
| Lamball | Grazing | Grazing |
| Pengullet | Idle | Transport |
| Penking | Transport | Transport |

All capable priorities displayed 1. These equal settings cannot demonstrate
priority ordering. Current Task is native activity evidence, not proof of an
exact target, completed output, manual-assignment intent or mod causation.
Mammorest's first transient blank was ignored; the settled field read Mining.

## Scheduler blocker corroborated

The server log through 23:01:31 repeatedly reports nine unverified assignments,
nine current workers awaiting assignment evidence and **zero permission
requests sent**, while demand changes. Examples include Transporting 69 at
22:59:26 and Transporting 3, Farming 1, Planting 1, Watering 1 at 23:01:31.

`Scripts/scheduler.lua` initializes `M.assignment_reader = nil`; the Scripts
search found no installation of a reader. `scheduler_plan.lua` preserves
observed eligible permissions when manual intent is unknown, reserving capacity
conservatively. This explains why plausible vanilla activity does not establish
working automatic priority allocation in this session. Explicit X and legacy
restrictions remain separate paths; this observation did not exercise them.

The log's eight unverified staffing conflicts are conservative permission
reservations, **not eight proven excess active workers**. Do not interpret
fence counts as activity or count-only counters as zero execution time.

Next acceptance requires a verified assignment reader, then distinct priorities
with simultaneous eligible jobs, actual target/activity/output observations,
manual-assignment checks and staffing-limit accounting.

## Frontend defect reproduced

Hovering modded priority cells left the native right-hand Pal detail panel on
the previously selected Pal. Name/portrait targeting also failed to refresh it
in this session. Hovering each untouched battle checkbox reliably selected the
correct Pal without clicking or changing its battle setting. That read-only
route was used for both roster passes. An intercepted vanilla hover event is a
hypothesis, not a code-proven cause. Fix and regress stale detail selection.

Normal Work was active. The fixed-assignment board showed a Flambelle portrait
on the Primitive Furnace alongside a Stopped label at that moment. That screen
alone does not prove ongoing production or deliberate assignment. No board
settings were changed. The stand was left open after the observation.
