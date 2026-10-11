# Monitoring Stand capture — 2026-09-11

**The candidate has a native stand-rendering failure and a recurring long-frame pattern. It is not ready for release.** Three independent 60-second captures succeeded after the user approved Windows elevation. Profiling is off again, all recorder processes exited, and the game remains running.

## Conditions and identity

Palworld PID 26236, started 21:25:15 Europe/Berlin; game 1.0.4.102642, UE4SS 2281fa31, installed 0.5.0-rc1. Installed main SHA-256: `1972d61f5ac7effd611d957328dcca93b93944bc97f23b8d9f961d1ea1515dc8`. The source-only completion-receipt fix was not loaded. Installed ui/ui_tree/ui_render matched source during capture.

1920×1080, i7-13700K, RTX 4090, driver 32.0.16.1664. Saved settings: 240 FPS limit, VSync false, DLSS Quality, frame generation Auto/1; actual generated-frame multiplier unverified. Existing mod installation, with MapCollectablesNative still temporarily disabled for the separately recorded startup-crash isolation.

The stand showed nine rows, vanilla checkboxes and the mod legend. The selected Pal changed from Penking to Mammorest; daylight, animation and base work continued. Foreground focus was not recorded. These are repeated live-scene observations, not a controlled estimate of profiler overhead.

## Frame measurements

Portable PresentMon 2.5.1 SHA-256 `9bec3083069f58f911e6a512f4806db51a27bd096103087bc1d05ef54c80a191`. Each capture targeted only PID 26236, used a separate session, an 8-second delay and automatic exit after 60 seconds, with input tracking disabled. No service/group/driver installation or permanent privilege change was made.

Every CSV contained only the same single DXGI swapchain, Composed Flip. All rows, including dropped presents, were retained. The quantity is **time between application Present calls**, not physical displayed-frame duration. `TimeInSeconds` is the current Present timestamp, and `msBetweenPresents` measures since the previous Present; timestamp differences matched those intervals within 0.01 ms. [Metric definitions](https://github.com/GameTechDev/PresentMon/blob/v1.9.2/README.md#csv-columns)

Full 60-second recordings:

| Profiling | Frames | Mean interval | p99 | Worst | Intervals >33.33 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Off, first | 8,412 | 7.13 ms | 10.62 ms | 98.56 ms | 63 |
| On | 6,977 | 8.60 ms | 12.87 ms | 90.60 ms | 60 |
| Off, repeat | 6,990 | 8.58 ms | 12.66 ms | 55.70 ms | 62 |

A common interior window at recorder seconds 20–65 excludes the first recording's screenshot/status at approximately second 14 and the start/stop edges. The same window was selected for all recordings, without filtering by spike size. Full data remain available.

| Profiling | Interior frames | p50 | p99 | Worst | Intervals >33.33 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Off, first | 6,343 | 6.70 ms | 10.45 ms | 54.44 ms | 46 |
| On | 5,210 | 8.27 ms | 12.73 ms | 90.60 ms | 45 |
| Off, repeat | 5,233 | 8.20 ms | 13.88 ms | 55.70 ms | 47 |

![Repeated long frames in the open stand](../test-results/stand-frame-times-20260911.png)

The recurring pattern persists with profiling disabled. The slower typical intervals in captures two and three cannot be assigned to profiling: they remained after disabling it, and live conditions changed. No mod-absent baseline or precise mapping between capture clocks and individual Lua events exists. A particular frame has not been attributed to a callback.

## Mod timings and native failure

The profiling window, 22:05:50–22:07:26 (96 seconds), surrounded capture two. Timings are inclusive; parent/child rows must not be summed. Observed clock step: 1 ms.

| Region | Timed samples | Mean | Worst |
| --- | ---: | ---: | ---: |
| Complete stand refresh | 88 | 39.318 ms | 54 ms |
| Complete scheduler | 9 | 42.222 ms | 44 ms |
| Storage, inside scheduler | 9 | 22.556 ms | 24 ms |
| Camp scan, inside scheduler | 9 | 10.111 ms | 11 ms |
| Complete pad drive | 4,300 | 0.317 ms | 3 ms |

All 88 stand refreshes reported unavailable cells. Their cost and cadence are a strong candidate explanation for the repeated hitches; correction and recapture are still required. Authority stayed yes, two camps/14 Pals. Assignments/manual states and storage remained unverified, with zero permission requests. These measure a deferral path, not successful scheduling/limits.

The bounded `stand` diagnostic failed at a removed `cells_under` reference after writing a partial tree. The tree includes nine rows and 117 cells under a ScrollBox. A native text leaf such as `BP_PalTextBlock_C` can be rejected by the reader's generic `_C` container requirement, invalidating discovery. Original fixtures gave every widget a child-count method, masking the mismatch. Additional rejected classes or traversal-budget refusal remain possible until a corrected native diagnostic succeeds.

## Evidence and next gate

[Durable capture evidence and artifact hashes](stand-capture-evidence-2026-09-11.json), [full normalized analyses](../test-results/stand-frame-evidence-20260911.json), [code identities](../test-results/stand-code-identities-20260911.json), [mod timings](../test-results/stand-profile-on-result-20260911.txt), [partial tree](../test-results/stand-tree-20260911.txt), [diagnostic failure](../test-results/stand-native-diagnostic-20260911.txt), [final state](../test-results/stand-final-state-20260911.txt). Screenshots00326–00329 are in the game's Saved/Screenshots/Windows directory.

No game code was replaced during capture. Native acceptance requires a checked restart, visible numbers, complete tree diagnostics, repeated close/reopen and another capture. Assignment, storage, producer and multiplayer gates remain open. Source-fix validation is recorded separately when completed.


## Source correction and automated validation

The source-only patch recognizes `BP_PalTextBlock_C` as an evidenced terminal before the generic blueprint-container rule. Existing native leaf traversal, including CheckBox content, is preserved. Unknown classes such as `PalUIActionWidgetBase` still fail conservatively pending native evidence. The reader returns bounded scalar refusal details (first class/name/stage, visit count and budget state); it retains no engine objects between calls. The stand dump uses the current resolver and differentiates complete empty results from refusal; warnings distinguish zero and partial painting.

Coordinator validation: 39 modules compile with Lua 5.4; all 32 Lua scripts pass, including 29 stand integration cases; structural check passes (panel 194 locals); all 102 Python tests pass. Lua source/test hashes were unchanged throughout the full Lua run. The durable evidence records the complete tested source fingerprint and output hashes. **Not deployed or hot-loaded.** A native restart/stand/frame retest is still necessary; further unknown native widget contracts may be exposed by the repaired diagnostic.

Before/after evidence used the verified original installed ui/ui_tree bytes only inside mocked Lua tests: both targeted scripts failed before (four stand integration failures), and both passed after (29 stand cases). [Reproduction details and hashes](../test-results/stand-ui-targeted-evidence-20260911.json). The agent and coordinator exchanged findings; review preserved CheckBox-content traversal rather than broadening the terminal assumption.

## Checked installation — 2026-09-12

After the user confirmed Palworld was closed, processes were checked before backup and again before deployment. The same tested source set was verified, then the compiler-gated deployment installed all 39 matching Lua files and matching Info.json; the existing pak matched source. All 243 backed-up save/mod-state files were unchanged. Previous code/configuration were retained by deployment. The receipt and stand tree fixes are now installed; native retest remains pending. MapCollectablesNative remains disabled for the existing crash isolation. [Installation receipt](../test-results/stand-install-result-20260912.json).

## Persistent frame-capture permission — 2026-09-12

The user explicitly approved adding the current local Windows account to the built-in Performance Log Users group (S-1-5-32-559). An elevated one-purpose helper added that membership and independently readback verified it. The existing session token does not yet contain the group; Windows sign-out/sign-in is required before testing unelevated capture. No administrator membership or UAC setting was changed. [Permission receipt](../test-results/frame-capture-permission-20260912.json).

Subsequent sign-in confirmed the group in the new token, and three unelevated captures succeeded. The native stand retest exposed a further refusal in an unrelated header prompt. [September 12 retest and the next checked source patch](stand-retest-2026-09-12.md) supersede the pending-test state above; native painting is still not accepted.
