---
date: 2026-09-24
tags: [stand-ui, input]
status: evidence
---
# Stand rebind and discovery safety — September 24, 2026

Related: [stand-close-events-2026-09-24](stand-close-events-2026-09-24.md) · [stand-pointer-2026-09-24](stand-pointer-2026-09-24.md) · [stand-keyboard-2026-09-24](stand-keyboard-2026-09-24.md)

## Scope and defects

A native row rebind previously invalidated queued input only if its Pal key
changed or the mod had observed the menu closed. Closing/reopening between
polls can reuse both names and keys. The regression reproduced a queued mouse
edit surviving that boundary. Every successful BindFromSlot now invalidates
the input generation; data-only repaints still preserve ordered rapid edits.

Menu discovery previously selected the first visible usable tree. Multiple
visible stands, or a second candidate with unreadable visibility, could leave
that arbitrary choice authorized. Discovery now requires one readable visible
tree. An incomplete/ambiguous query cancels the old generation and refuses
editing. It remains retryable, unlike a proven closed menu, which stands down
until another row bind. This prevents recovery from depending on an unrelated
bind event.

The independent review caught the retry and swallowed-visibility-error cases
after the initial fix. A visible but unavailable tree also causes refusal.
No native asset contract changed; no engine wrapper is retained.

## Offline evidence

- Before: 59 stand checks passed; two new regressions failed (same-Pal rebind
  and first-menu acceptance with two visible stands).
- After: 62 stand integration checks pass, including mouse/number/controller
  cancellation, rearming without duplicate labels, ambiguous-query recovery
  without rebinding, and throwing/nonboolean visibility results.
- Direct typed-query integration covers refusal of a visible missing tree
  and subsequent recovery without a bind.
- All 47 modules compile under Lua 5.4; all 66 regression scripts and the
  structural checker pass.
- Evidence: `test-results/stand-lifecycle-before-20260924.txt`,
  `stand-lifecycle-all-20260924.txt`, `stand-lifecycle-checker-20260924.txt`.

## Native check

The existing desktop restart helper performed normal save/quit/relaunch cycles.
The final source was installed before the second cycle: old PID30788 exited
18:18:46, final PID34100 was launched, and stand opening finished 18:19:49.
The first cycle loaded the intermediate discovery patch and is not counted as
acceptance of the final fixes. Independent final review found no remaining
issue in this bounded patch.

On the final build, numbers returned. Initial Right selected Verdash Handiwork
and the next native Right moved exactly once to Gathering. Grizzbolt Handiwork
changed 3→4 with a right click and returned to3 with direct number input.
Production Limits blocked number input to the covered stand; Escape closed
only Production Limits, and Right reacquired stand navigation afterward.
A clamped click on Grizzbolt Electricity1 cleared the selection without an edit.

Injected Alt+F1 did not open the panel in this run; the developer `open` command
was used. This is not evidence that the shortcut works. No menu was force-closed
and no game process was killed. The game remains open at the stand.

All47 installed Lua files match source. UI SHA256:
`e7d3f2dab582228a83a7433b819edffe7676fe9d9f18562f36512c2c8a97d6cf`.
Unchanged StandInput2/WorkRules3 pak SHA256:
`4eddf38bcf859ec27df2424aa9bda2ea9ded735e56ab7178b5c97d0b10bf4a9d`.
The final dump reports33 receivers,2 mouse events,2 native key events,
2 queued mouse edits,0 rejections and no receiver error. The sampled final
session contains no WARN/ERROR lines in priority.log.

Priorities have their original payload, with generation182→184 from the two
deliberate edits; caps/config remain byte-identical. No old generation was
restored. Receipt, session log and tree are under
`test-results/stand-lifecycle-native-{receipt,log,tree}-20260924.*`.
This test did not capture independent frame times.

## Remaining acceptance limits

These fixes depend on observing a bind or a discovery boundary. They do not
prove that a complete hide/reopen with no bind and no intervening poll is
detected. Native destruction/visibility event coverage remains to establish.
The duplicate-menu cases are simulated; no competing installation was added
to the user's game. Physical controller, populated multiplayer and frame-time
acceptance remain open. This is not a stutter-free or complete lifecycle claim.
