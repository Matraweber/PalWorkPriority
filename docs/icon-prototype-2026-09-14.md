# Blueprint lazy-icon experiment — 2026-09-14

## Decision

The opt-in prototype renders correctly, but four warm-picker recordings do **not** establish a performance improvement. Keep the existing loader as default. Cold loading needs a separate fresh-process comparison. This experiment does not address Monitoring Stand number-grid scans or close the reliability release gates.

## Implementation and identity

`BuildIconPrototypeCommandlet` generates `/Game/Mods/PalWorkPriorityPrototype/WBP_LazyItemIcon`, a UserWidget containing CommonLazyImage. Its SetItem event clears the previous brush, obtains the item manager/static data with validity guards, and supplies IconTexture to SetBrushFromLazyTexture. Only existing native runtime classes are required; the editor commandlet is not shipped.

`Scripts/icon_prototype.lua` resolves widgets through the current panel snapshot, keeps name/token state instead of collectable wrappers between callbacks, cancels unused tile requests, and falls back to the existing loader on failure. `pwp panel lazyicons on|off` is an explicit diagnostic switch, default off after restart. A failed draw disables the experiment to avoid a retry storm. Panel position is unchanged.

The initial LoadAsset class lookup failed. The working build uses the asset-registry route already used by the overlay. The first compiler selection also failed in engine headers; explicitly selecting installed compiler family 14.38.33130 fixed the editor build. Quote that argument in PowerShell.

Build/generate/cook succeeded; generation reported 0 errors/49 warnings and cook 0 errors/63 warnings. The kit warnings remain in the logs. Lua validation: 44 modules compiled with Lua 5.4, structural checker passed, 57 regression scripts passed. Tests cover default-off, token reuse, changed items, cancellation, replaced widgets and missing assets; these are not substitutes for native lifetime testing.

Experimental pak: 2 files, 2,485 bytes, SHA256 `DDC8202FE7E8E7EC106259DA29B6D48470CE93ED3F282794856C8007939EB6BD`. Installed separately as `Pal/Content/Paks/PalWorkPriorityPrototype_P.pak`. Production shell pak was not replaced. All 44 installed Lua source hashes matched the deployment manifest.

Runtime: Palworld 1.0.4.102642, UE4SS 2281fa31, unpublished mod 0.5.0-rc1. Valid comparison process: PID 30848, started 17:18:00 +02:00. Source is a dirty reliability worktree: use the per-file deployment hashes, not HEAD alone, to identify the candidate.

## Warm-page comparison

Four sequential 30-second PresentMon 2.5.1 captures, same process, stand closed, profiler off, warm full-picker pages 1 and 2, order old/new/new/old. Each sample has an eight-second warmup and three page changes during recording. Commands were checked against the capture's QPC-to-UTC interval. No screenshots or analysis ran during capture.

| Sample | Frame intervals | Mean ms | p99 ms | Worst ms | >16.67 ms | >33.33 ms |
|---|---:|---:|---:|---:|---:|---:|
| old-c1 | 5646 | 5.311 | 10.365 | 38.295 | 5 | 1 |
| lazy-c2 | 5660 | 5.295 | 10.346 | 25.147 | 5 | 0 |
| lazy-c3 | 5621 | 5.332 | 10.194 | 35.152 | 5 | 1 |
| old-c4 | 5292 | 5.665 | 10.831 | 37.955 | 6 | 1 |

The first interval is excluded. p99 uses nearest rank. Raw results also retain worst frames in two-second windows after page-command log timestamps. Those timestamps have only one-second precision; the windows include other game/mod work and cannot establish that an icon change caused a spike. Dynamic world/time-of-day changes and two samples per route limit small-difference conclusions. Both routes still have occasional spikes.

Earlier `icon-old-a1` and `icon-lazy-b1` recordings are **excluded**: their page commands ran after capture, and the orchestration briefly overlapped runners. PowerShell 5.1 also mishandled the manifest array in an earlier failed launch. The corrected runner uses pwsh, launches asynchronously, validates metadata availability, sends changes while recording, and waits for complete exit before the next sample.

## Native lifecycle observations

- Correct icons on full pages 1 and 2 and the six-item page 8; no leftover icons below the short page.
- At approximately 17:29, Escape removed the panel and icons but also opened vanilla Options. This is an input-behavior observation, not proof of a clean Escape contract. A second Escape returned to play.
- Reopening and switching to the item screen returned all 14 storage-item icons. Opening resets the picker filter, so a queued page-8 command was refused before that screen transition completed; this is not a successful page-8 reopen test.
- At 17:30:13 the prototype was explicitly disabled and profiling turned off. The separate pak remains installed but the normal loader is active.
- Native invalid-item handling, missing pak, mid-load rapid reassignment, respawn, multiplayer and long-session collection remain unverified.

## Evidence and repeat procedure

Artifacts under `test-results/`:

- `icon-prototype-generate-20260914.log`, `icon-prototype-cook-20260914.log`
- `icon-prototype-lua-20260914.txt`, `icon-prototype-hashes-20260914.json`, `icon-prototype-deploy3-20260914.txt`
- `icon-prototype-response.txt`, `PalWorkPriorityPrototype.pak`
- `capture-icon-prototype-20260914.ps1`, `run-icon-comparison-20260914.py`
- `correlation-icon-{old-c1,lazy-c2,lazy-c3,old-c4}-20260914.csv` and corresponding JSON/recorder outputs
- `icon-{old-c1,lazy-c2,lazy-c3,old-c4}-commands-20260914.txt`
- `icon-comparison-results-20260914.json`

Next experiment: alternate fresh processes using the checked AHK restart workflow, verify new PID and loaded fingerprints, then capture the first full-picker opening and first unseen page in each route. Keep scene/profiling settings matched and include time until icons appear, incomplete/missing icons, frame distributions and worst events. A fresh process resets game caches, not necessarily the OS disk cache; report that distinction. Never count a restart request or a sent command as completed work. Do not promote the prototype without a measured benefit and lifecycle acceptance.
