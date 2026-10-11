# Dedicated-server client restart macro

Two separate desktop entry points:

- `Restart and open monitoring stand.ahk`: original singleplayer route, unchanged.
- `Restart server and open monitoring stand.ahk`: RAM server route, matching `tools/restart-server-stand.ahk`.

Start with the stand grid open, already positioned to interact. Default mode closes the stand, returns to title normally, exits normally, launches a new process, opens Join Multiplayer / Recent Servers and selects the calibrated RAM row. It accepts the existing game-saved password; no password is stored in the script. It does not restart GPortal or modify game saves directly.

## Calibration and safeguards

- Current calibration: RAM is the **second Recent Servers row**. Recalibrate if that list changes. Image matching was tried but did not reliably find the label; the final macro does not use it.
- Requires a 16:9 game window, at least 800x450. Coordinates scale from its client area, rather than a monitor origin.
- Requires the local developer remote channel enabled before launch.
- A new process and fresh world-key log entry are required, followed by client authority, complete synchronization and the exact configured guild. Title-screen authority readiness is insufficient. Missing/unavailable guild data waits; a different confirmed guild stops without sending the stand key.
- Bounded waits, graceful exit, Pause / ScrollLock cancellation. No forced termination.
- Post-join pause/open-close restores gameplay interaction before holding V. This is a tested workaround for observed missing interaction prompts, not a proved fix to a mod defect. The cause still needs isolation.
- Keep other input idle. The accepted run took approximately two minutes; slow connections may take longer.
- Modes: --world, --title, --launch, --open-only, --check, --self-test. Open-only just holds V; no connection checks or pause recovery.

## Accepted native run

September25 22:23:06–22:24:59: default stand-open start, graceful exit of PID31740, new PID20332, RAM join, completed synchronization with the expected guild, then stand opened automatically. Native screenshot confirmed all nine Pal rows and priority numbers. No user input was needed during this complete run.

Nine AHK readiness regressions pass: empty/title-only, connecting, unavailable or missing guild, correct guild, wrong guild, prefix collision and missing client role. Repository and desktop copies hash-match. Original singleplayer copies still match and were not edited.

SERVER_READY proves only the connection checks. Sending V does not prove a visible stand, an edit receipt, assignment correctness, or performance acceptance. Visual verification and persistence checks remain separate.

## Follow-up multiplayer test

Native right-click changed Vixy Gathering from1 to2; pending feedback cleared and status reported saved/ready. Direct X input then produced an X row in the server priorities.txt, read through GPortal: Pal key ending 06FAE411445707C90B7777927A549836, work6. Client-restart persistence and restoration follow below after verification.

Second complete default macro run: 22:27:18–22:29:05, PID20332→38564. Stand reopened automatically and Vixy Gathering visibly remained X. Direct1 restored the original setting; GPortal Refresh confirmed generation13 with the same Pal/work row ending |6|1 (generation12 ended |6|X). Client status22:29:53 reported priorities saved and synchronization ready. This covers client process restart/reconnect, not a dedicated-server process restart, second client, other guild, or failed-save recovery.

Remaining observed issue: post-join focus required the pause roundtrip. Do not infer its cause from this workaround; isolate without the mod and inspect input ownership before changing recovery logic. No runtime mod code changed for these macro tests.
