# Callback-scoped stand discovery

Status: installed and hash-verified on client and RAM. Single-guild native
edit/restore smoke passed; multi-guild native acceptance remains open. The
edit-path spike found here is followed in [broadcast evidence](edit-broadcast-2026-09-29.md).

The September26 sample still spends154ms each on authority and camp discovery
over six passes. No verified replacement for either recurring scheduler scan
was established in this review. Timestamp authority hints remain disabled;
camp wrappers are not cached between callbacks.

A separate duplicate exists in multiplayer stand broadcasts: `push_stand`
memoizes rows per guild but previously let every guild repeat both discovery
calls. It now shares a lazy observation during the synchronous `net.push_pals`
call. Each guild still reads only its own Pal roster and capabilities. A later
push or standalone edit validation obtains fresh evidence. An unsuccessful
scan remains unavailable for the whole push; a changed session refuses even
already-built guild rows. Exceptions retain an unavailable observation.

The integration regression failed before the change on repeated discovery.
It now verifies one scan/authority check for two guilds, isolated rosters,
same-guild reuse, fresh next-push reads, unavailable-scan behavior and session
invalidation. All72 regression scripts pass;51 modules compile under Lua5.4;
structural checks pass (existing panel warning:194 top-level locals).

This removes two discovery calls per additional guild in a broadcast. It does
not reduce a one-guild broadcast or the scheduler's normal scan costs. No new
timing or frame-time improvement is claimed. Native two-guild testing remains
required before release.

Research lead only: the local SDK PalBaseCampManager header declares
GetBaseCampIds(TArray<FGuid>&) and TryGetModel(FGuid, UPalBaseCampModel*&).
This does not establish live-runtime support, safe out-parameter marshaling,
or cheap headless manager resolution. Previous unsafe superclass probes must
not be repeated. No scheduler route was changed on the strength of that header.

## Local installation and smoke test

September29 15:02:31: checked deployment to the D-drive game installation.
All51 installed Lua hashes match source. Main SHA256:
`718a301555dde8e9e1c9ab8801a29641963a51c8b016e17026f1ce9e8a32e01a`.
Prior code/config backup: mod-root `backups/deploy-20260929-150231-15cd727072b343b197dbba47765f8477`.
Preserved the native-tested12040-byte pak (4eddf38bâ€¦bf4a9d), not the older
5400-byte release asset. Config/priorities/caps hashes are unchanged after test.

GPortal returned repeated503 serverTime failures and an Error loading server
page with restart disabled. No server file was uploaded or server restarted.
The existing server continues to run the prior build; the client smoke test
below cannot certify the changed server-side broadcast path.

The title-mode macro failed normal exit and stopped without killing the game.
Normal UI Quit/Yes succeeded. The launch-mode macro then started PID31836,
loaded the candidate15:04:50, verified RAM/guild and opened the stand15:06:09.
Nine numeric rows appeared. Direct keyboard input changed Vixy Gathering1â†’2;
restored1, closed with Escape and reopened with the existing open-only macro.
All nine rows and original1 values returned. The initial synthetic mouse click
did not establish a confirmed change; no mouse acceptance claim follows.

Client-only profiling15:06:39â€“15:08:04 (85seconds):82 complete stand refreshes,
883ms inclusive total,10.768ms mean,20ms worst. Complete clock batches peaked
at23ms. Nested timings overlap; no independent frame capture, server timing or
stutter-free conclusion. Correct client authority/synchronization-ready status
at each sample; three initial echoes returned. One expected client-role warning
at15:05:57, no ERROR in the post-restart log. Profiling disabled15:08:04.
Evidence: `.tmp/assignment-census/client-stand-push-smoke-20260929.log`.

Next: upload checked main.lua when GPortal recovers, restart server/rejoin,
verify stand edit/restore and server logs. A two-guild broadcast is still needed
to measure the specific duplicate-scan saving.


## Server installation and native retest (September 29)

GPortal recovered. Downloaded the previous main.lua as a rollback copy, uploaded
only the checked replacement, and downloaded it again. Server readback SHA256
matches the source hash above. Evidence: `.tmp/assignment-census/main-before-stand-push.lua`
and `main-server-stand-push.lua`. RAM restarted; new banner 15:22:04. Rejoined
with client PID39584. The stand displayed nine rows. Direct input changed Vixy
Gathering 1 -> 2 -> 1; both changes were confirmed visually and server-side
at 15:29:18 / 15:29:38. Original priority restored; status reports saved.

Server profile 15:27:46-15:29:56, 130 seconds:

| Inclusive measurement | Samples | Mean | Worst |
| --- | ---: | ---: | ---: |
| Complete scheduler pass | 13 | 65.692 ms | 86 ms |
| Periodic pass callback | 11 | 62.455 ms | 86 ms |
| Authority resolution | 22 | 24.864 ms | 26 ms |
| Camp enumeration | 21 | 25.286 ms | 27 ms |
| Owned component resolution | 3 | 25 ms | 26 ms |
| Incoming network callback | 3 | 965 ms | 2456 ms |

Two edit-correlated incoming callbacks cost 2456 ms and 439 ms, while their
nested scheduler passes cost 84 ms each. This identifies a serious remaining
edit-path cost, not its exact cause. That callback also contains sender/roster
validation, persistence, snapshot push and acknowledgement work. Those phases
need separate timing before choosing a fix. Neither frame time nor a controlled
before/after comparison was captured. Do not call this stutter-free or attribute
the spike to this change without a baseline. Inclusive rows must not be summed.

Server authority remained yes. No WARN/ERROR in the downloaded post-restart
window through 15:32:32. Both log sinks reported zero failures. Final census:
9 Pals, 13 records, zero reader failures; LavaGirl retained the same fixed
Kindling assignment. This census does not prove completed production. Later
passes reported one unverified assignment; retain that uncertainty. Profiling
was confirmed off at 15:29:56. Evidence:
`.tmp/assignment-census/server-stand-push-final.log`.

Only one client/guild was present: the specific multiple-guild scan reduction
is still covered by offline regression, not native measurement. Close/reopen
passed in the earlier client smoke; it was not repeated after this server update.

The restart macro launched the client but raced server-list readiness, producing
'Mods are not allowed on this server'. Manual selection of the visible RAM row
connected successfully without changing server settings. Treat this as a macro
readiness defect, not successful end-to-end macro acceptance. No code commit or
public release was performed.
