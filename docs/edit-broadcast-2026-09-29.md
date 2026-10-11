# Priority-edit broadcast duplication

Status: fixed, offline checked, installed on RAM; native edit/restore/reopen smoke passed.
After-fix server timing blocked by GPortal management errors. Unpublished 0.5.0-rc1.

## Native baseline

Instrument-only main SHA256 8827adc9f9a1f403b4a5329975e43955dfe7cd870b8e434e7cbeba9cce51ee2f
was read back from RAM before restart. September 29, 15:41:50-15:43:52,
122-second profile. Two priority edits took 441 and 444 ms inclusive in the
incoming hook. Each made a full save-callback broadcast (~108 ms), then an
explicit one-Pal delta (109 ms). Save-and-notify was 113 ms inclusive; it is
not all disk time. Roster validation averaged 55.5 ms. One additional full
snapshot came from connection setup. The earlier 2456-ms event did not repeat;
its exact cause remains unknown. Lua os.clock timings are not frame times.

Evidence: `.tmp/assignment-census/server-edit-phases-before.log`.

## Change and checks

Store tracks pending one-Pal versus multi-Pal notification scope, retaining it
across save failures and detaching it before callbacks. Normal local saves and
background retries notify with the key (or nil for full). The network handler
requests invocation-local deferred notification and takes ownership of one
explicit broadcast: delta for clean/same-Pal commits, full if the flush also
committed other Pals. A clean no-op clear still sends a fresh snapshot. Failed
saves keep the existing applied_unsaved response and delta attempt. Disk
recovery, sender authorization and protocol acknowledgements are unchanged.
A successful save is not proof of successful delivery.

New tests failed before the fix and pass afterward. All 73 Lua regression
scripts pass; 51 modules compile under Lua 5.4; structural checker passes with
the existing panel 194-local warning. Independent read-only review found no
correctness defect; its requested multi-key and throwing-reentrant-callback
coverage was added and passed.

Server readback matches source:
- main.lua: 53cdec006c817a048cf9d5e897c3bee6ba57e82b52770fbc70978c7fe7cd7b8c
- store.lua: ac07ab5832b446854be8b99603ea6939882e9607120e32858617a6ced21990c3

Local next-start installation also matches; backup is mod-root
`backups/edit-notify-20260929-154739`. The currently running client has not
restarted for these two files; the behavior being tested executes on RAM.

## Native after-fix smoke and remaining timing gate

GPortal restart initially timed out. A later retry visibly passed through
Stopping/Maintenance/Updating and disconnected the client. Rejoined RAM:
client world boundaries 15:53:07/09. Nine rows appeared; Vixy Gathering
1 -> 2 -> 1 settled to normal green values without pending/error markers.
Client status at15:56:21: client role, synchronization ready, priorities saved.
No new client WARN/ERROR in the recorded post-rejoin segment. Client evidence:
`.tmp/assignment-census/client-edit-notify-after.log`.

GPortal subsequently stopped loading the server page and displayed an error
with automatic retry. After-fix server profiling could not be enabled or its
logs downloaded; therefore no measured speedup is claimed. The ~108ms removable
baseline work is measured, not a post-fix result. The after-fix server banner
and warning audit remain to be retrieved. Timing was disabled before the restart
and defaults off. Next: enable a new bounded profile, repeat1->2->1, check two
deltas with no edit-triggered full broadcasts, restore1 and turn timing off.

Both same-process reconnects required opening/closing the vanilla Escape menu
before the stand interaction prompt appeared. This happened with the diagnostic
build and again with the fix even though the stand was closed before restart.
Record as a separate input-lifecycle lead, not caused or fixed by this patch.
The known stale Pal detail-card hover was also visible and remains open.

Final close/reopen via the existing open-only AHK route returned all nine rows
and the restored priority1. Game left at the open stand. No public release or commit.
