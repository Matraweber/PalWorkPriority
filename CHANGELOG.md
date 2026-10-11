# Changelog

## 0.5.0-rc1 — reliability candidate, unreleased

Protects saved choices, reports incomplete edits and unavailable data accurately, and repairs permission, panel and session handling. **Not published; native acceptance remains open.**

- Refuse stale amount drafts when the current rule changed or was removed, preserving the newer value instead of overwriting or recreating it.
- Ignore foreign or unidentified respawn callbacks when a local controller is available, so they cannot cancel local edits or reset local writer roles.
- Reject incomplete panel trees when an advertised child or its name cannot be read, cancelling affected amount drafts instead of recreating controls from a partial view.
- Selecting an item with an existing limit now opens its actual Rules page and selects its amount control; later navigation or a guild change cancels a pending jump.
- Cancel amount drafts when their rule disappears, leaves the visible page, or changes guild; preserve drafts when the same rule moves within the page.
- Bind removal confirmation to the current rule value and guild; closing or navigating away cancels it, and stale queued removals are refused.

### Bundled performance work — September 13

- Separate periodic scheduling, stand maintenance and edit reconciliation across heartbeats; preserve prompt input and bounded background progress.
- Keep rapid edits ordered while yielding between expensive actions. Reconcile the completed burst once.
- Reduce current-tree accessor work and use verified scalar paths for injected labels, retaining fresh widget resolution and safe fallback.
- Reuse local-controller evidence only within a callback; avoid unnecessary storage class reads without turning unknown scope into known data.
- Budget icon loads between attempts, space picker-fill continuations and release temporary texture references after failed refreshes.
- Remove automatic startup icon diagnostics. Native restart/frame-time acceptance remains required; menu/camp sweeps and individual native-call spikes remain.

See the [performance inventory, regression evidence and remaining limits](docs/performance-bundle-2026-09-13.md).

### October 9 follow-through

- Add bounded, session/guild-bound storage snapshots for clients, with selected-base scope, complete-map validation and source-data expiry. Initial local server counts match; remaining lifecycle and multi-guild acceptance is tracked in the release ledger.
- Share one fresh transmitter census across a bounded packet batch. Live testing reduced five-packet replies from five censuses to two; this is not a frame-time or stutter-free claim.
- Cycle priorities through 1–5/X in both directions, including wraparound.
- Resolve Steam library installations instead of assuming the game is on C:. Preserve Unicode paths and reject ambiguous discovery.
- Label diagnostic configuration as local; clients do not present local staffing settings as confirmed server policy.
- Correct the empty-instance assignment diagnostic without treating unavailable Pal actors as idle or automatically assigned.

### Settings

- Preserve X through saving and unrelated edits. Validate durable Pal identities instead of saving temporary roster positions.
- Check file operations and retain validated live/.tmp/.pending/.bak generations, including a recovered temporary save during another write attempt.
- Migrate editable configuration to root `config.lua` with `config.migration.bak`. Reject malformed/nonfinite configuration as a whole before migration/reload/overrides, retaining prior accepted settings.
- Package the default template as `Scripts/default_config.lua` so manual extraction does not overwrite legacy editable configuration before migration.
- Keep 1 highest, 5 lowest and X disabled. Fresh defaults preserve checked→1/unchecked→X only when an unmanaged baseline can be established; upgrades do not reconstruct unknown original choices.
- Keep server snapshots separate from durable local settings.

Keep pre-update backups. A Workshop updater may delete old Scripts before first migration; the new defaults cannot recover that edited file. The candidate save schema is forward-migrated; downgrading requires compatible earlier backups. Already-lost X values require a surviving copy.

### Limits and command feedback

- Preserve existing suitability-wide rules as labeled **legacy group limits**, with editing/removal retained.
- Persist guild-local OFF masks when clearing inherited shared/configuration limits, without changing other guilds' rules.
- Reject fractional limits instead of rounding them; report queued client edits as pending and failed clears as failures.
- Show unavailable/unscoped stock as unavailable, not zero. Limit listings use verified current guild/base evidence and explain legacy semantics without blind rescans.
- Refuse new item-specific limits when no verified output-control adapter supports the producer.

**No native item-specific adapter is available.** Stone-only control while ore continues, synthesizers and measured in-flight overshoot remain undelivered native requirements.

### Panel, stand and synchronization

- Cancel edits before closing, preserve vanilla focus handoff and invalidate stale queued actions.
- Bind stand mouse edits to the cell receiving the native press, then revalidate that target before applying. Remove the delayed-hover raw mouse fallback; matching StandInput asset is required.
- Cancel queued stand edits when a row rebinds, including the same Pal and reused names. Refuse ambiguous or unreadable visible stand trees and retry discovery without requiring another bind. See [lifecycle evidence](docs/stand-lifecycle-2026-09-24.md).
- Invalidate stand-only input tokens at the native stand reconstruction event, preserving unrelated UI actions. Delayed destruction does not cancel new edits. Two same-process Escape/V reopen cycles confirmed native events and restored priorities; other lifecycle routes remain unverified. See [event evidence](docs/stand-close-events-2026-09-24.md).
- Route 1-5/X and Enter through the focused stand widget, capture their targets at the native event and validate them before applying. A click or arrow selection establishes focus; hovering alone never steals it. Remove global number-key observers, prevent duplicate native/raw arrow movement, and order controller mutations with mouse/number edits. Initial native input and normal-restart checks pass; physical controller, rapid-reopen and multiplayer acceptance remain open. See [keyboard evidence](docs/stand-keyboard-2026-09-24.md).
- Repair visibility/parent/cache behavior, page controls and amount-editor placement within the preferred panel position.
- Show item-limit availability before selection, distinguish existing legacy groups, and preserve their amounts when opening them. Browse labels no longer promise unsupported creation.
- Keep a fixed help/notice row on both Rules and Items so notices, errors and editing instructions do not move the controls under the pointer.
- Reserve ordered row containers before pagination so incremental filling and list growth cannot insert page controls between item or rule rows.
- Validate whole-number input; Escape cancels an unfinished edit.
- Distinguish rendered/skipped/failed cells, including explicit failed writes, and separate pending edits from confirmed values.
- Add direct stand priority input/navigation paths while retaining left/right clicks; native controller/focus acceptance remains required.
- Strengthen session/schema/snapshot/edit handling and preserve sender/guild authorization.

Escape crashes, photo-mode backdrops, duplicate panels, all required layouts and live multiplayer still require native verification.

### Scheduling and data availability

- Reconcile X choices and stale restrictions even with no demand.
- Repair incomplete demand identity and quarantine unknown camp scope.
- Account for held/fallback workers and stable candidate ordering; explain balanced versus strict mode without reversing saved priorities.
- Distinguish empty rosters from unavailable reads; partial off-lists and nil item IDs remain unknown.
- Prefer current client Role 2 over stale GameMode evidence.
- Confirm restoration by readback and preserve pending permission writes across policy edits.
- Preserve saved numeric/X priorities when native checkbox bits change without an authenticated priority edit. Observed permission changes are no longer automatically saved as X or 1; a verified adapter for deliberate unmodded-client checkbox edits remains unavailable.

Complete native assignment acceptance remains open, including missing Pal actors on an empty dedicated server. Actual fixed/manual assignments, occupied jobs, research, cooling, generation and production output are not established by permission models alone.

### Diagnostics and packaging

- Restrict stand-cell discovery to each verified row's priority controls, with complete-layout fallback and shared traversal budgets. Add inclusive subregion timings for label lookup, painting and the legend; native speedup awaits the next restart test.
- Skip storage work for camps without applicable limits unless the panel requests totals. Back off repeated incomplete reads up to 30 seconds while retaining unknown status; explicit resets and shorter configured scan intervals remain honored.
- Report unmeasured counts explicitly, label inclusive timings and retain bounded timing/log evidence.
- Reuse the current traversal's full-name class token, read a controller once per pad sample, and defer unused storage scans until a prepared roster needs them. Native performance gains require the next restart measurement; existing complete-pass and frame captures still show spikes.
- Stop probing child APIs on exact native Image/Spacer/TextBlock widgets; keep CheckBox content traversable. Preserve detailed storage ownership-read failures without interpreting empty/unreadable IDs as safe exclusions. September 13 restart observations show stand refresh around 27 ms versus 30 ms previously; recurring frame spikes remain. Rapid-click recovery is user-confirmed and supported by live priority-preservation events; broader input and performance acceptance remains open.
- Add read-only identity fingerprinting and analysis of existing independent frame captures; neither tool records gameplay or proves compatibility.
- Require useful, request-bound completed passes and fresh server readiness rather than treating a sent command or boot banner as success.
- Build matching Workshop/manual archives from one reviewed source/asset contract and exclude user data/developer triggers.
- Correct panel discovery to **Alt+F1** and explain command output in **priority.log**.

The complete isolated Lua/UI and Python suites pass, including server process-ownership checks, final stress health checks and actual dry-run validation. Detailed results, exact baseline failures, hashes and remaining native gates are in the [reliability ledger](docs/reliability-2026-09-11.md). No performance, installation or current-runtime acceptance is implied.

## 0.4.1 — published August 28, 2026

Historical implementation summary, with September audit corrections:

- Added cheaper authority evidence and owned-component lookup routes, an early no-camp exit and Monitoring Stand tree traversal.
- Reduced repeated panel property writes and added headless/controller guards.
- Added `!pwp perf` and `!pwp stand` diagnostics.

Earlier release text overstated the outcome. The tests did not establish that all expensive lookups disappeared, all client clicks became cheap or gameplay was stutter-free. Some profiler rows counted calls without timing them and displayed zero milliseconds. Complete pass cost and external frame captures were missing; nested timing totals overlapped. The earlier headless guard also did not establish that all polling recognized a populated server correctly.

Historical long-session object scans were observed around 36–45 ms, but those observations are not a candidate benchmark or a current-runtime guarantee. Continued periodic stutter, settings loss and UI failures are tracked in the September ledger. The rules/picker pager overlap was not resolved by this release.

The saved August UE4SS log names `c838a8ac`; September's dependency advertised `2281fa31`. Compatibility with the newer runtime does not follow from the August tests.

## 0.4.0

- Added authoritative-server scheduling and client grid/rule synchronization. A client-only installation cannot replace the server mod.
- Changed fence widening to retain higher-priority permissions, addressing a cause implicated in generator and Handiwork/Kindling reports.
- Added restoration routes when disabling scheduling.
- Added temporary-file persistence and validation, reduced several icon lookup/logging paths, adjusted panel drawing and feedback.
- Tightened guild authorization and chat mutation routing, isolated the DarnMenu settings environment and bounded incoming client data.
- Made the developer remote channel opt-in at startup.

Corrections to the original release claims:

- Temporary-file writing was **not** crash-proof: ordinary write/close failures and destructive replacement remained. The statement that “a crash costs nothing” was wrong.
- Retaining a priority in a fence did not prove a Pal actually worked that station or produced output. Generator displacement, manual assignments and research still need native evidence.
- Removing specific icon lookup work did not prove the picker or the whole game could no longer stutter.
- The release lacked protocol negotiation; mixed versions and incomplete synchronization were not fully covered.
- Pager overlap, UI lifecycle risks and restart persistence defects remained.

## 0.3.0

Added optional DarnMenu settings/hotkeys, in-game item names and `tools/pakcheck.py` after an earlier asset packaging error. Hash matching can catch a mismatched artifact; it does not verify a native widget contract.

## 0.2.0

Shipped with a stale pak: only 7 of 21 expected named widgets resolved in the historical test. The asset mismatch was addressed in 0.3.0. Clean-package mounting and widget acceptance remain required for every new release.
