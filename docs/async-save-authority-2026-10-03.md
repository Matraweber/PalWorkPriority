# Authority-side save identity observations — October 3, 2026

Read-only follow-up to the client identity probe. No production code or settings
migration changed. The previously checked probe is reused with fresh one-shot
nonces; source and installed hashes are checked before each arm.

## First local-host run

The documented singleplayer macro launched the existing first world. The probe
reported SelectedWorldSaveDirectoryName as 31141b9948fe8b9a8b4cc399974dddf1,
bIsLoadedWorldSaveData=true, and AutoSaveWorldDefaultName empty. Both name/status
reads succeeded; there was no candidate agreement. The production log separately
reported a fresh PWP_READY role=authority/settings=available session.

The selected ID matches exactly one account/world directory containing Level.sav.
Its modification time advanced during the run; this is stronger correlation than
a dormant directory's existence alone. The screenshot shows the existing local
test roster at the stand and the 3114... world prefix. This remains observational
correlation, not permission for the experimental backend to bind real storage.

Evidence: test-results/save-identity-authority-20261003/host-first/ (before world
inventory, identity and production logs, engine log, restart log and acceptance).
Local paths remain in evidence; no account identifier is needed in this report.

## Repeat and return

The second host boot produced the same selected ID and loaded-world=true,
with a fresh role=authority readiness record. The normal macro recorded the old
process 14604 exiting and new process 16044 starting. Evidence is archived under
host-repeat/. This establishes two host boots separated by ONE full process
restart, not two repeated restarts.

A useful negative: at 19:21:22 local time, the repeat probe observed the selected
ID on the Title map while loaded-world=false. It then observed loaded-world=true
on MainWorld5 at 19:21:26. A format-valid directory field is therefore not proof
that its world has loaded or that a writer may bind it.

Return to RAM completed in fresh process 42500. Both identity properties were
empty and loaded-world=false in the client gameplay sample. The corrected
collector found no positive-session gameplay authority readiness. The restart
macro independently verified RAM's expected guild, and the stand was visually
confirmed open with priority numbers. Evidence: client-return/ and summary.json.
All diagnostic controls are DISABLED; installed probe hashes and production Lua
hashes match the original checked installation. The sequence uses process
restarts; it does not exercise host/client transitions within a single process.

Independent review caught an overly broad evidence check: startup session-0
PWP_READY authority must not establish gameplay authority. The collector now
isolates the fresh boot, requires its MainWorld5 boundary and accepts only
positive-session readiness afterward. Original phase logs and initial file-time
observations are retained when regenerating summaries. Both host runs pass;
the client does not. There is no production authority-code change here.

## Implication and remaining limits

Follow-up: [same-process host-to-client evidence](async-save-transition-2026-10-03.md)
now confirms that the selected local ID survives a RAM join. Unlike the fresh
client boot below, a reused game instance retains a valid-looking stale ID.
The experimental probe still refuses to verify identity or select storage.

Reject the assumption that AutoSaveWorldDefaultName is a corroborating GUID on
this runtime. It is empty in the observed host and client runs. The selected
save-directory property is a candidate only on the observed host.

Do not promote the probe's verified=false output. Still required: another local
save, authoritative dedicated-server identity, same-process session switching,
copy/restore policy and robust readiness conditions. Empty client fields do not
prove that every client route lacks an identifier. Recovery absence and global
native singleton enforcement remain separate gates. No stutter measurement or
release-readiness claim follows from these tests.

Collector limitation: its automated check selects the first boot after the saved
log offset; it does not independently correlate PID/nonce or bound readiness to
the probe's FINAL timestamp. Independent manual review supports these three
specific runs. Mtime changes demonstrate disk activity, not by themselves proof
of which save was loaded. Client classification is supported by explicit client
logs and the RAM handshake, not merely absence of an authority marker.
