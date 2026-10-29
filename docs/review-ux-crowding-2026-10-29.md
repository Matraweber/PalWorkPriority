---
date: 2026-10-29
tags: [release, ui, records]
status: current
---
# UI crowding and clarity review (2026-10-29)

Related: [review-round3-2026-10-29](review-round3-2026-10-29.md) · [retest-r3-2026-10-29](retest-r3-2026-10-29.md) · [DECISIONS](DECISIONS.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md)

The user asked whether the UI is overcrowded and easy to understand. The newcomer UX
reviewer judged build da6db81 from the retest screenshots (`ScreenShot00389` to
`00408`) and the code. **Rating 6/10, no P1.** The user picked every item below for
fixing (branch `fix/r3-ux`).

## Answer in short

The number of elements is fine everywhere. The problem is repeated text: the Limits
list explains each control two or three times, the empty list never says what a limit
is, and three lines say something false at that moment.

| Screen | Instruction lines at once | Clarity (1-5) |
| --- | --- | --- |
| Stand + legend | 1 | 3 |
| Limits list with rows | 3, two repeat | 4 |
| Empty list | 3, no definition | 3 |
| Item picker | 2, plus a caption per tile | 3 |
| Client view | panel footer and stand legend | 3 |
| Notices | stay 60 s | 3 |

## P2

1. The stand legend never says 1 is first and X is never; Palworld's own work levels
   run the other way.
2. A notice from before "change base" contradicts the rows.
3. After adding a limit, "Left/Right now step it" while the selection is still on "Add
   a limit"; Right reopens the picker.
4. Help row and footer repeat each other; Alt+F2 is named twice.
5. The empty list never defines a limit, and its footer talks about rows that do not
   exist.
6. "Add a limit" is the dimmest bar on the empty screen when selected.
7. The selected picker tile looks like a tile that already has a limit.

## P3

Permanent "Limits saved"; a repeated picker caption; "group limit" against "whole
job"; the legend over the game's "unused Stat Points" bar; the panel's top edge jumps;
search matches internal ids ("ore" lists Lily Hat); "No Pals are assigned" reads like
Pals stop working; "All start at 1" may be false for jobs unticked before install.

The full report with exact texts is kept with the fix branch's brief.
