# PalPriority reference comparison and conditional transport lookup

Compared the user's downloaded July26 Core/UI archives, not the newest online
release. Sources were extracted read-only under ignored
`.tmp/assignment-census/reference/`; no reference code was executed or installed.

## Useful lessons and boundaries

| Reference location | Observation | Decision for our mod |
|---|---|---|
| Core main.lua950–1004, sendToggle783–813 | Reads permission differences before sending; unavailable routes do not advance convergence | Resolve our owned component only for an eligible write, before pending-write bookkeeping |
| Core main.lua1007–1038,1244–1304 | Skips unchanged/converged camps, with periodic verification and roster work | Worth further study, but our assignments, X reconciliation, pending writes, storage and session changes all need invalidation coverage before skipping whole passes |
| Core main.lua590–610,1398–1419 | Slow discovery plus event-discovered camps; retains director/work wrappers | Do not copy retained UObject caches; checking a stale wrapper is not a lifetime guarantee |
| UI main.lua277–297 | Changed glyph/style avoids redundant reflected writes | Our render-token approach already does this; retain success-only cache commits and generation invalidation |
| UI main.lua323–351,480–487 | Caches cells, menu and component between callbacks | Do not adopt across-callback wrappers; use current-tree resolution and callback-scoped reuse |
| Core main.lua777–799 | Owner-specific routing and explicit deferral | Useful constraint; our multi-owner/guild acceptance remains open and is not solved by this performance patch |

Reference timing comments are not benchmarks on RAM. Its wrapper caching and
fewer features prevent treating apparent responsiveness as proof that the same
implementation is safe or equivalent here. No source copied into our runtime.

## Implemented change

The measured RAM baseline was85.6ms/pass, including25.4ms owned-component
resolution even when no changes were sent. `scheduler.lua` now resolves at the
first eligible permission difference, after phase/pending/budget/dry-run gates.
A separate attempted flag bounds misses to one synchronous pass; successful
wrappers and failed attempts are discarded at pass completion or exception.
Unavailable routes mark writes blocked/deferred without inventing pending RPCs.
Restore retains its explicit owned-route prerequisite.

The unavailable-work replication branch also shares this route and supplies
the explicit component to `request_work_replication`. It cannot independently
fall back to a global component. Thus a read-only pass without a replication
request has zero write-transport lookups; a pass needing either kind of RPC has
at most one. Authority remains freshly verified before Pal reads, and camp
enumeration remains fresh. The deliberately disabled timestamp authority hint
has not been restored.

Regression: unchanged-pass lookup assertion fails before implementation.
After:72 Lua regression scripts pass,51 modules compile on Lua5.4, structural
checks pass. Cases cover unchanged/dry passes, multiple writes sharing a route,
missing route without pending receipts, next-pass recovery, unavailable work
replication sharing the route, and explicit API route bypassing fallback.

Expected unchanged-pass saving is roughly25ms from the previous measurement;
this remains an estimate until the restart retest below. Changed passes retain
the lookup cost. Whole-pass costs can vary with object population and workload.

## Native RAM retest

Installed scheduler.lua and palapi.lua only; server restart and existing AHK
reconnect completed06:12:31–06:14:03 (PID6224). Stand visibly reopened with nine
rows and existing priorities. No user settings or fixed assignments edited.
Backup of the previous scheduler matches its recorded SHA256992F1EAA…C67A76.

Measured window06:15:02–06:16:08 (66seconds):

| Evidence | Result |
|---|---|
| Complete passes |6;397ms total;66.167ms mean;85ms worst|
| Unchanged passes |5;312ms combined;62.4ms mean|
| Changed pass |06:16:03;two permission requests;85ms|
| Owned-component resolution |1 sample;25ms total|
| Authority resolution |6 samples;154ms total;25.667ms mean|
| Camp enumeration |6 samples;154ms total;25.667ms mean|
| Direct assignment reads |54 samples;5ms total|

The one lookup matches the one changed pass. Versus the earlier85.6ms average,
this sample averages22.7% lower, but these are different live windows rather
than a matched A/B benchmark. The stronger causal evidence is five eliminated
lookups while all six passes still checked authority, camps and assignments.
The changed pass retains the previous spike. Nested totals overlap and must
not be summed. Clock resolution was not established by this window's probe;
zero rows are not proof of zero cost. No client frame capture was taken.

Final census: nine Pals,ten native records,zero read failures; eight records
match direct assignment evidence and Braloha is explicitly unassigned/not
fixed with no census record. Flambelle retains its original fixed Kindling
Reserve job. No WARN/ERROR during the measured window; one repeated-client-
announcement rate-limit warning occurred before it, at06:13:50, and remains
an observed reconnect issue rather than being erased from acceptance.
Profiling switched off afterward. Raw log:
`.tmp/assignment-census/server-lazy-route.log`.

Remaining dominant costs: fresh authority and camp discovery (~51ms combined
per pass here). Do not restore timestamp-only authority hints or cache camp
wrappers to remove them. Distinct priorities, actual output, multiple guilds,
and broader frontend/frame-time acceptance remain separate release gates.
