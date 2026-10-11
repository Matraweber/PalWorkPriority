# Photo mode and stale limit drafts — September 24, 2026

## Native photo-mode check

On PID15092 with the existing 0.5.0-rc1 candidate, entered Photo Mode through
the vanilla command wheel after prior stand/Production Limits use and closure.
No dormant grey mod backdrop was visible with the HUD shown, hidden via F, or
restored. Escape returned to gameplay. Production Limits reopened afterward,
and its open input route blocked the command-wheel key as expected. This is
closed-panel photo-mode acceptance only, not all UI hide/show paths or respawn.
The ordinary keyboard settings were inspected without changing any binding.

## Confirmed stale-draft defect and correction

The amount editor remembered its initial limit but confirmation did not compare
that value against current rules. A changed or removed rule could be overwritten
or recreated by an old draft. The new real-renderer regression failed before
the fix with `stale draft overwrote newer limit`.

Confirmation now compares the current effective guild/work/item value with the
draft's original value before any write. A mismatch refuses the edit and asks
the player to cancel/reopen. Unrelated rule changes do not block confirmation.
Tests cover changed and deleted rules and preservation of unrelated changes.

All49 Lua modules compile; all67 regression scripts and the structural checker
pass. This protects against already-observed changes in the current view; it
does not add a server-side atomic compare-and-set or detect an unseen concurrent
edit. Populated multiplayer concurrency acceptance remains open.

Checked deployment receipt: test-results/editor-conflict-deploy-20260924.txt.
The normal AHK restart was launched in --world mode for fresh-load acceptance.

## Fresh-load check and review

The helper exited PID15092 normally, launched PID2964 at20:41:08, and reopened
the stand at20:41:39. Priority numbers returned. Opened Production Limits via
the development channel, clicked Wood's amount, and confirmed its unchanged
30000 value using the actual Confirm control. The editor closed normally, with
no false conflict. Escape then closed only the limits panel. Stand left open.

Installed panel source matches the checked source; priorities, caps and config
remain byte-identical to the earlier backup. No WARN/ERROR matched the captured
post-restart window. Receipt: test-results/editor-conflict-native-20260924.txt.
Independent review found no blocking issue and passed conflict/render tests.
Its suggested queued-confirm regression was added and passes: changing the
target after queuing Confirm but before execution results in no write.

Changed/deleted-rule conflict behavior has regression coverage, not a live
two-owner multiplayer reproduction. Respawn and the full native pagination
matrix are still pending; existing simulated 0/1/13/14/26/27 checks pass.
