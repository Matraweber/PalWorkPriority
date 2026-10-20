---
date: 2026-09-29
tags: [network, performance]
status: evidence
---
# Transmitter-first broadcast discovery — September 29

Related: [edit-latency-root-cause-2026-09-29](edit-latency-root-cause-2026-09-29.md) · [push-lifetime-2026-09-29](push-lifetime-2026-09-29.md) · [save-flush-2026-09-29](save-flush-2026-09-29.md)

Candidate remains unpublished 0.5.0-rc1. This changes only net.lua at runtime.

Broadcast discovery now enumerates transmitters, resolves their typed BaseCamp
components, and matches exact negotiated component names. Existing fresh
owner/guild/peer/session proof remains. One lazy global component scan handles
unresolved recipients, reusing the transmitter map. Direct replies are unchanged.
No native instance survives the callback. Guards cover class resolution,
component lookup, validity/name reads and fallback discovery before further
native access, sending or revision commitment.

Independent review found no blocking discovery defect. The new regression
contains290 cases across P/R streams, two guilds, name mismatch, missing class
or method, partial resolution, fallback recovery, guild rejection, peer/session/
nonce/authority replacement and nested pushes at native boundaries. The saved
pre-change module fails both fast-route cases (expected0 scans, got1). The new
module passes; all77 regression scripts pass and51 modules compile under Lua5.4.
Structural checks pass with the existing panel194-local warning.

Source/client/downloaded-server-readback net.lua SHA256:
1c67fb25bd91a1e85dad4c46cfc6dfb908fd95d0b92b76b2904f494cf5ac8fc2.
Prior client module preserved under mod-root backups/transmitter-first-20260929-194402;
its hash matches the preceding385e7efb… build. No saves/configuration/pak changed
by deployment.

## Native RAM comparison

Server boot19:45:30. Normal native Return to Title/Yes and Quit/Yes ended the
old client; the documented --launch AHK macro started PID20040 and verified
RAM/guild at19:47:14. All nine stand rows returned. Four native Vixy Gathering
edits1→2→1→2→1 confirmed visually; server receipts19:47:49,19:48:11,19:48:35,
19:48:54 agree. Original1 returned to green. Profiler window19:47:31–19:49:02,
91seconds, one client/guild/camp and nine Pals, daytime progressing into night.

| Inclusive region | Prior lifetime smoke | New measurement |
|---|---:|---:|
| Stand delta |2 samples,110ms mean|4 samples,83.5ms mean,89ms max|
| Component discovery |2 scans,25.5ms mean|0 scans; row absent|
| Transmitter discovery |25.5ms mean|4 scans,25.5ms mean|
| Push roster |58.5ms mean|57.75ms mean|
| Edit validation roster |55.5ms mean|54.75ms mean|
| Save and notify |4/5ms|4 saves,497ms total,482ms max|
| Complete incoming edit |300/306ms|274/276/280/738ms|

The specific delta stage is26.5ms lower (~24.1%), consistent with the eliminated
25.5ms scan and stable transmitter/roster costs. This is stronger mechanism
evidence than comparing whole-session averages; it is still sequential live
testing, not randomized identical-world A/B. No fallback was required by these
four updates. Native multi-recipient and fallback behavior remain unexercised.

Three ordinary edits average276.7ms, but do not discard the fourth when reporting
overall performance: all four average392ms. The738ms callback includes a482ms
save, of which478ms was closing the temporary file. Other three saves total15ms.
This reproduces the separate close-operation stall more severely, without
identifying its OS/hosting cause. Checked saves/recovery remain intact. It is
not evidence that all remaining stutter is solved or that the broader edit
latency distribution improved.

Twelve complete scheduler passes averaged73.833ms,90ms maximum. Six needed
owned-component resolution (25.667ms mean). Varying work/permission requests
and night transition differ from the earlier two-edit scene. One assignment
remains explicitly unverified. No WARN/ERROR occurred in the measured window;
final status reports authority yes and priorities saved. Profiling off verified
at19:49:02; both logging sinks report zero failures. No independent frame-time
capture or exact click-to-ack timing was taken.

Evidence: `.tmp/assignment-census/server-transmitter-first.log`,
`client-transmitter-first.log`, `net-transmitter-first-server.lua`,
`transmitter-first-tests.txt`, `transmitter-first-server-running.png`.

## 2026-09-29 (18:16-18:17): stand delta phases, before this change

Merged from push-phases-2026-09-29 (deleted 2026-10-20, git history keeps it).

net.lua got seven opt-in phase labels (component scan, transmitter discovery,
peer guild, direct guild, roster, snapshot encoding, message send); with
profiling off the original functions are called directly. 59 s edit-only
window on RAM, one client, one camp, nine Pals, four edits:

| Inclusive region | Samples | Mean | Worst |
|---|---:|---:|---:|
| Incoming edit hook | 4 | 302.25 ms | 351 ms |
| Stand delta | 4 | 111 ms | 113 ms |
| Push roster | 4 | 58.75 ms | 61 ms |
| Component scan (FindAllOf) | 4 | 26.5 ms | 27 ms |
| Transmitter discovery | 4 | 25.5 ms | 26 ms |
| Peer guild | 4 | 0.25 ms | 1 ms |
| Snapshot encoding / message send | 4 | 0 reported | 0 reported |
| Edit roster validation | 4 | 57 ms | 59 ms |

The 111 ms delta is roster 58.75 + component scan 26.5 + transmitter
discovery 25.5 ms. Encoding and send were below the clock's resolution
(reported zero is not zero cost). The component scan is the one this change
removed.

## 2026-09-29 (15:02-15:32): one discovery per multi-guild broadcast

Merged from stand-push-discovery-2026-09-29 (deleted 2026-10-20, git history
keeps it).

`push_stand` memoised rows per guild but let every guild repeat both discovery
calls. Since then one lazy observation is shared within the synchronous
`net.push_pals` call; each guild still reads only its own roster, a failed
scan stays unavailable for the whole push, and a changed session refuses
already built rows. This saves two discovery calls per additional guild and
nothing for one guild. It is tested offline only (integration regression with
two guilds); no native two-guild broadcast was measured. The discovery route
it shared (component scan plus transmitter scan) was replaced the same evening
by the transmitter-first route above.

The same day's server profile (130 s) still showed authority resolution
24.9 ms (22 samples) and camp enumeration 25.3 ms (21 samples) per call, and
one unexplained 2456 ms incoming callback. Research lead only: the SDK header
of PalBaseCampManager declares `GetBaseCampIds` and `TryGetModel`; live
support and safe out-parameter marshalling are unproven, and no route was
changed on that basis.
