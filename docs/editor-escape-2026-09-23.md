# Focused amount-editor Escape — September 23, 2026

## Change and scope

Contract 2's CommonUI cancellation route closes the panel over the Monitoring Stand, but the focused editable text box consumes the first Escape. The native September 23 test required two presses. Contract 3 keeps CommonUI for ordinary panel cancellation and adds an Escape-only preview for the current focused amount editor. It requests cancellation; Lua cancels the edit after input routing. It does not save the draft or deactivate the panel inside the key handler.

The current editor is an engine-owned Blueprint object property, cleared when editing ends. Lua retains no new collectable widget wrapper across callbacks. Preview handling requires an activated panel and focus on the editor or its descendants. Backspace, Enter and controller B are left to their existing routes. Held repeats do not request another cancellation, and a new non-repeat keydown can recover a missed release.

Independent review found two cleanup failures, now covered by persisted Lua regressions: an editor-reference write failure must not prevent deactivation/detachment; losing the current widget tree while editing must close the abandoned panel and invalidate queued actions.

## Automated evidence

- Lua 5.4 compiles 44 modules; all 59 regression scripts pass. Structural checker passes (panel remains close to Lua's local-variable limit).
- Unreal 5.1 editor module builds. Generated Blueprint compiles without errors or warnings; idempotent regeneration and fresh-process saved-asset readback pass.
- Hidden Slate fixture establishes actual editable-field focus, then invokes the compiled handlers to test cancellation, repeated keys, inactive state, key-up and missed-release recovery. This verifies handler logic, **not Palworld's complete native event routing after hiding the field**.
- Single-package Windows cook passes with no errors. Known kit startup warnings remain.
- Candidate package contains exactly four files; the ModActor pair is unchanged. SHA256: `a385faf11e7d815ac839c6d7f2951d6e235edab938297b1d816ace44bb79c216` (7702 bytes).

Receipts are in `test-results/editor-escape-*-20260923.*`; package manifest is `editor-escape-package-20260923.json`.

## Installation and native acceptance

The game exited through Return to Title and Quit, without a forced termination. Checked Lua deployed at 22:12:31; previous code/configuration remains in `backups/deploy-20260923-221231-b3be00a02c8446c5bb91a59bdd074c1f`. The prior installed contract 2 pak is preserved at `test-results/editor-escape-backup-20260923/installed-contract2.pak`.

Priorities, limits and user configuration matched their pre-test hashes before and after installation. The authorized restart helper was started in `--launch` mode at 22:12:41, avoiding its stand-start path while the separate [queued-target investigation](restart-input-investigation-2026-09-23.md) remains open.

### First native run and follow-up correction

Game 1.0.5.102999, UE4SS 2281fa31, PID27020 (22:12:43). The helper completed at 22:13:42 and priority numbers were visibly present. A real mouse click opened Wood's amount editor; Backspace changed its draft, and one Escape cancelled it, preserving the stored 30000 limit and both panels. However, subsequent Escape presses failed to close Production Limits.

Fresh-root diagnostics established the focus transition: before editing, `focus=true descendants=false editor=false`; during editing, `focus=false descendants=true editor=true`; after cancellation, `focus=false descendants=true editor=false held=false`. The collapsed editable field retained focus. This was not a stuck held flag.

Normal cancellation now clears/verifies the native editor reference and requests focus on the still-open shell only if the previous editor owned direct/descendant focus and the shell is active. Unknown focus/activation does not authorize refocus or prevent reference cleanup. Teardown does not request refocus. The new focus regression failed before this correction and passes afterward; other-menu, inactive, unknown-activation and teardown cases are covered.

With the correction loaded, native selected-text cancellation returned `focus=true descendants=false editor=false held=false` at 22:18:17. The next Escape closed only Production Limits; a further Escape closed the stand normally. Priorities, limits and configuration still matched their pre-test hashes exactly. Mouse Close also worked during the investigation.

The complete 59-script suite and structural checker passed again. Final checked Lua deployed at 22:20:11 (`backups/deploy-20260923-222011-f8a7ee0fb7ed46759098f8f965992867`); the helper started a full `--world` restart at 22:20:12 to verify the final code without hot reload.

Held-key routing after the native field disappears and physical controller B still require acceptance; direct compiled-handler tests alone do not establish them. The baseline release pak and `docs/asset-contract.json` have not been promoted. Photo mode, respawn, multiplayer and the wider gameplay/performance gates remain separate.

### Final full-restart result

The helper exited PID27020 normally at 22:20:37, observed new PID3400 at 22:21:09 and completed stand opening at 22:21:40. Priority numbers were visibly present. The final build passed: Alt+F1 opens the panel; mouse opens Wood's amount field; Backspace edits only its draft; a single Escape cancels it with the original 30000 limit intact; the next Escape closes only Production Limits. Reopening, mouse Cancel and then Escape also worked. The panel briefly showed its backdrop before the next redraw filled its controls; this was not a persistent blank panel.

At 22:23:48 the panel was closed, no editor remained, and profiling was off. All 44 installed Lua files match source; the installed pak matches the candidate hash above. Priorities, caps and configuration match the pre-test hashes **byte for byte**. No WARN/ERROR line appears in the captured test window. This is a narrow native regression result, not a stutter/crash-free or complete gameplay verdict.

Evidence: `test-results/editor-escape-native-20260923.json` (fingerprints/settings/checks) and `.txt` (log excerpt). The game is left running with the Monitoring Stand open. No commit, public reply, publication or baseline package promotion was performed.
