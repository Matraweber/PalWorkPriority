# Dedicated async: next evidence gates — October 9, 2026

Status: proposed checklist only. No new native run, deployment, backend attachment,
or write enablement is authorized by this document. Dedicated/public async defaults
remain OFF. Each gate has its own acceptance; completing an observer does not admit
a writer. Use the isolated fixture and preserve existing local recovery protection.

## Verified starting point

[Guild acceptance](../test-results/server-identity-20261009/guild-acceptance.json),
[raw log](../test-results/server-identity-20261009/guild-identity.log),
[installation manifest](../test-results/server-identity-20261009/guild-installation.json),
and [fingerprints](../test-results/server-identity-20261009/guild-fingerprints.json)
cover the third isolated boot. The original acceptance file indexes the separate runs.

- Eleven samples resolved `PalUtility.GetGroupManager(current_world)`, checked its
  world owner, selected the explicit `GuildMap` key with matching guild `GetId()`,
  and read `IndividualIdArray.IndividualCharacterHandleIds.Items[].HandleId`.
- Target `d2c75eae4e5c0c4c4d24b89b2010b5eb` returned a complete 16-handle roster.
  The target chooses a query; it does not establish authority or destination ownership.
- Current-world/save-manager checks agreed, loaded-world was true, dedicated role
  was 3, and the observed absolute Saved root matched the fixture expectation.
- Every grant remained false. The terminal record reports 11 samples and successful
  timer cancellation. Main observed normal shutdown; the restoration receipt and
  independently inspected filesystem agree that the third fixture was archived,
  original directories restored, and temporary runtime/proxy removed.
- Archived runtime and all six observer Lua/config files match the installation
  manifest. This is disk-file verification, not loaded-memory attestation or a
  byte-for-byte comparison of every restored original file.

The route is accessible on this runtime for this fixture guild. Its 16 handles
are not proof of 16 Pals, active assignments, output, or recovered-priority coverage.
`guild_stability=not_evaluated` is intentional: ordered repeated reads are not an
atomic engine snapshot. No cross-guild mutation or writer lifecycle trial occurred.
Relative Saved strings, if returned on another run, must remain raw observations;
never resolve them against a tool/launcher working directory to grant authority.

## Gate 1 — supplied-world parameter and membership observation

Smallest next native trial: a separate default-off, read-only experiment using the
verified headless route. Reference implementations are
[`dedicated_guild_probe.lua`](../experiments/dedicated_guild_probe.lua),
[`settings_priority_world_lookup.lua`](../experiments/settings_priority_world_lookup.lua),
and [`settings_priority_live_reader.lua`](../experiments/settings_priority_live_reader.lua).
The latter two currently depend on local viewport/player context; do not relax
those checks in place. A new headless reader must supply and reprove its own world.

- [ ] Offline review/test the dedicated reader before installing it. Resolve native
  parameters through declared `GetIndividualCharacterParameterByIstanceID(world,id)`
  using the ORIGINAL reflected `FPalInstanceID` from the selected guild roster.
  Never reconstruct a Lua GUID table for the native const-reference argument,
  enumerate actors to infer ownership, or infer guild membership from a client.
- [ ] Reacquire world/state/instance/save-manager and group-manager ownership before
  and after each resolution; compare parameter identity and group to the requested
  key/guild. Keep wrappers callback-local. A changed or unreadable chain invalidates
  the result, including a non-nil parameter returned before the change.
- [ ] Preserve current identity validation, including the strict nonzero InstanceId
  guard. Do not reinterpret human handles as Pals or weaken validity from formatting
  alone. Classify unavailable/unloaded parameters as unknown, never empty membership.
- [ ] Bound the proposed trial to at most 60 samples, one second apart, with at most
  one selected-handle parameter attempt per sample. Retain existing map/roster bounds;
  overflow or timeout is incomplete. Measure callback duration; a time budget cannot
  preempt a blocking native call. Record only bounded scalar counts/status/reasons.
- [ ] Offline regressions cover a valid member, foreign group, missing parameter,
  duplicate identity, malformed/oversized roster, native failure, reentry, and world,
  owner or identity change during resolution. Native evidence must distinguish cases
  actually exercised from offline cases; never label untested faults native PASS.
- [ ] Native pass requires at least one directly resolved Pal with matching identity,
  group and fresh context, plus normal cancellation/restoration. All-unavailable is
  a useful observed result but does not pass parameter membership.

This gate establishes the parameter route, not full priority recovery admission.
Before admitting recovered priorities, every recovered key needs fresh membership
proof and [`settings_priority_coverage.lua`](../experiments/settings_priority_coverage.lua)
requires a complete current-camp roster with capability sets. Guild count alone
cannot satisfy that check. Missing capability evidence remains unknown; do not
synthesize baselines, drop keys, or bypass `verify_coverage` in startup.

## Gate 2 — dedicated lifecycle and revocation, without backend IO

Use [`settings_startup_lifecycle.lua`](../experiments/settings_startup_lifecycle.lua)
and its epoch contract as the reference. Keep the observer separate from native
writer attachment. Install instrumentation early enough to observe initialization.

- [ ] Record bounded, ordered events for `RegisterLoadMapPreHook/PostHook`,
  `RegisterInitGameStatePreHook/PostHook`, and `RegisterEndPlayPreHook`, with process
  identity, run nonce, epoch and scalar world identity. Reject absent/failed hook
  registration; never substitute an address-only epoch.
- [ ] Demonstrate initialization ordering and normal dedicated shutdown natively.
  Check the actual EndPlay reason: current lifecycle closes for Quit=4; reasons
  0–3 alone do not identify this session. Do not claim shutdown-hook coverage from
  the earlier observer's timer cancellation or Main's normal shutdown alone.
- [ ] Offline tests prove immediate revocation on load/init pre-events, proof loss,
  world/guild change, reentry and explicit close. A late callback cannot reuse a
  revoked token, reacquire authority, or attach a replacement owner.
- [ ] If a controlled world transition is included in a separately approved native
  trial, prove the old epoch is fenced before new-world work and cannot resume.
  Otherwise record transition ordering as still untested natively.
- [ ] Preserve one admission/owner per sidecar lifetime and existing cleanup-once
  semantics. No real writer is needed for this gate; fake-owner tests cover repeated
  close, failed cleanup and retained uncertain ownership. Actual native draining
  remains a later backend integration gate.

A subsequent dedicated authority adapter must be separate and default-off.
[`settings_startup_authority.lua`](../experiments/settings_startup_authority.lua)
deliberately requires local authority and `dedicated=false`; do not loosen it.
The dedicated adapter needs exact configured storage, guild, session and lifecycle
binding with fresh context checks. A matching Saved path alone is insufficient.

## Gate 3 — isolated dedicated native recovery, read-only surface

The existing [`dispatch.hpp`](../experiments/native-draining-bridge/dispatch.hpp)
defaults to `test-results/native-limits-live-20261007/store` and exposes recovery
approval/submission commands. Do not reuse that installed writer by merely changing
the Lua caller. A dedicated recovery trial needs a reviewed server-specific profile
and a command surface that cannot initialize or submit writes.

- [ ] Pin the explicit manual runtime root, expected runtime hash, helper binary,
  source/build manifest, dedicated test storage root and scope. Verify containment
  and absence of redirects; never select a world or destination by enumeration.
  Keep diagnostic output free of credentials and payload dumps.
- [ ] Prepare disposable known journal fixtures offline, with exact nonce-bearing
  bytes, world/guild/stream scope and expected generations/checksums. Native trial
  only reads them. No production migration, startup coordinator attachment, recovery
  approval, initialization or submit route may be reachable through the probe.
- [ ] Review and test the native read-only boundary itself, including rejection of
  write command IDs. Preserve owner exclusion for the scoped read; do not bypass
  the registry to observe files concurrently with a writer.
- [ ] Exercise exact valid recovery, competing slots/generation selection, corrupt
  or truncated records, wrong world/guild/stream, oversized data, missing records,
  access denial, and duplicate ownership. Missing must be distinguished from IO
  failure; neither result permits initialization in this gate.
- [ ] Hash the journal fixture before and after the native read, require exact
  recovered bytes/generation for valid cases, record bounded failures, and verify
  release/cancellation. Archive process/nonce and disk fingerprints together.
  Report precisely which matrix cases ran natively versus only offline.

Read-only recovery may be developed independently of full membership coverage,
but cannot activate recovered settings or confer storage authority. Dedicated
write admission still requires gates 1 and 2 plus full priority coverage and a
reviewed dedicated authority adapter.

## Evidence handoff and later write gates

For each proposed trial, review the concrete files, offline regressions, installer
preflight and stop/restore procedure before a separate native-run decision. Keep
per-run acceptance separate: commands/results, PID/creation time, nonce, target,
runtime/source hashes, bounded log, cancellation, shutdown and restoration evidence.
Do not overwrite earlier observations or promote offline fault tests to live proof.

After these read-only gates, the remaining write-stage checklist is explicit:
complete legacy recovery-set backup/equality checks; both-stream startup fences;
complete priority membership/capability coverage; scoped native owner uniqueness;
fresh authorization around recovery/admission; interrupted/error IO recovery;
pending-write shutdown/world-change drain and uncertain-outcome handling; exact
restart/readback; generation-bound durable remote acknowledgements; and matched
performance measurements. These are later trials, not actions initiated here.

Cross-reference: [async enablement history](async-enablement-2026-10-04.md) and
[release gates](release-gates-2026-10-09.md). Earlier statements that the guild route
was inaccessible/unproved are superseded by the third-boot evidence above only
for route accessibility; authority and writer acceptance remain separate gates.
