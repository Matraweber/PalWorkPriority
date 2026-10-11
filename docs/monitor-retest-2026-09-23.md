# Monitor migration and native retest — September 23

Unpublished 0.5.0-rc1. User resumed native testing and requested a restart macro for the new monitor. No publishing or commit.

## Installation repair

The running game had moved to `D:\Steam\steamapps\common\Palworld`; the former C-drive path no longer existed. The current window has a 1280x720 client area (1282x752 outer window). The old desktop macro used absolute desktop coordinates.

The initial session did not map UE4SS, and both logs were historical September 16 files. The moved native runtime folder lacked its DLL/settings/default activation files. Restored the already-downloaded Workshop dependency 3625223587, version 2281fa31, DLL SHA256 `21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8`. The in-game manager also had no active packages. Enabled only the installed UE4SS dependency; unrelated Workshop mods remain inactive. This is a different mod cohort from earlier multi-mod recordings.

Dependency activation rewrote stock mods.txt, so PalWorkPriority has its own empty enabled.txt marker. The checked deploy passed Lua 5.4 compilation; all 59 Lua regression scripts passed beforehand. All 44 installed Lua files match source. The test pak is contract2, SHA256 `0c2c2941286bd1483068858efd40a9a055678bbacdcf741deca026b5f1a36629`. The source/release baseline pak remains unchanged.

Backups: runtime `backups/monitor-repair-20260923-204850`, and PWP `backups/deploy-20260923-204851-98f4803e4a394ea2a7e726bed84c3de4`. Original asset and player settings preserved. No save rollback.

## Restart helper

`tools/restart-stand.ahk` is copied to the existing desktop shortcut filename. The original is preserved as `Restart and open monitoring stand.ahk.backup-20260923`.

- Default: start at the stand with its grid open, Production Limits closed, first world = Palpagos Islands.
- `--world`: same position with grid closed; `--title`: title screen; `--launch`: game already closed; `--check`: configuration/syntax only.
- Clicks scale against the current game client rectangle. Moving between monitors is supported without fixed screen coordinates; only 16:9 windows of at least 800x450 are accepted. Different aspect ratios require calibration.
- Normal Return to Title and Quit save/exit paths; never force-kills. Verifies old PID exits and a new PID appears. Waits for a fresh, nonzero-session PWP_READY marker with a bounded timeout, then an additional loading margin before holding V.
- Pause or Scroll Lock aborts. Cleanup releases only a key actually held by the helper. A first draft sent a spurious Escape release at exit and closed the stand; corrected before final acceptance. An earlier ProcessWaitClose return-value mistake was also caught and corrected.
- Title transitions still use conservative fixed waits, and the first-world/stand location are explicit preconditions. A missing world marker stops the macro; it never treats a sent key as proof of visible numbers.

The corrected `--world` cycle ran 20:58:53–21:00:21, PID22756 exited, PID20780 launched, session1 became ready; visual inspection confirmed the stand remained open with saved numeric/X priorities after the helper exited. Final default-path repeat is recorded in the appended results below.

## Native contract2 and September 23 Lua acceptance

Observed on PID20780, Palworld 1.0.5.102999, 1280x720, local authority, two camps/14 Pals:

- Alt+F1 opens the 21-widget Production Limits panel over the stand. State reports native_escape=true.
- Automated mouse clicks reach panel.handle_click but report hovered=nothing, despite the visible targeted Wood limit. Cursor diagnostic reads bShowMouseCursor=false while the panel is open, route GameAndUIEx. A software cursor remains near the screen centre while the injected pointer is elsewhere. **Automated hit-testing fails; physical-input comparison is still needed before attributing all of this to player-facing behavior.** No mouse acceptance claim.
- Opened Wood editor through the existing guarded diagnostic action (not a successful physical-click test). Backspace edits 30000 to 3000 without closing the panel.
- First Escape while the modified editor has focus leaves editing=Wood. Second Escape cancels the editor, retains 30000, and leaves panel and stand open. **One-Escape cancellation fails acceptance.** Likely editable-text handling needs examination; exact cause not proven.
- Next Escape closes only Production Limits and leaves the stand visible. Next closes the stand; next opens vanilla Options. This directly passes the previously failing stand-handoff sequence for panel closure.
- Explicit `open,mode item` produces completed open/screen receipts and the actual picker. Repeated open leaves it open. Search accepts `wood`; Backspace yields `woo` and matching results without closing.
- Repeated `close,close` completes closed state and visibly detaches the panel. Reopening produces a single visible panel. This is a small repetition sample, not a long lifetime or respawn test.
- Priorities, limits and user configuration are byte-for-byte unchanged after these cancellation/input checks (`monitor-settings-before/after-20260923.json`).

The contract2 asset is **not accepted for release**: mouse interaction and one-Escape editing remain open. Controller B, photo mode, populated multiplayer, and gameplay assignment/output gates were not exercised. Scheduler logs still report 14 unverified assignments and three unverified workers above the staffing limit; zero errors does not resolve those limitations.

## Independent frame capture limitation

PresentMon 2.5.1 (verified existing executable hash) ran one 45-second closed-menu recording after a five-second lead, plus a separate 10-second current-format diagnostic, targeting live PID20780. Both printed started/stopped but produced **no CSV and no usable frame samples**. Stderr contains a generic elevated-process-query warning. The current Windows token does include Performance Log Users, so missing group membership is not established as the cause. Do not report frame percentiles, zero hitches or stutter-free behavior from these runs. Their stdout/stderr and first-run metadata are preserved under `test-results/monitor-*20260923.*`.

No input, screenshots, remote requests or unrelated computation occurred during either recording window. No permissions were changed to work around the failed capture. Mod-region timings, if collected below, are explicitly separate from independent frame evidence.

## Final default-macro repeat and timings

Default `--stand` completed 21:09:05–21:10:34 (89 seconds): PID20780 exited normally at 21:09:31; replacement PID27960 reported world/session1 readiness. Visual inspection after the helper exited confirmed the stand remained open, with priorities present. Both corrected starting paths (--world and default open stand) therefore have a completed native cycle. The macro source and desktop copy have matching hashes in `monitor-macro-hashes-20260923.json`; the full attempt history is `monitor-macro-runs-20260923.log`.

Final PID27960 stand-open profile: 21:11:02–21:12:20, 78-second window, seven complete scheduler samples and 75 complete stand refreshes (`monitor-perf-stand-20260923.txt`). All durations are inclusive; nested rows must not be added together.

| Measured region | Samples | Mean | Worst |
|---|---:|---:|---:|
| Complete scheduler | 7 | 20.571 ms | 23 ms |
| Complete stand refresh | 75 | 11.427 ms | 17 ms |
| Roster lookup (inside stand refresh) | 75 | 6.973 ms | 9 ms |
| Complete clock batch | 749 | 1.457 ms | 25 ms |

These are meaningful remaining game-thread costs, **not a frame-time distribution or proof of stutter cause**. The profiler's clock-resolution probe reports unmeasured, so zero-valued authority/component timing samples are not evidence of zero cost. Their route counters remain separately marked unmeasured.

Final status confirms local authority, saved priorities and limits, complete/deduplicated storage with no unknown scope/read failures. Profiling is turned off again. The final installation/process identity is in `monitor-final-fingerprint-20260923.json`. Player settings remain unchanged across the cancellation tests and final restart. Game is left running at the open Monitoring Stand; no recording or AHK restart helper remains active.

Next work: isolate native panel cursor ownership/hit-testing and focused-field Escape handling; fix independent frame collection before accepting performance claims. Keep assignment/output, item-specific producer control, multiplayer, controller and photo-mode gates open.
