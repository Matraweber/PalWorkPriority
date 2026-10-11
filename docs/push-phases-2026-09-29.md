# Stand update phase measurements — September 29

Status: diagnostics installed and measured on RAM; no new performance
optimization is claimed. Candidate remains unpublished 0.5.0-rc1.

## Change and verification

net.lua has seven fixed, opt-in phase labels: component scan, transmitter
discovery, peer guild, direct guild, roster, snapshot encoding and message send.
Profiling off calls the original functions directly. No additional discovery,
authorization shortcuts, persistence changes or retained native wrappers.
The component scan label covers FindAllOf, not subsequent validity/name reads.
Encoding covers protocol.snapshot, not earlier row filtering/string assembly.
Labels are shared by full/rules pushes, so use an edit-only window for attribution.

75 regression scripts pass; 51 modules compile under Lua5.4. The added real
transport/profiler regression checks on/off equivalence of packets, operation
order, revisions and recipients, plus incomplete roster refusal, guild mismatch,
native send failure and direct-component routing. Existing transport tests cover
the wider protocol; this new test is not a native multi-guild acceptance test.
Independent review found no instrumentation blocker.

Installed net.lua SHA256 (source, client, downloaded server readback match):
3a50c2fa26274a378e32082d30ad7a92230bd4f9bfcb9da94e47ceb42c907d78.
Previous client file preserved in mod-root backups/push-phases-20260929-175309
and .tmp/assignment-census/net-before-push-phases.lua.
RAM boot17:54:17. The title macro stopped safely after failing normal exit;
manual native Quit/Yes succeeded. Launch-mode macro then verified RAM and
opened the stand17:57:46 with new clientPID39820. Full unattended restart
acceptance remains open. An interrupted diagnostic window was discarded and
profiling disabled18:15:50 before the measured window below.

## Live edit-only window

September29 18:16:18–18:17:17, 59seconds. One client/guild, one loaded camp,
nine Pals, idle/night scene. Native input changed Vixy Gathering1→2→1 twice;
all four server receipts appear, original1 returned to normal green, and final
status says priorities saved and authority yes. Profiling off18:17:17.

| Inclusive region | Samples | Mean | Worst |
|---|---:|---:|---:|
| Incoming edit hook |4|302.25ms|351ms|
| Stand delta |4|111ms|113ms|
| Push roster |4|58.75ms|61ms|
| Component scan |4|26.5ms|27ms|
| Transmitter discovery |4|25.5ms|26ms|
| Peer guild |4|0.25ms|1ms|
| Snapshot encoding |4|0 reported|0 reported|
| Message send |4|0 reported|0 reported|
| Edit roster validation |4|57ms|59ms|
| Save and deferred notification |4|21.75ms|73ms|
| Temporary file close after write |4|17.25ms|69ms|
| Complete scheduler |9|60.556ms|66ms|

Individual edit durations351,293,278,287ms; delta112,111,108,113ms.
No full broadcast was measured. The roster plus discovery phases explain
almost all of the update cost; actual snapshot encoding/send has timed samples
below observable precision. Runtime clock resolution was unmeasured. These
are inclusive runtime durations, not independently captured frame times;
parent/child rows must not be summed as separate costs.

The save diagnostics caught a69ms close operation inside one73ms save; other
three saves totaled14ms. This identifies a blocking operation in this window,
not an OS/filesystem root cause and not proof that the old278ms save or2456ms
handler had the same cause. Retain checked close, verification and recovery.

Zero WARN/ERROR in the measured window, both log sinks report zero failures.
One assignment remains unverified; green priorities establish synchronization,
not complete assignment/production correctness. No stutter-free claim.

## Next bounded change

Investigate eliminating the second roster build using only plain data from
the complete, successful edit validation, with fresh authority and recipient
guild checks. Any reuse must survive neither session/nonce changes nor nested
callbacks. Clears require recomputing inherited effective values and cannot
simply replace the priority with nil. Full/multi-Pal notifications and failed
saves must preserve their existing semantics. No such optimization is installed
yet; a regression for invalidation between same-guild recipients is required.

Evidence under .tmp/assignment-census/: server-push-phases.log,
client-push-phases.log, net-push-phases-server.lua, push-phases-tests.txt,
push-phases-checker.txt and push-phases-server-running.png.
