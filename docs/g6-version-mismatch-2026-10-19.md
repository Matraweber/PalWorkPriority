# G6: old client and new server disagree politely, 2026-10-19

Gate: a 0.4.1 client joining a 0.5.0 server, and the reverse, shows a clear
incompatible-version message and corrupts nothing.

## Designed behaviour (rc1 code)

- rc1 server, old client: `net.receive_command` answers 0.4.1's `PWP_Hello`
  (no schema fields) with `PWP_Incompatible|<schema>|<works>` and refuses every
  old-format mutation with the same reply; old messages never reach main.
- rc1 client, old server: 0.4.1's reply formats (`PWP_Incompatible`,
  `PWP_Rule`, `PWP_Pal`, ...) set the client status to `incompatible`, and the
  stand says "Server version incompatible; priority data unavailable."

## A. 0.4.1 client on the rc1 server (RAM, 3daac01): no corruption, no message

1. Game at the title screen; the whole local mod folder snapshotted with a
   SHA-256 manifest (5,040 files, verified) to
   `D:\PalWorkPriority-backups\pre-g6-version-20261019-174915`. Live `Scripts`
   moved (not deleted) into the snapshot, tag v0.4.1's `Scripts` (23 files) and
   `Info.json` extracted in place (as in the 2026-10-11 upgrade test; 0.4.1's
   own pak was never available, the current pak stayed).
2. Joined RAM by hand with the game-stored password after the macro's join
   silently failed (cause below; first misread as a wrong row). 17:50:24 `Pal Work Priority 0.4.1 loaded`, 17:54:37 world,
   17:54:59 0.4.1 detects it is a client.
3. `!pwp net`: transport hooks fine, 4 messages up, 4 down, echo round trip
   works. `!pwp limit`: "no stock limits set" although the server held the
   user's Wood rule: the old client sees an empty view with **no explanation**.
4. Old-format mutation: `!pwp limit Lumbering Wood 5000` on the 0.4.1 client.
   It printed "limit set ... Your rules are sent to it" (old code). Server file
   listing afterwards: **no `caps.txt` created, `priorities.txt` unchanged
   (17:33)**, only `priority.log` written. Nothing corrupted.
5. Restored: 0.4.1 files moved into the snapshot (`v041-test/`), rc1 `Scripts`
   and `Info.json` back; manifest check: only `priority.log` (this test) and
   `remote.txt` (the command channel, then restored) differed. 0.4.1 wrote no
   local data. rc1 loaded again at 17:57:41.

Client log of the run: `test-results/g6-20261019/client-041-on-rc1-server.log`
(local).

Verdict A: corrupts nothing (pass); the "clear message" half fails on the old
client, which cannot understand the server's `PWP_Incompatible`. Proposed fix
for the server side: on an old-format Hello, also send the player a personal
in-game announcement ("this server runs Pal Work Priority 0.5.0; update the
mod to edit priorities") through the game's own announce path, which 0.4.1
does not need to understand.

## Fixes after A (2026-10-19 18:00-18:08)

**Old-client notice.** `net.notify_old_client(comp)`: when the server answers a
client with `PWP_Incompatible` (old Hello or old-format mutation), it also sends
that player a system chat message through the game's own
`UPalUtility::SendSystemToPlayerChat(world, text, {PlayerUId})`, reached via
component -> transmitter (class walk) -> owning controller -> PlayerState. Once
per client per session, authority only, names kept, failures logged and never
blocking the reply. Text: "Pal Work Priority: this server runs a newer version
of the mod (0.5.0). Your copy is older, so your priority and limit changes are
not applied here. Please update Pal Work Priority." Tests:
`tests/test_net_old_client_notice.lua` (sent once with the player's uid, not
twice, again after a new session, never from a client, failure logged and not
retried) and an assertion in `test_net_settings_gate.lua` that an old Hello
triggers it; negative control: without the call that assertion fails. 219
scripts pass. Engine call verified live in singleplayer (sent to the local
player): the chat showed `[SYSTEM]: Pal Work Priority: this server runs a newer
version ...`. The server-side path with a real 0.4.1 client is not yet
verified live (needs the server on this build: next server update).

**Server macro join.** The first diagnosis ("wrong row") was wrong: the macro
clicks the second Recent Servers row, and RAM was second. The real fault: it
clicked the row immediately after opening Recent Servers, before the list had
loaded (about 3 s for players and ping), so the password and confirm clicks hit
nothing. Now 4 s after Recent Servers, 3 s before the password OK, 2.5 s before
confirm. Live: 18:06:11 start, 18:07:07 row, 18:07:51 SERVER_READY with the
verified guild.

## A, rerun with the notice (2026-10-19 18:09-18:16): PASS

Server RAM updated to 28e41ca through the panel (backup `Scripts-before-28e41ca`,
58 files, net.lua 93.6 KiB matches the commit); the user approved the restart
click this time: restart 18:11:41, PWP_READY 18:11:54, no PalWorkPriority
error. Local client switched to 0.4.1 again (rc1 28e41ca Scripts moved into the
snapshot as `live-moved-28e41ca`). The fixed server macro joined on its own:
18:12:42 0.4.1 loaded, 18:13:25 RAM row, 18:13:36 world. The 0.4.1 client's
chat showed, in a freshly started game process:

    [SYSTEM]: Pal Work Priority: this server runs a newer version of the mod
    (0.5.0). Your copy is older, so your priority and limit changes are not
    applied here. Please update Pal Work Priority.
    [SYSTEM]: Matraweber joined the server.

Restored: rc1 Scripts back (all 58 equal to the repo, Info.json equal);
local priorities.txt, caps.txt and config.lua byte-equal to the snapshot.

**Verdict A: PASS.** Corrupts nothing, and the old client now gets a clear
message in its own chat.

## B. rc1 client on a 0.4.1 server (2026-10-19 18:17-18:35): PASS after a fix

The user approved the server switch and the restart clicks for this step.

**Setup.** 0.4.1 drops X rows when it saves, so `priorities.txt` was first
archived on the server with the panel's Zip function
(`priorities-before-g6-041-20261019.zip`, 18:18; the file itself was not
touched). rc1 `28e41ca` was renamed to `Scripts-rc1-28e41ca-during-g6`, the
0.4.1 Scripts were uploaded and unzipped (23 files, main.lua 118.14 KiB =
120,972 bytes, matching the tag), restart 18:21:06, 0.4.1 loaded 18:21:13
(0.4.1 writes no `PWP_READY`).

**First join (rc1 28e41ca client).** The server macro joined on its own
(18:22:57 RAM row). The client log was right:

    18:23:16 synchronization: client; incompatible
    18:23:16 sync: incompatible (server_requires_matching_mod)

but the limits panel (Alt+F1, 18:24:06) said "Connecting to server..." and
kept saying it. Cause: a client role starts at "connecting" in `caps.set_role`,
and net reports a status only when it changes. On this join net had already
reported "incompatible" before `decide_write_or_send` decided the client role,
so set_role overwrote it and nothing ever sent it again. The client could not
write either way (no Welcome, no snapshot); only the message was wrong.

**Fix.** `decide_write_or_send` takes over net's final states (incompatible,
unavailable) right after `caps.set_role` for a client. "ready" is not taken
over, it still needs this session's snapshots. Test: "incompatible reported
before the client role keeps the panel on incompatible" in
`tests/test_main_integration.lua` replays exactly this order (old-format rule
first, then the role tick) and checks the panel status and reason. Negative
control: without the fix it fails at that assertion. 219 scripts pass.

**Second join (with the fix).** Deployed locally 18:26:12, the server macro
restarted the game and joined again: 18:27:49 connecting (awaiting_handshake),
18:27:54 incompatible (server_requires_matching_mod). The panel now showed
"Server version incompatible" with "Server and client need matching mod
versions".

**Server data.** `priorities.txt` on the server stayed 2.43 KiB, modified
6:11 PM (before the 0.4.1 phase), so the 0.4.1 server rewrote nothing.

**Restored.** 0.4.1 renamed to `Scripts-041-g6test`, rc1 back to `Scripts`
(6:11 PM), restart, `PWP_READY version=0.5.0-rc1` at 18:34:42, no
PalWorkPriority error or warning in the log, scheduling again. Local client
back in the singleplayer world (macro, 18:37:14) with the fix deployed; local
priorities.txt, caps.txt and config.lua byte-equal to the pre-G6 snapshot.

**Verdict B: PASS** (after the panel fix). The new client refuses to edit an
old server and now says why.
