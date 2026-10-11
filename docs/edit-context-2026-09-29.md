# Incoming priority edit: bounded sender reuse and stale acknowledgement guard

Status: installed and live-tested September 29; residual latency remains open.

Follow-up to `edit-broadcast-2026-09-29.md`. The transport already resolves the
sender guild to authenticate a negotiated request. Main then repeated that
transmitter lookup before roster validation. This change removes that second
lookup only within the same synchronous incoming priority handler.

The transport passes an opaque internal token. A private context contains only
plain data and the plain peer record, never engine wrappers. Main asks for the
guild with that token, its current session epoch and the current component.
The resolver checks token identity, epoch, server nonce, peer identity and its
session/guild fields, and sender name. Reentry, session reset and handler exit
invalidate the token. An invalid token refuses; an invocation without a token
uses the existing fresh guild lookup. Main's fresh authority latch, full roster
authorization, recipient checks and scheduler safety checks remain.
Token comparison uses raw identity. The helper rechecks its context after the
native sender-name read, and main rechecks again after roster reads immediately
before mutation. The independent reviewer identified these two extra boundaries;
regressions cover metamethod forgery and nested callbacks at both read sites.

A regression also reproduced a correctness defect: a handler could replace its
session or peer while authority remained true, then the transport recorded and
sent an acknowledgement for the superseded request. The return path now checks
the captured epoch, nonce, peer identity and peer session/guild fields before
recording or sending any acknowledgement.

Tests cover token forgery, wrong epoch/sender, successive independent lookups,
expiry on return/exception/reentry/reset, same-epoch nonce rotation, peer
replacement, real-main lookup count, and false/unknown fresh authority preventing
native roster reads. Existing no-op edits, multi-Pal saves, failed saves and
duplicate requests remain covered by the full suite. The stale-ACK regression
failed before the production fix.

All 73 regression scripts pass, all 51 modules compile with Lua 5.4, and the
structural checker passes with the existing panel 194-local warning. Logs:
`.tmp/assignment-census/edit-context-tests.txt` and `edit-context-checker.txt`.
The independent reviewer checked the final code and tests and found no remaining
blocker for this scoped change; their review did not include live measurements.

Pre-install performance claim: one fewer sender lookup per accepted priority invocation,
verified in regression tests. No milliseconds saved are claimed: sender lookup
was not separately timed. The earlier 441/444ms edits were before the duplicate
broadcast fix; approximately 330ms afterward was an estimate, not a reading.
The earlier 2456ms outlier remains unexplained.

Before the native retest below, GPortal's file manager reported
"Error loading server" with a retry countdown exceeding ten minutes. That
temporarily prevented installation and timing. Recovery and scoped native
acceptance are recorded below; the broader stutter investigation is not complete.

Deferred: sharing native camp observations across validation/save/broadcast,
or stopping roster validation at the target Pal. Those changes widen object
lifetime or risk skipping unknown ownership, partial rosters and duplicate
identities. Neither is justified by current measurements.

## Installation and native retest, 16:27-16:33

GPortal recovered. Uploaded main.lua and net.lua, downloaded both and matched
SHA256 to source before restart:
- main: 011d14e5ac8d7216d534573da6f93dde94ce90f66f1f6c12d1127b323f55aa95
- net: eb4f49306b0beeb7c1cad2c9edca4277dcea33bf0689f4e2632bb305697b9c98

Store was already the verified scope/deferred-notification build. Local scripts
were also backed up and replaced (mod-root backups/edit-context-20260929-162707).
Server banner 16:27:31 confirms restart; the documented AHK --title route
exited client39584 and started24088, with expected RAM guild ready16:30:26.
One manual Recent Servers click occurred while the macro was progressing;
therefore this is not evidence of an unattended macro pass. The macro finished
its synchronization checks and stand-open sequence. Both client and server
now run the updated files.

Native Vixy Gathering1->2->1 repeated twice. All four edits settled from pending
to normal green; original1 restored. Escape close followed by --open-only AHK
returned all nine rows with restored values. Client status: client role, ready,
saved. Server status: authority, priorities saved. No limits file exists on RAM;
this test did not create rules or validate production limits.

109-second server profile ending16:32:03 (four incoming edits):

| Inclusive region | Samples | Mean | Worst |
|---|---:|---:|---:|
| Incoming network hook | 4 | 373.25ms | 577ms |
| Stand delta | 4 | 108ms | 110ms |
| Save (notification deferred) | 4 | 73ms | 278ms |
| Roster validation | 4 | 55.5ms | 57ms |
| Complete scheduler pass | 13 | 71.462ms | 88ms |

Individual incoming edit durations:577,304,304,308ms. No full-stand-broadcast
row appeared: four deltas for four edits. This directly verifies removal of
duplicate full snapshots in this one-client scene. Three edits were about31%
below the earlier441/444ms samples; the all-four mean was about16% lower. Scenes
had different work demand, and these are runtime-clock hook durations, not
end-to-end input latency or frame times. Nested timings must not be summed.

The577ms event coincided with278ms in the save phase (the other three saves
totaled14ms). This narrows a new observed spike to persistence but does not
identify the particular file operation or explain the old2456ms event. The
remaining ~304ms ordinary edit path is still substantial. No stutter-free claim.

Profiling was turned off at16:32:03. No WARN/ERROR in the measurement window;
one earlier16:30:11 warning rate-limited repeated join announcements. Startup
initially had nine unverified assignments while no player was connected; later
observations resolved them. Neither absence of errors nor plausible activity
is proof of all scheduling behavior.

Evidence: .tmp/assignment-census/server-context-after.log,
server-context-start.log, client-context-after.log, main-context-server.lua,
net-context-server.lua, context-install-server.png. Pre-install73 suites passed.
