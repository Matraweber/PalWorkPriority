---
date: 2026-10-21
tags: [input, stand-ui, testing]
status: evidence
---
# Controller input on game 1.0.5, 2026-10-21: the mod reads no pad button

Related: [ux-review-2026-10-21](ux-review-2026-10-21.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md) · [comment-ledger-2026-09-11](comment-ledger-2026-09-11.md) · [testing](testing.md)

Asked: check 1-5-X cycling with mouse, keyboard and gamepad mixed (Material
Defender's wraparound request, marked done in rc1 without pad acceptance).

## Rig

- Virtual Xbox 360 pad from `vgamepad` 0.1.0 (pip, in a scratchpad venv) on the
  existing ViGEmBus 1.22.0 driver, driven by a queue-file script
  (`pad_server.py`, scratchpad). Its pip install tried to install the bundled
  older bus driver 1.17 twice (MSI 1603, refused: newer present) and left two
  broken `ROOT\SYSTEM\0003/0004` device nodes; the user removed them with
  `pnputil /remove-device` (admin) at 15:18.
- First run: a leftover Sunshine pad (created 14:37:33 for a Moonlight session
  that ended 14:37:49) held XInput slot 0, so the test pad was slot 1. The game
  gives only the first pad to the player. The user restarted SunshineService
  (admin); then the test pad was slot 0, and the game was restarted with it
  plugged in (world ready 15:23:33).
- Mod side: `pwp panel pad watch` (polls `PlayerController:IsInputKeyDown` for
  16 pad and 16 keyboard keys every 100 ms, logs each new press) and
  `pwp panel pad probe` (one read while a button is held).

## Results

| Check | Game reacts | Mod reads |
|---|---|---|
| Keyboard W held 4 s (world) | walks | probe: `down right now: W` |
| Keyboard Up in the panel | selection moves | watch: nothing (panel keys come through the widget's key dispatch, not this poll) |
| Pad slot 0, D-pad down (stand) | stand focus moves, pad prompts shown | watch: nothing |
| Pad slot 0, LB held 2-4 s | (none expected) | probe and watch: nothing |
| Pad D-pad up in the panel | nothing | nothing |
| User's DualSense, D-pad and L1 | nothing (keyboard prompts stay) | nothing |

The DualSense is not XInput and the game was started by the restart macro, not
through Steam, so Steam Input was not involved: that row says nothing about the
mod. On 2026-08-25 (game 1.0.4) the same watch logged `pad: Gamepad_DPad_Down
down`, so the read worked then.

## Verdict

**Open, not a pass.** On game 1.0.5 the mod's controller path (pad.lua, stand
raise/lower on LB/RB/A/X, panel navigation) saw no Gamepad_* key while the game
itself responded to the same pad. Keyboard reads through the same call work.
Not yet separated: a game-side change in 1.0.5 versus only ViGEm virtual pads
being invisible to the player's key state. Next step: a real pad through
Steam (launch via Steam with Steam Input on) and, if that also fails, read
`Gamepad_*` through `GetInputAnalogKeyState`/Enhanced Input instead.

Controller support was already on the deferred list (Steam Deck and controller,
TheJoe, Erbse, tigerpow100); the changelog must not claim it works in 0.5.0.

## Mouse 1-X wrap

Not completed live: the game repeatedly lost focus to the desktop while the
user was using the PC, and clicks did not reach the stand (priorities.txt
unchanged, cmp equal to the backup taken 15:07). The wrap is covered by
`store.cycle` regression tests; live check stays open.
