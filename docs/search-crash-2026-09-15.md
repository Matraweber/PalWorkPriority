---
date: 2026-09-15
tags: [crash, reports, panel]
status: evidence
---
# Search-crash sidecar — September 15, 2026

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [comment-ledger-2026-09-11](comment-ledger-2026-09-11.md) · [icon-prototype-2026-09-14](icon-prototype-2026-09-14.md)

Nexus bug **1133489 remains un-attributed and unreproduced**. The local evidence supports the already-deployed exclusion-before-localization change, but supplies no additional proven crash fix. Cosmetic Outfits (5049) is the reporter's suspected interaction, not an established cause.

## Scope and identity

Read-only investigation of repository sources, archived local crash XMLs, downloaded file/archive names, and existing test artifacts. Only this report was written. No third-party code was installed or executed; no game commands, process attachment, save changes, deployment, browser access, network posts, or scheduler investigation occurred.

- Public comparison: local Git `v0.4.1`, commit `aa66480ffa1ba0bda97ce41d348d02785d993210`. This identifies the compared source, not the reporter's installed files.
- Candidate receipt: [picker-filter-hashes-20260915.json](../test-results/picker-filter-hashes-20260915.json). All 44 entries record equal source/installed hashes. This sidecar independently rehashed the current repository copies of items.lua, panel.lua, icons.lua and icon_prototype.lua; all four match that receipt. It did not re-read the installed payload or loaded process memory.
- At investigation start, process **PID 4756** was supplied by the coordinating agent from its process check; this sidecar performed no process verification. The older PID 47304 acceptance in [performance-2026-09-15.md](g5-performance-2026-10-19.md) belongs to a prior restart and is not silently relabeled as current evidence. The subsequent panel-storage retest uses PID 44368 and changes panel.lua independently; the hash comparison above describes this sidecar's earlier inspection time.

## Available evidence and gaps

The [local comment ledger](comment-ledger-2026-09-11.md) records DarkWyrmReaper's September 14 report: Add item/search all items aborts to desktop after recently adding Cosmetic Outfits. It does not contain a reporter crash attachment, exact exception text/stack, affected item ID, query, package version/hash, or installed runtime identity. Whether “search all” means selecting the show-all toggle or typing remains unresolved.

Inspected all **29** `CrashContext.runtime-xml` files under `C:/Users/matra/AppData/Local/Pal/Saved/Crashes`. Their filesystem modification timestamps span August 21, 20:11:57 through September 11, 21:24:10, 2026; these are file timestamps, not independently validated event times. Every ErrorMessage reports `EXCEPTION_ACCESS_VIOLATION`. None of the XML text contains `abort`, `GetItemName`, `GetDataTableRowNames`, `LoadAsset`, `Cosmetic`, or `1133489`. These records belong to this local installation and cannot be substituted for the reporter's crash. The associated minidumps were located but not symbolized. Unsymbolized UE4SS/module offsets do not identify an item lookup or establish a shared cause. Historical narratives in the older crash documents include revised hypotheses and are not new proof for this report.

Searched repository and Downloads filenames, including ignored files, for Cosmetic/Outfit/5049/1133489. Also inspected the central directories of **46 top-level Downloads ZIPs**, without extraction or execution, and checked the upload directory. No identifiable Cosmetic Outfits package or associated item-data export was found. Unrelated filename matches were discarded. Five non-ZIP archives were not opened; nested archive contents and other disk locations were not exhaustively searched. Therefore no assertion is made that the mod is absent from the machine. Existing extracted reference-mod assets are not evidence about 5049's contents.

## Exact reachable boundaries

Line numbers below refer to the checked current sources; public line numbers refer to the tag above. Reachability is established by code, not by a crash stack.

| Stage | Current boundary | Public v0.4.1 / implication |
|---|---|---|
| Catalogue capture | [items.lua:52](../Scripts/items.lua#L52): `GetDataTableRowNames(tbl, raw)`; lines 61–62: RemoteUnrealParam `get()` and FName `ToString()` | Same capture at line 54. Needed for both full-catalogue paths, even when later IDs are excluded. Raw wrappers become strings in the same call. |
| Item localization | [items.lua:302](../Scripts/items.lua#L302): `GetItemName(pc, FName(id), box)`; line 310: returned FText `ToString()` | Lines 199/207. Both versions already pass FName, so the documented bare-string marshaling hazard is not present at this call site. Eligible items still enter these native calls. |
| Actual typed text | [panel.lua:2204](../Scripts/panel.lua#L2204): search widget `GetText()` and line 2205 FText conversion | Also present publicly. A command-injected query need not exercise the same physical text-input route. No evidence presently singles it out. |
| Icon acquisition | [icons.lua:295](../Scripts/icons.lua#L295): `LoadAsset`; line 296 checks the fresh result through `IsValid`; lines 414/416 enumerate Texture2D objects and read their FNames | Public loads at line 316, normal frame sweep at 476/503, further discovery at 636/653. Current loading is budgeted and hands fresh results directly to the panel. Rare discovery remains indivisible. |
| Icon application | [panel.lua:1690](../Scripts/panel.lua#L1690): brush ResourceObject read, then validity; lines 1481/1530: `SetBrushFromTexture` for visible image/pin | Native brush writes also exist publicly at 1527/1576. Current pin widgets are resolved through panel_runtime's current snapshot. This addresses retained-wrapper exposure, not arbitrary asset corruption. |

The native widget construction and layout calls surrounding these operations are also outside Lua error containment. `pcall` catches Lua/binding errors; it does not demonstrate containment of a native access violation or process abort. “Abort signal” alone cannot distinguish these boundaries.

The separate [icon prototype](../Scripts/icon_prototype.lua) defaults off at line 5. Its native asset-registry/widget/`SetItem(FName(item))` route is not an active compatibility fix and does not replace item-name indexing.

## Safe offline reproduction performed

Executed the actual public/current item module and extracted actual picker selection functions in independent Lua 5.4 runtimes. Used the repository's scalar workdefs and a two-row synthetic catalogue: `NPC_CrashSentinel`, `Wood`. Native functions were replaced with in-memory stubs; the GetItemName stub records the requested ID **before** throwing a Lua error for the selected sentinel. Typed query was `wood`, so the excluded NPC row was not even a textual match. No fixture files were written.

| Source/path | Sentinel | Resolver calls |
|---|---|---:|
| v0.4.1 typed search | NPC_CrashSentinel | 1 |
| v0.4.1 show-all | NPC_CrashSentinel | 1 |
| Current typed picker | NPC_CrashSentinel | 0 |
| Current show-all | NPC_CrashSentinel | 0 |
| Current generic items.search | NPC_CrashSentinel | 1 |
| Current typed picker, eligible item | Wood | 1 |

This proves unnecessary pre-filter localization in the public source and the current mitigation's boundary. It **does not reproduce a native crash**, identify a Cosmetic Outfits row, or demonstrate how that mod changes item data. The stub error is deliberately catchable; its call counter prevents pcall from hiding whether the resolver was reached.

Reran four existing focused scripts: `test_picker_search.lua`, `test_items_catalogue.lua`, `test_picker_catalogue.lua`, `test_icons_demand.lua`. All passed; the runner also compiled all 44 Lua modules successfully. The maintained [picker fixture](../tests/test_picker_search.lua) covers excluded sentinels, generic independence, ranking/cap boundaries, budgets, resets, unavailable states and wrapper lifetimes. A safe native reproduction from the currently available data is not possible without inventing the missing failure conditions.

## Disposition and bounded next evidence

Retain the implemented filtered picker index. Public panel lines 3422/3426 call generic search/load before filtering; the current [panel.lua:3153](../Scripts/panel.lua#L3153) supplies the scalar predicate before localization, and [line 3088](../Scripts/panel.lua#L3088) caps results after eligibility. No additional code change or ID blacklist is justified by this sidecar.

The 128 **examined-ID** cap still counts rejected IDs ([items.lua:189](../Scripts/items.lua#L189)). CPU savings do not automatically reduce slice count or input-to-results latency; capture/sort and individual native calls can overrun their soft budget. Existing native search acceptance is useful local smoke evidence, not compatibility proof or a matched historical speedup measurement.

The next useful inputs are the reporter's existing crash context/minidump and adjacent log tail, exact game/UE4SS/mod versions and archive hashes, and whether failure occurs on the toggle, first keystroke, or a specific result page. If the actual 5049 archive or row export becomes available, inspect it as data without installation; map its real IDs through the existing scalar predicate in a Lua-only fixture. That can establish which IDs remain exposed and which phase a stack could implicate. It cannot establish a native fault by itself. Stop before a new runtime probe unless those inputs narrow a concrete boundary; do not attribute the report to scheduler work, icon loading, or the cosmetic mod merely from timing or co-installation.
