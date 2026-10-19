# G6: guild isolation on rc1, 2026-10-19

Dedicated server "RAM" on 3daac01 (0.5.0-rc1), local client on the same build.
Gate: the August fabricated-guild test (a rule under a fake guild id plus the
real-guild control) gives the same result on rc1.

## Setup

The server had no `caps.txt` (no rules). A test file was written in the mod's
own data format (`# PWP-DATA 1 <gen> <bytes> <fnv1a>` header, generation 1,
FNV-1a 32 checksum over the payload) with two rules:

| guild | work | item | ceiling | role |
|---|---|---|---|---|
| `-111111111-222222222-333333333-444444444` (fabricated) | Mining | Stone | 1 | would stop all mining at once if it leaked to the user's guild |
| `-357895952-1262986004-1392804764--410933938` (the user's server guild, from `restart-server-stand.ahk`) | Deforest | Wood | 9999999 | control, never met |

Offline first: loaded through the real `datafile` + `caps` modules (temporary
test run, not committed): 2 rules; `caps.all` for the real guild returns only
Deforest/Wood, for the fake guild only Mining/Stone. Copy of the file:
`test-results/g6-20261019/server-caps-guildtest.txt` (local).

Uploaded to the server's mod folder through the GPortal panel (17:30). The
server restart that loads it was done by the user (the auto-mode classifier
blocked Claude's restart click); PWP_READY 17:33:47, no PalWorkPriority error
or warning, no recovery message.

## Result: PASS

The local client joined through `restart-server-stand.ahk --launch` (17:35:58
`role: client`, `server guild: -357895952-...--410933938`). `!pwp limit` on the
client listed exactly one rule, `Lumbering Wood unavailable / 9999999` (stock
unavailable is the normal client state before the panel requests storage);
the fabricated guild's Mining rule was not visible. The list the server sends
a client is `caps.all` filtered by the sender's guild, the same function the
scheduler uses per camp guild (`caps.for_work`), which the offline load
confirmed excludes the fake guild. The server's own pass log (`priority.log`,
83 MB) was not read; the panel's UE4SS log does not carry scheduler lines.

## Cleanup

Renamed on the server to `caps.txt.guildtest-20261019` (not deleted). No
`caps.txt` or `.bak` remains, so the next server start has no rules; until then
the two rules stay in memory (harmless: the fake guild matches no player, the
control is never met) and are only written back if a rule changes.

Also: `tools/restart-server-stand.ahk` got the same focus fallback as
`restart-stand.ahk` (title-bar click, short settle).
