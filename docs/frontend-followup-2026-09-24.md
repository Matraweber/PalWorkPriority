# Frontend follow-up — September 23–24, 2026

Unpublished 0.5.0-rc1 candidate. This work does not close the full reliability
release gates or establish stutter-free play.

## Picker capability presentation

The ITEMS tab and Browse items action describe browsing, rather than promising
that every catalogue entry can create a working production limit. Each tile now
shows its capability before selection: an existing legacy group, a supported
item limit, a restorable legacy group, or unavailable support. Rule identity is
work type plus item, so a rule for a different work type cannot authorize this
item's action. Selection checks current support again, rather than trusting a
previous draw. Existing limits keep their amount when opened.

`picker_presentation.lua` contains plain-Lua presentation decisions; no native
producer support was added or implied. Current installed producer adapters remain
empty. Labels are short and storage counts occupy a separate upper line. Full
legacy scope and unavailability explanations appear in the notice area.

Focused regressions cover exact rule identity, unavailable and changed support,
legacy OFF restoration, existing-value preservation, widget reuse, keyboard
browsing, long work names and very large storage counts. The long-label test
failed on the first draft and passed after shortening labels and separating the
storage-count line.

## Native check and additional layout defect

Checked deployment `deploy-20260923-235444-c3132c5a6f2e4f07ae6076b567db2aca`
compiled all 46 modules and matched source hashes. The user's AHK helper ran the
normal save/exit/relaunch path in `--world` mode: PID3400 exited at 23:55:21,
PID28128 started at 23:55:29, session1 was ready at 23:56:12, and the helper
finished reopening the stand at 23:56:28. Runtime/game versions remain the
September23 test environment (UE4SS2281fa31 / game1.0.5.102999).

At 1280x720, the picker labels fit and selecting Red Berries showed its unavailable
reason without creating a rule. Selecting Wood opened the existing Lumbering
legacy rule at 30,000 without a write. Escape closed the panel and left the
stand open. All three settings hashes matched the pre-run receipt.

This exposed a separate layout defect: conditional notices moved the item grid
down about16px when selected, then back up when the notice expired. The Rules
screen also moved its amount/remove controls on notice appearance. This is
unsafe for repeated clicks even if input is correctly ordered. The repair keeps
one notice/help row present on both screens; follow-up native verification is
recorded below when complete.

Two injected Alt+F1 attempts did not open the panel during this run; the diagnostic
open command did. This does not distinguish short injected-key delivery from a
mod input defect, and is not a successful shortcut acceptance result.

## Stand event route: diagnostic evidence only

The new explicit `pwp stand input` command arms a60s class-name census on
`/Script/UMG.UserWidget:OnMouseButtonDown`; `pwp stand events` reports it. The
callback changes no return value, reads no pointer-event parameters, and retains
only bounded class-name counters. Collection expires; the dormant hook remains
installed until process exit. Normal installations never arm it automatically.

`pwp stand` also checks five exact input-function paths on the freshly found
cell/checkbox class, without enumerating parameter memory. All five own-class
paths were absent on both classes in this session. The base-function census
registered successfully but recorded zero events for a click on an incapable
dash and a no-op left click on Grizzbolt's priority1 cell.

**This does not prove those widgets receive no input.** A child/native override
can consume an event, and hooking the base reflected function does not establish
coverage of all generated overrides. Even positive class counts would not identify
the owned Pal/work target or distinguish a bubbling ancestor. The default engine
route in `UserWidget.cpp`1782 and `SObjectWidget.cpp`271 is evidence for a candidate
route only.

The queued stand-click targeting defect remains open. No cached-hover workaround
or unsafe off-thread UObject read was introduced. Its eventual repair needs a
verified event-time owned-cell identity and generation, with scalar-only queued
edits, fresh validation, and no duplicate raw-key edit. See
[the reproduction](restart-input-investigation-2026-09-23.md).

Evidence: `test-results/frontend-lua-20260923.txt`,
`frontend-checker-20260923.txt`, `frontend-settings-before-20260923.json`, and
`frontend-stand-probe-20260923.txt`. Full native input routing, physical controller,
all resolution/layout cases, modded search crashes and frame-time acceptance remain
release gaps.

## Second native run: stable notices; pager ordering reproduced

Deployment `deploy-20260924-000326-caa44bde1c854375b7715d3206844593`
passed 64 regression scripts and the checker before the normal AHK restart.
PID32800 loaded session1 and reopened the stand at 00:04:54. At 1280x720:

- Red Berries refusal replaced the help text without moving its tile (y327).
- Wood opened its existing 30,000 rule. Expiring the notice after eight seconds
  left amount/remove controls at the same y396 position.
- Entering the amount editor, changing only the draft to 3000, and pressing one
  Escape restored 30,000 in place and left the panel open.
- Priorities, caps and configuration still matched their original hashes.

A persistent blank gap appeared between the picker's second and third item rows.
The current native tree, read before reloading any renderer, established the cause:
ItemList had six children for five item rows. Its child at index2 was a visible
34px SizeBox with three inner children; the other five were 40px item hosts.
The 34px host is the pagination row. Partial filling had created it before later
item rows, and ScrollBox uses creation order. Switching Rules→Items retained the
gap. This is independent of the notice-row fix and needs an ordering regression.

The census was added to the explicit stand diagnostic in a module not previously
loaded in this process; checked copying and lazy loading preserved the faulty live
tree for inspection. It reads bounded current native children, not cached Lua
widget references. Evidence is `frontend-picker-native-rows-20260924.txt` and
`frontend-picker-gap-20260924.png` in test-results. The dormant input census was
not armed in this process.

An additional offline regression now distinguishes nil/nonboolean capability
answers from a confirmed unsupported producer: both remain unavailable, but the
former correctly says “Support unknown.” It failed before that correction and
passes after.

## Final installed build and native acceptance

All 66 regression scripts pass, all 46 Lua modules compile, and the structural
checker passes. The new host-order regression failed before the repair: a pager
host preceded later item/rule hosts. The renderer now reserves bounded collapsed
row containers before creating pagination; tile construction remains incremental.

Checked deployment backup:
`deploy-20260924-001847-62397d1964e24a69ba6f2d1a32ed0d3c`.
The normal AHK helper exited PID32800 and started PID33244, reopening the stand
at 00:20:16. Game 1.0.5.102999, UE4SS 2281fa31; the existing contract3 test pak
was retained, not promoted into the release package.

At 1280x720, native testing confirmed:

- Five storage-item rows are contiguous, with no pager gap between rows.
- The current ItemList has ten children in logical order 0 through 9; pagination
  is last. Unused item hosts are collapsed.
- Full catalogue pages, Previous/Next and a final 25-item page render without
  pagination overlap. Returning to 14 storage items preserves the same host
  identities and collapses unused rows.
- Escape closes Production Limits and leaves the Monitoring Stand and numbers
  visible. Profiling was turned off after collection.
- All 46 installed Lua hashes match source. Priorities, caps and configuration
  remain byte-identical to the pre-test receipt.

Catalogue size changed from 195 to 187 while names resolved. This is recorded,
not accepted as stable search/filter behavior; the broader search audit remains
open. Multi-resolution, physical-controller and full Rules pagination acceptance
are also incomplete. The queued stand-click target defect is unchanged.

The 347-second browsing window recorded 1,574 complete panel refreshes:
mean 5.893ms, worst 37ms. Stand refresh mean 11.571ms/worst 18ms; 31 complete
scheduler passes mean 19.452ms/worst 24ms; icon-pump worst 26ms. These are
inclusive runtime-clock callback durations, not frame-time distributions or a
matched before/after comparison. Nested rows must not be summed. Remaining
spikes prevent any stutter-free claim. Both log sinks reported zero failures.

Evidence: `test-results/frontend-lua-20260924.txt`,
`frontend-checker-20260924.txt`, `frontend-host-order-before-20260924.txt`,
`frontend-final-native-rows-20260924.txt`, `frontend-final-readback-20260924.txt`,
and screenshots `frontend-picker-fixed-20260924.png`,
`frontend-picker-full-page-20260924.png`, `frontend-picker-short-page-20260924.png`.
