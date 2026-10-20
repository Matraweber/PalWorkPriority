---
date: 2026-09-15
tags: [release, reports]
status: current
---
# 0.5.0-rc1 reply drafts — not posted

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [comment-ledger-2026-09-11](comment-ledger-2026-09-11.md)

**Internal evidence note:** The complete Lua/UI and Python isolated suites pass. This candidate is unpublished and has no native acceptance. Use [RELEASE-0.5.0](RELEASE-0.5.0.md) for gate results and the [comment ledger](comment-ledger-2026-09-11.md) for the finding IDs and reporters. These drafts have not been posted; recheck the ledger and obtain separate posting authorization before use.

## Settings and recovery — F01/F02/F03/F12

For Gim1i, spleenszuru, MaD, ThatFawker, valdacil and lainverse:

> I found and corrected a save bug that dropped X values. The old source fails the regression and the candidate passes, with checked writes and recoverable generations added. It is not released yet; actual restart/update testing remains. Numeric resets and fixed-assignment loss need their own checks. Keep pre-update settings backups: already-lost values cannot be reconstructed, and an older mod version needs compatible earlier saves rather than the candidate's new format.

## Panel and input — F04/F05/F06

For Zekrom144, Gim1i, Bernie Laplante, Calas Typhon, Drokz077 and Hall9002:

> The candidate repairs focus handoff, visibility/layout caches, pagination and amount editing while keeping the preferred panel position. Its isolated UI tests pass, but those do not prove that the reported Escape crashes, photo-mode grey box or duplicate panels are fixed in Unreal. Those exact native scenarios remain release gates.

## Scheduling and assignments — F08/F09/F10/F11/F18

For KhanKeal, Samurai9400, GammaEuviex, srvtsonn, Rey, CosmicWarbear, Glave and Ruse Spark:

> The candidate corrects idle permission updates, worker accounting and incomplete demand handling. Tests cover those decisions, but I still need actual work/output evidence for the reported Pals and stations. An enabled permission is not proof that a Pal uses the intended station. Priority 1 remains highest; balanced mode distributes workers before adding more to one type, while strict mode fills higher-priority demand first. Native manual-assignment support is still incomplete.

## Production and storage — F07/F19/F22/F23

For SolidRhoé, BIG DADDY, lainverse and [TLD]Bob77:

> Existing limits control whole work types, which explains why a stone limit can stop ore too. The candidate labels these as legacy group limits and keeps them editable. Clearing an inherited rule now persists an OFF mask for that guild. New item-specific limits are refused until a producer has verified output controls; none is available yet. Limit commands reject fractions and distinguish pending edits, failures and unavailable stock. Guild storage and actual output limits still need native tests.

## Multiplayer and controls — F12/F13/F14/F18

For NoAhQ, Drokz077, giorgn, TheJoe and dedicated-server questions:

> The candidate separates remote snapshots from local saves and strengthens session, snapshot and edit-confirmation handling. Rapid edits build on pending values; direct priority input/navigation paths retain mouse clicks. These paths have isolated coverage, but two-guild servers, unmodded-client edits, reconnects, same-map role changes and actual controller focus still need live acceptance. I cannot yet call every blank-grid or reverting-edit report resolved.

## Performance — F15/F16/F20

For Plz, Ashura, luller, UltraJohn and Siberfox99:

> My earlier “stutter-free” conclusions went beyond the measurements. Some counters printed 0 ms without timing their work, complete pass costs were missing, and steady tick cadence cannot rule out frame hitches. The candidate improves measurement and test tools, but no independent frame captures have established the result yet. The linked mod collection helps define compatibility tests; it does not identify another mod as the cause.

## Installation and command discovery — F17/F20

For Toomy141, coolmunch, Saber57Draxus and decamhian:

> Alt+F1 opens Production Limits; Alt+F2 requests a scheduler pass. Replies go to priority.log in the mod folder, not necessarily game chat. The intended dependency is [Experimental UE4SS for Palworld, item 3625223587](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587), but its current runtime still needs acceptance. Vortex is not certified. Avoid duplicate manual/Workshop copies and back up configuration before updating: an updater that deletes old Scripts before migration can remove the only edited copy.

## Priority order and defaults — F03/F18

For Maritisa, Reudo, Han Byeol, GammaEuviex and srvtsonn:

> I am keeping 1 highest, 5 lowest and X disabled so saved values retain their meaning. A genuinely fresh installation should preserve checked work as 1 and unchecked work as X. Existing mod settings remain the upgrade baseline; I cannot infer your original vanilla choices from flags an older version already changed. The interface explains both the number order and balanced versus strict staffing.

## Logging and diagnostics — F20/F23

For lainverse and command-output questions:

> Command replies are in priority.log. The candidate fixes line framing and reports pending edits, failed clears and unavailable storage explicitly. A sent command is not treated as a confirmed change or completed scheduler pass. Native logging and server behavior still need verification.

## Optional access restriction — F21

For NoNickNeeded:

> The optional high-quality-stand restriction is recorded and deferred until the reliability blockers pass. It is not included in the current candidate.

Before posting, replace candidate wording only with behavior supported by the current ledger. Link a published release only after verifying publication; do not promise dates, native fixes or compatibility that remain untested.
