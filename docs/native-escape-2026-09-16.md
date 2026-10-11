# Native Escape ownership â€” September 16

## Purpose and scope

The September 15 native test reproduced Escape cancelling a Production Limits editor while also closing the Monitoring Stand beneath it. The raw UE4SS key observer cannot consume the game's input. This candidate adds a narrowly scoped handler to the panel's own widget, rather than changing global Escape or switching the whole interface to UI-only input.

The first candidate implemented OnPreviewKeyDown with PWP_InputContract=1. Its compiled tests passed but native input isolation failed (see below). The replacement candidate uses the shipped PalUserWidget parent and Palworld consuming RadialMenuCancel binding, registered entirely inside Blueprint, with PWP_InputContract=2. Its engine-bound callback only requests cancellation; Lua handles that request after routing. Physical controller Back/Cancel acceptance remains separate.

The engine's local UE5.1 source documents and routes this preview event through `UUserWidget::NativeOnPreviewKeyDown` and `SObjectWidget::OnPreviewKeyDown` while the widget or a descendant has focus. Native testing is still needed to establish Palworld's behavior, including interaction with its menu input.

## Lua contract

The overlay reads capability and pending state only from the widget resolved in the current callback. No new collectable wrappers are retained. A confirmed capable open panel suppresses the duplicate raw Escape action. Contract 2 additionally requires a completed registration attempt and a verified active widget; the opaque registration handle is not treated as runtime success evidence. Lua activates the current widget on opening and deactivates it before removal. Failed activation refuses opening; failed deactivation prevents another attachment. Older/missing pak installations retain the existing raw fallback, including its known propagation limitation.

The renderer consumes pending input using its existing fresh tree lookup. Cancellation precedes rendering and queued edits. It executes synchronously inside that game-thread callback and invalidates old UI/action queues, so an earlier deferred Confirm cannot save or change the rule underneath the cancelled editor. Acknowledgment failures keep the cancellation pending and block edits until a successful retry; unknown state does not become a successful acknowledgement. Closing/resetting clears the capability claim.

## Automated evidence

`test-results/escape-baseline-20260916.py` ran the new regressions against a temporary copy of the still-installed September 15 code, without replacing source or game files. All three scripts failed on the relevant old behavior. Current tests pass under Lua 5.4.

An independent review found an initial deferred-cancellation race and a failed-acknowledgment gap. `escape-ordering-before-20260916.txt` records the deferred Confirm regression failing before correction. The corrected tests cover Confirm and navigation already queued before refresh, failed acknowledgement/retry, duplicate requests, old/missing contracts, native field errors, closed widgets, raw-binding fallback and normal editing/closing. Full Lua/checker receipts are `escape-lua-20260916.txt` and `escape-checker-20260916.txt`.

## Native acceptance

Contract 1 failed native acceptance. Contract 2 passed build/cook checks and was installed for testing on September 16; live acceptance was not completed. Do not mark this issue resolved or update public packages from automated results alone.

September 23 update: [native monitor retest](monitor-retest-2026-09-23.md) exercised contract2. Closing Production Limits preserved the stand and subsequent vanilla Escape behavior. Focused amount editing required two Escapes; automated mouse hit-testing also failed with cursor=false. Contract2 remains unaccepted for release. The later "testing paused" section below describes the earlier offline continuation, not the latest live status.

## First native candidate: failed acceptance

On Palworld 1.0.5.102999, PID 48532 (September 16, boot 00:39:14, world 00:40:03), the 6307-byte candidate pak `569511c52cad481672ff600cf1849aa57de171290d5500b0cc48e130cf5953e5` loaded all 21 expected widgets and reported native_escape=true. Escape cancelled the Wood amount editor, but also closed the Monitoring Stand underneath it. A later Escape closed the panel and opened Options. The temporary UIOnlyEx diagnostic route also opened Options when closing the panel. Therefore this candidate does not fix input isolation. The next experiment consumes the release event as well, keeping the panel attached until release; key-up routing is a hypothesis, not yet an established cause.

The first modding-kit asset had the obsolete 12-widget shell. It was rejected before installation and rebuilt from the unchanged HEAD 21-widget layout recipe, with exact names/types/order verified. The packaged ModActor files are unchanged from the installed baseline. The AHK restart ran, but the pak remained locked; normal menu exit was used before replacing it and launching the game again. No settings were edited during these tests.

## Action-router replacement

The installed BreedingHelper source documents its consuming Blueprint RadialMenuCancel binding and the race caused by a raw UE4SS observer deactivating a widget before the game router consumes input. Its earlier attempt to pass the action delegate by value from Lua caused a native crash. This candidate never uses that Lua route: the generated graph constructs the delegate in Unreal and owns registration/unregistration. The local Pal kit confirms the declarations but has stub implementations, so editor execution cannot prove Palworld input consumption.

The old release-event hypothesis was not tested or accepted; action routing supersedes that unfinished branch. The new Lua adapter tests verify activation, deactivation-before-detach, unregistered/inactive/unknown states, failed activation, failed cleanup preventing duplicate attachment, reset cleanup and the existing deferred-cancellation/acknowledgment regressions. Receipts: escape-router-lua-20260916.txt and escape-router-checker-20260916.txt.


### Contract 2 pre-install gate (01:05)

- Cooked PalUserWidget route verified: 21 generated object properties, 18 graph connections, three bound-delegate callback cases and six lifecycle cases. Fresh-process readback and idempotent regeneration passed. Native consumption remains unverified.
- Two lifecycle regressions added and reproduced before fixes: delayed class arrival without a viewport could construct a panel; closed overlay could leave panel state and queued Confirm alive. Fixed fresh viewport check, synchronous host-close fallthrough, and immediate local edit/queue invalidation on host closure. Immediate and delayed failed activation tests pass.
- Controller polling defers Cancel only while native contract2 is active. Raw fallback still cancels an edit before closing the panel. Kit RadialMenuCancel maps B, Escape and Backspace; physical controller and editable-text Backspace need native acceptance.
- Lua5.4: 44 modules compile and all58 regression scripts pass; structural checker passes. Reviewer has no outstanding Lua findings. Renderer fixture now restores its final open state for dependent tests and reacquires its amount editor after panel replacement.
- Candidate pak SHA256: `0c2c2941286bd1483068858efd40a9a055678bbacdcf741deca026b5f1a36629` (6484bytes; exactly four files, original ModActor pair preserved).
- Install initially refused because the game had reopened (PID46056,01:01:48). No files changed by that attempt. Exiting normally before replacement.


## September 23 continuation: live testing paused

At the user's request, further work is offline only. The recorded September 16 installation at 01:06 used the 6484-byte contract2 candidate above and 44 hash-verified Lua modules. The game was launched and reached world selection; that establishes neither panel mounting nor cancellation behavior. This is a historical installation record, not a fresh September 23 runtime fingerprint. No game actions, deployment, trigger writes or recording were performed in this continuation.

Required next native checks remain: Escape cancels an amount edit without closing the stand; the next Escape closes only Production Limits; ordinary vanilla Escape still works afterward; Backspace edits amount/search text correctly; reopening does not accumulate consuming bindings. Physical controller B, missing-pak fallback, respawn/photo mode and other release gates remain separate. Do not promote the candidate pak into the release asset contract until acceptance.
