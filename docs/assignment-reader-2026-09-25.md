# Assignment reader investigation — September 25, 2026

The multiplayer observation in [Pal activity](pal-activity-2026-09-25.md)
confirmed nine unknown assignments and zero permission requests. Do not bypass
this guard by interpreting current suitability as an automatic assignment.

## Implemented diagnostic

`pwp assignments` runs a bounded, read-only authority census. It correlates
fresh PalWorkAssign objects with the live camp roster using full Pal identity,
then reads job/handle identity, base-camp ownership, native state, fixed flag
and suitability. Output contains only ordinary Lua values. There is no polling
cost unless requested, no saved UObject, no recursive class walk and no native
out-array call. It is not on the foreign-chat command allowlist.

Source contract: local modding-kit PalWorkAssign.h, PalWorkAssignHandleId.h,
PalWorkBase.h and EPalWorkWorkerState.h. Existing Discovery.txt corroborates
PalWorkBase fields, but the current server must still verify PalWorkAssign
semantics. SDK declarations alone are not live acceptance.

The diagnostic distinguishes occupied/reserved/unknown candidates. Missing fixed
flags, conflicting identities, cross-camp records, multiple assignments,
unsupported states and missing records never imply manual=false or verified
idle. Complete means the bounded census finished, not that every Pal was
resolved or that scheduler changes are safe. Scheduler integration stays off.

Validation: Lua 5.4 compiles 50 modules; all 71 regression scripts pass,
including 17 new diagnostic cases; structural checks pass (panel remains194
top-level locals). These are mocked contract regressions, not engine acceptance.

## Native acceptance needed

1. Obtain populated authority output and compare identity/suitability with
   native Current Task, including transport, grazing and a normal station.
2. Deliberately fix/unfix one worker and verify the fixed flag transitions;
   restore the original assignment. Observe Reserve/Working/Leave transitions.
3. Establish a complete, authoritative idle path. Absence from a global census
   alone cannot prove that a worker has no fixed reservation elsewhere.
4. Replace the manual global census with one callback-local camp read before
   enabling scheduling. Keep completion, duplicates and scope checks.
5. Test distinct priorities under competing demand, fixed-assignment conflicts,
   staffing limits, actual output, reconnect and changed worlds.

## Deployment record

Only main.lua (help and diagnostic command) plus assignment_probe.lua added to
RAM's existing Scripts. Server entry script was downloaded before replacement
and matches the installed client copy: SHA256
f5d9c3564d29e6cb9612572c354eb7b518551a08a014e0b5ab1bcaa41f25bc9b.
Recoverable local copies are under ignored `.tmp/assignment-census/`.
The existing administrative file-command mechanism was enabled with a blank
remote.txt for this test. No priorities/configuration/pak was uploaded.
## Native census and fixed-assignment transition

RAM restarted successfully; the server macro reconnected and visibly reopened
all nine stand rows (23:23:21–23:24:52, new client PID32052).
Three authority censuses completed with no read failures:

| Time | Native records | Roster | Flambelle evidence |
|---|---:|---:|---|
| 23:46:13 | 13 | 9 | Kindling1, State3 (Leave), fixed=true |
| 23:48:07 | 11 | 9 | Ranch13, State2 (Working), fixed=false |
| 23:49:10 | 13 | 9 | Original Kindling job, State1 (Reserve), fixed=true |

The middle sample follows deliberate unchecking of Flambelle on the native
Primitive Furnace assignment board. The final sample follows restoration;
both the portrait and the original job ID returned. No mod priorities changed.
No WARN/ERROR occurred in the saved 23:40–23:49 probe window.
Evidence: ignored `.tmp/assignment-census/server-fixed-transition.log`.

Ranch workers have real assignment suitability13 even when the old
GetCurrentWorkSuitability read is unavailable. A fixed stopped furnace can
retain a Leave/Reserve record, so neither state may mean completed production.
Missing records remain unknown; the final sample matched all nine Pals.

## Direct reader built for comparison

`assignments.lua` follows the fresh roster handle to its actor and parameter
component. It checks component owner/camp, explicit assigned/fixed booleans,
record owner/fixed flag, job/handle ID and job scope. An explicit unassigned,
not-fixed component with no assignment record can yield ready/manual=false;
missing actors/flags or contradictory records cannot. Reserve and Leave keep
verified manual intent without claiming occupied work or job completion.

The roster exposes its existing callback-local handle alongside param. No
wrapper survives the pass. This direct reader performs no FindAllOf,
FindFirstOf or StaticFindObject; 15 focused cases enforce its contract.
All72 regression scripts and compilation of51 Lua modules pass. The diagnostic
now prints direct results beside the independent census for native comparison.
Scheduler integration remains disabled pending that comparison.

## September 26: direct comparison and integration

At 23:57 the eight automatic workers explicitly reported no assignment and
not fixed; the census had no records for those eight. Flambelle retained the
original fixed Kindling job in Leave state through the night.

At 00:01:47 the direct reader agreed with all nine independent census records
on job identity, fixed flag and native state: Vixy/Vaelet/Lamball ranching,
Mammorest/Survivor logging, Pengullet/Penking watering, Braloha reserved for
mining, and Flambelle still fixed to its original furnace job in Leave.
These are assignment observations, not proof of production output or priority
ordering. Evidence: `.tmp/assignment-census/server-direct-comparison.log`.

The scheduler now defaults to this callback-local reader, with an inclusive
`scheduler: assignment read` timing scope. Integration regressions caught an
additional defect: the candidate and fallback loops could admit new work when
manual status was unknown. Both now require explicit manual=false; unknown
workers retain observed permissions subject to X/cap restrictions. Tests model
automatic workers explicitly instead of using missing evidence as an idle
fixture. Fixed Leave evidence protects the user's assignment against competing
higher-priority demand; missing actors cannot acquire new permissions.

Before server deployment: 51 Lua 5.4 modules compile, 72 regression scripts
pass (19 direct-reader cases), structural checks pass. Only scheduler.lua and
scheduler_plan.lua uploaded; restart/reconnect acceptance pending below.

### RAM acceptance after restart

Server macro completed 00:05:48–00:07:19 (PID35652). Native screenshot
confirmed the stand open with all nine rows and existing priority1 values.
The first spawn-time pass (00:06:45) conservatively retained nine unknown
assignments. From 00:06:57 the reader supplied usable evidence: by 00:10:25,
20 passes had sent18 permission requests, with no unverified assignments in
the subsequent19 passes. These are sent requests, not a claim of measured
output or immediate native delivery. Flambelle remained Kindling-only and
retained its original fixed job in subsequent census samples (Reserve state).
00:10:00 status confirmed authority, saved priorities and spread/max3 mode.

Three later censuses (00:10:00, 00:10:01, 00:10:21) continued to match the direct
reader, including ranching, planting/gathering, mining, logging and transport/
watering reservations. No gameplay error was logged. A no-component warning
at startup with nobody connected is expected. A malformed diagnostic command
at00:10:00 was caused by Monaco appending text; its zero-length timing window
was discarded. Explicit select-all/delete and separately verified Save fixed
the test procedure. No user settings were edited during this integration test.

### Valid timing window (00:11:01–00:12:01)

Five complete passes,45 assignment reads,1ms observed clock step. Inclusive
durations below overlap: do not add parent totals and child totals.

| Region | Total / samples | Mean | Worst |
|---|---|---:|---:|
| Complete scheduler |428ms /5|85.6ms|89ms|
| Camp enumeration |127ms /5|25.4ms|26ms|
| Authority resolution |127ms /5|25.4ms|28ms|
| Owned component resolution |127ms /5|25.4ms|28ms|
| Camp roster |29ms /5|5.8ms|9ms|
| Assignment reader |5ms /45|0.111ms|1ms|
| Fence planning |7ms /5|1.4ms|2ms|

The reader contributes about1ms per nine-Pal pass; the three resolution scopes
dominate. This is server runtime timing, not client frame-time measurement or
proof of no stutter. Profiling was switched off afterward. Evidence saved at
`.tmp/assignment-census/server-integrated-timed.log`.

Still required: distinct-priority competing-work/output test, manual/X
conflicts, staffing under reservations, unloaded actors, further worlds and
two-client/guild transitions. Installed client files remain unchanged; this
deployment updates the dedicated-server scheduler only. Nothing published.
