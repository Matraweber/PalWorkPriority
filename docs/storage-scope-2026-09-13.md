# Base storage scope: September 13

Local 0.5.0-rc1 investigation, unpublished. This addresses world loot invalidating base-stock evidence. It does not establish item-specific stopping, shared guild-chest coverage, or a stutter-free release.

**17:20 follow-up:** an aged session exposed zero-ID dropped-item piles absent from the original unknown set. The exact `PalMapObjectDropItemModel` class now uses the same strict authority-only policy; scoped drops remain counted. Two new native projections match complete stock. See [the follow-up and performance comparison](storage-prefetch-2026-09-13.md). The four-class and earlier test-count descriptions below describe the original stage.

## Cause and declared policy

The old reader treated every inventory-bearing map object with an empty base GUID as an unresolved storage owner. A bounded native census in PID 42636 found 776 distinct backing containers, 549 of them unassigned to a base: 254 `BP_MapObjectTreasureBoxModel_C`, 11 `PalMapObjectTreasureBoxModel`, 277 `PalMapObjectPickupItemOnLevelModel`, and 7 `PalMapObjectPalEggModel`. All contained items; none shared backing names with scoped containers. A second census 157 seconds later found the same 549 unknown entries. This is not an empty-container optimization.

The 227 scoped holders included ordinary chests, food boxes, conversion/production stations, dropped items and 78 level pickups. A class-only exclusion would lose legitimate base items.

The new policy excludes only the four exact observed world-loot classes when the current authority reads a valid, all-zero base GUID. Such loot currently has no game-assigned base. Nonzero instances remain counted; each scan rechecks membership. Unknown classes, zero-GUID chests/stations/guild chests, failed or malformed scope, and undecided/client roles remain unavailable. A fractional field cannot be rounded into a zero GUID. The unscoped all-world diagnostic keeps its existing meaning.

This is completeness for **game-assigned base stock**, not every item physically near a base. A newly spawned pickup can be counted only after the game assigns its base ID. Shared guild storage was not present in the census and is not accepted by this test. Exclusions are reported separately from failures.

## Changes and review

- `palapi.lua`: exact no-base loot classification on confirmed authority; strict GUID integers; callback-local class lookup reuse; scalar exclusion counter.
- `main.lua`: separate exclusion status; stock command labels containers and partial results accurately.
- `storage_probe.lua`: manual read-only census, no reflection enumeration or writes, 8,192 model and 32,768 aggregate slot budgets, at most 4,096 slots per target. Fresh local wrappers only; scalar report. One indivisible `FindAllOf` remains.
- Two independent reviews examined the policy and diagnostic. Their constraints—authority-only, exact classes, current-scan membership, conservative unknowns and explicit coverage limits—are implemented.

The new world-loot regression fails before the change and passes afterward. It covers owned/unowned versions of every class, missing/malformed/throwing reads, unknown Blueprint/station/guild classes, zero→nonzero→zero, client/session reset, filter precedence and unscoped totals. Existing deduplication, conflicting ownership and slot-failure tests also pass. All 52 Lua regressions pass, with 41 modules compiled using Lua 5.4.

## Native evidence

Evidence resides under `test-results/storage-*20260913*`.

- Baseline PID 42636: census at 16:05:11 and 16:07:48; no census failures, truncation, shared scoped/unknown targets or conflicting targets.
- Baseline 63-second timing window: six complete scheduler samples, mean 28.333 ms/worst 43 ms; two bucketed-storage samples, mean 20.5 ms/worst 21 ms. Inclusive timings overlap and are not frame times.
- Source/install hash receipts and checked deployment backups recorded separately for census and policy builds.

## Installed retest

Policy build PID **16836**, process start 16:11:20, world key 16:11:44, session-1 authority ready 16:11:49. Status at 16:12:16 and 16:13:40 reports complete/deduplicated base stock, zero unknown scope and failed reads, with **550 world-loot exclusions**. Saved priorities and limits remain available. The census build was PID 42636; the pre-investigation build was PID 42972.

| Window | Complete scheduler samples, mean / worst | Storage samples, mean / worst |
|---|---|---|
| Before, stand open, 63 s | 6, 28.333 / 43 ms | 2, 20.500 / 21 ms |
| After, stand open, 84 s | 8, 31.250 / 46 ms | 3, 21.667 / 23 ms |
| After, stand closed, 102 s | 10, 27.000 / 43 ms | 3, 21.333 / 22 ms |

**No performance improvement established.** The added class reads have a modest observed cost; scenes and activity differ, sample counts are small, and a short local verification ran near the end of the closed-stand window. These inclusive Lua timings are not frame captures or stutter attribution. The recurring storage scan and camp enumeration remain optimization targets.

The first native inventory reports are 171 seconds apart and cross a restart. Several quantities and holder counts changed; rare-item differences remain unexplained at event level. They are not claimed to be identical snapshots. Eleven item quantities in the first base were unchanged.

To check the actual exclusion logic, the manual census now independently projects every positive-base-GUID container, without using the new class exclusion. It compares both directions of every item amount and container count against a fresh production scan in the same synchronous callback. This is **two successive reads, not an atomic snapshot**. Incomplete/malformed production evidence cannot report a match. The second production scan is additional to the bounded census and is not a hot-path feature.

Both native comparisons matched:

- **16:19:49:** 759 distinct holders, 550 unknown-only world-loot targets; scoped containers **60 + 149**. All 17 + 12 item totals agree by stable base GUID, with complete production evidence.
- **16:20:46:** 759 holders, same 550 exclusions; scoped containers **59 + 150**. All quantities again agree despite normal intervening changes. No census failure, truncation or conflicting ownership in either read.

At **16:20:10**, the visible Production Limits panel reported Wood **38,798 = 18,667 + 20,131** and Stone **40,386 = 30,639 + 9,747**, correctly labelled all loaded bases in the guild and legacy group caps. This verifies displayed aggregation for the sampled bases; it does not verify individual output stopping. Later Wood changed and the comparison still matched its new count.

Only the never-before-invoked, lazily required `storage_probe.lua` was updated after the policy restart for this comparison. The hash-delta check confirmed all already-loaded modules unchanged; all 41 installed/source hashes match. The first census invocation in PID 16836 loaded that checked diagnostic. Hot reload was not used. Checked deployment backups and hash receipts are retained.

Final regression receipt: `storage-final-checks-20260913.txt` (52 passing scripts). Final process/log/profiler state: `storage-final-health-20260913.json`. The independent reviewers cleared the narrow implementation and confirmed the reported coverage limits.

## Remaining acceptance

- Controlled native add/remove/consume and zero→nonzero base-assignment transitions; the automated transition regression does not replace these.
- Shared guild chests (none present in the census), two guilds, and appropriate client/server transitions.
- Actual assignment and output evidence: 14 assignments remain unverified; permission fences and cap labels do not prove stopped production.
- Verified per-output adapters; existing rules still affect an entire work type.
- Storage/camp-scan cost reduction and independently correlated frame-time tests.
