# Reference UI comparison — 13 September 2026

Read-only source/package inspection; no reference mod was launched or installed. No performance equivalence is claimed.

## PalPriority UI

Inspected the user's downloaded Core/UI archives (3830, July 26 filenames). UI source declares 1.2.0. Inspection copies are in `test-results/reference-mods/`.

The UI polls every 500ms, but gates idle scheduling on its BindFromSlot-driven open flag. It caches menuRef, cellCache and injected TextBlock wrappers across callbacks. menuIsShowing and tickBody reuse those objects until invalidation; ensureTextBlock reuses its stored wrapper. Text/style tokens suppress unchanged SetText calls. Consequently, it avoids the fresh ownership traversal our stand pays each refresh.

This is an architectural explanation, not evidence of measured smoothness. Do not copy its cross-callback wrapper cache: calling IsValid on a stale collectable wrapper has caused native crashes in our runtime. Its source also treats a failed IsVisible call as visible, which conflicts with our unknown-data handling. Our existing value tokens already implement the useful unchanged-write suppression.

## CreativeMenu

Installed metadata declares 1.2.4. It ships cooked Blueprint packages, not Lua scripts. UnrealPak extracted an inspection copy of CreativeMenu_P.pak. Asset name tables show:

- `WBP_ItemSelector`: TileView/ListView, GetItemIDManager, GetStaticItemData, IconTexture, SetBrushFromLazyTexture.
- `PalTileItem`: SetBrushFromLazyTexture and brush/tint setters.
- `WBP_ItemWithCount`: game item-data lookup, IconTexture and SetBrushFromLazyTexture.
- `WBP_ItemIconButton`: LoadAsset and SetBrush; not every asset follows one universal loading path.

Evidence: `test-results/reference-mods/creative-asset-symbols.json` and extracted assets. These are symbol references, not a fully decoded Blueprint graph: they do not prove call order, frequency, cancellation or frame-time benefit. In particular, the old comments in our icons.lua naming LoadIconToImage should not be substituted for these observations.

Our icon path currently queues synchronous LoadAsset operations, with a 4ms soft budget between operations and a twelve-attempt ceiling; a single operation can overrun. Engine brushes retain successfully pinned textures. Unknown names can still cause a throttled global texture discovery. This is materially different from an engine-owned lazy-image/list implementation.

## Recommended next experiment

1. Build a small owned Blueprint item tile accepting an item ID. Resolve game item data and its soft icon reference within Blueprint, with explicit recycled-tile identity and teardown handling. Validate the lazy image contract before wiring it in; do not guess delegate or soft-reference layouts in Lua.
2. Compare a single picker page against the current queue using matched cold/warm captures, including rapid page changes and close/reopen. Keep a safe fallback until correctness and frames are verified.
3. Treat stand traversal separately: the last two measured full refreshes averaged 10.731/10.551ms, of which row ownership totaled 3.493/3.397ms and checkbox contents 2.299/2.346ms. Icon changes cannot remove this number-grid cost. Investigate an engine-owned stand helper/current binding contract rather than retaining Lua wrappers.

Do not promise a speedup before those tests. No production code changed in this comparison.

## Archive-tool incident

The first UnrealPak invocation used an unsupported equals-form extraction argument, and the tool overwrote the Workshop source package with an empty package. Immediately restored it from the untouched installed package. Both now have size 578836 and SHA-256 `b1507a64cd4b1d97730a17c7e61ffc02575239cd46d586e0f322a081eb4b16f9`. Subsequent extraction used a separate inspection copy and the correct two-argument syntax. The installed game package was never targeted.
