# Save spike investigation: September 29

Status: checked operation-level timing installed on RAM and client; live tested.
No persistence behavior optimization or durability relaxation was made.

## Reason and implementation

The preceding four-edit test contained a577ms edit with278ms in deferred save;
the other three saves totaled14ms. The exact slow file operation was unknown.
datafile.lua now times each existing checked open/read/write/close/remove/rename
under finite phase names: inspect temporary/recovery/live/backup, write/verify
temporary, protect recovery, rotate backup, preserve live, install and restore.
Only explicit profiling collects these measurements; no per-operation logging
or extra filesystem calls are introduced. Checked return tuples, error handling,
close attempts, verification, backup and recovery ordering remain intact.

74 Lua regression scripts pass;51 modules compile with Lua5.4. The real-profiler
test injects a278ms replacement delay and verifies attribution, as well as
identical file contents, operation order and results with timing on/off. Faults
cover open, thrown read, write, close, backup removal, preservation, installation,
failed restoration and temporary-generation protection. Assertions verify that
each intended fault actually fires. Independent review found no blocker and
requested improvements to failure annotation and coverage, both incorporated.

## Installation and native evidence

Server datafile.lua downloaded after upload and matched SHA256:
16c13cc215aba447cce3e24ef8b5b45a7cb9cdf6e0ecfc41f7f72244fe73c9dc.
Local copy matches too, with backup under mod-root
backups/save-phases-20260929-170534. Server boot17:05:50. The documented AHK
--title macro exited client24088, started35008, verified the RAM guild and opened
the stand at17:08:04 without manual game input during the macro. Nine rows
returned. Vixy Gathering1->2->1 repeated twice; each value settled to normal
green, and original1 was restored. No other priority intentionally changed.

88-second profile17:08:01-17:09:29:

| Inclusive region | Samples | Mean | Worst |
|---|---:|---:|---:|
| Incoming edit hook |4|279.25ms|282ms|
| Deferred save |4|4.5ms|5ms|
| Stand delta |4|108.75ms|111ms|
| Roster validation |4|55.5ms|57ms|
| Complete scheduler |11|59ms|62ms|

Edits:274,279,282,282ms. Live, backup and temporary-verification reads each
recorded1ms per save. Other filesystem phases had timed samples but zero reported
duration: below the clock's observable precision, not proof of zero cost.
Clock-resolution estimate in this window was unmeasured. Nested measurements
overlap; do not sum them or interpret them as frame times.

The278ms save spike did not reproduce. Ordinary saves remain4-5ms, so removing
recovery protections would not address most of the recurring edit delay. The
night/idle scheduler was cheaper than the earlier active scene; the lower total
edit times do not demonstrate a speedup caused by instrumentation.

Profile off17:09:29; serverauthority and saved priorities confirmed. No
WARN/ERROR within the measurement window. Earlier17:07:50 join-announcement
rate-limit warning remains documented. One assignment remained unverified;
these timings do not establish correctness of that Pal's scheduling.

Evidence under .tmp/assignment-census/: server-save-phases.log,
client-save-phases.log, datafile-save-phases-server.lua, save-phases-tests.txt,
save-phases-checker.txt and save-phases-server-running.png.

## Next investigation

Keep the detailed counters available for a future recurring save spike. The
old2456ms event and278ms save event remain unexplained at operation level.
Prioritize measured recurring network/roster work next; preserve fresh authority,
guild isolation, conservative incomplete-roster handling and callback-local
native-object lifetimes. No broad stutter-free or release-ready claim.
