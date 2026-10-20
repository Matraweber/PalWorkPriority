---
date: 2026-09-24
tags: [input, stand-ui]
status: evidence
---
# Native stand keyboard input — September 24, 2026

Related: [stand-pointer-2026-09-24](stand-pointer-2026-09-24.md) · [widget-spec](widget-spec.md) · [stand-lifecycle-2026-09-24](stand-lifecycle-2026-09-24.md)

## Change

The previous global 1–5/X observer queued a call that chose hover only when
the queue drained. Moving the pointer could therefore change the target.
Those global number bindings are removed.

StandInput contract 2 handles number keys in its own native OnKeyDown event.
A handled mouse press requests focus on that receiver. Explicit stand
navigation can focus a freshly resolved receiver only while the stand already
owns focus. Painting and hovering never request focus. The first click or
arrow selection is therefore required before using number keys.

Native arrows move selection and focus synchronously; the raw arrow observer
only establishes initial focus and cannot duplicate native navigation afterward.
A failed focus change preserves the old selection. Enter captures its native
source cell. Controller keys owned by the existing Lua handler are consumed
without a second native action. All mutations share the mouse/number FIFO;
controller cycles use the pending value at execution, never an old snapshot.
Mouse and number edits preserve navigation performed after their capture.

The native handler rejects unknown keys and modified chords, and consumes
recognized repeats without another edit. Escape remains unhandled so the
game's parent route can process it. Lua independently checks current receiver
focus, binding token and session/UI generations.

Inside that game-thread callback, Lua resolves the owned roster and captures
the hovered cell, or the event receiver when no cell is hovered. Unknown or
ambiguous hover rejects the edit. Only scalar cell/Pal/work identity, an opaque
token and generations enter the queue. Execution freshly validates the same
cell and binding; it never reacquires hover. Production Limits blocks capture
and execution. No widget, class, function or event wrapper survives a callback.

## Automated evidence and review

All 47 Lua modules compile and all 66 regression scripts pass, including 59
stand integration checks. Synthetic native contexts exercise moved hover/focus,
missing focus, blocked panels, replacement receivers, row/world changes,
ordered 5/X/1, invalid priorities and mixed mouse/keyboard/controller edits.
Main integration asserts the global numeric bindings are absent.

Independent review reproduced and verified corrections for failed focus
transfers, native/raw arrow duplication, late Return targeting, mouse edits
erasing newer selections, and controller edits overtaking queued numbers.

These tests cannot prove native routing or frame times. Number capture and
application intentionally use separate fresh roster resolutions; neither stage
repeats its roster walk. No performance improvement is claimed.

## Native asset checks and installation

The first generator build compiled without errors or warnings, but its fresh
instance check refused the asset before installation. The generator now rebuilds
Blueprint post-construction property initialization after setting CDO defaults;
the untouched fresh receiver inherits focusability correctly. Final generation,
fresh-process reload, idempotent regeneration and cook pass. Compiled handlers
are tested with actual Slate focus in a hidden editor fixture, including keys,
modifiers, repeats, empty targets and focus loss. That is separate from live
game delivery and does not establish physical-controller behavior.

Installed six-file pak: 12,040 bytes; SHA-256
`4eddf38bcf859ec27df2424aa9bda2ea9ded735e56ab7178b5c97d0b10bf4a9d`.
All 47 installed Lua files match source. Settings were unchanged before launch.
The baseline release asset remains older; clean release packaging is blocked.

## First live session (PID 11988)

AHK `--launch` completed at 18:00:24 on game 1.0.5.102999 and UE4SS 2281fa31.
Thirty-three receivers were created. Generating Electricity changed 1→5→X→1
without brackets. Right selected adjacent Handiwork once; Enter changed its
3→2 despite the pointer being elsewhere. One right-click restored it to 3.
Ctrl+1, a number with Production Limits open, and a number with the stand closed
made no priority changes. Escape returned from Production Limits and closed a
stand whose receiver held native focus.

Counters: three mouse dispatches, five keyboard dispatches, zero rejected mouse
intents, no receiver error and no WARN/ERROR in the session. All priority payload
bytes were restored (generation 177→182, checksum 737a8e16). Ceilings and
configuration remained byte-identical. Receipts/logs:

- `test-results/stand-keyboard-native-receipt-20260924.json`
- `test-results/stand-keyboard-native-session1-20260924.txt`
- `test-results/stand-keyboard-first-session-tree-20260924.txt`
- `test-results/stand-keyboard-package-20260924.json`
- `test-results/stand-keyboard-*-20260924.log`

A short injected V tap did not reopen the stand; the existing helper holds V.
A normal AHK save/restart is used for the next loaded-settings acceptance.
This is not same-process rapid-reopen evidence. Physical key repeat/controllers,
multiplayer chat, rapid native interleavings, recycling stress and independent
frame times remain unaccepted.

## Normal save/restart acceptance (PID 32968)

AHK `--world` exited PID11988 normally at 18:04:08, launched PID32968 and
opened the stand at 18:05:11. Original numbers returned. Before any mouse
click, Right established selection on Verdash Handiwork; the next Right moved
exactly once to Gathering. A clamped click on Generating Electricity cleared
the navigation marker without changing priorities. Second-session counters:
33 receivers, one mouse dispatch, one native keyboard dispatch, no rejects or
receiver error. The first arrow correctly used only the initial-focus route.

Final priority payload is identical to the pretest copy; generation remains182.
Ceilings/configuration are byte-identical. All47 installed Lua files still match
source. Neither test session logged WARN/ERROR. Game remains open at the stand;
profiling was not enabled. This was an input/loaded-settings acceptance run,
not a frame-time or overall scheduling correctness test.
